import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/plugin_catalog.dart';
import 'package:onfeed/src/models/provider_plugin.dart';
import 'package:onfeed/src/screens/installed_provider_screen.dart';
import 'package:onfeed/src/screens/plugin_collection_screen.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/plugin_compatibility.dart';
import 'package:onfeed/src/services/plugin_library_repository.dart';
import 'package:onfeed/src/services/plugin_library_service.dart';
import 'package:onfeed/src/services/plugin_trust.dart';
import 'package:onfeed/src/services/provider_plugin_service.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _repoUrl =
    'https://raw.githubusercontent.com/someone/providers/main/manifest.json';

Map<String, dynamic> _scraper(
  String id, {
  String version = '1.0.0',
  List<String>? disabledPlatforms,
  List<String> types = const ['movie', 'tv'],
  bool hasSettings = false,
  bool enabled = true,
}) => {
  'id': id,
  'name': 'Provider $id',
  'filename': 'providers/$id.js',
  'version': version,
  'author': 'Someone',
  'supportedTypes': types,
  'enabled': enabled,
  'disabledPlatforms': ?disabledPlatforms,
  if (hasSettings) 'hasSettings': true,
};

ProviderRepository _parse(
  List<Map<String, dynamic>> scrapers, {
  String? version,
}) => ProviderRepository.fromJson(
  _repoUrl,
  'Someone repo',
  scrapers,
  version: version,
);

/// A service whose manifest and scripts come from the test.
class _Host {
  List<Map<String, dynamic>> scrapers = [_scraper('a'), _scraper('b')];
  String? repoVersion = '2.0.0';
  final Map<String, String> code = {};
  final Set<String> brokenScripts = {};
  bool offline = false;
  final List<String> downloads = [];

  Future<ProviderRepository> manifest(String url) async {
    if (offline) throw const SocketException('Network is unreachable');
    return _parse(scrapers, version: repoVersion);
  }

  Future<String> script(Uri url) async {
    downloads.add(url.toString());
    if (brokenScripts.contains(url.toString())) {
      throw const SocketException('Connection reset');
    }
    return code[url.toString()] ??
        'module.exports.getStreams = async () => [];';
  }

  ProviderPluginService service({ReelishDevice device = ReelishDevice.phone}) =>
      ProviderPluginService(
        storage: StorageService(),
        networkDestinations: NetworkDestinationValidator(
          lookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
        manifestReader: manifest,
        scriptReader: script,
        device: () => device,
      );
}

String _script(String id) =>
    'https://raw.githubusercontent.com/someone/providers/main/providers/$id.js';

class _CatalogService extends PluginLibraryService {
  _CatalogService(this.json);
  final Map<String, Object?> json;

  @override
  Future<PluginCatalogSnapshot?> loadCached() async => PluginCatalogSnapshot(
    catalog: PluginCatalog.fromJson(json),
    origin: PluginCatalogOrigin.cache,
    checkedAt: DateTime.now().toUtc(),
  );

  @override
  Future<PluginCatalogSnapshot?> loadBundled() async => null;

  @override
  Future<PluginCatalogSnapshot> fetchRemote() async =>
      throw const SocketException('offline');
}

Map<String, Object?> _catalog({String? listedUrl, bool verified = false}) => {
  'version': 1,
  'updatedAt': '2026-11-01T00:00:00Z',
  'providers': [
    if (listedUrl != null)
      {
        'id': 'someone',
        'name': 'Someone repo',
        'manifestUrl': listedUrl,
        'verified': verified,
        'scrapers': [],
      },
  ],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('manifest metadata', () {
    test('keeps what a provider declares and drops malformed values', () {
      final repository = ProviderRepository.fromJson(_repoUrl, 'Repo', [
        {
          ..._scraper('a', disabledPlatforms: ['tv', 'ios']),
          'logo': 'https://example.com/logo.png',
          'formats': ['m3u8', 7, null],
          'contentLanguage': ['en'],
          'hasSettings': true,
        },
        {
          'id': 'b',
          'filename': 'b.js',
          'version': {'nested': true},
          'author': ['not', 'text'],
          'logo': 'http://insecure.example/logo.png',
          'disabledPlatforms': 'tv',
          'hasSettings': 'yes',
        },
        'not an object',
        {'id': '', 'filename': 'missing-id.js'},
      ], version: 3);

      expect(repository.version, '3');
      expect(repository.plugins.map((p) => p.id), ['a', 'b']);
      final a = repository.plugins.first;
      expect(a.version, '1.0.0');
      expect(a.author, 'Someone');
      expect(a.logoUrl, Uri.parse('https://example.com/logo.png'));
      expect(a.formats, ['m3u8', '7']);
      expect(a.disabledPlatforms, ['tv', 'ios']);
      expect(a.hasSettings, isTrue);

      final b = repository.plugins.last;
      expect(b.version, isNull);
      expect(b.author, isNull);
      expect(b.logoUrl, isNull, reason: 'only HTTPS logos are kept');
      expect(b.disabledPlatforms, isEmpty);
      expect(b.hasSettings, isFalse);
    });

    test('copyWith keeps the declared metadata', () {
      final plugin = _parse([
        _scraper('a', disabledPlatforms: ['tv']),
      ]).plugins.single;
      final off = plugin.copyWith(enabled: false);
      expect(off.enabled, isFalse);
      expect(off.defaultEnabled, isTrue);
      expect(off.version, '1.0.0');
      expect(off.disabledPlatforms, ['tv']);
    });

    test('catalog scrapers tell "no platform data" from "none disabled"', () {
      final catalog = PluginCatalog.fromJson({
        'version': 1,
        'providers': [
          {
            'id': 'x',
            'name': 'X',
            'scrapers': [
              {'id': 'old', 'name': 'Old'},
              {
                'id': 'new',
                'name': 'New',
                'disabledPlatforms': [],
                'version': '1.2',
              },
            ],
          },
        ],
      });
      final scrapers = catalog.providers.single.scrapers;
      expect(scrapers.first.disabledPlatforms, isNull);
      expect(scrapers.last.disabledPlatforms, isEmpty);
      expect(scrapers.last.version, '1.2');
    });
  });

  group('compatibility', () {
    ProviderPlugin plugin(Map<String, dynamic> json) =>
        _parse([json]).plugins.single;

    test('nothing declared against the device is compatible', () {
      final result = PluginCompatibility.of(
        plugin(_scraper('a')),
        ReelishDevice.tv,
      );
      expect(result.level, PluginCompatibilityLevel.compatible);
      expect(result.reasons, isEmpty);
    });

    test('an author-disabled platform is unsupported only there', () {
      final tvOnly = plugin(_scraper('a', disabledPlatforms: ['tv']));
      final onTv = PluginCompatibility.of(tvOnly, ReelishDevice.tv);
      expect(onTv.level, PluginCompatibilityLevel.unsupported);
      expect(onTv.blockedOnDevice, isTrue);
      expect(onTv.reasons.single, contains('TV devices'));
      expect(
        PluginCompatibility.of(tvOnly, ReelishDevice.phone).level,
        PluginCompatibilityLevel.compatible,
      );
      expect(
        PluginCompatibility.of(tvOnly, ReelishDevice.windows).level,
        PluginCompatibilityLevel.compatible,
      );
    });

    test('platform names Reelish cannot map never block', () {
      final iosOnly = plugin(_scraper('a', disabledPlatforms: ['ios', 'web']));
      for (final device in ReelishDevice.values) {
        expect(
          PluginCompatibility.of(iosOnly, device).blockedOnDevice,
          isFalse,
        );
      }
    });

    test('a provider for content Reelish never searches cannot run', () {
      final anime = plugin(_scraper('a', types: ['anime']));
      final result = PluginCompatibility.of(anime, ReelishDevice.phone);
      expect(result.level, PluginCompatibilityLevel.unsupported);
      expect(result.searchable, isFalse);
    });

    test('declared settings Reelish lacks are a limit, not a block', () {
      final result = PluginCompatibility.of(
        plugin(_scraper('a', hasSettings: true)),
        ReelishDevice.phone,
      );
      expect(result.level, PluginCompatibilityLevel.partial);
      expect(result.blockedOnDevice, isFalse);
    });

    test('a catalog repository is judged from its scrapers', () {
      ReelishPlugin entry(List<Map<String, Object?>> scrapers) =>
          ReelishPlugin.tryParse({
            'id': 'x',
            'name': 'X',
            'scrapers': scrapers,
          })!;

      expect(
        PluginCompatibility.ofCatalog(
          entry([
            {
              'id': 'a',
              'name': 'A',
              'supportedTypes': ['movie'],
            },
          ]),
          ReelishDevice.tv,
        ).level,
        PluginCompatibilityLevel.unknown,
      );
      final mixed = PluginCompatibility.ofCatalog(
        entry([
          {
            'id': 'a',
            'name': 'A',
            'supportedTypes': ['movie'],
            'disabledPlatforms': ['tv'],
          },
          {
            'id': 'b',
            'name': 'B',
            'supportedTypes': ['tv'],
            'disabledPlatforms': [],
          },
        ]),
        ReelishDevice.tv,
      );
      expect(mixed.level, PluginCompatibilityLevel.partial);
      expect(mixed.reasons.single, contains('1 of its 2 sources'));
    });
  });

  group('source trust', () {
    test('only the catalog flag makes a publisher verified', () {
      expect(PluginSourceTrust.of(_repoUrl, null), PluginSourceTrust.unknown);
      expect(
        PluginSourceTrust.of(_repoUrl, PluginCatalog.fromJson(_catalog())),
        PluginSourceTrust.unlisted,
      );
      expect(
        PluginSourceTrust.of(
          _repoUrl,
          PluginCatalog.fromJson(_catalog(listedUrl: _repoUrl)),
        ),
        PluginSourceTrust.listed,
      );
      expect(
        PluginSourceTrust.of(
          _repoUrl,
          PluginCatalog.fromJson(_catalog(listedUrl: _repoUrl, verified: true)),
        ),
        PluginSourceTrust.verified,
      );
    });

    test('a look-alike address is not treated as listed', () {
      final catalog = PluginCatalog.fromJson(_catalog(listedUrl: _repoUrl));
      expect(
        PluginSourceTrust.of(
          'https://raw.githubusercontent.com/s0meone/providers/main/manifest.json',
          catalog,
        ),
        PluginSourceTrust.unlisted,
      );
    });

    test('the host is read from the address', () {
      expect(PluginHost.of(_repoUrl).label, 'GitHub · someone/providers');
      expect(
        PluginHost.of(
          'https://codeberg.org/api/v1/repos/eclipsia/nuvio-plugin/raw/manifest.json',
        ).label,
        'Codeberg · eclipsia/nuvio-plugin',
      );
      expect(
        PluginHost.of(
          'https://codeberg.org/CENSORED/Nuvio-Plugin/raw/branch/main/manifest.json',
        ).label,
        'Codeberg · CENSORED/Nuvio-Plugin',
      );
      expect(
        PluginHost.of('https://plugins.example.org/manifest.json').label,
        'plugins.example.org',
      );
    });
  });

  group('installed providers', () {
    test('a provider disabled for TV starts off on TV only', () async {
      final host = _Host()
        ..scrapers = [
          _scraper('a', disabledPlatforms: ['tv']),
          _scraper('b'),
        ];

      final tv = host.service(device: ReelishDevice.tv);
      await tv.install(_repoUrl);
      expect(tv.repositories.single.plugins.map((p) => p.enabled), [
        false,
        true,
      ]);

      SharedPreferences.setMockInitialValues({});
      final phone = host.service();
      await phone.install(_repoUrl);
      expect(phone.repositories.single.plugins.map((p) => p.enabled), [
        true,
        true,
      ]);
    });

    test('switching it on by choice survives a relaunch', () async {
      final host = _Host()
        ..scrapers = [
          _scraper('a', disabledPlatforms: ['tv']),
        ];
      final service = host.service(device: ReelishDevice.tv);
      await service.install(_repoUrl);
      final repo = service.repositories.single;
      await service.setPluginEnabled(repo, repo.plugins.single, true);

      final relaunched = host.service(device: ReelishDevice.tv);
      await relaunched.load();
      expect(relaunched.repositories.single.plugins.single.enabled, isTrue);
      expect(
        relaunched.hasEnabledChoice(
          relaunched.repositories.single,
          relaunched.repositories.single.plugins.single,
        ),
        isTrue,
      );
    });

    test('switching one provider off leaves the others alone', () async {
      final host = _Host();
      final service = host.service();
      await service.install(_repoUrl);
      final repo = service.repositories.single;
      await service.setPluginEnabled(repo, repo.plugins.first, false);
      expect(service.repositories.single.plugins.map((p) => p.enabled), [
        false,
        true,
      ]);
      expect(service.repositories.single.version, '2.0.0');
    });
  });

  group('update check', () {
    test('changed code waits for review with its version change', () async {
      final host = _Host();
      final service = host.service();
      await service.install(_repoUrl);

      // First check: the code listed at install is the trusted baseline.
      var result = await service.checkForUpdates(_repoUrl);
      expect(result, (checked: 2, awaitingReview: 0, failed: 0));
      final repo = service.repositories.single;
      expect(service.approvedVersionFor(repo, repo.plugins.first), '1.0.0');

      // The repository ships new code for "a" as 1.0.1.
      host.scrapers = [_scraper('a', version: '1.0.1'), _scraper('b')];
      host.code[_script('a')] = 'module.exports.getStreams = async () => [1];';
      result = await service.checkForUpdates(_repoUrl);
      expect(result, (checked: 2, awaitingReview: 1, failed: 0));
      final updated = service.repositories.single;
      final a = updated.plugins.first;
      expect(service.isAwaitingReview(updated, a), isTrue);
      expect(service.isAwaitingReview(updated, updated.plugins.last), isFalse);
      expect(service.approvedVersionFor(updated, a), '1.0.0');
      expect(a.version, '1.0.1');
      // Downloading is not running: no lookup happened.
      expect(service.errors, isEmpty);
      expect(service.lastLookupMessage, isNull);

      await service.approveScriptUpdates(_repoUrl);
      expect(service.isAwaitingReview(updated, a), isFalse);
      expect(service.approvedVersionFor(updated, a), '1.0.1');

      // Versions survive a relaunch; removal forgets them.
      final relaunched = host.service();
      await relaunched.load();
      final again = relaunched.repositories.single;
      expect(
        relaunched.approvedVersionFor(again, again.plugins.first),
        '1.0.1',
      );
      await relaunched.remove(again);
      expect(await StorageService().providerScriptVersions(), isEmpty);
    });

    test('a provider a manifest update adds is held for review', () async {
      final host = _Host();
      final service = host.service();
      await service.install(_repoUrl);
      host.scrapers = [...host.scrapers, _scraper('c')];
      final result = await service.checkForUpdates(_repoUrl);
      expect(result.awaitingReview, 1);
      final repo = service.repositories.single;
      final added = repo.plugins.last;
      expect(service.isAwaitingReview(repo, added), isTrue);
      expect(service.hasApprovedCode(repo, added), isFalse);
    });

    test('only providers that are on are downloaded', () async {
      final host = _Host()
        ..scrapers = [_scraper('a'), _scraper('b', enabled: false)];
      final service = host.service();
      await service.install(_repoUrl);
      await service.checkForUpdates(_repoUrl);
      expect(host.downloads, [_script('a')]);
    });

    test(
      'a script that cannot be downloaded is reported, not approved',
      () async {
        final host = _Host()..brokenScripts.add(_script('b'));
        final service = host.service();
        await service.install(_repoUrl);
        final result = await service.checkForUpdates(_repoUrl);
        expect(result, (checked: 1, awaitingReview: 0, failed: 1));
        final repo = service.repositories.single;
        expect(service.hasApprovedCode(repo, repo.plugins.last), isFalse);
      },
    );

    test('an unreachable manifest throws and keeps the collection', () async {
      final host = _Host();
      final service = host.service();
      await service.install(_repoUrl);
      host.offline = true;
      await expectLater(
        service.checkForUpdates(_repoUrl),
        throwsA(isA<SocketException>()),
      );
      expect(service.repositories.single.url, _repoUrl);
      expect(await StorageService().providerRepositoryUrls(), [_repoUrl]);
    });
  });

  group('Plugin Manager pages', () {
    Future<void> pump(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: GlassTheme.dark, home: home));
      await tester.pumpAndSettle();
    }

    testWidgets('a collection shows its source trust and providers', (
      tester,
    ) async {
      final host = _Host()
        ..scrapers = [
          _scraper('a'),
          _scraper('b', types: ['anime']),
        ];
      final service = host.service();
      await service.install(_repoUrl);
      final library = PluginLibraryRepository(
        service: _CatalogService(_catalog()),
      );

      await pump(
        tester,
        PluginCollectionScreen(
          repositoryUrl: _repoUrl,
          pluginService: service,
          pluginLibrary: library,
          device: ReelishDevice.phone,
        ),
      );
      expect(find.text('Someone repo'), findsWidgets);
      expect(find.text('Added by link'), findsWidgets);
      expect(find.textContaining('not a confirmed identity'), findsOneWidget);
      expect(find.text('Provider a'), findsOneWidget);
      expect(find.text('Provider b'), findsOneWidget);
      expect(find.text('What providers can do'), findsOneWidget);

      // The filter shows only what applies, with counts.
      await tester.tap(find.text('Not for this device (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Provider a'), findsNothing);
      expect(find.text('Provider b'), findsOneWidget);
    });

    testWidgets('a listed collection says listed, not safe', (tester) async {
      final service = _Host().service();
      await service.install(_repoUrl);
      final library = PluginLibraryRepository(
        service: _CatalogService(_catalog(listedUrl: _repoUrl)),
      );
      await pump(
        tester,
        PluginCollectionScreen(
          repositoryUrl: _repoUrl,
          pluginService: service,
          pluginLibrary: library,
          device: ReelishDevice.phone,
        ),
      );
      expect(find.text('Listed in the catalog'), findsWidgets);
      expect(
        find.textContaining('Nobody has verified its publisher'),
        findsOneWidget,
      );
      expect(find.text('Verified publisher'), findsNothing);
    });

    testWidgets('new code shows its version change and needs a yes', (
      tester,
    ) async {
      final host = _Host();
      final service = host.service();
      {
        await service.install(_repoUrl);
        await service.checkForUpdates(_repoUrl);
        host.scrapers = [_scraper('a', version: '1.0.1'), _scraper('b')];
        host.code[_script('a')] = 'module.exports = {changed: true};';
        await service.checkForUpdates(_repoUrl);
      }
      await pump(
        tester,
        PluginCollectionScreen(
          repositoryUrl: _repoUrl,
          pluginService: service,
          device: ReelishDevice.phone,
        ),
      );
      expect(find.text('1 provider has new code'), findsOneWidget);
      expect(find.textContaining('Version 1.0.0 → 1.0.1'), findsOneWidget);
      expect(find.text('Paused for review'), findsOneWidget);

      await tester.tap(find.text('Review and allow'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(service.pendingScriptUpdates, isNotEmpty);

      await tester.tap(find.text('Review and allow'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Allow'));
      await tester.pumpAndSettle();
      expect(service.pendingScriptUpdates, isEmpty);
      expect(find.text('1 provider has new code'), findsNothing);
    });

    testWidgets('switching on a provider not meant for TV asks first', (
      tester,
    ) async {
      final host = _Host()
        ..scrapers = [
          _scraper('a', disabledPlatforms: ['tv']),
        ];
      final service = host.service(device: ReelishDevice.tv);
      await service.install(_repoUrl);
      await pump(
        tester,
        PluginCollectionScreen(
          repositoryUrl: _repoUrl,
          pluginService: service,
          device: ReelishDevice.tv,
        ),
      );
      expect(find.text('Not for this device'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Switch on Provider a?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.repositories.single.plugins.single.enabled, isFalse);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Switch on anyway'));
      await tester.pumpAndSettle();
      expect(service.repositories.single.plugins.single.enabled, isTrue);
    });

    testWidgets('provider details explain compatibility and limits', (
      tester,
    ) async {
      final host = _Host()..scrapers = [_scraper('a', hasSettings: true)];
      final service = host.service();
      await service.install(_repoUrl);
      await pump(
        tester,
        InstalledProviderScreen(
          repositoryUrl: _repoUrl,
          pluginId: 'a',
          pluginService: service,
          device: ReelishDevice.windows,
        ),
      );
      expect(find.text('Provider a'), findsOneWidget);
      expect(find.text('Works with limits on Windows'), findsOneWidget);
      expect(find.textContaining('runs with its defaults'), findsOneWidget);
      expect(find.text('Someone (as its manifest states)'), findsOneWidget);
      expect(find.text('Search this provider'), findsOneWidget);

      await tester.tap(find.text('What providers can do'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Read your Reelish or Trakt account'),
        findsOneWidget,
      );
    });
  });
}
