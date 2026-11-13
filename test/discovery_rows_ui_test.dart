import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/desktop/desktop_pages.dart';
import 'package:onfeed/src/desktop/desktop_widgets.dart';
import 'package:onfeed/src/discovery/discovery_controller.dart';
import 'package:onfeed/src/discovery/discovery_data.dart';
import 'package:onfeed/src/discovery/discovery_store.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/recommendation_settings_screen.dart';
import 'package:onfeed/src/screens/tv/tv_browse.dart';
import 'package:onfeed/src/screens/tv/tv_pages.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/paged_feed_controller.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:onfeed/src/widgets/media_card.dart';
import 'package:onfeed/src/widgets/recommendation_feedback_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _comedy = 35;

MediaItem _title(int id, {List<int> genres = const [_comedy]}) => MediaItem(
  id: '$id',
  type: 'movie',
  name: 'Title $id',
  genreIds: genres,
  rating: '7.8',
  voteCount: 3000,
  popularity: 30,
  releaseDate: '2021-03-01',
);

class _NoHistory extends StorageService {
  _NoHistory(Directory dir) : super(filesDirectory: () async => dir);

  @override
  Future<List<MediaItem>> history() async => const [];

  @override
  Future<List<MediaItem>> favorites() async => const [];
}

/// The personalised rows on each interface, and the feedback each offers.
void main() {
  late Directory dir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    StorageService.debugResetWrites();
    DiscoveryStore.debugResetWrites();
    dir = await Directory.systemTemp.createTemp('discovery_ui_test');
  });

  tearDown(() async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities();
    for (var attempt = 0; await dir.exists(); attempt++) {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  /// A controller with one "Picked for your genres" row, built for real
  /// (store, profile, engine), with no TMDB request.
  Future<DiscoveryController> discoveryWithRow(WidgetTester tester) async {
    final discovery = DiscoveryController(
      recommendationsFor: (_) async => const [],
      storage: _NoHistory(dir),
      store: DiscoveryStore(filesDirectory: () async => dir),
    );
    await tester.runAsync(() async {
      await discovery.bindUser('viewer');
      await discovery.setFavoriteGenres([_comedy]);
      await discovery.refresh(
        pool: [for (var i = 0; i < 10; i++) _title(100 + i)],
      );
    });
    expect(discovery.sections.single.title, 'Picked for your genres');
    return discovery;
  }

  TvCatalog catalog(DiscoveryController discovery) {
    PagedFeedController feed(String label) => PagedFeedController(
      label: label,
      fetch: (page, {previous, required forceRefresh, onRevalidated}) async =>
          CatalogPage(
            items: [for (var i = 0; i < 6; i++) _title(page * 1000 + i)],
            page: page,
            totalPages: 1,
          ),
    );
    final tmdb = TmdbService(
      baseUrl: 'https://api.themoviedb.org/3',
      accessToken: ({bool forceRefresh = false}) async => 'test-token',
      testClient: MockClient(
        (_) async => http.Response(jsonEncode({'results': []}), 200),
      ),
      network: NetworkDestinationValidator(
        lookup: (_) async => [InternetAddress('8.8.8.8')],
      ),
      cache: TmdbResponseCache(directory: dir),
      wait: (_) async {},
      jitter: () => 0,
    );
    return TvCatalog(
      tmdb: tmdb,
      movies: feed('movies'),
      series: feed('series'),
      releases: feed('releases'),
      top10: feed('top10'),
      spotlight: const [],
      continueWatching: const [],
      catalogSettled: true,
      resumeFraction: (_) => 0,
      favoriteKeys: const {},
      hasSources: true,
      discovery: discovery,
    );
  }

  testWidgets(
    'Windows: the row shows reasons and hides a title as Not interested',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final discovery = await discoveryWithRow(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopHomePage(
              catalog: catalog(discovery),
              onOpen: (_) {},
              onPlay: (_) {},
              onToggleFavorite: (_) async => false,
              onRetry: () {},
              onAddSource: () {},
            ),
          ),
        ),
      );
      await tester.pump();
      final row = tester.widget<DesktopMediaRow>(
        find.byWidgetPredicate(
          (w) => w is DesktopMediaRow && w.title == 'Picked for your genres',
        ),
      );
      expect(row.removeLabel, 'Not interested');
      final first = row.items.first;
      expect(
        row.captionOf!(first),
        'Matches your taste for comedy',
        reason: 'the mixed row says why each title is there',
      );
      await tester.runAsync(() => row.onRemove!(first));
      expect(
        discovery.data.feedback.values.single.kind,
        FeedbackKind.notInterested,
      );
      expect(discovery.sections.single.items, isNot(contains(first)));
      await tester.pumpWidget(const SizedBox.shrink());
      discovery.dispose();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('TV: the row is a remote row after the catalog rows', (
    tester,
  ) async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
      hasTouchscreen: false,
    );
    tester.view.physicalSize = const Size(1920, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final discovery = await discoveryWithRow(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TvHomePage(
            catalog: catalog(discovery),
            onOpen: (_) {},
            onRetry: () {},
            onAddSource: () {},
          ),
        ),
      ),
    );
    await tester.pump();
    final rows = tester
        .widgetList<TvMediaRow>(find.byType(TvMediaRow))
        .map((row) => row.title)
        .toList();
    expect(rows, contains('Picked for your genres'));
    await tester.pumpWidget(const SizedBox.shrink());
    discovery.dispose();
  });

  testWidgets(
    'Phone: long press opens the sheet; Not interested can be undone',
    (tester) async {
      final discovery = await discoveryWithRow(tester);
      final item = discovery.sections.single.items.first;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => MediaCard(
                item: item,
                onTap: () {},
                onLongPress: () => RecommendationFeedbackSheet.show(
                  context,
                  discovery: discovery,
                  item: item,
                  reason: discovery.sections.single.reasonFor(item),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.longPress(find.byType(MediaCard));
      await tester.pumpAndSettle();
      expect(find.text('Matches your taste for comedy'), findsOneWidget);
      await tester.tap(find.text('Not interested'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(find.text('Hidden. You will see less like it.'), findsOneWidget);
      expect(discovery.data.feedback, hasLength(1));
      await tester.tap(find.text('Undo'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(discovery.data.feedback, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      discovery.dispose();
    },
  );

  testWidgets('A card without a long-press action keeps its old long press '
      '(it opens the title, as a tap does)', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaCard(item: _title(1), onTap: () => taps++),
        ),
      ),
    );
    await tester.longPress(find.byType(MediaCard));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(taps, 1);
  });

  testWidgets('Settings: genres are picked and recommendations reset', (
    tester,
  ) async {
    // Tall enough for the whole page, so nothing needs scrolling to.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final discovery = await discoveryWithRow(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RecommendationSettingsScreen(discovery: discovery),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilterChip, 'Horror'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(discovery.favoriteGenres, unorderedEquals([_comedy, 27]));

    await tester.tap(find.text('Reset recommendations'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Reset'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(discovery.sections, isEmpty);
    expect(discovery.favoriteGenres, isNotEmpty, reason: 'genres stay');
    await tester.pumpWidget(const SizedBox.shrink());
    discovery.dispose();
  });
}
