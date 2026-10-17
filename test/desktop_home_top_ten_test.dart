import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:onfeed/src/desktop/desktop_pages.dart';
import 'package:onfeed/src/desktop/desktop_top_ten.dart';
import 'package:onfeed/src/desktop/desktop_widgets.dart';
import 'package:onfeed/src/models/app_update.dart';
import 'package:onfeed/src/screens/home_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/media_catalog_rules.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/widgets/app_update_flow.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Top 10 in the real Windows Home: the shared seeds, ranking and request
/// budget, reached with the keyboard from the sidebar.
void main() {
  late Directory cacheRoot;
  late List<Uri> urls;
  late MockClient client;
  late AccentSettingsController accentSettings;

  setUp(() async {
    cacheRoot = await Directory.systemTemp.createTemp('reelish-desktop-top10-');
    AppUpdateFlow.resetForTest();
    AppUpdateFlow.windowsStartupDelay = Duration.zero;
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

  /// A TMDB page of titles that pass every row's filters. Recommendation
  /// lists repeat titles across seeds, so the shared de-duplication is
  /// exercised.
  http.Response page(Uri url) {
    final pageNumber = int.tryParse(url.queryParameters['page'] ?? '1') ?? 1;
    final series = url.path.contains('/tv');
    final recommendations = url.path.contains('/recommendations');
    final base = recommendations
        ? 900000 + pageNumber * 40
        : (url.path.hashCode.abs() % 1000) * 1000 + pageNumber * 40;
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
                    'vote_average': 8.0 - i * .05,
                    'vote_count': 500,
                    'popularity': 40,
                    'genre_ids': [18],
                  }
                : {
                    'id': base + i,
                    'title': 'Movie ${base + i}',
                    'release_date': daysAgo(20 + i),
                    'vote_average': 7.8 - i * .05,
                    'vote_count': 500,
                    'popularity': 40,
                    'genre_ids': [28],
                  },
        ],
      }),
      200,
    );
  }

  bool isRecommendations(Uri url) => url.path.contains('/recommendations');

  Future<void> settle(WidgetTester tester, {int rounds = 30}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
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
    await settle(tester, rounds: 40);
  }

  Future<void> disposeHome(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester, rounds: 3);
    accentSettings.dispose();
    client.close();
    tester.view.reset();
  }

  Finder topTen() => find.byType(DesktopTopTenRow);

  Future<void> revealTopTen(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      find.text('Top 10 recommendations'),
      300,
      scrollable: find
          .descendant(
            of: find.byType(DesktopHomePage),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await settle(tester, rounds: 25);
  }

  testWidgets(
    'Top 10 is on Windows Home, ranked from the shared feed, without extra '
    'requests',
    (tester) async {
      await pumpHome(tester);
      await revealTopTen(tester);

      final cards = tester
          .widgetList<DesktopPosterCard>(
            find.descendant(
              of: topTen(),
              matching: find.byType(DesktopPosterCard),
            ),
          )
          .toList();
      expect(cards, hasLength(10));
      expect(cards.map((card) => card.rank), [for (var i = 1; i <= 10; i++) i]);
      // Each title once.
      expect(
        cards.map((card) => MediaCatalogFilter.key(card.item)).toSet(),
        hasLength(10),
      );
      // One recommendations request per seed (best movie, best series).
      final recommendations = urls.where(isRecommendations).toList();
      expect(recommendations, hasLength(2));

      // Leaving Home and coming back reuses everything already loaded.
      final before = urls.length;
      for (final page in ['Movies', 'My library', 'Home']) {
        await tester.tap(find.text(page).first);
        await settle(tester, rounds: 10);
      }
      expect(urls.sublist(before).where(isRecommendations), isEmpty);
      expect(
        tester.widgetList(
          find.descendant(
            of: topTen(),
            matching: find.byType(DesktopPosterCard),
          ),
        ),
        hasLength(10),
      );

      await disposeHome(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'the arrow keys reach Top 10 from the sidebar, row by row',
    (tester) async {
      await pumpHome(tester);

      DesktopPosterCard? focusedCard() => FocusManager
          .instance
          .primaryFocus
          ?.context
          ?.findAncestorWidgetOfExactType<DesktopPosterCard>();
      bool inTopTen() {
        final context = FocusManager.instance.primaryFocus?.context;
        return context?.findAncestorWidgetOfExactType<DesktopTopTenRow>() !=
            null;
      }

      // Right from a cold start lands on the sidebar, then the content.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester, rounds: 3);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester, rounds: 3);
      for (var i = 0; i < 12 && !inTopTen(); i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await settle(tester, rounds: 12);
      }
      expect(inTopTen(), isTrue, reason: 'focus never reached Top 10');
      final first = focusedCard()!;
      expect(first.rank, isNotNull);
      // The focused card is on screen.
      final rect = tester.getRect(find.byWidget(first));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.bottom, lessThanOrEqualTo(1000));

      // Right moves to the next rank; Up leaves the row upward.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await settle(tester, rounds: 6);
      expect(focusedCard()!.rank, first.rank! + 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await settle(tester, rounds: 6);
      expect(inTopTen(), isFalse);
      expect(focusedCard(), isNotNull);

      await disposeHome(tester);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
