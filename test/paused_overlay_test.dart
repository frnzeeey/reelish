import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/episode_context.dart';
import 'package:onfeed/src/models/media_details.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/widgets/player/paused_overlay.dart';
import 'package:onfeed/src/widgets/player/player_controls.dart';
import 'package:video_player/video_player.dart';

const _movie = MediaItem(
  id: '157336',
  type: 'movie',
  name: 'The Last Horizon',
  year: '2014',
  rating: '8.4',
  description: 'Explorers chase a signal before the countdown ends.',
  background: 'https://image.tmdb.org/t/p/w1280/backdrop.jpg',
  poster: 'https://image.tmdb.org/t/p/w500/poster.jpg',
);

const _series = MediaItem(
  id: '1399',
  type: 'series',
  name: 'Northern Lights',
  description: 'A family saga across three decades.',
  background: 'https://image.tmdb.org/t/p/w1280/series.jpg',
);

const _episode = EpisodeRef(
  season: 2,
  episode: 4,
  title: 'The Awakening',
  overview: 'Mara finally opens the vault.',
  stillPath: '/still.jpg',
  runtimeMinutes: 48,
);

Widget _overlay(
  ValueNotifier<bool> visible,
  PauseCardContent content, {
  VoidCallback? onPlay,
}) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(
    backgroundColor: Colors.black,
    body: ReelishPausedOverlay(
      visible: visible,
      scrubbing: ValueNotifier(false),
      content: content,
      artworkWidth: 1280,
      onPlay: onPlay ?? () {},
    ),
  ),
);

void main() {
  group('pause screen content', () {
    test('a movie shows its year, genres, length, rating and synopsis', () {
      final content = PauseCardContent.resolve(
        item: _movie,
        details: const MediaDetails(genres: ['Science Fiction', 'Drama', 'X']),
        duration: const Duration(hours: 2, minutes: 49, seconds: 10),
      );
      expect(content.title, 'The Last Horizon');
      expect(content.metadata, ['2014', 'Science Fiction, Drama', '2h 49m']);
      expect(content.rating, '8.4');
      expect(content.synopsis, _movie.description);
      expect(content.artwork, [_movie.background, _movie.poster]);
    });

    test('a movie falls back to the listed runtime and details synopsis', () {
      final content = PauseCardContent.resolve(
        item: const MediaItem(id: '1', type: 'movie', name: 'Quiet'),
        details: const MediaDetails(
          overview: 'From TMDB details.',
          runtimeMinutes: 95,
          rating: '7.25',
        ),
        duration: Duration.zero,
      );
      expect(content.metadata, ['1h 35m']);
      expect(content.synopsis, 'From TMDB details.');
      expect(content.rating, '7.3');
    });

    test('an episode shows its own code, title, length and synopsis', () {
      final content = PauseCardContent.resolve(
        item: _series,
        episode: _episode,
        season: 2,
        episodeNumber: 4,
      );
      expect(content.title, 'Northern Lights');
      expect(content.metadata, ['S02 E04', 'The Awakening', '48 min']);
      expect(content.synopsis, 'Mara finally opens the vault.');
      expect(content.rating, isEmpty);
      // Episode still first, then the series artwork.
      expect(content.artwork, [_episode.still, _series.background]);
    });

    test('an episode without its own synopsis uses the series synopsis', () {
      final content = PauseCardContent.resolve(
        item: _series,
        episode: const EpisodeRef(season: 1, episode: 2, overview: ' null '),
      );
      expect(content.synopsis, 'A family saga across three decades.');
      expect(content.metadata, ['S01 E02']);
    });

    test('before the episode list resolves, the numbers still show', () {
      final content = PauseCardContent.resolve(
        item: _series,
        season: 3,
        episodeNumber: 11,
        duration: const Duration(minutes: 52),
      );
      expect(content.metadata, ['S03 E11', '52 min']);
    });

    test('missing values are left out, never shown as placeholders', () {
      final content = PauseCardContent.resolve(
        item: const MediaItem(
          id: '9',
          type: 'movie',
          name: 'Blank',
          year: 'null',
          rating: '0.0',
          description: 'undefined',
        ),
      );
      expect(content.metadata, isEmpty);
      expect(content.rating, isEmpty);
      expect(content.synopsis, isEmpty);
      expect(content.artwork, isEmpty);
    });

    test('runtime formatting', () {
      expect(PauseCardContent.formatRuntime(const Duration(seconds: 20)), '');
      expect(
        PauseCardContent.formatRuntime(const Duration(minutes: 48)),
        '48 min',
      );
      expect(PauseCardContent.formatRuntime(const Duration(hours: 2)), '2h');
      expect(
        PauseCardContent.formatRuntime(const Duration(minutes: 169)),
        '2h 49m',
      );
    });
  });

  test('the episode list keeps each episode synopsis, still and runtime', () {
    final context = EpisodeContext.fromTmdb(
      [
        {
          'season_number': 2,
          'episode_number': 4,
          'name': 'The Awakening',
          'overview': '  Mara finally opens the vault. ',
          'still_path': '/still.jpg',
          'runtime': 48,
        },
        {'season_number': 2, 'episode_number': 5, 'runtime': null},
      ],
      season: 2,
      episode: 4,
      today: DateTime(2026, 10, 5),
    )!;
    expect(context.current.overview, 'Mara finally opens the vault.');
    expect(
      context.current.still,
      'https://image.tmdb.org/t/p/original/still.jpg',
    );
    expect(context.current.runtimeMinutes, 48);
    expect(context.next?.still, isEmpty);
    expect(context.next?.runtimeMinutes, isNull);
  });

  group('pause screen', () {
    final content = PauseCardContent.resolve(
      item: _series,
      episode: _episode,
      duration: const Duration(minutes: 48),
    );
    // No artwork: these tests never reach the network, and cover the video
    // frame fallback.
    final noArtwork = PauseCardContent(
      title: content.title,
      metadata: content.metadata,
      synopsis: content.synopsis,
    );

    testWidgets('animates in on pause and out on resume', (tester) async {
      tester.view.physicalSize = const Size(1600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final visible = ValueNotifier(false);
      var plays = 0;
      await tester.pumpWidget(
        _overlay(visible, noArtwork, onPlay: () => plays++),
      );
      expect(find.text('PAUSED'), findsNothing);

      visible.value = true;
      await tester.pumpAndSettle();
      expect(find.text('PAUSED'), findsOneWidget);
      expect(find.text('Northern Lights'), findsOneWidget);
      expect(find.text('Mara finally opens the vault.'), findsOneWidget);
      expect(find.bySemanticsLabel('Resume playback'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Resume playback'));
      expect(plays, 1);

      visible.value = false;
      await tester.pump(const Duration(milliseconds: 100));
      // Not tappable while fading out.
      await tester.tap(
        find.bySemanticsLabel('Resume playback'),
        warnIfMissed: false,
      );
      expect(plays, 1);
      await tester.pumpAndSettle();
      expect(find.text('PAUSED'), findsNothing);
    });

    testWidgets('appears at once when motion is reduced', (tester) async {
      final visible = ValueNotifier(false);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: _overlay(visible, noArtwork),
        ),
      );
      visible.value = true;
      await tester.pump();
      await tester.pump();
      expect(find.text('PAUSED'), findsOneWidget);
    });

    for (final (name, size) in [
      ('phone landscape', const Size(740, 360)),
      ('small phone landscape', const Size(640, 320)),
      ('phone portrait', const Size(360, 780)),
      ('tablet landscape', const Size(1280, 800)),
      ('desktop', const Size(1920, 1080)),
      ('picture in picture', const Size(240, 135)),
    ]) {
      testWidgets('fits a $name screen without overlapping', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final visible = ValueNotifier(true);
        await tester.pumpWidget(
          _overlay(
            visible,
            PauseCardContent(
              title: 'An Exceptionally Long Series Title That Keeps Going',
              metadata: const ['S12 E104', 'A Very Long Episode Title Indeed'],
              synopsis: List.filled(30, 'Something happens.').join(' '),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final play = tester.getRect(find.bySemanticsLabel('Resume playback'));
        expect(play.width, greaterThanOrEqualTo(48));
        final title = find.textContaining('Exceptionally');
        if (size.height < 260) {
          // Tiny windows show only the artwork and the play button.
          expect(title, findsNothing);
          return;
        }
        expect(title, findsOneWidget);
        // Very short screens drop the synopsis rather than crowd the controls.
        final synopsis = find.textContaining('Something happens');
        var details = tester.getRect(title);
        if (size.height >= 360) expect(synopsis, findsOneWidget);
        if (synopsis.evaluate().isNotEmpty) {
          details = details.expandToInclude(tester.getRect(synopsis));
        }
        expect(details.overlaps(play), isFalse);
        // Clear of the controls' top and bottom bars.
        expect(details.top, greaterThanOrEqualTo(64));
        expect(details.bottom, lessThanOrEqualTo(size.height - 112));
      });
    }
  });

  testWidgets('controls give the center to the pause screen', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://cdn.example/video.m3u8'),
    );
    addTearDown(controller.dispose);
    controller.value = controller.value.copyWith(
      duration: const Duration(minutes: 100),
      isInitialized: true,
      size: const Size(1920, 1080),
    );
    final pauseScreen = ValueNotifier(false);
    var toggles = 0;
    var settings = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: PlayerControlsOverlay(
            controller: controller,
            title: 'The Show',
            subtitle: 'S2 · E3',
            sourceLabel: '',
            subtitleEnabled: false,
            showAudio: false,
            showSources: false,
            landscapeLocked: true,
            onBack: () {},
            onTogglePlay: () => toggles++,
            onSeekBy: (_) {},
            onSeekTo: (_) {},
            onScrubChanged: (_) {},
            onSubtitles: () {},
            onAudio: () {},
            onSources: () {},
            onSettings: () => settings++,
            onPip: () {},
            onRotate: () {},
            pauseScreen: pauseScreen,
          ),
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('Play'));
    expect(toggles, 1);

    pauseScreen.value = true;
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Play'), warnIfMissed: false);
    expect(toggles, 1);
    // The rest of the controls keep working.
    await tester.tap(find.bySemanticsLabel('Playback settings'));
    expect(settings, 1);
  });
}
