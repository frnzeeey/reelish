import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/account/account_api.dart';
import 'package:onfeed/src/analytics/analytics_service.dart';
import 'package:onfeed/src/models/app_update.dart';
import 'package:onfeed/src/models/media_details.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/app_information_screens.dart';
import 'package:onfeed/src/screens/credits_screen.dart';
import 'package:onfeed/src/screens/first_run_consent_screen.dart';
import 'package:onfeed/src/screens/legal_information_screen.dart';
import 'package:onfeed/src/screens/playback_settings_screen.dart';
import 'package:onfeed/src/screens/help_support_screen.dart';
import 'package:onfeed/src/screens/home_screen.dart';
import 'package:onfeed/src/screens/library_screen.dart';
import 'package:onfeed/src/screens/media_details_screen.dart';
import 'package:onfeed/src/screens/plugins_screen.dart';
import 'package:onfeed/src/screens/watch_party/join_party_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/media_catalog_rules.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/support/support_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/screens/tv/tv_details_screen.dart';
import 'package:onfeed/src/watch_party/party_models.dart';
import 'package:onfeed/src/widgets/settings/settings_components.dart';
import 'package:onfeed/src/widgets/soft_glass_dock.dart';
import 'package:onfeed/src/widgets/tv/tv_focus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The journeys a first-time viewer takes, on the real Home: getting around
/// with Back, searching, playing with nothing installed, and finding Watch
/// Party on each interface.
const _movie = MediaItem(
  id: '8',
  type: 'movie',
  name: 'The title',
  year: '2021',
);
const _series = MediaItem(id: '7', type: 'series', name: 'Show', year: '2020');

class _FakeTmdb extends TmdbService {
  @override
  Future<MediaDetails> details(
    MediaItem item, {
    bool forceRefresh = false,
    void Function(MediaDetails)? onRevalidated,
  }) async => const MediaDetails(overview: 'A plot.', genres: ['Drama']);

  @override
  Future<List<Map<String, dynamic>>> seasons(
    MediaItem item, {
    bool forceRefresh = false,
  }) async => [
    {'season_number': 1, 'name': 'Season 1'},
  ];

  @override
  Future<List<Map<String, dynamic>>> episodes(
    MediaItem item,
    int season, {
    bool forceRefresh = false,
  }) async => [
    {'episode_number': 1, 'name': 'First', 'air_date': '2020-01-01'},
  ];
}

void main() {
  late Directory cacheRoot;
  late AccentSettingsController accent;
  late MockClient client;
  late List<Uri> requests;

  setUp(() async {
    cacheRoot = await Directory.systemTemp.createTemp('reelish-ux-test-');
    SharedPreferences.setMockInitialValues({});
    StorageService.debugResetWrites();
  });

  tearDown(() async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities();
    for (var attempt = 0; await cacheRoot.exists(); attempt++) {
      try {
        await cacheRoot.delete(recursive: true);
      } on FileSystemException {
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  String daysAgo(int days) => MediaFreshnessRules.tmdbDate(
    DateTime.now().toUtc().subtract(Duration(days: days)),
  );

  http.Response page(Uri url) {
    final number = int.tryParse(url.queryParameters['page'] ?? '1') ?? 1;
    final series = url.path.contains('/tv');
    final base = (url.path.hashCode.abs() % 1000) * 1000 + number * 40;
    return http.Response(
      jsonEncode({
        'page': number,
        'total_pages': 50,
        'results': [
          for (var i = 0; i < 20; i++)
            {
              'id': base + i,
              'media_type': series ? 'tv' : 'movie',
              if (series) 'name': 'Series $i' else 'title': 'Movie $i',
              if (series)
                'first_air_date': daysAgo(20 + i)
              else
                'release_date': daysAgo(20 + i),
              'backdrop_path': '/b$i.jpg',
              'poster_path': '/p$i.jpg',
              'vote_average': 7.8,
              'vote_count': 500,
              'popularity': 40,
              'genre_ids': [18],
            },
        ],
      }),
      200,
    );
  }

  Future<void> settle(WidgetTester tester, {int rounds = 30}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpHome(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    requests = [];
    client = MockClient((request) async {
      requests.add(request.url);
      return page(request.url);
    });
    accent = AccentSettingsController();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? GlassTheme.dark,
        home: HomeScreen(
          accentSettings: accent,
          tmdbService: TmdbService(
            baseUrl: 'https://api.themoviedb.org/3',
            accessToken: ({bool forceRefresh = false}) async => 'test-token',
            testClient: client,
            network: NetworkDestinationValidator(
              lookup: (_) async => [InternetAddress('8.8.8.8')],
            ),
            cache: TmdbResponseCache(directory: cacheRoot),
            wait: (_) async {},
            jitter: () => 0,
          ),
          updateChecker: () async =>
              const UpdateCheckResult(UpdateCheckStatus.upToDate),
        ),
      ),
    );
    await settle(tester, rounds: 40);
  }

  Future<void> disposeHome(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, rounds: 3);
    accent.dispose();
    client.close();
  }

  /// Tapped where it is in the chip row, which scrolls sideways and builds
  /// its chips as they near the screen.
  Future<void> tapChip(WidgetTester tester, String label) async {
    final chips = find.ancestor(
      of: find.widgetWithText(ChoiceChip, 'For you', skipOffstage: false),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.widgetWithText(ChoiceChip, label),
      120,
      scrollable: chips.first,
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(ChoiceChip, label));
    await settle(tester, rounds: 10);
  }

  group('phone Home', () {
    testWidgets('the header fits a 360 dp phone away from the Spotlight', (
      tester,
    ) async {
      await pumpHome(tester, size: const Size(360, 740));
      await tapChip(tester, 'Movies');
      // An overflow is reported as an exception.
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('Profile', skipOffstage: false), findsOneWidget);
      await disposeHome(tester);
    });

    testWidgets('a row heading promises nothing it does not do', (
      tester,
    ) async {
      await pumpHome(tester);
      await tapChip(tester, 'Movies');
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      await disposeHome(tester);
    });

    testWidgets('a landscape phone lays Home out without overflowing', (
      tester,
    ) async {
      await pumpHome(tester, size: const Size(844, 390));
      expect(tester.takeException(), isNull);
      await disposeHome(tester);
    });

    testWidgets('Continue watching is a row, not a chip that repeats it', (
      tester,
    ) async {
      await pumpHome(tester);
      expect(find.widgetWithText(ChoiceChip, 'Trending'), findsOneWidget);
      expect(
        find.widgetWithText(ChoiceChip, 'Continue watching'),
        findsNothing,
      );
      await disposeHome(tester);
    });

    testWidgets('Movies fills the page and pages as it is scrolled', (
      tester,
    ) async {
      await pumpHome(tester);
      await tapChip(tester, 'Movies');
      expect(find.byType(SliverGrid), findsOneWidget);
      final before = requests
          .where((url) => url.queryParameters['page'] == '2')
          .length;
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -3000),
      );
      await settle(tester, rounds: 20);
      expect(
        requests.where((url) => url.queryParameters['page'] == '2').length,
        greaterThan(before),
      );
      expect(tester.takeException(), isNull);
      await disposeHome(tester);
    });

    testWidgets('Trending is a row, loaded only as it nears the screen', (
      tester,
    ) async {
      await pumpHome(tester);
      bool trending(Uri url) => url.path.contains('/trending/');
      expect(requests.where(trending), isEmpty);
      for (var i = 0; i < 6; i++) {
        await tester.drag(
          find.byType(CustomScrollView).first,
          const Offset(0, -500),
        );
        await settle(tester, rounds: 12);
      }
      expect(requests.where(trending), hasLength(1));
      expect(tester.takeException(), isNull);
      await disposeHome(tester);
    });

    testWidgets('searching from a chip shows the results', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Search'));
      await settle(tester, rounds: 5);
      await tester.enterText(find.byType(TextField), 'movie');
      await tester.pump(const Duration(milliseconds: 500));
      await settle(tester, rounds: 20);
      expect(find.text('Search results'), findsOneWidget);
      await disposeHome(tester);
    });
  });

  group('Android Back on the phone', () {
    Future<bool> back(WidgetTester tester) async {
      final handled = await tester.binding.handlePopRoute();
      await settle(tester, rounds: 5);
      return handled;
    }

    SoftGlassDock dock(WidgetTester tester) =>
        tester.widget(find.byType(SoftGlassDock));

    testWidgets('goes from a tab to Home', (tester) async {
      await pumpHome(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(SoftGlassDock),
          matching: find.text('Library'),
        ),
      );
      await settle(tester, rounds: 5);
      expect(dock(tester).selectedIndex, 1);
      await back(tester);
      expect(dock(tester).selectedIndex, 0);
      await disposeHome(tester);
    });

    testWidgets('returns from Movies to For you', (tester) async {
      await pumpHome(tester);
      await tapChip(tester, 'Movies');
      expect(find.byType(SliverGrid), findsOneWidget);
      await back(tester);
      expect(find.byType(SliverGrid), findsNothing);
      await settle(tester, rounds: 40);
      // Back at the top of the page, not partway down it.
      expect(find.byTooltip('Profile'), findsOneWidget);
      final chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'For you', skipOffstage: false),
      );
      expect(chip.selected, isTrue);
      await disposeHome(tester);
    });

    testWidgets('Home in the dock, tapped on Home, returns to the top', (
      tester,
    ) async {
      await pumpHome(tester);
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -1500),
      );
      await settle(tester, rounds: 10);
      expect(find.byTooltip('Profile'), findsNothing);
      await tester.tap(
        find.descendant(
          of: find.byType(SoftGlassDock),
          matching: find.text('Home'),
        ),
      );
      await settle(tester, rounds: 40);
      expect(find.byTooltip('Profile'), findsOneWidget);
      await disposeHome(tester);
    });

    testWidgets('closes a search and stays on Home', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.byTooltip('Search'));
      await settle(tester, rounds: 5);
      expect(find.byTooltip('Close search'), findsOneWidget);
      await back(tester);
      expect(find.byTooltip('Close search'), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
      await disposeHome(tester);
    });
  });

  group('phone details', () {
    Widget screen(
      MediaItem item, {
      ValueChanged<BuildContext>? onPlay,
      void Function(BuildContext, PartyContent)? onWatchTogether,
    }) => MediaDetailsScreen(
      item: item,
      tmdb: _FakeTmdb(),
      onPlay: onPlay ?? (_) {},
      onPlayEpisode: (_, _, _) {},
      onToggleFavorite: () async => true,
      onWatchTogether: onWatchTogether ?? (_, _) {},
    );

    Future<void> pump(WidgetTester tester, Widget page, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: GlassTheme.dark, home: page));
      await tester.pumpAndSettle();
    }

    testWidgets('a series has a Play action on the first view', (tester) async {
      var played = 0;
      await pump(
        tester,
        screen(_series, onPlay: (_) => played++),
        const Size(390, 844),
      );
      await tester.tap(find.text('Play'));
      expect(played, 1);
    });

    testWidgets('a movie names Watch together in words', (tester) async {
      final started = <PartyContent>[];
      await pump(
        tester,
        screen(_movie, onWatchTogether: (_, content) => started.add(content)),
        const Size(390, 844),
      );
      await tester.tap(find.text('Watch together'));
      expect(started.single.tmdbId, 8);
    });

    testWidgets('text keeps clear of a landscape camera cutout', (
      tester,
    ) async {
      tester.view.padding = const FakeViewPadding(left: 60);
      addTearDown(tester.view.resetPadding);
      await pump(tester, screen(_movie), const Size(844, 390));
      expect(tester.getTopLeft(find.text('The title')).dx, greaterThan(60));
      expect(tester.getTopLeft(find.text('A plot.')).dx, greaterThan(60));
    });

    for (final (label, size) in const [
      ('landscape', Size(844, 390)),
      ('a small phone', Size(320, 568)),
    ]) {
      testWidgets('the title clears Back on $label at large text', (
        tester,
      ) async {
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pump(tester, screen(_movie), size);
        expect(tester.takeException(), isNull);
        final back = tester.getBottomLeft(find.byTooltip('Back'));
        final badge = tester.getTopLeft(find.text('MOVIE'));
        expect(badge.dy, greaterThan(back.dy));
      });
    }
  });

  group('Play with nothing installed', () {
    Future<void> playFirstTitle(WidgetTester tester) async {
      await tester.tap(find.text('Details').first);
      await settle(tester, rounds: 20);
      await tester.tap(find.textContaining('Play').last);
      await settle(tester, rounds: 40);
    }

    testWidgets('explains itself and leads to Plugins', (tester) async {
      // Wide enough for the Plugins page in the test font.
      await pumpHome(tester, size: const Size(600, 844));
      await playFirstTitle(tester);
      expect(find.text('Add a source to watch'), findsOneWidget);

      await tester.tap(find.text('Open Plugins'));
      await settle(tester, rounds: 30);
      expect(find.byType(MediaDetailsScreen), findsNothing);
      expect(
        tester.widget<SoftGlassDock>(find.byType(SoftGlassDock)).selectedIndex,
        2,
      );
      expect(find.byType(PluginsScreen), findsOneWidget);
      await disposeHome(tester);
    });

    testWidgets('Not now stays on the title', (tester) async {
      await pumpHome(tester);
      await playFirstTitle(tester);
      await tester.tap(find.text('Not now'));
      await settle(tester, rounds: 20);
      expect(find.byType(MediaDetailsScreen), findsOneWidget);
      await disposeHome(tester);
    });
  });

  group('Watch Party on TV and Windows Home', () {
    testWidgets('TV: the D-pad reaches Join and opens it', (tester) async {
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      await pumpHome(
        tester,
        // A 1080p TV at its usual scale.
        size: const Size(960, 540),
        theme: GlassTheme.tv,
      );
      // From Add a source, past Movies and Series.
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await settle(tester, rounds: 8);
      }
      // It comes fully onto the screen, not just its focus ring.
      expect(tester.getRect(find.text('Watch together')).bottom, lessThan(540));
      // The row is a stop in both directions: on past it, and back up.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await settle(tester, rounds: 8);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await settle(tester, rounds: 8);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await settle(tester, rounds: 20);
      expect(find.byType(JoinPartyScreen), findsOneWidget);
      await disposeHome(tester);
    });

    testWidgets(
      'Windows: Home says how to join and host',
      (tester) async {
        DeviceCapabilities.debugOverride = const DeviceCapabilities(
          hasTouchscreen: false,
          supportsPictureInPicture: false,
        );
        await pumpHome(tester, size: const Size(1600, 6000));
        final button = find.text('Join with a code');
        expect(button, findsOneWidget);
        await tester.tap(button);
        await settle(tester, rounds: 20);
        expect(find.byType(JoinPartyScreen), findsOneWidget);
        await disposeHome(tester);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.windows),
    );
  });

  group('Join a party', () {
    final preview = PartyPreview(
      code: '12345678',
      phase: PartyPhase.lobby,
      content: PartyContent.fromItem(_movie)!,
      hostName: 'Sam',
      participants: 1,
      capacity: 5,
    );

    testWidgets('says how to host until a party is found', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: JoinPartyScreen(preview: (_) async => preview, open: (_, _) {}),
        ),
      );
      expect(find.textContaining('Host your own'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '12345678');
      await tester.pumpAndSettle();
      expect(find.textContaining('Host your own'), findsNothing);
      expect(find.textContaining('Hosted by Sam'), findsOneWidget);
    });

    testWidgets('a failed join says why and can be tried again', (
      tester,
    ) async {
      var attempts = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: JoinPartyScreen(
            preview: (_) async => preview,
            start: (_) async {
              attempts++;
              throw const AccountApiException('network', 'x', status: 0);
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '12345678');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Join party'));
      await tester.pumpAndSettle();
      expect(attempts, 1);
      expect(
        find.text('No connection. Check your network and try again.'),
        findsOneWidget,
      );
      // The button works again; it was left dead before.
      await tester.tap(find.text('Join party'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
    });

    testWidgets('TV: the remote lands on Join once the party is found', (
      tester,
    ) async {
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.tv,
          home: JoinPartyScreen(preview: (_) async => preview, open: (_, _) {}),
        ),
      );
      tester.widget<TvFocusable>(find.byType(TvFocusable).first).onSelect!();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '12345678');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'Join party');
    });
  });

  group('large text', () {
    Future<void> pumpScaled(WidgetTester tester, Widget page, Size size) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(MaterialApp(theme: GlassTheme.dark, home: page));
      await tester.pumpAndSettle();
    }

    for (final size in const [Size(320, 568), Size(844, 390)]) {
      testWidgets('the consent page keeps Agree on a '
          '${size.width.toInt()} dp screen', (tester) async {
        await pumpScaled(
          tester,
          FirstRunConsentScreen(onAccepted: () {}),
          size,
        );
        expect(tester.takeException(), isNull);
        final agree = tester.getRect(find.text('Agree and continue'));
        expect(agree.bottom, lessThanOrEqualTo(size.height));
        // What does not fit scrolls.
        await tester.dragUntilVisible(
          find.text('Terms of use'),
          find.byType(SingleChildScrollView),
          const Offset(0, -80),
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('the report form fits a small phone', (tester) async {
      await pumpScaled(
        tester,
        const ReportScreen(kind: ReportKind.bug),
        const Size(600, 900),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('TV: Remove from history', () {
    const watched = MediaItem(
      id: '8',
      type: 'movie',
      name: 'Film',
      year: '2021',
      resumeMs: 60000,
      durationMs: 600000,
    );

    Future<void> pump(WidgetTester tester, Future<void> Function()? remove) =>
        tester.pumpWidget(
          MaterialApp(
            theme: GlassTheme.tv,
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => TvMediaDetailsScreen(
                      item: watched,
                      tmdb: _FakeTmdb(),
                      onPlay: (_) {},
                      onPlayEpisode: (_, _, _) {},
                      onRemoveFromHistory: remove,
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('asks first, then removes and leaves the page', (tester) async {
      var removed = 0;
      await pump(tester, () async => removed++);
      await open(tester);
      await tester.tap(find.text('Remove from history'));
      await tester.pumpAndSettle();
      expect(find.text('Remove from history?'), findsOneWidget);
      // Cancel holds focus, so Select cannot remove by accident.
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(removed, 0);
      expect(find.byType(TvMediaDetailsScreen), findsOneWidget);

      await tester.tap(find.text('Remove from history'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(removed, 1);
      expect(find.byType(TvMediaDetailsScreen), findsNothing);
    });

    testWidgets('a failure says so and stays on the page', (tester) async {
      await pump(tester, () async => throw StateError('disk'));
      await open(tester);
      await tester.tap(find.text('Remove from history'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Could not remove it. Try again.'), findsOneWidget);
      expect(find.byType(TvMediaDetailsScreen), findsOneWidget);
    });

    testWidgets('Back from Watch together returns to it', (tester) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      DeviceCapabilities.debugOverride = const DeviceCapabilities(
        isTelevision: true,
        hasTouchscreen: false,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.tv,
          home: TvMediaDetailsScreen(
            item: watched,
            tmdb: _FakeTmdb(),
            onPlay: (_) {},
            onPlayEpisode: (_, _, _) {},
            onWatchTogether: (context, _) => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('party')),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      Widget? focusedButton() => FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<OutlinedButton>();
      final button = focusedButton();
      expect(button, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(find.text('party'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('party'), findsNothing);
      expect(focusedButton(), isNotNull, reason: 'focus left the button');
    });

    testWidgets('a title with no history offers nothing', (tester) async {
      await pump(tester, null);
      await open(tester);
      expect(find.text('Remove from history'), findsNothing);
    });
  });

  group('Settings and Help & Support', () {
    Future<void> pumpHelp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(theme: GlassTheme.dark, home: const HelpSupportScreen()),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('Settings is preferences; information is in Help', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final accent = AccentSettingsController();
      addTearDown(accent.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: SettingsScreen(
              accentSettings: accent,
              onPlaybackSettings: () {},
              onAppearanceSettings: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      for (final moved in [
        'About Reelish',
        'Credits & attribution',
        'Open-source licenses',
        'Privacy policy',
        'Terms of use',
        'Support development',
      ]) {
        expect(find.text(moved), findsNothing, reason: moved);
      }
      expect(find.text('Help & Support'), findsOneWidget);
      // The privacy policy sends people here to delete their account.
      expect(find.text('Profile and account'), findsOneWidget);
    });

    testWidgets('Share usage statistics stays in Settings, under General', (
      tester,
    ) async {
      // Local builds have no analytics configured, so the switch is hidden.
      final analytics = AnalyticsService.instance;
      analytics.available.value = true;
      addTearDown(() => analytics.available.value = false);
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final accent = AccentSettingsController();
      addTearDown(accent.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: Scaffold(
            body: SettingsScreen(
              accentSettings: accent,
              onPlaybackSettings: () {},
              onAppearanceSettings: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      double top(String text) => tester.getTopLeft(find.text(text)).dy;
      expect(find.text('Share usage statistics'), findsOneWidget);
      // The privacy policy promises it can be turned off in Settings.
      expect(
        top('Share usage statistics'),
        greaterThan(top('Join a watch party')),
      );
      expect(top('Share usage statistics'), lessThan(top('PLAYBACK')));
    });

    for (final (entry, screen) in const [
      ('About Reelish', AboutScreen),
      ('Support development', SupportDevelopmentScreen),
      ('Privacy policy', LegalInformationScreen),
      ('Terms of use', LegalInformationScreen),
    ]) {
      testWidgets('Help opens $entry, and Back returns', (tester) async {
        await pumpHelp(tester);
        await tester.tap(find.text(entry));
        await tester.pumpAndSettle();
        expect(find.byType(screen), findsOneWidget);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(screen), findsNothing);
        expect(find.byType(HelpSupportScreen), findsOneWidget);
      });
    }

    testWidgets('Credits and licenses are reached through About', (
      tester,
    ) async {
      await pumpHelp(tester);
      await tester.tap(find.text('About Reelish'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Credits & attribution'));
      await tester.pumpAndSettle();
      expect(find.byType(CreditsScreen), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Open-source licenses'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Open-source licenses'), findsOneWidget);
    });
  });

  group('library', () {
    testWidgets('Undo puts a title back where it was', (tester) async {
      final storage = StorageService();
      await tester.runAsync(() async {
        await storage.saveProgress(_series, 1000);
        await storage.saveProgress(_movie, 1000);
        await storage.saveProgress(
          const MediaItem(id: '9', type: 'movie', name: 'Third'),
          1000,
        );
      });
      // Newest first: Third, The title, Show.
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: LibraryScreen(storage: storage, onPlay: (_) {}),
        ),
      );
      await settle(tester, rounds: 10);
      await tester.tap(find.byTooltip('Remove from watch history').at(1));
      await settle(tester, rounds: 10);
      await tester.tap(find.text('Undo'));
      await settle(tester, rounds: 10);
      final names = (await tester.runAsync(
        storage.history,
      ))!.map((e) => e.name);
      expect(names, ['Third', 'The title', 'Show']);
    });

    testWidgets('removing a title from the history can be undone', (
      tester,
    ) async {
      final storage = StorageService();
      await tester.runAsync(
        () => storage.saveProgress(_movie, 60000, durationMs: 600000),
      );
      var told = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: LibraryScreen(
            storage: storage,
            onPlay: (_) {},
            onHistoryChanged: () => told++,
          ),
        ),
      );
      await settle(tester, rounds: 10);
      await tester.tap(find.byTooltip('Remove from watch history').first);
      await settle(tester, rounds: 10);
      expect(await tester.runAsync(storage.history), isEmpty);
      expect(told, 1);
      // The notice sits above the dock, not over its tabs.
      expect(
        tester.getBottomLeft(find.text('Undo')).dy,
        lessThanOrEqualTo(600 - SettingsMetrics.dockClearance),
      );

      await tester.tap(find.text('Undo'));
      await settle(tester, rounds: 10);
      final history = (await tester.runAsync(storage.history))!;
      expect(history.single.id, '8');
      // The resume point comes back with it.
      expect(history.single.resumeMs, 60000);
      expect(history.single.durationMs, 600000);
      expect(told, 2);
    });

    testWidgets('names My list as everywhere else, and offers a way back', (
      tester,
    ) async {
      var browsed = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: LibraryScreen(
            storage: StorageService(),
            onPlay: (_) {},
            onBrowse: () => browsed++,
          ),
        ),
      );
      await settle(tester, rounds: 10);
      expect(find.text('Favorites'), findsNothing);
      expect(find.text('Your favorites'), findsNothing);
      await tester.tap(find.text('Browse').first);
      expect(browsed, 1);
    });
  });
}
