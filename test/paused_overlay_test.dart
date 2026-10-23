import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/episode_context.dart';
import 'package:onfeed/src/models/media_details.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
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
  ThemeData? theme,
}) => MaterialApp(
  theme: theme ?? ThemeData.dark(),
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
    expect(context.current.still, 'https://image.tmdb.org/t/p/w1280/still.jpg');
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

  group('pause screen balance', () {
    const movie = PauseCardContent(
      title: 'Avengers: Infinity War',
      metadata: ['2018', 'Adventure, Action', '2h 29m'],
      rating: '7.6',
      synopsis:
          'With the universe at stake, a team of unlikely heroes must stop '
          'a warlord from collecting six stones that would let him reshape '
          'reality, whatever the cost to themselves and everyone they love.',
    );

    Future<({Rect play, Rect title, Rect details, Size size})> layout(
      WidgetTester tester,
      Size logical, {
      double cutoutLeft = 0,
      DeviceCapabilities device = const DeviceCapabilities(),
    }) async {
      tester.view.physicalSize = logical;
      tester.view.devicePixelRatio = 1;
      tester.view.padding = FakeViewPadding(left: cutoutLeft);
      addTearDown(tester.view.reset);
      DeviceCapabilities.debugOverride = device;
      addTearDown(
        () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
      );
      // In the app's font: the test font draws every letter a full square
      // wide, which would wrap and cut text that fits in Montserrat.
      await tester.runAsync(() async {
        final loader = FontLoader('Montserrat');
        for (final weight in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
          loader.addFont(
            rootBundle.load('assets/fonts/Montserrat-$weight.ttf'),
          );
        }
        await loader.load();
      });
      await tester.pumpWidget(
        _overlay(
          ValueNotifier(true),
          movie,
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'Montserrat',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final title = tester.getRect(find.text(movie.title));
      final details = title
          .expandToInclude(
            tester.getRect(find.textContaining('2018', findRichText: true)),
          )
          .expandToInclude(
            tester.getRect(find.textContaining('With the universe')),
          );
      return (
        play: tester.getRect(find.bySemanticsLabel('Resume playback')),
        title: title,
        details: details,
        size: logical,
      );
    }

    testWidgets('a phone with a cutout gives the details real room', (
      tester,
    ) async {
      // 2400 by 1080 at 2.75: 873 by 393, with a 110-wide camera cutout.
      // The details used to end 32 px before the centered button: about
      // 230 px, which broke the title and cut off the rating.
      final r = await layout(tester, const Size(873, 393), cutoutLeft: 110);
      expect(r.details.width, greaterThan(300));
      // The whole details line shows, rating included: nothing is cut off.
      final details = tester.renderObject<RenderParagraph>(
        find.textContaining('7.6', findRichText: true),
      );
      expect(details.didExceedMaxLines, isFalse);
      // A clear gap between the text and the button, which moved right.
      expect(r.play.left - r.details.right, greaterThanOrEqualTo(40));
      expect(r.play.center.dx, greaterThan((110 + 873) / 2));
      expect(r.play.right, lessThanOrEqualTo(873));
    });

    testWidgets('large screens keep the button centered and the text grown', (
      tester,
    ) async {
      final desktop = await layout(tester, const Size(1536, 807));
      expect(desktop.play.center.dx, closeTo(1536 / 2, .5));
      expect(desktop.details.right, lessThan(desktop.play.left));
      final ultrawide = await layout(tester, const Size(3440, 1400));
      expect(ultrawide.play.center.dx, closeTo(3440 / 2, .5));
      // Text grows with the screen instead of staying desktop-sized.
      expect(ultrawide.title.height, greaterThan(desktop.title.height));
      expect(ultrawide.play.width, greaterThan(desktop.play.width));
    });

    testWidgets('Windows keeps the normal edges, not the TV-safe ones', (
      tester,
    ) async {
      // Windows shares the TV interface but not a TV's cropped edges.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final r = await layout(
        tester,
        const Size(1280, 720),
        device: const DeviceCapabilities(
          hasTouchscreen: false,
          supportsPictureInPicture: false,
        ),
      );
      expect(DeviceCapabilities.usesTvLayout, isTrue);
      expect(r.details.left, PlayerControlsLayout.contentEdge(tv: false));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('on TV the text stays inside the overscan-safe area', (
      tester,
    ) async {
      // A 1920 by 1080 TV at 2x is 960 by 540; TVs may crop about 5%.
      final r = await layout(
        tester,
        const Size(960, 540),
        device: const DeviceCapabilities(
          isTelevision: true,
          hasTouchscreen: false,
        ),
      );
      expect(r.details.left, greaterThanOrEqualTo(960 * .05));
      expect(r.details.top, greaterThanOrEqualTo(540 * .05));
      expect(r.details.bottom, lessThanOrEqualTo(540 * .95));
    });
  });

  testWidgets('on TV the controls stay inside the overscan-safe area', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(960, 540);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
      hasTouchscreen: false,
    );
    addTearDown(
      () => DeviceCapabilities.debugOverride = const DeviceCapabilities(),
    );
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://cdn.example/video.m3u8'),
    );
    addTearDown(controller.dispose);
    controller.value = controller.value.copyWith(
      duration: const Duration(minutes: 100),
      isInitialized: true,
      size: const Size(1920, 1080),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: PlayerControlsOverlay(
            controller: controller,
            title: 'The Show',
            subtitle: 'S2 · E3',
            sourceLabel: '1080p',
            subtitleEnabled: false,
            showAudio: true,
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
            onSettings: () {},
            onPip: null,
            onRotate: null,
          ),
        ),
      ),
    );
    final back = tester.getRect(find.bySemanticsLabel('Back'));
    final settings = tester.getRect(
      find.bySemanticsLabel('Playback settings').first,
    );
    expect(back.left, greaterThanOrEqualTo(960 * .05 - 1));
    expect(back.top, greaterThanOrEqualTo(540 * .05 - 1));
    expect(settings.right, lessThanOrEqualTo(960 * .95 + 1));
    final audio = tester.getRect(find.text('Audio').first);
    expect(audio.bottom, lessThanOrEqualTo(540 * .95 + 1));
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
