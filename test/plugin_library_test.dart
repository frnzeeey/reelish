import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/plugin_catalog.dart';
import 'package:onfeed/src/models/provider_plugin.dart';
import 'package:onfeed/src/screens/plugin_details_screen.dart';
import 'package:onfeed/src/screens/plugin_library_screen.dart';
import 'package:onfeed/src/services/plugin_library_query.dart';
import 'package:onfeed/src/services/plugin_library_repository.dart';
import 'package:onfeed/src/services/plugin_library_service.dart';
import 'package:onfeed/src/services/provider_plugin_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:onfeed/src/widgets/plugin_library/plugin_card.dart';
import 'package:onfeed/src/widgets/plugin_library/plugin_filter_bar.dart';
import 'package:onfeed/src/widgets/plugin_library/plugin_install_button.dart';
import 'package:onfeed/src/widgets/plugin_library/plugin_logo.dart';

final _bundledJson = File('assets/data/plugins.json').readAsStringSync();

Map<String, Object?> _catalogJson({
  String updatedAt = '2026-10-01T00:00:00Z',
  List<Map<String, Object?>>? providers,
}) => {
  'version': 1,
  'updatedAt': updatedAt,
  'source': {
    'name': 'Test Library',
    'url': 'https://example.com/',
    'curator': 'tester',
  },
  'providers':
      providers ??
      [
        _provider(
          'alpha',
          'Alpha',
          author: 'zed',
          scrapers: ['AnimePahe', 'MoviesMod'],
          languages: ['Multi Language'],
          types: ['movie', 'tv', 'anime'],
          updated: '2026-09-30T00:00:00Z',
        ),
        _provider(
          'bravo',
          'Bravo',
          author: 'amy',
          scrapers: ['UHDMovies'],
          languages: ['Turkish'],
          updated: '2026-01-01T00:00:00Z',
        ),
        _provider(
          'charlie',
          'Charlie',
          author: 'bob',
          scrapers: ['One', 'Two', 'Three', 'Four', 'Five'],
          languages: ['French'],
        ),
      ],
};

Map<String, Object?> _provider(
  String id,
  String name, {
  String? author,
  List<String> scrapers = const [],
  List<String> languages = const [],
  List<String> types = const ['movie', 'tv'],
  String? updated,
}) => {
  'id': id,
  'name': name,
  'author': author,
  'languages': languages,
  'manifestUrl':
      'https://raw.githubusercontent.com/$id/repo/main/manifest.json',
  'lastUpdated': updated,
  'scrapers': [
    for (final scraper in scrapers)
      {
        'id': scraper.toLowerCase(),
        'name': scraper,
        'supportedTypes': types,
        'contentLanguage': ['en'],
      },
  ],
};

class _FakeService extends PluginLibraryService {
  _FakeService({this.cached, this.bundled, this.remote, this.remoteError});

  PluginCatalogSnapshot? cached;
  PluginCatalogSnapshot? bundled;
  PluginCatalogSnapshot? remote;
  Object? remoteError;
  int remoteCalls = 0;

  @override
  Future<PluginCatalogSnapshot?> loadCached() async => cached;

  @override
  Future<PluginCatalogSnapshot?> loadBundled() async => bundled;

  @override
  Future<PluginCatalogSnapshot> fetchRemote() async {
    remoteCalls++;
    if (remoteError != null) throw remoteError!;
    return remote!;
  }
}

PluginCatalogSnapshot _snapshot(
  Map<String, Object?> json,
  PluginCatalogOrigin origin, {
  DateTime? checkedAt,
}) => PluginCatalogSnapshot(
  catalog: PluginCatalog.fromJson(json),
  origin: origin,
  checkedAt: checkedAt,
);

void main() {
  group('PluginCatalog', () {
    test('the bundled catalog parses with real provider data', () {
      final catalog = PluginCatalog.fromJson(jsonDecode(_bundledJson));
      expect(catalog.providers, isNotEmpty);
      expect(catalog.sourceName, 'Community Plugin Library');
      for (final plugin in catalog.providers) {
        expect(plugin.manifestUrl?.scheme, 'https');
        expect(plugin.manifestUrl!.path, endsWith('/manifest.json'));
        // Nothing is marked featured or verified the source does not mark.
        expect(plugin.featured, isFalse);
        expect(plugin.verified, isFalse);
        if (!plugin.available) expect(plugin.scrapers, isEmpty);
      }
    });

    test('skips malformed entries and treats unsafe links as missing', () {
      final catalog = PluginCatalog.fromJson({
        'version': 1,
        'providers': [
          'not an object',
          {'id': 'no-name'},
          {
            'id': 'ok',
            'name': 'Ok',
            'manifestUrl': 'http://insecure.example/manifest.json',
            'iconUrl': 'javascript:alert(1)',
            'scrapers': [
              {
                'id': 's',
                'name': 'S',
                'logo': 'https://user:pw@example.com/a.png',
              },
              {'name': 'missing id'},
            ],
          },
          {'id': 'ok', 'name': 'Duplicate'},
        ],
      });
      expect(catalog.providers, hasLength(1));
      final plugin = catalog.providers.single;
      expect(plugin.manifestUrl, isNull);
      expect(plugin.iconUrl, isNull);
      expect(plugin.scrapers.single.logoUrl, isNull);
    });

    test('rejects unsupported catalog versions', () {
      expect(
        () => PluginCatalog.fromJson({'version': 99, 'providers': []}),
        throwsFormatException,
      );
      expect(() => PluginCatalog.fromJson([]), throwsFormatException);
    });

    test('logos never load from IP literals or local hosts', () {
      expect(
        PluginLogo.isLoadableLogo(Uri.parse('https://cdn.example.com/a.png')),
        isTrue,
      );
      expect(
        PluginLogo.isLoadableLogo(Uri.parse('https://192.168.1.1/a.png')),
        isFalse,
      );
      expect(
        PluginLogo.isLoadableLogo(Uri.parse('https://localhost/a.png')),
        isFalse,
      );
      expect(
        PluginLogo.isLoadableLogo(Uri.parse('https://printer.local/a.png')),
        isFalse,
      );
    });
  });

  group('PluginLibraryQuery', () {
    final plugins = PluginCatalog.fromJson(_catalogJson()).providers;
    List<String> names(PluginLibraryQuery query) =>
        query.apply(plugins).map((plugin) => plugin.name).toList();

    test(
      'searches names, authors, languages and scrapers case-insensitively',
      () {
        expect(names(const PluginLibraryQuery(search: 'ANIME')), ['Alpha']);
        expect(names(const PluginLibraryQuery(search: 'amy')), ['Bravo']);
        expect(names(const PluginLibraryQuery(search: 'turkish')), ['Bravo']);
        expect(names(const PluginLibraryQuery(search: 'movies')), [
          'Alpha',
          'Bravo',
        ]);
        expect(
          names(const PluginLibraryQuery(search: 'nothing-like-this')),
          isEmpty,
        );
      },
    );

    test('filters by language and content type', () {
      expect(names(const PluginLibraryQuery(language: 'french')), ['Charlie']);
      expect(
        names(const PluginLibraryQuery(contentType: PluginContentType.anime)),
        ['Alpha'],
      );
    });

    test('every sort mode changes the order', () {
      expect(names(const PluginLibraryQuery()), ['Charlie', 'Alpha', 'Bravo']);
      expect(names(const PluginLibraryQuery(sort: PluginSort.name)), [
        'Alpha',
        'Bravo',
        'Charlie',
      ]);
      expect(names(const PluginLibraryQuery(sort: PluginSort.author)), [
        'Bravo',
        'Charlie',
        'Alpha',
      ]);
      expect(names(const PluginLibraryQuery(sort: PluginSort.scraperCount)), [
        'Charlie',
        'Alpha',
        'Bravo',
      ]);
      // Providers without a date sort last.
      expect(
        names(const PluginLibraryQuery(sort: PluginSort.recentlyUpdated)),
        ['Alpha', 'Bravo', 'Charlie'],
      );
    });

    test(
      'recommended ranks featured, verified and reachable providers first',
      () {
        final ranked = PluginCatalog.fromJson(
          _catalogJson(
            providers: [
              {
                ..._provider(
                  'big',
                  'Big',
                  scrapers: List.generate(9, (i) => 's$i'),
                ),
              },
              {..._provider('down', 'Down'), 'available': false},
              {
                ..._provider('verified', 'Verified', scrapers: ['a']),
                'verified': true,
              },
              {..._provider('featured', 'Featured'), 'featured': true},
            ],
          ),
        ).providers;
        expect(const PluginLibraryQuery().apply(ranked).map((p) => p.name), [
          'Featured',
          'Verified',
          'Big',
          'Down',
        ]);
      },
    );

    test('stats and facets are derived from the data', () {
      final stats = PluginLibraryStats.of(plugins);
      expect(stats.providerCount, 3);
      expect(stats.sourceCount, 8);
      expect(stats.languageCount, 1);
      final facets = PluginLibraryFacets.of(plugins);
      expect(facets.languages.first, 'Multi Language');
      expect(facets.contentTypes, PluginContentType.values);
    });

    test('previews put scrapers matching the search first', () {
      final charlie = plugins.last;
      expect(previewScrapers(charlie).map((s) => s.name), [
        'One',
        'Two',
        'Three',
      ]);
      expect(previewScrapers(charlie, search: 'five').map((s) => s.name), [
        'Five',
        'One',
        'Two',
      ]);
    });
  });

  group('PluginLibraryRepository', () {
    final older = _catalogJson(updatedAt: '2026-01-01T00:00:00Z');
    final newer = _catalogJson(updatedAt: '2026-10-01T00:00:00Z');

    test(
      'shows the newest offline copy and skips the network while fresh',
      () async {
        final service = _FakeService(
          cached: _snapshot(
            newer,
            PluginCatalogOrigin.cache,
            checkedAt: DateTime.now().toUtc(),
          ),
          bundled: _snapshot(older, PluginCatalogOrigin.bundled),
        );
        final repository = PluginLibraryRepository(service: service);
        await repository.load();
        expect(repository.status, PluginLibraryStatus.ready);
        expect(repository.snapshot!.origin, PluginCatalogOrigin.cache);
        expect(service.remoteCalls, 0);
      },
    );

    test('a failed refresh keeps the offline catalog and flags it', () async {
      final service = _FakeService(
        bundled: _snapshot(older, PluginCatalogOrigin.bundled),
        remoteError: const SocketException('offline'),
      );
      final repository = PluginLibraryRepository(service: service);
      await repository.load();
      await repository.refresh();
      expect(repository.status, PluginLibraryStatus.ready);
      expect(repository.plugins, hasLength(3));
      expect(repository.showingOfflineCopy, isTrue);
    });

    test('reports an error only when there is nothing to show', () async {
      final service = _FakeService(
        remoteError: const SocketException('offline'),
      );
      final repository = PluginLibraryRepository(service: service);
      await repository.load();
      expect(repository.status, PluginLibraryStatus.error);

      service
        ..remoteError = null
        ..remote = _snapshot(newer, PluginCatalogOrigin.remote);
      await repository.retry();
      expect(repository.status, PluginLibraryStatus.ready);
      expect(repository.snapshot!.origin, PluginCatalogOrigin.remote);
      expect(repository.showingOfflineCopy, isFalse);
    });

    test(
      'an older remote catalog never replaces a newer bundled one',
      () async {
        final service = _FakeService(
          bundled: _snapshot(newer, PluginCatalogOrigin.bundled),
          remote: _snapshot(older, PluginCatalogOrigin.remote),
        );
        final repository = PluginLibraryRepository(service: service);
        await repository.load();
        await repository.refresh();
        expect(repository.snapshot!.origin, PluginCatalogOrigin.bundled);
        expect(repository.refreshError, isNull);
      },
    );
  });

  group('PluginLibraryService cache', () {
    late Directory directory;
    setUp(
      () => directory = Directory.systemTemp.createTempSync('plugin_catalog'),
    );
    tearDown(() => directory.deleteSync(recursive: true));

    test('a downloaded catalog is cached for offline use', () async {
      final service = PluginLibraryService(
        fetchRemote: () async => jsonEncode(_catalogJson()),
        cacheDirectory: () async => directory,
        loadBundled: () async => _bundledJson,
      );
      expect(await service.loadCached(), isNull);
      await service.fetchRemote();
      final cached = await service.loadCached();
      expect(cached!.origin, PluginCatalogOrigin.cache);
      expect(cached.catalog.providers, hasLength(3));
      expect(cached.checkedAt, isNotNull);
    });

    test('an invalid download does not overwrite the cache', () async {
      var body = jsonEncode(_catalogJson());
      final service = PluginLibraryService(
        fetchRemote: () async => body,
        cacheDirectory: () async => directory,
        loadBundled: () async => _bundledJson,
      );
      await service.fetchRemote();
      body = '{"version": 1}';
      await expectLater(service.fetchRemote(), throwsFormatException);
      expect((await service.loadCached())!.catalog.providers, hasLength(3));
    });
  });

  group('install integration', () {
    test('installed state comes from the existing provider service', () {
      final service = ProviderPluginService();
      const url =
          'https://raw.githubusercontent.com/alpha/repo/main/manifest.json';
      expect(PluginInstallButton.isInstalled(service, Uri.parse(url)), isFalse);
      service.repositories.add(
        const ProviderRepository(url: url, name: 'Alpha'),
      );
      expect(PluginInstallButton.isInstalled(service, Uri.parse(url)), isTrue);
      expect(PluginInstallButton.isInstalled(service, null), isFalse);
    });
  });

  group('PluginLibraryScreen', () {
    late ProviderPluginService pluginService;
    late PluginLibraryRepository repository;
    String? clipboard;

    setUp(() {
      pluginService = ProviderPluginService();
      repository = PluginLibraryRepository(
        service: _FakeService(
          cached: _snapshot(
            _catalogJson(),
            PluginCatalogOrigin.cache,
            checkedAt: DateTime.now().toUtc(),
          ),
        ),
      );
      clipboard = null;
    });

    Future<void> pumpLibrary(
      WidgetTester tester, {
      Size size = const Size(400, 900),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.dark,
          home: PluginLibraryScreen(
            repository: repository,
            pluginService: pluginService,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('renders the header, computed stats and plugin cards', (
      tester,
    ) async {
      await pumpLibrary(tester);
      expect(find.text('Reelish Plugins'), findsOneWidget);
      expect(
        find.text(
          'Discover community providers and expand your streaming sources.',
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('3 Providers'), findsOneWidget);
      expect(find.bySemanticsLabel('8 Sources'), findsOneWidget);
      expect(find.text('Largest collections'), findsOneWidget);
      expect(find.text('Popular providers'), findsNothing);
      await tester.scrollUntilVisible(
        find.text('All plugins'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('All plugins'), findsOneWidget);
    });

    testWidgets('search filters results and the empty state clears filters', (
      tester,
    ) async {
      await pumpLibrary(tester);
      await tester.enterText(find.byType(TextField), 'anime');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      expect(find.text('Results'), findsOneWidget);
      expect(find.text('1 provider'), findsOneWidget);
      expect(find.text('Largest collections'), findsNothing);

      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle(const Duration(milliseconds: 300));
      await tester.scrollUntilVisible(
        find.text('No plugins found'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text(
          'Try a different search or remove some filters. If the '
          'provider is not listed, paste its manifest URL instead.',
        ),
        findsOneWidget,
      );
      expect(find.text('Paste a manifest'), findsOneWidget);
      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('No plugins found'), findsNothing);
      expect(find.text('Largest collections'), findsOneWidget);
    });

    testWidgets('language chips and sort menu change the list', (tester) async {
      await pumpLibrary(tester);
      final turkish = find.widgetWithText(ChoiceChip, 'Turkish');
      await tester.scrollUntilVisible(
        turkish,
        100,
        scrollable: find
            .descendant(
              of: find.byType(PluginFilterBar),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(turkish);
      await tester.pumpAndSettle();
      await tester.tap(turkish);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Results'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('1 provider'), findsOneWidget);
      await tester.tap(turkish);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Recommended'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Name').last);
      await tester.pumpAndSettle();
      expect(find.text('Name'), findsOneWidget);
    });

    testWidgets('copy manifest writes the URL to the clipboard', (
      tester,
    ) async {
      await pumpLibrary(tester);
      await tester.tap(find.text('Copy').first);
      await tester.pump();
      expect(clipboard, startsWith('https://raw.githubusercontent.com/'));
      expect(clipboard, endsWith('/manifest.json'));
      expect(find.text('Manifest URL copied'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 3));
    });

    testWidgets('a card opens the details screen', (tester) async {
      await pumpLibrary(tester);
      await tester.tap(find.text('View details').first);
      await tester.pumpAndSettle();
      expect(find.text('Install plugin'), findsOneWidget);
      expect(find.text('Manifest'), findsOneWidget);
      expect(find.text('Not verified, community provider'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('One'),
        300,
        scrollable: find
            .descendant(
              of: find.byType(PluginDetailsScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      // The first-listed provider by recommendation has five sources.
      expect(find.text('One'), findsOneWidget);
    });

    testWidgets('an installed manifest is marked installed', (tester) async {
      pluginService.repositories.add(
        const ProviderRepository(
          url:
              'https://raw.githubusercontent.com/charlie/repo/main/manifest.json',
          name: 'Charlie',
        ),
      );
      await pumpLibrary(tester);
      expect(find.text('Installed'), findsWidgets);
    });

    for (final (width, columns) in [
      (400.0, 1),
      (800.0, 2),
      (1100.0, 3),
      (1600.0, 4),
    ]) {
      testWidgets('lays out $columns column(s) at ${width.toInt()}px', (
        tester,
      ) async {
        await pumpLibrary(tester, size: Size(width, 1400));
        await tester.scrollUntilVisible(
          find.text('All plugins'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
        await tester.pumpAndSettle();
        final grid = find.byType(SliverGrid);
        final cards = find.descendant(
          of: grid,
          matching: find.byType(PluginCard),
        );
        final tops = [
          for (final element in cards.evaluate())
            (element.renderObject! as RenderBox).localToGlobal(Offset.zero).dy,
        ];
        final firstRow = tops
            .where((top) => (top - tops.first).abs() < 1)
            .length;
        expect(firstRow, columns.clamp(1, 3));
      });
    }

    testWidgets('a failed load with no offline copy offers retry', (
      tester,
    ) async {
      repository = PluginLibraryRepository(
        service: _FakeService(remoteError: const SocketException('offline')),
      );
      await pumpLibrary(tester);
      expect(find.text('Unable to load plugins'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}
