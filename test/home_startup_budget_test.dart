import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/models/app_update.dart';
import 'package:onfeed/src/screens/home_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/media_catalog_rules.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Home's network budget: what a cold start fetches on a phone-sized
/// screen, and what scrolling Home and its rows fetches later. Every list
/// reports many pages, so nothing stops early by running out of data.
void main() {
  late Directory cacheRoot;

  setUp(() async {
    cacheRoot = await Directory.systemTemp.createTemp('reelish-budget-test-');
  });

  tearDown(() async {
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

  /// A full TMDB page of 20 titles that pass every row's filters.
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
                    'name': 'Series ${base + i}',
                    'first_air_date': daysAgo(20 + i),
                    'vote_average': 8.0,
                    'vote_count': 500,
                    'popularity': 40,
                    'genre_ids': [18],
                  }
                : {
                    'id': base + i,
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

  bool isNewReleases(Uri url) =>
      url.path.contains('/discover/') &&
      url.queryParameters.containsKey('vote_average.gte');
  bool isNewMovies(Uri url) =>
      url.path.endsWith('/discover/movie') && !isNewReleases(url);
  bool isSeries(Uri url) =>
      url.path.endsWith('/discover/tv') && !isNewReleases(url);
  bool isRecommendations(Uri url) => url.path.contains('/recommendations');
  int pageOf(Uri url) => int.tryParse(url.queryParameters['page'] ?? '1') ?? 1;

  late List<Uri> urls;
  late MockClient client;
  late AccentSettingsController accentSettings;

  /// Opens Home on a phone-sized screen with every list 50 pages long.
  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 915);
    tester.view.devicePixelRatio = 1;
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
        home: HomeScreen(
          accentSettings: accentSettings,
          tmdbService: tmdb,
          updateChecker: () async =>
              const UpdateCheckResult(UpdateCheckStatus.upToDate),
        ),
      ),
    );
  }

  // The TMDB disk cache uses real file I/O, which cannot complete inside
  // the widget test's fake-async zone; let it run in real time.
  Future<void> settle(WidgetTester tester, {int rounds = 30}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> disposeHome(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    accentSettings.dispose();
    client.close();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  Finder homeScrollable() => find
      .descendant(
        of: find.byKey(const PageStorageKey<String>('home-feed')),
        matching: find.byType(Scrollable),
      )
      .first;

  Finder row(String title) => find.byKey(PageStorageKey<String>('row:$title'));

  /// Scrolls Home down until the row's title is on screen (a row not loaded
  /// yet shows its title over reserved space), then lets loads finish.
  Future<void> revealRow(WidgetTester tester, String title) async {
    await tester.scrollUntilVisible(
      find.text(title),
      300,
      scrollable: homeScrollable(),
    );
    // Long enough for rows passed on the way to outlast the load dwell.
    await settle(tester, rounds: 25);
  }

  testWidgets('cold Home start stays within its TMDB request budget', (
    tester,
  ) async {
    await pumpHome(tester);
    await settle(tester, rounds: 40);

    // Before this change a cold start sent 7 requests on this screen: the
    // catalog (2), Top 10 (2) and New releases (3), though New releases was
    // below the dock. Now only what the first screen shows is fetched.
    expect(urls, hasLength(4));
    expect(urls.where(isNewMovies), hasLength(1));
    expect(urls.where(isSeries), hasLength(1));
    expect(urls.where(isRecommendations), hasLength(2));
    expect(urls.where(isNewReleases), isEmpty);
    expect(urls.where((url) => pageOf(url) > 1), isEmpty);

    await disposeHome(tester);
  });

  testWidgets('New releases loads as it is scrolled toward', (tester) async {
    await pumpHome(tester);
    await settle(tester, rounds: 40);
    expect(urls.where(isNewReleases), isEmpty);

    await revealRow(tester, 'New releases');

    expect(urls.where(isNewReleases), hasLength(3));
    expect(urls.where(isNewReleases).map(pageOf), everyElement(1));
    // Scrolling down Home pages nothing horizontally.
    expect(urls.where((url) => pageOf(url) > 1), isEmpty);

    await disposeHome(tester);
  });

  testWidgets('scrolling a row to its end loads its next page once', (
    tester,
  ) async {
    await pumpHome(tester);
    await settle(tester, rounds: 40);
    await revealRow(tester, 'New movies');
    final before = urls.length;
    final seriesBefore = urls.where(isSeries).length;
    final releasesBefore = urls.where(isNewReleases).length;
    final recommendationsBefore = urls.where(isRecommendations).length;

    // Page 1 holds 20 cards; drag toward the end in steps, as a viewer
    // would, so the row reports many scroll updates near its end.
    for (var i = 0; i < 12; i++) {
      await tester.drag(row('New movies'), const Offset(-260, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await settle(tester, rounds: 15);

    final added = urls.sublist(before);
    expect(added.where(isNewMovies).map(pageOf), [2]);
    // Other rows are untouched.
    expect(urls.where(isSeries), hasLength(seriesBefore));
    expect(urls.where(isNewReleases), hasLength(releasesBefore));
    expect(urls.where(isRecommendations), hasLength(recommendationsBefore));
    // Page 2's titles were appended to the row.
    final list = tester.widget<ListView>(row('New movies'));
    expect(list.childrenDelegate.estimatedChildCount, greaterThan(20 * 2));

    await disposeHome(tester);
  });

  testWidgets('switching tabs keeps loaded rows without new requests', (
    tester,
  ) async {
    await pumpHome(tester);
    await settle(tester, rounds: 40);
    final before = urls.length;

    for (final tab in ['Movies', 'Series', 'For you']) {
      await tester.tap(find.text(tab).first);
      await settle(tester, rounds: 10);
    }

    expect(urls, hasLength(before));
    await disposeHome(tester);
  });
}
