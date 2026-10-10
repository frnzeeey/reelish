import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/models/app_update.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/home_screen.dart';
import 'package:onfeed/src/screens/tv/tv_details_screen.dart';
import 'package:onfeed/src/screens/tv/tv_home_shell.dart';
import 'package:onfeed/src/screens/tv/tv_pages.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/media_catalog_rules.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/soft_glass_dock.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The real Home in TV mode, over a fake TMDB: the shell, the catalog rows,
/// remote navigation, and the details round trip.
void main() {
  late Directory cacheRoot;
  late MockClient client;
  late AccentSettingsController accentSettings;
  late List<Uri> urls;

  setUp(() async {
    cacheRoot = await Directory.systemTemp.createTemp('reelish-tv-test-');
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
      hasTouchscreen: false,
    );
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
    final pageNumber = int.tryParse(url.queryParameters['page'] ?? '1') ?? 1;
    final series = url.path.contains('/tv');
    final base = (url.path.hashCode.abs() % 1000) * 1000 + pageNumber * 40;
    return http.Response(
      jsonEncode({
        'page': pageNumber,
        'total_pages': 50,
        'results': [
          for (var i = 0; i < 20; i++)
            series
                ? {
                    'id': base + i,
                    'media_type': 'tv',
                    'name': 'Series ${base + i}',
                    'first_air_date': daysAgo(20 + i),
                    'vote_average': 8.0,
                    'vote_count': 500,
                    'popularity': 40,
                    'genre_ids': [18],
                  }
                : {
                    'id': base + i,
                    'media_type': 'movie',
                    'title': 'Movie ${base + i}',
                    'release_date': daysAgo(20 + i),
                    'vote_average': 7.8,
                    'vote_count': 500,
                    'popularity': 40,
                    'genre_ids': [28],
                  },
        ],
      }),
      200,
    );
  }

  Future<void> pumpTvHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    urls = [];
    client = MockClient((request) async {
      urls.add(request.url);
      return page(request.url);
    });
    SharedPreferences.setMockInitialValues({});
    accentSettings = AccentSettingsController();
    final tmdb = TmdbService(
      apiKey: 'test-key',
      testClient: client,
      network: NetworkDestinationValidator(
        lookup: (_) async => [InternetAddress('8.8.8.8')],
      ),
      cache: TmdbResponseCache(directory: cacheRoot),
      wait: (_) async {},
      jitter: () => 0,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: GlassTheme.tv,
        home: HomeScreen(
          accentSettings: accentSettings,
          tmdbService: tmdb,
          updateChecker: () async =>
              const UpdateCheckResult(UpdateCheckStatus.upToDate),
        ),
      ),
    );
  }

  // The TMDB disk cache uses real file I/O; let it run in real time.
  Future<void> settle(WidgetTester tester, {int rounds = 30}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await settle(tester, rounds: 15);
  }

  Future<void> disposeHome(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    accentSettings.dispose();
    client.close();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  String? focused() => FocusManager.instance.primaryFocus?.debugLabel;

  /// With no source installed (as in these tests), Home opens on its "Add a
  /// source" action; the first row is right below it.
  bool addSourceFocused() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<FilledButton>() !=
      null;

  testWidgets('TV Home shows the rail and rows, and starts light on requests', (
    tester,
  ) async {
    await pumpTvHome(tester);
    await settle(tester, rounds: 40);

    expect(find.byType(TvHomeShell), findsOneWidget);
    expect(find.byType(SoftGlassDock), findsNothing);
    expect(find.byType(TvHomePage), findsOneWidget);
    expect(find.text('Add a source'), findsOneWidget);
    expect(addSourceFocused(), isTrue);

    // Cold start: page 1 of the two catalog rows and Trending. Top 10 and
    // New releases wait until the list nears them.
    bool path(Uri url, String end) => url.path.endsWith(end);
    expect(urls.where((url) => path(url, '/discover/movie')), hasLength(1));
    expect(urls.where((url) => path(url, '/discover/tv')), hasLength(1));
    expect(urls.where((url) => url.path.contains('/trending/')), hasLength(1));
    expect(urls.where((url) => url.path.contains('/recommendations')), isEmpty);
    expect(urls, hasLength(3));

    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'New movies 0');
    expect(find.text('New movies'), findsOneWidget);
    // Moving down brings Top 10 near, and it loads.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'Series worth the queue 0');
    expect(
      urls.where((url) => url.path.contains('/recommendations')),
      isNotEmpty,
    );
    expect(tester.takeException(), isNull);

    await disposeHome(tester);
  });

  testWidgets('a poster opens TV details on Play, and Back returns to it', (
    tester,
  ) async {
    await pumpTvHome(tester);
    await settle(tester, rounds: 40);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'New movies 0');

    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(focused(), 'New movies 1');
    await press(tester, LogicalKeyboardKey.select);
    await settle(tester, rounds: 20);

    expect(find.byType(TvMediaDetailsScreen), findsOneWidget);
    expect(find.text('Play movie'), findsOneWidget);
    // Play has focus as the page opens.
    final play = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<FilledButton>();
    expect(play, isNotNull);

    await tester.binding.handlePopRoute();
    await settle(tester, rounds: 20);
    expect(find.byType(TvMediaDetailsScreen), findsNothing);
    expect(focused(), 'New movies 1');
    expect(tester.takeException(), isNull);

    await disposeHome(tester);
  });

  testWidgets('the rail opens Movies as a grid and Search with its field', (
    tester,
  ) async {
    await pumpTvHome(tester);
    await settle(tester, rounds: 40);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'New movies 0');

    await press(tester, LogicalKeyboardKey.arrowLeft);
    expect(focused(), 'Rail Home');
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'Rail Movies');
    expect(find.byType(TvCatalogPage), findsOneWidget);
    await press(tester, LogicalKeyboardKey.arrowRight);
    // The first poster of the grid.
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<TvCatalogPage>(),
      isNotNull,
    );

    await press(tester, LogicalKeyboardKey.arrowLeft);
    await press(tester, LogicalKeyboardKey.arrowDown);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'Rail Search');
    await press(tester, LogicalKeyboardKey.arrowRight);
    expect(find.text('Search movies and series'), findsOneWidget);
    expect(find.text('Find your next favorite'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await disposeHome(tester);
  });
}
