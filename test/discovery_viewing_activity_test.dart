import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/discovery/discovery_data.dart';
import 'package:onfeed/src/discovery/viewing_activity.dart';
import 'package:onfeed/src/models/media_item.dart';

const _movie = MediaItem(
  id: '10',
  type: 'movie',
  name: 'Arrival',
  genreIds: [878, 18],
);
const _series = MediaItem(
  id: '20',
  type: 'series',
  name: 'Dark',
  genreIds: [10765, 9648],
);

const _hour = 60 * 60 * 1000;
final _t0 = DateTime.utc(2026, 1, 1);

TitleActivity? _watch(
  TitleActivity? previous,
  double share, {
  MediaItem item = _movie,
  int durationMs = 2 * _hour,
  DateTime? at,
  ({int season, int episode})? episode,
}) => TitleActivity.record(
  previous,
  item,
  positionMs: (share * durationMs).round(),
  durationMs: durationMs,
  episode: episode,
  at: at ?? _t0,
);

void main() {
  group('TitleActivity.record', () {
    test('a failed or sampled start never counts', () {
      expect(_watch(null, 0), isNull);
      // 60 s of a two-hour film: under the minimum.
      expect(
        TitleActivity.record(
          null,
          _movie,
          positionMs: 60 * 1000,
          durationMs: 2 * _hour,
          at: _t0,
        ),
        isNull,
      );
    });

    test('distinguishes in progress, mostly watched and completed', () {
      final started = _watch(null, .3)!;
      expect(started.status(now: _t0), ViewingStatus.inProgress);
      final most = _watch(started, .7)!;
      expect(most.status(now: _t0), ViewingStatus.mostlyWatched);
      final done = _watch(most, .95)!;
      expect(done.status(now: _t0), ViewingStatus.completed);
      expect(done.completions, 1);
      expect(done.finished, isTrue);
      // More saves at the end of the same viewing do not count again.
      expect(_watch(done, .99)!.completions, 1);
    });

    test('watching again from the start is a rewatch', () {
      var entry = _watch(null, .95)!;
      entry = _watch(entry, .05)!;
      expect(entry.completions, 1, reason: 'restarted, not yet finished');
      entry = _watch(entry, .5)!;
      entry = _watch(entry, .92)!;
      expect(entry.completions, 2);
      expect(entry.status(now: _t0), ViewingStatus.rewatched);
    });

    test('left early and not returned to is abandoned', () {
      final entry = _watch(null, .1)!;
      expect(entry.status(now: _t0), ViewingStatus.inProgress);
      expect(
        entry.status(now: _t0.add(const Duration(days: 30))),
        ViewingStatus.abandoned,
      );
      // A title most of the way through is never abandoned.
      expect(
        _watch(null, .7)!.status(now: _t0.add(const Duration(days: 300))),
        ViewingStatus.mostlyWatched,
      );
    });

    test('an unknown length counts as started, never finished', () {
      final entry = TitleActivity.record(
        null,
        _movie,
        positionMs: 3 * _hour,
        durationMs: 0,
        at: _t0,
      )!;
      expect(entry.completions, 0);
      expect(entry.share, 0);
    });

    test('series count finished episodes', () {
      // A save without an episode (the series-wide history entry) is
      // ignored; the episode's own save is what counts.
      expect(_watch(null, .9, item: _series), isNull);
      var entry = _watch(
        null,
        .95,
        item: _series,
        episode: (season: 1, episode: 1),
      )!;
      expect(entry.status(now: _t0), ViewingStatus.completed);
      for (var episode = 2; episode <= 3; episode++) {
        entry = _watch(
          entry,
          .95,
          item: _series,
          episode: (season: 1, episode: episode),
        )!;
      }
      expect(entry.completedEpisodes, 3);
      expect(entry.status(now: _t0), ViewingStatus.rewatched);
    });

    test('only meaningful changes are worth saving', () {
      final a = _watch(null, .31)!;
      final b = _watch(a, .33)!;
      expect(a.meaningfullyDifferent(b, now: _t0), isFalse);
      final c = _watch(b, .45)!;
      expect(b.meaningfullyDifferent(c, now: _t0), isTrue);
    });
  });

  group('persisted shapes', () {
    test('activity and feedback survive a round trip', () {
      var data = DiscoveryData.empty
          .withActivity(
            _watch(null, .95, item: _series, episode: (season: 2, episode: 3))!,
          )
          .withActivity(_watch(null, .95)!)
          .withFeedback(
            TitleFeedback.of(FeedbackKind.notInterested, _movie, _t0),
          )
          .withFavoriteGenres([878, 878, 18])
          .seeded();
      data = DiscoveryData.fromJson(data.toJson());
      expect(data.activity.keys, ['series:20', 'movie:10']);
      expect(data.activity['series:20']!.episodes, {'2:3': .95});
      expect(data.activity['movie:10']!.completions, 1);
      expect(data.activity['movie:10']!.genreIds, [878, 18]);
      expect(data.feedback['movie:10']!.kind, FeedbackKind.notInterested);
      expect(data.favoriteGenres, [878, 18]);
      expect(data.seededFromHistory, isTrue);
    });

    test('unreadable entries are skipped, not fatal', () {
      final data = DiscoveryData.fromJson({
        'activity': [
          'junk',
          {'type': 'game', 'id': '1'},
          {
            'type': 'movie',
            'id': '5',
            'name': 'Ok',
            'first': '2026-01-01T00:00:00Z',
            'last': '2026-01-02T00:00:00Z',
            'share': 7,
          },
        ],
        'feedback': [
          {'kind': 'nope'},
        ],
      });
      expect(data.activity.keys, ['movie:5']);
      expect(data.activity['movie:5']!.share, 1.0);
      expect(data.feedback, isEmpty);
      expect(DiscoveryData.fromJson('not a map').activity, isEmpty);
    });

    test('reset keeps picked genres and the history mark', () {
      final data = DiscoveryData.empty
          .withActivity(_watch(null, .5)!)
          .withFavoriteGenres([35])
          .seeded()
          .reset();
      expect(data.activity, isEmpty);
      expect(data.favoriteGenres, [35]);
      expect(data.seededFromHistory, isTrue);
    });

    test('activity is bounded, oldest first out', () {
      var data = DiscoveryData.empty;
      for (var i = 0; i < DiscoveryData.maxActivity + 5; i++) {
        data = data.withActivity(
          _watch(
            null,
            .5,
            item: MediaItem(id: '$i', type: 'movie', name: 'M$i'),
          )!,
        );
      }
      expect(data.activity.length, DiscoveryData.maxActivity);
      expect(data.activity.containsKey('movie:0'), isFalse);
      expect(data.activity.containsKey('movie:304'), isTrue);
    });
  });
}
