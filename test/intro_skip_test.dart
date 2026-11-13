import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/intro_skip/intro_outro_service.dart';
import 'package:onfeed/src/intro_skip/skip_planner.dart';
import 'package:onfeed/src/intro_skip/skip_segments.dart';
import 'package:onfeed/src/models/playback_settings.dart';

const _key = EpisodeKey('tt0903747', 1, 2);
const _minute = Duration(minutes: 1);
Duration _s(num seconds) => Duration(milliseconds: (seconds * 1000).round());

Map<String, Object?> _segment(
  int startMs,
  int endMs, {
  double confidence = .92,
  int count = 14,
}) => {
  'start_sec': startMs / 1000,
  'end_sec': endMs / 1000,
  'start_ms': startMs,
  'end_ms': endMs,
  'confidence': confidence,
  'submission_count': count,
  'updated_at': '2026-09-12T21:03:17.409Z',
};

/// IntroDB's `/segments` answer, shaped as its docs show.
Map<String, Object?> _response({
  String imdb = 'tt0903747',
  int season = 1,
  int episode = 2,
  Object? intro,
  Object? outro,
  bool noIntro = false,
  bool noOutro = false,
  bool isMovie = false,
}) => {
  'imdb_id': imdb,
  'media_type': isMovie ? 'movie' : 'tv',
  'is_movie': isMovie,
  'season': season,
  'episode': episode,
  'intro': intro,
  'recap': null,
  'outro': outro,
  'post_credits': null,
  'no_intro': noIntro,
  'no_recap': true,
  'no_outro': noOutro,
};

/// Intro 0:30–1:30, outro 44:00–46:30 on a 47-minute stream.
EpisodeSegments _episode({
  double introConfidence = .92,
  int introCount = 14,
  bool outro = true,
}) => EpisodeSegments.fromIntroDb(
  _key,
  _response(
    intro: _segment(
      30000,
      90000,
      confidence: introConfidence,
      count: introCount,
    ),
    outro: outro ? _segment(44 * 60000, 46 * 60000 + 30000) : null,
  ),
)!;

const _length = Duration(minutes: 47);

void main() {
  group('Episode key', () {
    test('only the shape IntroDB accepts', () {
      expect(EpisodeKey.of('tt0903747', 1, 2), _key);
      expect(EpisodeKey.of(' tt12345678 ', 3, 4)?.imdbId, 'tt12345678');
      for (final (id, season, episode) in [
        ('', 1, 1),
        ('0903747', 1, 1),
        ('tt12', 1, 1),
        ('tt0903747x', 1, 1),
        ('tt0903747', 0, 1),
        ('tt0903747', 1, 0),
        ('tt0903747', null, 1),
        ('tt0903747', 1, null),
      ]) {
        expect(EpisodeKey.of(id, season, episode), isNull, reason: id);
      }
    });
  });

  group('IntroDB response', () {
    test('the documented response is read in milliseconds', () {
      final read = _episode();
      expect(read.intro!.start, _s(30));
      expect(read.intro!.end, _s(90));
      expect(read.intro!.confidence, .92);
      expect(read.intro!.submissions, 14);
      expect(read.outro!.start, const Duration(minutes: 44));
    });

    test('an answer about another episode or a movie is never used', () {
      for (final response in [
        _response(imdb: 'tt0000001', intro: _segment(0, 60000)),
        _response(season: 2, intro: _segment(0, 60000)),
        _response(episode: 3, intro: _segment(0, 60000)),
        _response(isMovie: true, intro: _segment(0, 60000)),
      ]) {
        expect(EpisodeSegments.fromIntroDb(_key, response), isNull);
      }
      expect(EpisodeSegments.fromIntroDb(_key, 'nope'), isNull);
    });

    test('malformed or impossible segments are dropped, the rest kept', () {
      Map<String, Object?> bad(Map<String, Object?> change) => {
        ..._segment(30000, 90000),
        ...change,
      };
      for (final segment in [
        bad({'start_ms': '30000'}),
        bad({'end_ms': null}),
        bad({'start_ms': -1}),
        bad({'end_ms': 30000}), // empty
        bad({'end_ms': 32000}), // 2 s: too short
        bad({'end_ms': 30000 + 6 * 60000}), // 6 min intro: too long
        bad({'confidence': 1.5}),
        bad({'confidence': -.1}),
        bad({'submission_count': 2.5}),
      ]) {
        final read = EpisodeSegments.fromIntroDb(
          _key,
          _response(intro: segment, outro: _segment(2640000, 2790000)),
        )!;
        expect(read.intro, isNull, reason: '$segment');
        expect(read.outro, isNotNull);
      }
    });

    test('a confirmed absence wins over a stray segment', () {
      final read = EpisodeSegments.fromIntroDb(
        _key,
        _response(intro: _segment(0, 60000), noIntro: true),
      )!;
      expect(read.intro, isNull);
    });
  });

  group('Segments for the playing stream', () {
    test('a segment that cannot belong to this stream is dropped', () {
      final full = _episode();
      expect(full.forStream(_length).intro, isNotNull);
      expect(full.forStream(_length).outro, isNotNull);
      // Another cut: a 6-minute stream cannot have its outro at 44 min.
      final short = full.forStream(const Duration(minutes: 6));
      expect(short.outro, isNull);
      // An intro ending after half the stream is not this stream's intro.
      expect(
        full.forStream(const Duration(minutes: 2, seconds: 50)).isEmpty,
        isTrue,
        reason: 'shorter than any episode',
      );
      final late = EpisodeSegments(
        key: _key,
        intro: SkipSegment(
          kind: SkipKind.intro,
          start: const Duration(minutes: 20),
          end: const Duration(minutes: 25),
          confidence: 1,
          submissions: 9,
        ),
      );
      expect(late.forStream(_length).intro, isNull);
      // An outro running past the end.
      expect(full.forStream(const Duration(minutes: 45)).outro, isNull);
      // Unknown duration: nothing.
      expect(full.forStream(Duration.zero).isEmpty, isTrue);
    });

    test('overlapping intro and outro are contradictory: neither is used', () {
      final overlapping = EpisodeSegments(
        key: _key,
        intro: SkipSegment(
          kind: SkipKind.intro,
          start: Duration.zero,
          end: const Duration(minutes: 4),
          confidence: 1,
          submissions: 5,
        ),
        outro: SkipSegment(
          kind: SkipKind.outro,
          start: const Duration(minutes: 3),
          end: const Duration(minutes: 7),
          confidence: 1,
          submissions: 5,
        ),
      );
      expect(overlapping.forStream(const Duration(minutes: 7)).isEmpty, isTrue);
    });
  });

  group('Planner', () {
    late DateTime now;
    late SkipPlanner planner;

    SkipPlan at(
      Duration position, {
      bool playing = true,
      bool buffering = false,
      bool ready = true,
      Duration duration = _length,
    }) => planner.update(
      position: position,
      duration: duration,
      playing: playing,
      buffering: buffering,
      ready: ready,
    );

    setUp(() {
      now = DateTime.utc(2026, 11, 13, 20);
      planner = SkipPlanner(
        introMode: SkipMode.auto,
        outroMode: SkipMode.button,
        clock: () => now,
      );
    });

    test('1. the intro is skipped once as it starts; the outro offered', () {
      planner.setSegments(_episode());
      expect(at(_s(10)), SkipPlan.none);
      expect(at(_s(30.2)).seekTo, _s(90));
      // While the seek lands, nothing else happens.
      expect(at(_s(31)), SkipPlan.none);
      expect(at(_s(90.1)), SkipPlan.none);
      expect(
        at(const Duration(minutes: 44, seconds: 2)).offer?.kind,
        SkipKind.outro,
      );
      expect(at(const Duration(minutes: 44, seconds: 2)).seekTo, isNull);
      expect(at(const Duration(minutes: 46, seconds: 40)), SkipPlan.none);
    });

    test('2. intro only: no outro offer', () {
      planner.setSegments(_episode(outro: false));
      expect(at(_s(40)).seekTo, _s(90));
      expect(at(const Duration(minutes: 44, seconds: 2)), SkipPlan.none);
    });

    test('3/4/13. no, invalid or failed data: normal playback', () {
      planner.setSegments(EpisodeSegments.none(_key));
      expect(at(_s(40)), SkipPlan.none);
      final planner2 = SkipPlanner(
        introMode: SkipMode.auto,
        outroMode: SkipMode.auto,
      );
      expect(
        planner2.update(
          position: _s(40),
          duration: _length,
          playing: true,
          buffering: false,
          ready: true,
        ),
        SkipPlan.none,
        reason: 'no data at all yet',
      );
    });

    test('5. resuming inside the intro (Continue watching) skips it', () {
      planner.setSegments(_episode());
      // The resume seek is the player's own, not reported as the viewer's.
      expect(at(_s(55)).seekTo, _s(90));
    });

    test('6. seeking into the intro: watched on purpose, button only', () {
      planner.setSegments(_episode());
      planner.userSeeked(_s(45));
      final plan = at(_s(45));
      expect(plan.seekTo, isNull);
      expect(plan.offer?.kind, SkipKind.intro);
      expect(at(_s(50)).seekTo, isNull);
    });

    test('7. seeking past the intro: nothing', () {
      planner.setSegments(_episode());
      planner.userSeeked(const Duration(minutes: 5));
      expect(at(const Duration(minutes: 5)), SkipPlan.none);
    });

    test('8. paused in the intro: button, then the skip on resume', () {
      planner.setSegments(_episode());
      final paused = at(_s(40), playing: false);
      expect(paused.seekTo, isNull);
      expect(paused.offer?.kind, SkipKind.intro);
      expect(at(_s(40)).seekTo, _s(90));
    });

    test('9. a seek by the viewer during a skip takes over', () {
      planner.setSegments(_episode());
      expect(at(_s(31)).seekTo, _s(90));
      planner.userSeeked(_s(10));
      // Back before the intro: watching again, so it may be skipped again.
      expect(at(_s(10)), SkipPlan.none);
      expect(at(_s(31)).seekTo, _s(90));
    });

    test('10. buffering or not ready: no skip', () {
      planner.setSegments(_episode());
      expect(at(_s(40), buffering: true).seekTo, isNull);
      expect(at(_s(40), ready: false), SkipPlan.none);
      expect(at(_s(40)).seekTo, _s(90));
    });

    test('12. a source or engine switch does not skip twice', () {
      planner.setSegments(_episode());
      expect(at(_s(31)).seekTo, _s(90));
      // The new engine restores the position after the intro.
      expect(at(_s(90.5), ready: false), SkipPlan.none);
      expect(at(_s(91)), SkipPlan.none);
    });

    test('14. late data: used only while its segment still plays', () {
      expect(at(_s(40)), SkipPlan.none);
      planner.setSegments(_episode());
      expect(at(_s(70)).seekTo, _s(90), reason: 'still inside: forward');
      final late = SkipPlanner(
        introMode: SkipMode.auto,
        outroMode: SkipMode.auto,
        clock: () => now,
      )..setSegments(_episode());
      expect(
        late.update(
          position: const Duration(minutes: 3),
          duration: _length,
          playing: true,
          buffering: false,
          ready: true,
        ),
        SkipPlan.none,
        reason: 'past it: never a seek back',
      );
    });

    test('14b. a seek made before the data arrived still counts', () {
      planner.userSeeked(_s(45));
      planner.setSegments(_episode());
      expect(at(_s(46)).seekTo, isNull);
    });

    test('16. disposed: nothing', () {
      planner.setSegments(_episode());
      planner.dispose();
      expect(at(_s(40)), SkipPlan.none);
      expect(planner.skip(_episode().intro!), isNull);
    });

    test('17/18. an unusual duration or another cut: nothing applied', () {
      planner.setSegments(_episode());
      expect(at(_s(40), duration: const Duration(minutes: 2)), SkipPlan.none);
      // A 2:50 intro end on a 5-minute stream is past its middle.
      final odd =
          SkipPlanner(introMode: SkipMode.auto, outroMode: SkipMode.auto)
            ..setSegments(
              EpisodeSegments(
                key: _key,
                intro: SkipSegment(
                  kind: SkipKind.intro,
                  start: Duration.zero,
                  end: const Duration(minutes: 2, seconds: 50),
                  confidence: 1,
                  submissions: 9,
                ),
              ),
            );
      expect(
        odd.update(
          position: _s(20),
          duration: const Duration(minutes: 5),
          playing: true,
          buffering: false,
          ready: true,
        ),
        SkipPlan.none,
      );
    });

    test('weak data offers the button and never seeks on its own', () {
      planner.setSegments(_episode(introConfidence: .6));
      final plan = at(_s(40));
      expect(plan.seekTo, isNull);
      expect(plan.offer?.kind, SkipKind.intro);
      planner = SkipPlanner(introMode: SkipMode.auto, outroMode: SkipMode.off)
        ..setSegments(_episode(introCount: 1));
      expect(at(_s(40)).seekTo, isNull, reason: 'one submission');
      planner = SkipPlanner(introMode: SkipMode.auto, outroMode: SkipMode.off)
        ..setSegments(_episode(introConfidence: .3));
      expect(at(_s(40)), SkipPlan.none, reason: 'too weak even to offer');
    });

    test('the button skips, once, and only while the segment plays', () {
      planner = SkipPlanner(
        introMode: SkipMode.button,
        outroMode: SkipMode.button,
        clock: () => now,
      )..setSegments(_episode());
      final offer = at(_s(40)).offer!;
      expect(at(_s(40)).seekTo, isNull, reason: 'button mode never seeks');
      expect(planner.skip(offer), _s(90));
      expect(planner.skip(offer), isNull, reason: 'a skip is under way');
    });

    test('a skip that never lands is given up, not repeated', () {
      planner.setSegments(_episode());
      expect(at(_s(31)).seekTo, _s(90));
      now = now.add(SkipPlanner.seekTimeout + const Duration(seconds: 1));
      // The position did not move: the intro is not skipped again.
      expect(at(_s(32)).seekTo, isNull);
      expect(at(_s(32)).offer?.kind, SkipKind.intro);
    });

    test(
      'outro: automatic when chosen; the target stays inside the stream',
      () {
        planner =
            SkipPlanner(
              introMode: SkipMode.off,
              outroMode: SkipMode.auto,
              clock: () => now,
            )..setSegments(
              EpisodeSegments(
                key: _key,
                outro: SkipSegment(
                  kind: SkipKind.outro,
                  start: const Duration(minutes: 44),
                  end: const Duration(minutes: 47, seconds: 3),
                  confidence: .9,
                  submissions: 4,
                ),
              ),
            );
        expect(at(_s(40)), SkipPlan.none, reason: 'intros off');
        expect(at(const Duration(minutes: 44, seconds: 1)).seekTo, _length);
      },
    );

    test('Watch Party: no automatic skip, the button stays', () {
      planner = SkipPlanner(
        introMode: SkipMode.auto,
        outroMode: SkipMode.auto,
        allowAutomatic: false,
      )..setSegments(_episode());
      final plan = at(_s(40));
      expect(plan.seekTo, isNull);
      expect(plan.offer?.kind, SkipKind.intro);
    });

    test('off: nothing at all', () {
      planner = SkipPlanner(introMode: SkipMode.off, outroMode: SkipMode.off)
        ..setSegments(_episode());
      expect(at(_s(40)), SkipPlan.none);
      expect(at(const Duration(minutes: 45)), SkipPlan.none);
    });
  });

  group('Service', () {
    late Directory dir;
    late DateTime now;
    late List<Uri> asked;
    late Future<http.Response> Function(http.Request) answer;

    IntroOutroService service() => IntroOutroService(
      client: MockClient((request) {
        asked.add(request.url);
        return answer(request);
      }),
      filesDirectory: () async => dir,
      clock: () => now,
    );

    http.Response ok(Object body) => http.Response(jsonEncode(body), 200);

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('introdb_test');
      now = DateTime.utc(2026, 11, 13, 20);
      asked = [];
      answer = (_) async => ok(
        _response(
          intro: _segment(30000, 90000),
          outro: _segment(2640000, 2790000),
        ),
      );
    });

    tearDown(() async {
      for (var attempt = 0; await dir.exists(); attempt++) {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          if (attempt >= 20) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });

    test('asks IntroDB the documented question, once', () async {
      final s = service();
      final read = await s.segmentsFor(_key);
      expect(read.intro?.end, _s(90));
      expect(
        asked.single.toString(),
        'https://api.introdb.app/segments?imdb_id=tt0903747&season=1&episode=2',
      );
      await s.segmentsFor(_key);
      expect(asked, hasLength(1), reason: 'memory');
      await s.flush();
      // A new launch reads it from disk.
      final relaunched = service();
      expect((await relaunched.segmentsFor(_key)).intro?.end, _s(90));
      expect(asked, hasLength(1));
    });

    test('simultaneous requests share one', () async {
      final gate = Completer<void>();
      final inner = answer;
      answer = (request) async {
        await gate.future;
        return inner(request);
      };
      final s = service();
      final a = s.segmentsFor(_key), b = s.segmentsFor(_key);
      gate.complete();
      await Future.wait([a, b]);
      expect(asked, hasLength(1));
    });

    test('a miss is kept for a day; found data for a week', () async {
      answer = (_) async => ok(_response());
      final s = service();
      expect((await s.segmentsFor(_key)).isEmpty, isTrue);
      await s.segmentsFor(_key);
      expect(asked, hasLength(1));
      now = now.add(IntroOutroService.missingTtl + _minute);
      await s.segmentsFor(_key);
      expect(asked, hasLength(2), reason: 'may have been timed since');
    });

    test('failures are not cached, and not retried at once', () async {
      for (final failure in <Future<http.Response> Function(http.Request)>[
        (_) async => http.Response('{"error":"Rate limit reached"}', 429),
        (_) async => http.Response('oops', 500),
        (_) async => throw const SocketException('offline'),
        (_) async => http.Response('not json', 200),
        (_) async =>
            http.Response('x' * (IntroOutroService.maxResponseBytes + 1), 200),
      ]) {
        asked.clear();
        answer = failure;
        final s = service();
        expect((await s.segmentsFor(_key)).isEmpty, isTrue);
        await s.segmentsFor(_key);
        expect(asked, hasLength(1), reason: 'cooldown');
        now = now.add(IntroOutroService.failureCooldown + _minute);
        answer = (_) async => ok(_response(intro: _segment(30000, 90000)));
        expect((await s.segmentsFor(_key)).intro, isNotNull);
        now = DateTime.utc(2026, 11, 13, 20);
        // The last answer is still being written; the next case must start
        // with an empty cache, not find it.
        await s.flush();
        await dir.delete(recursive: true);
        await dir.create();
      }
    });

    test('a redirect is not followed', () async {
      answer = (request) async {
        expect(request.followRedirects, isFalse);
        return http.Response(
          '',
          302,
          headers: {'location': 'https://evil.example/'},
        );
      };
      expect((await service().segmentsFor(_key)).isEmpty, isTrue);
    });

    test('an answer about another episode is kept as nothing', () async {
      answer = (_) async =>
          ok(_response(episode: 9, intro: _segment(0, 60000)));
      final s = service();
      expect((await s.segmentsFor(_key)).isEmpty, isTrue);
      await s.segmentsFor(_key);
      expect(asked, hasLength(1));
    });

    test('an unreadable cache file is a cold cache', () async {
      await File('${dir.path}/introdb_segments.v1.json').writeAsString('{[');
      expect((await service().segmentsFor(_key)).intro, isNotNull);
    });
  });

  group('Settings', () {
    test('saves from before skipping existed get the defaults', () {
      final old = PlaybackSettings.fromJson({'touchGestures': false});
      expect(old.introSkip, SkipMode.auto);
      expect(old.outroSkip, SkipMode.button);
      expect(old.usesIntroDb, isTrue);
    });

    test('choices survive a round trip; unknown values default', () {
      final chosen = const PlaybackSettings().copyWith(
        introSkip: SkipMode.button,
        outroSkip: SkipMode.off,
      );
      final read = PlaybackSettings.fromJson(
        jsonDecode(jsonEncode(chosen.toJson())) as Map<String, dynamic>,
      );
      expect(read.introSkip, SkipMode.button);
      expect(read.outroSkip, SkipMode.off);
      expect(
        PlaybackSettings.fromJson({'introSkip': 'always'}).introSkip,
        SkipMode.auto,
      );
      expect(
        const PlaybackSettings()
            .copyWith(introSkip: SkipMode.off, outroSkip: SkipMode.off)
            .usesIntroDb,
        isFalse,
      );
    });
  });
}
