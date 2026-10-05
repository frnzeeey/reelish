import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/episode_context.dart';
import 'package:onfeed/src/models/episode_progress.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/widgets/player/episode_panel.dart';
import 'package:onfeed/src/widgets/player/player_controls.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

final _today = DateTime(2026, 10, 5);

/// Season 1: 10 episodes; season 2: 3 episodes, the last airing next week.
List<EpisodeRef> _series() => [
  for (var e = 1; e <= 10; e++)
    EpisodeRef(
      season: 1,
      episode: e,
      title: 'One $e',
      runtimeMinutes: 47,
      airDate: DateTime(2020, 1, e),
    ),
  for (var e = 1; e <= 3; e++)
    EpisodeRef(
      season: 2,
      episode: e,
      title: 'Two $e',
      overview: e == 1 ? 'A long synopsis. ' * 12 : '',
      airDate: e == 3 ? DateTime(2026, 10, 12) : DateTime(2026, 1, e),
    ),
];

EpisodeContext _at(int season, int episode) => EpisodeContext.fromEpisodes(
  _series(),
  season: season,
  episode: episode,
  today: _today,
)!;

const _show = MediaItem(id: '1396', type: 'series', name: 'Breaking Point');

void main() {
  group('episode navigation', () {
    test('next and previous within a season', () {
      final context = _at(1, 5);
      expect(context.previous?.episode, 4);
      expect(context.next?.episode, 6);
    });

    test('season boundaries: S1 E10 -> S2 E1 and back', () {
      expect((_at(1, 10).next!.season, _at(1, 10).next!.episode), (2, 1));
      final first = _at(2, 1).previous!;
      expect((first.season, first.episode), (1, 10));
    });

    test('first has no previous; unaired and finale have no next', () {
      expect(_at(1, 1).previous, isNull);
      // S2 E3 airs next week: providers cannot have it yet.
      expect(_at(2, 2).next, isNull);
      expect(_at(2, 3).next, isNull);
    });

    test('lists seasons and their episodes', () {
      final context = _at(1, 1);
      expect(context.seasons, [1, 2]);
      expect(context.episodesIn(2).map((e) => e.episode), [1, 2, 3]);
    });

    test('an unlisted episode has no context', () {
      expect(
        EpisodeContext.fromEpisodes(_series(), season: 9, episode: 1),
        isNull,
      );
    });

    test('TMDB parsing keeps a small thumbnail and the full still', () {
      final ref = EpisodeRef.listFromTmdb([
        {
          'season_number': 1,
          'episode_number': 2,
          'still_path': '/a.jpg',
          'air_date': '2020-02-01',
        },
      ]).single;
      expect(ref.thumbnail, 'https://image.tmdb.org/t/p/w300/a.jpg');
      expect(ref.still, 'https://image.tmdb.org/t/p/original/a.jpg');
      expect(ref.airDate, DateTime(2020, 2, 1));
    });
  });

  group('episode progress', () {
    test('watched from 90%, which then restarts from the beginning', () {
      const minute = 60000;
      const half = EpisodeProgress(
        positionMs: 43 * minute,
        durationMs: 100 * minute,
      );
      expect(half.isInProgress, isTrue);
      expect(half.resumeMs, 43 * minute);
      // A few seconds in: resumes there, but is not shown as started.
      const justStarted = EpisodeProgress(
        positionMs: 3000,
        durationMs: 58 * minute,
      );
      expect(justStarted.isInProgress, isFalse);
      expect(justStarted.resumeMs, 3000);
      const done = EpisodeProgress(positionMs: 95, durationMs: 100);
      expect(done.isWatched, isTrue);
      expect(done.resumeMs, 0);
      const unknownLength = EpisodeProgress(positionMs: 5, durationMs: 0);
      expect(unknownLength.fraction, 0);
      expect(unknownLength.resumeMs, 5);
    });

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('each episode keeps its own position', () async {
      final storage = StorageService();
      Future<void> save(int e, int position) => storage.saveEpisodeProgress(
        _show,
        season: 1,
        episode: e,
        positionMs: position,
        durationMs: 1000,
      );
      await save(1, 1000);
      await save(2, 430);
      await save(3, 120);
      await save(2, 450); // Episode 2 again: only its own entry changes.
      final progress = await storage.seriesProgress(_show);
      expect(progress.of(1, 1)?.isWatched, isTrue);
      expect(progress.of(1, 2)?.positionMs, 450);
      expect(progress.of(1, 3)?.positionMs, 120);
      expect(progress.of(1, 4), isNull);
      expect(progress.last, (season: 1, episode: 2));
    });

    test('series are kept apart, and history is unchanged', () async {
      final storage = StorageService();
      const other = MediaItem(id: '1399', type: 'series', name: 'Other');
      await storage.saveEpisodeProgress(
        other,
        season: 1,
        episode: 1,
        positionMs: 10,
        durationMs: 100,
      );
      expect((await storage.seriesProgress(_show)).episodes, isEmpty);
      expect(await storage.history(), isEmpty);
    });

    test('unreadable data is treated as no progress', () async {
      SharedPreferences.setMockInitialValues({
        'onfeed.history.episodes.v1': '{not json',
      });
      expect((await StorageService().seriesProgress(_show)).episodes, isEmpty);
    });
  });

  group('episode panel', () {
    Future<List<Object?>> open(
      WidgetTester tester, {
      required Size size,
      required EpisodeContext context,
      SeriesProgress progress = SeriesProgress.empty,
      List<EpisodeRef>? episodes,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final results = <Object?>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context_) => TextButton(
                onPressed: () async => results.add(
                  await EpisodePanel.show(
                    context_,
                    seriesTitle: 'Breaking Point',
                    episodes: episodes ?? context.episodes,
                    progress: progress,
                    current: context.current,
                    previous: context.previous,
                    next: context.next,
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return results;
    }

    const phone = Size(390, 844);
    const tablet = Size(1280, 800);

    testWidgets('phone: bottom sheet on the current season', (tester) async {
      await open(tester, size: phone, context: _at(2, 2));
      expect(find.byType(DraggableScrollableSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.text('Two 2'), findsOneWidget);
      expect(find.text('One 1'), findsNothing);
      // Marked by a word and an icon as well as color.
      expect(find.text('PLAYING'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp(r'episode 2\. Two 2\..*Playing')),
        findsOneWidget,
      );
    });

    testWidgets('tablet: side panel, the video stays visible', (tester) async {
      await open(tester, size: tablet, context: _at(1, 3));
      expect(find.byType(DraggableScrollableSheet), findsNothing);
      final panel = tester.getRect(find.text('EPISODES'));
      expect(panel.left, greaterThan(tablet.width / 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching seasons and choosing an episode', (tester) async {
      final results = await open(tester, size: tablet, context: _at(1, 3));
      await tester.tap(find.text('Season 2'));
      await tester.pumpAndSettle();
      expect(find.text('Two 1'), findsOneWidget);
      expect(find.text('PLAYING'), findsNothing);

      await tester.tap(find.text('Two 2'));
      await tester.pumpAndSettle();
      expect(results.single, isA<EpisodeRef>());
      final chosen = results.single! as EpisodeRef;
      expect((chosen.season, chosen.episode), (2, 2));
    });

    testWidgets('the playing episode just closes the panel', (tester) async {
      final results = await open(tester, size: tablet, context: _at(1, 3));
      await tester.tap(find.text('One 3'));
      await tester.pumpAndSettle();
      expect(results, [null]);
    });

    testWidgets('an unaired episode cannot be chosen', (tester) async {
      final results = await open(tester, size: tablet, context: _at(2, 1));
      expect(find.textContaining('Airs Oct 12, 2026'), findsOneWidget);
      await tester.tap(find.text('Two 3'));
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(find.text('EPISODES'), findsOneWidget);
    });

    testWidgets('previous and next cross the season boundary', (tester) async {
      final results = await open(tester, size: tablet, context: _at(1, 10));
      expect(find.text('Next · S2 E1'), findsOneWidget);
      await tester.tap(find.text('Next · S2 E1'));
      await tester.pumpAndSettle();
      final next = results.single! as EpisodeRef;
      expect((next.season, next.episode), (2, 1));
    });

    testWidgets('first episode: Previous is disabled', (tester) async {
      await open(tester, size: tablet, context: _at(1, 1));
      final previous = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Previous'),
          matching: find.byType(TextButton),
        ),
      );
      expect(previous.onPressed, isNull);
    });

    testWidgets('shows progress, watched, and remaining time', (tester) async {
      await open(
        tester,
        size: tablet,
        context: _at(1, 3),
        progress: const SeriesProgress(
          episodes: {
            '1:1': EpisodeProgress(positionMs: 2820000, durationMs: 2820000),
            '1:2': EpisodeProgress(positionMs: 1212600, durationMs: 2820000),
            '1:3': EpisodeProgress(positionMs: 60000, durationMs: 2820000),
          },
        ),
      );
      expect(find.text('47 min · Watched'), findsOneWidget);
      expect(find.text('47 min · 27 min left'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('43 percent watched')), findsOne);
    });

    testWidgets('scrolls a far-down current episode into view', (tester) async {
      final long = [
        for (var e = 1; e <= 60; e++)
          EpisodeRef(season: 1, episode: e, title: 'Episode title $e'),
      ];
      final context = EpisodeContext.fromEpisodes(
        long,
        season: 1,
        episode: 52,
        today: _today,
      )!;
      await open(tester, size: phone, context: context, episodes: long);
      final card = find.text('Episode title 52');
      expect(card, findsOneWidget);
      final rect = tester.getRect(card);
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(phone.height));
    });

    testWidgets('long synopses are clamped and can expand', (tester) async {
      await open(tester, size: tablet, context: _at(2, 1));
      final synopsis = find.textContaining('A long synopsis.');
      expect(tester.widget<Text>(synopsis).maxLines, 2);
      await tester.tap(find.bySemanticsLabel('Show full synopsis'));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(synopsis).maxLines, 8);
    });

    for (final (name, size) in [
      ('small phone', const Size(320, 568)),
      ('phone landscape', const Size(740, 360)),
      ('desktop', const Size(1920, 1080)),
    ]) {
      testWidgets('fits a $name with large text', (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.4;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await open(tester, size: size, context: _at(1, 10));
        expect(tester.takeException(), isNull);
        expect(find.text('EPISODES'), findsOneWidget);
      });
    }

    testWidgets('an empty list says so', (tester) async {
      await open(tester, size: phone, context: _at(1, 1), episodes: const []);
      expect(find.text('No episodes are listed for this series.'), findsOne);
    });
  });

  group('player controls', () {
    Future<void> pump(WidgetTester tester, {VoidCallback? onEpisodes}) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = VideoPlayerController.networkUrl(
        Uri.parse('https://cdn.example/video.m3u8'),
      );
      addTearDown(controller.dispose);
      controller.value = controller.value.copyWith(
        duration: const Duration(minutes: 47),
        isInitialized: true,
        size: const Size(1920, 1080),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: PlayerControlsOverlay(
              controller: controller,
              title: 'Breaking Point',
              subtitle: 'S1 · E3',
              sourceLabel: '1080p',
              subtitleEnabled: false,
              showAudio: false,
              showSources: true,
              landscapeLocked: true,
              onBack: () {},
              onTogglePlay: () {},
              onSeekBy: (_) {},
              onSeekTo: (_) {},
              onScrubChanged: (_) {},
              onSubtitles: () {},
              onAudio: () {},
              onSources: () {},
              onEpisodes: onEpisodes,
              onSettings: () {},
              onPip: () {},
              onRotate: () {},
            ),
          ),
        ),
      );
    }

    testWidgets('a movie has no Episodes button', (tester) async {
      await pump(tester);
      expect(find.text('Episodes'), findsNothing);
    });

    testWidgets('a series episode has one, and it opens the panel', (
      tester,
    ) async {
      var opened = 0;
      await pump(tester, onEpisodes: () => opened++);
      await tester.tap(find.bySemanticsLabel(RegExp('^Episodes')));
      expect(opened, 1);
    });
  });
}
