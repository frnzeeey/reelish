// Universal Search as people use it on Windows, TV and phones: results by
// kind, a title opening its details, people and collections opening their
// own pages, filters, and provider sources under the top result.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/discovery/tmdb_genres.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/search/search_cards.dart';
import 'package:onfeed/src/screens/search/search_detail_screens.dart';
import 'package:onfeed/src/screens/search/universal_search_screen.dart';
import 'package:onfeed/src/screens/search/universal_search_view.dart';
import 'package:onfeed/src/search/playback_availability.dart';
import 'package:onfeed/src/search/universal_search_controller.dart';
import 'package:onfeed/src/theme/glass_theme.dart';

class _Catalog implements SearchCatalog {
  final calls = <String>[];

  Map<String, dynamic> _page(List<Object?> results) => {
    'results': results,
    'total_pages': 1,
  };

  @override
  Future<Map<String, dynamic>> multi(String query, {int page = 1}) async {
    calls.add('multi:$query');
    return _page([
      {
        'id': 438631,
        'media_type': 'movie',
        'title': 'Dune',
        'release_date': '2021-10-22',
        'genre_ids': [878],
        'vote_average': 7.8,
        'vote_count': 12000,
        'overview': 'Paul Atreides travels to Arrakis.',
      },
      {
        'id': 2,
        'media_type': 'movie',
        'title': 'Dune: Part Two',
        'release_date': '2024-03-01',
        'genre_ids': [878],
        'vote_average': 8.2,
        'vote_count': 6000,
      },
      {
        'id': 90228,
        'media_type': 'tv',
        'name': 'Dune: Prophecy',
        'first_air_date': '2024-11-17',
        'genre_ids': [10765],
        'vote_average': 7.1,
        'vote_count': 400,
      },
      {
        'id': 137427,
        'media_type': 'person',
        'name': 'Denis Villeneuve',
        'known_for_department': 'Directing',
      },
    ]);
  }

  @override
  Future<Map<String, dynamic>> category(
    String kind,
    String query, {
    int page = 1,
    int? year,
  }) async {
    calls.add('$kind:$query${year == null ? '' : ':$year'}');
    if (kind == 'collection') {
      return _page([
        {'id': 726871, 'name': 'Dune Collection', 'overview': 'Arrakis.'},
      ]);
    }
    if (kind == 'person') {
      return _page([
        {
          'id': 137427,
          'name': 'Denis Villeneuve',
          'known_for_department': 'Directing',
        },
      ]);
    }
    return (await multi(query))
      ..['results'] = [
        for (final r in (await multi(query))['results'] as List)
          if ((r as Map)['media_type'] == (kind == 'tv' ? 'tv' : 'movie')) r,
      ];
  }

  @override
  Future<Map<String, dynamic>> discover(
    String type,
    Map<String, String> params, {
    int page = 1,
  }) async {
    calls.add('discover:$type');
    return _page(const []);
  }

  @override
  Future<Map<String, dynamic>> person(int id) async => {
    'id': id,
    'name': 'Denis Villeneuve',
    'known_for_department': 'Directing',
    'combined_credits': {
      'cast': <Object>[],
      'crew': [
        {
          'id': 438631,
          'media_type': 'movie',
          'title': 'Dune',
          'job': 'Director',
          'vote_count': 12000,
        },
      ],
    },
  };

  @override
  Future<Map<String, dynamic>> collection(int id) async => {
    'id': id,
    'name': 'Dune Collection',
    'parts': [
      {'id': 2, 'title': 'Dune: Part Two', 'release_date': '2024-03-01'},
      {'id': 438631, 'title': 'Dune', 'release_date': '2021-10-22'},
    ],
  };

  @override
  Future<GenreCatalog> genres() async => GenreCatalog.fallback;
}

void main() {
  late _Catalog catalog;
  late UniversalSearchController search;
  late List<MediaItem> opened;
  late List<String> asked;

  PlaybackAvailability availability() => PlaybackAvailability(
    lookup: (item, {required isCancelled, required onSource}) async {
      asked.add(item.id);
      onSource(
        const StreamSource(
          name: 'Alpha',
          url: 'https://a.example/1.m3u8',
          providerName: 'Alpha',
          quality: '1080p',
        ),
      );
      onSource(
        const StreamSource(
          name: 'Alpha',
          url: 'https://a.example/2.m3u8',
          providerName: 'Alpha',
        ),
      );
      return const [];
    },
  );

  setUp(() {
    catalog = _Catalog();
    search = UniversalSearchController(
      catalog: catalog,
      debounce: const Duration(milliseconds: 10),
    );
    opened = [];
    asked = [];
  });
  tearDown(() {
    search.dispose();
    DeviceCapabilities.debugOverride = const DeviceCapabilities();
  });

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(1600, 1000),
    bool tv = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: tv ? GlassTheme.tv : GlassTheme.dark,
        home: Scaffold(body: child),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'Windows: results by kind, the top result with provider '
    'sources, and a title opening its details',
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    (tester) async {
      final sources = availability();
      addTearDown(sources.dispose);
      await pump(
        tester,
        UniversalSearchView(
          search: search,
          availability: sources,
          onOpenTitle: opened.add,
        ),
      );
      expect(find.text('Browse by genre'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'dune');
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pumpAndSettle();
      expect(catalog.calls, ['multi:dune', 'collection:dune']);
      expect(find.text('Top result'), findsOneWidget);
      for (final section in ['Movies', 'Series', 'People', 'Collections']) {
        expect(find.text(section), findsWidgets, reason: section);
      }
      // The best match is a movie, so the providers were asked about it
      // (by its TMDB id), and only what they said is shown.
      expect(asked, ['438631']);
      expect(find.text('2 sources from 1 provider'), findsOneWidget);
      expect(find.text('Alpha · 2 sources · 1080p'), findsOneWidget);
      expect(find.textContaining('not tried yet'), findsOneWidget);

      await tester.tap(find.byType(SearchTitleCard).first);
      expect(opened.single.name, 'Dune');
      expect(tester.takeException(), isNull);
      // Leaving the page stops any check still running.
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('a person and a collection open their own pages', (tester) async {
    await pump(
      tester,
      UniversalSearchView(search: search, onOpenTitle: opened.add),
    );
    await search.search('dune');
    await tester.pumpAndSettle();

    final down = find.byWidgetPredicate(
      (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
    );
    await tester.scrollUntilVisible(
      find.byType(SearchPersonCard),
      200,
      scrollable: down.first,
    );
    await tester.ensureVisible(find.byType(SearchPersonCard));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SearchPersonCard));
    await tester.pumpAndSettle();
    expect(find.byType(PersonScreen), findsOneWidget);
    expect(find.text('Directing  1'), findsOneWidget);
    await tester.tap(find.byType(SearchTitleCard));
    expect(opened.single.id, '438631');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.byType(SearchCollectionCard),
      200,
      scrollable: down.first,
    );
    await tester.ensureVisible(find.byType(SearchCollectionCard));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SearchCollectionCard));
    await tester.pumpAndSettle();
    expect(find.byType(CollectionScreen), findsOneWidget);
    final first = tester.getTopLeft(find.text('Dune').last);
    final second = tester.getTopLeft(find.text('Dune: Part Two').last);
    expect(first.dx, lessThan(second.dx), reason: 'release order');
  });

  testWidgets('See all opens one kind; filters show, apply and clear', (
    tester,
  ) async {
    await pump(
      tester,
      UniversalSearchView(search: search, onOpenTitle: opened.add),
    );
    await search.search('dune');
    await tester.pumpAndSettle();

    // People: no filters for them.
    await tester.tap(find.widgetWithText(ChoiceChip, 'People'));
    await tester.pumpAndSettle();
    expect(catalog.calls.last, 'person:dune');
    expect(find.text('Rating'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Movies'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rating'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('8 and up'));
    await tester.pumpAndSettle();
    expect(search.filters.minRating, 8);
    expect(find.text('TMDB 8+'), findsOneWidget);
    expect(find.text('Dune: Part Two'), findsOneWidget);
    expect(find.text('Dune'), findsNothing, reason: '7.8 is under 8');
    expect(search.query, 'dune', reason: 'the words stay');

    await tester.tap(find.text('Clear all'));
    await tester.pumpAndSettle();
    expect(search.filters.isEmpty, isTrue);
    expect(find.text('Dune'), findsOneWidget);
  });

  testWidgets('TV: the field opens the keyboard dialog, and the remote '
      'reaches the results', (tester) async {
    DeviceCapabilities.debugOverride = const DeviceCapabilities(
      isTelevision: true,
      hasTouchscreen: false,
    );
    await pump(
      tester,
      UniversalSearchView(
        search: search,
        onOpenTitle: opened.add,
        autofocus: true,
      ),
      size: const Size(1920, 1080),
      tv: true,
    );
    await search.search('dune');
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing, reason: 'TvTextField');
    // Down from the field moves through the page to a result.
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      if (FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<SearchTitleCard>() !=
          null) {
        break;
      }
    }
    final card = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<SearchTitleCard>();
    expect(card, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(opened, isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone: full screen, and Close search goes back', (tester) async {
    await pump(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => UniversalSearchScreen(
                search: search,
                onOpenTitle: opened.add,
              ),
            ),
          ),
          child: const Text('open'),
        ),
      ),
      size: const Size(430, 900),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'dune');
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();
    expect(find.text('Top result'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'fits a phone');
    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(find.byType(UniversalSearchScreen), findsNothing);
    // The search is kept for next time.
    expect(search.query, 'dune');
  });

  testWidgets('a failed search offers Try again', (tester) async {
    final failing = UniversalSearchController(catalog: _Failing());
    addTearDown(failing.dispose);
    await pump(
      tester,
      UniversalSearchView(search: failing, onOpenTitle: opened.add),
    );
    await failing.search('dune');
    await tester.pumpAndSettle();
    expect(find.text('Search didn’t work'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });
}

class _Failing extends _Catalog {
  @override
  Future<Map<String, dynamic>> multi(String query, {int page = 1}) =>
      Future.error(Exception('offline'));
}
