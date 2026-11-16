import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/spotlight/spotlight_deck.dart';
import 'package:onfeed/src/spotlight/spotlight_motion.dart';
import 'package:onfeed/src/spotlight/spotlight_motion_controller.dart';

import 'support/fake_account.dart';
import 'package:onfeed/src/widgets/brand_logo.dart';
import 'package:onfeed/src/widgets/avatar_frame.dart';
import 'package:onfeed/src/theme/reelish_icons.dart';
import 'package:onfeed/src/widgets/liquid_glass.dart';
import 'package:onfeed/src/screens/search/search_cards.dart';
import 'package:onfeed/src/screens/search/universal_search_screen.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/models/app_update.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/screens/home_screen.dart';
import 'package:onfeed/src/screens/media_details_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/media_catalog_rules.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/widgets/media_card.dart';
import 'package:onfeed/src/widgets/soft_glass_dock.dart';
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
                    // Search mixes types, so it names each one.
                    if (url.path.contains('/search/')) 'media_type': 'movie',
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
  Future<void> pumpHome(
    WidgetTester tester, {
    // Saved before Home opens: watch history, My list.
    Future<void> Function()? seed,
    Size size = const Size(430, 915),
    // The Spotlight animation; the app-wide controller when null.
    SpotlightMotionController? motion,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    urls = [];
    client = MockClient((request) async {
      urls.add(request.url);
      return page(request.url);
    });
    SharedPreferences.setMockInitialValues({});
    // Each test starts with storage's write queue free (see
    // StorageService.debugResetWrites).
    StorageService.debugResetWrites();
    if (seed != null) await tester.runAsync(seed);
    accentSettings = AccentSettingsController();
    final tmdb = TmdbService(
      baseUrl: 'https://api.themoviedb.org/3',
      accessToken: ({bool forceRefresh = false}) async => 'test-token',
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
          spotlightMotion: motion,
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

  testWidgets(
    'the header: the mark, a labelled Join party and Search in one glass '
    'capsule, '
    'then the profile; above the Spotlight',
    (tester) async {
      await pumpHome(tester);
      await settle(tester, rounds: 40);
      final deck = tester.getRect(find.byType(SpotlightDeck));
      Rect button(String tip) => tester.getRect(
        find
            .ancestor(
              of: find.byTooltip(tip),
              matching: find.byType(IconButton),
            )
            .first,
      );
      // Labelled, so it says what it does at a glance.
      final party = tester.getRect(
        find
            .ancestor(
              of: find.text('Join party'),
              matching: find.byType(TextButton),
            )
            .first,
      );
      final search = button('Search');
      final profile = button('Profile');
      // Clear of the cards, which move with the Spotlight animation, and in
      // one row.
      for (final control in [party, search, profile]) {
        expect(control.bottom, lessThanOrEqualTo(deck.top));
        expect(control.center.dy, closeTo(profile.center.dy, .5));
      }
      // Search and Join a watch party share one capsule, side by side;
      // the profile stands apart at the right.
      final capsule = find.ancestor(
        of: find.byTooltip('Search'),
        // One piece of liquid glass, as the dock.
        matching: find.byType(LiquidGlass),
      );
      expect(capsule, findsOneWidget);
      expect(
        find.descendant(of: capsule.first, matching: find.text('Join party')),
        findsOneWidget,
      );
      expect(search.left, greaterThan(party.left));
      expect(profile.left, greaterThan(search.right));
      // The bare mark, not the app tile.
      expect(find.byType(ReelishMark), findsWidgets);
      expect(
        find.ancestor(
          of: find.byType(ReelishMark).first,
          matching: find.byType(AccentAppIcon),
        ),
        findsNothing,
      );
      final mark = tester.getRect(find.byType(ReelishMark).first);
      expect(mark.bottom, lessThanOrEqualTo(deck.top));

      // On the page's 18 px grid, like the chips, titles and rows below.
      final width =
          tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final ring = tester.getRect(
        find
            .descendant(
              of: find
                  .ancestor(
                    of: find.byTooltip('Profile'),
                    matching: find.byType(IconButton),
                  )
                  .first,
              matching: find.byType(Container),
            )
            .first,
      );
      expect(mark.left, 18);
      expect(ring.right, width - 18);
      // One height for the capsule and the avatar, on one centre line.
      final glass = tester.getRect(capsule);
      expect(glass.height, 44);
      expect(ring.height, glass.height);
      expect(mark.center.dy, closeTo(glass.center.dy, .5));
      expect(ring.center.dy, closeTo(glass.center.dy, .5));
      // The capsule's icons match; hierarchy comes from colour and label.
      expect(
        tester.getSize(find.byIcon(ReelishIcons.people).first),
        tester.getSize(find.byIcon(ReelishIcons.search).first),
      );
      // One ring around the avatar: no frame rim inside it.
      expect(
        find.descendant(
          of: find.byTooltip('Profile'),
          matching: find.byType(AvatarFrameRim),
        ),
        findsNothing,
      );
      await disposeHome(tester);
    },
  );

  for (final preset in SpotlightMotion.values) {
    testWidgets(
      '${preset.label}: a small phone with large text lays out without '
      'overflow, header and Spotlight both',
      (tester) async {
        final motion = (await tester.runAsync(fakeSpotlightMotion))!;
        await tester.runAsync(() => motion.select(preset));
        expect(motion.value, preset);
        tester.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await pumpHome(tester, size: const Size(360, 640), motion: motion);
        await settle(tester, rounds: 40);
        // A turn, as a swipe would, then rest on the next card.
        await tester.drag(find.byType(SpotlightDeck), const Offset(-200, 0));
        await settle(tester, rounds: 30);
        // An overflow anywhere is reported as an exception.
        expect(tester.takeException(), isNull);
        expect(find.text('Join party'), findsOneWidget);
        expect(find.byTooltip('Profile'), findsOneWidget);
        await disposeHome(tester);
      },
    );
  }

  testWidgets('the Spotlight says when its title is on My list', (
    tester,
  ) async {
    await pumpHome(tester);
    await settle(tester, rounds: 40);
    final spotlightTitle = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .firstWhere((d) => d != null && d.startsWith('Movie '))!;

    // The shown card's: its neighbour peeks out but takes no taps.
    await tester.tap(find.text('My list').hitTestable());
    await settle(tester, rounds: 10);
    expect(find.text('On My list'), findsOneWidget);
    expect(find.text('$spotlightTitle saved to your list'), findsOneWidget);
    // The wider label still fits on a narrow phone (an overflow fails).
    tester.view.physicalSize = const Size(360, 915);
    await settle(tester, rounds: 5);
    expect(find.text('On My list'), findsOneWidget);
    tester.view.physicalSize = const Size(430, 915);
    await settle(tester, rounds: 5);
    // Dismiss that message; the next one would wait behind it.
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .removeCurrentSnackBar();
    await settle(tester, rounds: 5);

    await tester.tap(find.text('On My list'));
    await settle(tester, rounds: 10);
    expect(find.text('On My list'), findsNothing);
    expect(find.text('My list').hitTestable(), findsOneWidget);
    expect(find.text('$spotlightTitle removed from your list'), findsOneWidget);
    await disposeHome(tester);
  });

  testWidgets('Search opens Universal Search, results by kind, and a '
      'result opens its details page', (tester) async {
    await pumpHome(tester);
    await settle(tester, rounds: 40);
    await tester.tap(find.byTooltip('Search'));
    await settle(tester, rounds: 5);
    expect(find.byType(UniversalSearchScreen), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'movie');
    await settle(tester, rounds: 40);
    expect(urls.where((u) => u.path.endsWith('/search/multi')), isNotEmpty);
    expect(find.text('Movies'), findsWidgets);
    final cards = find.byType(SearchTitleCard);
    expect(cards, findsWidgets);
    // Posters keep the 2:3 shape.
    final art = tester.getSize(
      find.descendant(of: cards.first, matching: find.byType(AspectRatio)),
    );
    expect(art.height / art.width, closeTo(1.5, .01));

    // A result still opens its details page.
    await tester.tap(cards.first);
    await settle(tester, rounds: 20);
    expect(find.byType(MediaDetailsScreen), findsOneWidget);
    await disposeHome(tester);
  });

  testWidgets('Top 10 is the first row, right under the Spotlight', (
    tester,
  ) async {
    const started = MediaItem(id: '601', type: 'movie', name: 'Half Watched');
    await pumpHome(
      tester,
      seed: () =>
          StorageService().saveProgress(started, 60000, durationMs: 600000),
    );
    await settle(tester, rounds: 40);

    // Both rows are built (Continue watching sits just below Top 10).
    final top10 = find.byKey(
      const PageStorageKey<String>('row:Top 10 picks'),
      skipOffstage: false,
    );
    expect(top10, findsOneWidget);
    // "Continue watching" is also a label higher up; the row's header is
    // the lowest one.
    final resumeHeader = find
        .text('Continue watching', skipOffstage: false)
        .evaluate()
        .map(
          (element) => (element.renderObject! as RenderBox)
              .localToGlobal(Offset.zero)
              .dy,
        )
        .reduce((a, b) => a > b ? a : b);
    expect(
      tester.getTopLeft(top10).dy,
      lessThan(resumeHeader),
      reason: 'Top 10 leads; Continue watching follows it',
    );
    final chips = find.text('Trending', skipOffstage: false).first;
    expect(
      tester.getTopLeft(top10).dy,
      greaterThan(tester.getTopLeft(chips).dy),
      reason: 'below the Spotlight and its category chips',
    );

    await disposeHome(tester);
  });

  testWidgets('removing a title in the Library takes it off Home at once', (
    tester,
  ) async {
    const removed = MediaItem(id: '501', type: 'movie', name: 'Removed Film');
    const kept = MediaItem(id: '502', type: 'movie', name: 'Kept Film');
    await pumpHome(
      tester,
      seed: () async {
        final storage = StorageService();
        await storage.saveProgress(kept, 60000, durationMs: 600000);
        await storage.saveProgress(removed, 60000, durationMs: 600000);
        await storage.toggleFavorite(removed);
      },
    );
    await settle(tester, rounds: 40);
    MediaCard? cardOf(String name) => tester
        .widgetList<MediaCard>(find.byType(MediaCard, skipOffstage: false))
        .where((card) => card.item.name == name)
        .firstOrNull;
    // Home's Continue watching row.
    final pickUp = find.text('Continue watching');
    expect(pickUp, findsWidgets);
    expect(cardOf('Removed Film'), isNotNull);
    expect(cardOf('Removed Film')!.isFavorite, isTrue);

    final dock = find.byType(SoftGlassDock);
    await tester.tap(find.descendant(of: dock, matching: find.text('Library')));
    await settle(tester, rounds: 20);
    // The first card in the Library's Continue watching is the newest.
    await tester.tap(find.byTooltip('Remove from watch history').first);
    await settle(tester, rounds: 20);

    // Home, still behind the Library tab, has followed already.
    await tester.tap(find.descendant(of: dock, matching: find.text('Home')));
    await settle(tester, rounds: 20);
    final homeCards = tester.widgetList<MediaCard>(
      find.descendant(
        of: find.byKey(const PageStorageKey<String>('home-feed')),
        matching: find.byType(MediaCard, skipOffstage: false),
      ),
    );
    final names = homeCards.map((card) => card.item.name).toList();
    expect(names, contains('Kept Film'));
    expect(names, isNot(contains('Removed Film')));
    // Its My list entry stays: removing the watch history is not removing
    // it from My list.
    expect(
      (await tester.runAsync(
        () => StorageService().favorites(),
      ))!.map((item) => item.id),
      contains('501'),
    );

    // Opening the Library again reloads history; it does not come back.
    await tester.tap(find.descendant(of: dock, matching: find.text('Library')));
    await settle(tester, rounds: 20);
    await tester.tap(find.descendant(of: dock, matching: find.text('Home')));
    await settle(tester, rounds: 20);
    expect(
      tester
          .widgetList<MediaCard>(
            find.descendant(
              of: find.byKey(const PageStorageKey<String>('home-feed')),
              matching: find.byType(MediaCard, skipOffstage: false),
            ),
          )
          .map((card) => card.item.name),
      isNot(contains('Removed Film')),
    );
    await disposeHome(tester);
  });
}
