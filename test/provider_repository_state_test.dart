import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/provider_plugin.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/provider_plugin_service.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alpha = 'https://example.com/alpha/manifest.json';
const _beta = 'https://example.com/beta/manifest.json';
const _gamma = 'https://example.com/gamma/manifest.json';

ProviderRepository _repository(String url) => ProviderRepository(
  url: url,
  name: url,
  plugins: const [
    ProviderPlugin(id: 'p', name: 'Provider', filename: 'provider.js'),
  ],
);

/// A manifest host whose answers the test releases one URL at a time.
class _ManifestHost {
  final Map<String, Completer<ProviderRepository>> pending = {};
  final Set<String> offline = {};
  final List<String> requested = [];

  Future<ProviderRepository> read(String url) {
    requested.add(url);
    if (offline.contains(url)) {
      return Future.error(const SocketException('Network is unreachable'));
    }
    return (pending[url] ??= Completer<ProviderRepository>()).future;
  }

  void answer(String url) {
    final completer = pending.remove(url);
    completer?.complete(_repository(url));
  }

  void answerAll() => pending.keys.toList().forEach(answer);
}

ProviderPluginService _service(_ManifestHost host) => ProviderPluginService(
  storage: StorageService(),
  networkDestinations: NetworkDestinationValidator(
    lookup: (_) async => [InternetAddress('93.184.216.34')],
  ),
  manifestReader: host.read,
);

Future<List<String>> _savedUrls() => StorageService().providerRepositoryUrls();

void main() {
  late _ManifestHost host;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'onfeed.nuvio.plugin.repositories': [_alpha, _beta],
    });
    host = _ManifestHost();
  });

  test(
    'an install during the launch load keeps every saved repository',
    () async {
      final service = _service(host);
      final loading = service.load();
      await pumpEventQueue();
      // Launch load still waiting on the saved manifests; repositories is empty.
      expect(service.repositories, isEmpty);

      final installing = service.install(_gamma);
      await pumpEventQueue();
      host.answer(_gamma);
      await pumpEventQueue();
      host.answerAll();
      await loading;
      await installing;

      expect(await _savedUrls(), [_alpha, _beta, _gamma]);
      expect(service.repositories.map((repo) => repo.url), [
        _alpha,
        _beta,
        _gamma,
      ]);
    },
  );

  test('a removal during a refresh is not undone by the refresh', () async {
    final service = _service(host);
    final first = service.load();
    await pumpEventQueue();
    host.answerAll();
    await first;

    final refreshing = service.load();
    await pumpEventQueue();
    final removing = service.remove(service.repositories.first);
    host.answerAll();
    await refreshing;
    await removing;

    expect(await _savedUrls(), [_beta]);
    expect(service.repositories.map((repo) => repo.url), [_beta]);
  });

  test('installing the same repository twice saves it once', () async {
    SharedPreferences.setMockInitialValues({});
    final service = _service(host);
    final first = service.install(_gamma);
    final second = service.install(_gamma);
    await pumpEventQueue();
    host.answerAll();
    await first;
    await expectLater(second, throwsException);

    expect(await _savedUrls(), [_gamma]);
    expect(service.repositories, hasLength(1));
  });

  test('a repository that fails to load stays installed', () async {
    host.offline.add(_alpha);
    final service = _service(host);
    final loading = service.load();
    await pumpEventQueue();
    host.answerAll();
    await loading;

    expect(service.failedRepositoryUrls, {_alpha});
    expect(service.errors.keys, contains(_alpha));
    // Dismiss only hides provider lookup errors; it never uninstalls.
    service.dismissError(_alpha);
    expect(service.errors.keys, contains(_alpha));
    expect(await _savedUrls(), [_alpha, _beta]);

    // Removing it is an explicit action.
    await service.removeFailed(_alpha);
    expect(await _savedUrls(), [_beta]);
    expect(service.errors, isEmpty);
  });

  test('a refresh that cannot reach a host keeps the loaded copy', () async {
    final service = _service(host);
    final first = service.load();
    await pumpEventQueue();
    host.answerAll();
    await first;

    host.offline.add(_alpha);
    final refresh = service.load();
    await pumpEventQueue();
    host.answerAll();
    await refresh;

    expect(service.repositories.map((repo) => repo.url), [_alpha, _beta]);
    expect(service.failedRepositoryUrls, {_alpha});
  });

  group('provider code changes', () {
    const movie = MediaItem(id: '1', type: 'movie', name: 'Film');
    // The approval decision happens before a script runs. (The desktop
    // QuickJS build used by `flutter test` cannot apply the runtime memory
    // limit, so a script that is allowed fails to start here; a paused one
    // never gets that far.)
    bool paused(ProviderPluginService service) => RegExp(
      'changed (its|their) code',
    ).hasMatch(service.lastLookupMessage ?? '');

    ProviderPluginService serviceWith(String Function() code) =>
        ProviderPluginService(
          storage: StorageService(),
          networkDestinations: NetworkDestinationValidator(
            lookup: (_) async => [InternetAddress('93.184.216.34')],
          ),
          manifestReader: (url) async => _repository(url),
          scriptReader: (_) async => code(),
        );

    test('changed code is paused until the viewer allows it', () async {
      SharedPreferences.setMockInitialValues({
        'onfeed.nuvio.plugin.repositories': [_alpha],
      });
      var code = 'module.exports.getStreams = async () => [];';
      final service = serviceWith(() => code);
      await service.load();

      // First version seen: trusted and recorded.
      await service.streams(movie);
      expect(paused(service), isFalse);
      expect(service.pendingScriptUpdates, isEmpty);

      // The repository changes the script: it is held back.
      code = 'module.exports.getStreams = async () => [/* changed */];';
      await service.load(); // A refresh drops cached scripts.
      expect(await service.streams(movie), isEmpty);
      expect(paused(service), isTrue);
      expect(service.pendingScriptUpdates.keys, [_alpha]);

      // Allowed: the new code may run, and the approval is remembered.
      await service.approveScriptUpdates(_alpha);
      await service.streams(movie);
      expect(paused(service), isFalse);
      expect(service.pendingScriptUpdates, isEmpty);

      final relaunched = serviceWith(() => code);
      await relaunched.load();
      await relaunched.streams(movie);
      expect(paused(relaunched), isFalse);

      // Removing the repository forgets its approvals.
      await relaunched.remove(relaunched.repositories.single);
      SharedPreferences.setMockInitialValues({
        'onfeed.nuvio.plugin.repositories': [_alpha],
        'onfeed.plugin.scriptHashes.v1':
            (await SharedPreferences.getInstance()).getString(
              'onfeed.plugin.scriptHashes.v1',
            ) ??
            '{}',
      });
      final reinstalled = serviceWith(() => 'module.exports = {};');
      await reinstalled.load();
      await reinstalled.streams(movie);
      expect(paused(reinstalled), isFalse);
    });

    test('a script a manifest update adds waits for approval', () async {
      SharedPreferences.setMockInitialValues({});
      var plugins = const [
        ProviderPlugin(id: 'p', name: 'Provider', filename: 'provider.js'),
      ];
      final service = ProviderPluginService(
        storage: StorageService(),
        networkDestinations: NetworkDestinationValidator(
          lookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
        manifestReader: (url) async =>
            ProviderRepository(url: url, name: url, plugins: plugins),
        scriptReader: (_) async =>
            'module.exports.getStreams = async () => [];',
      );
      await service.install(_alpha);

      // A script listed at install time is trusted on first use.
      await service.streams(movie);
      expect(paused(service), isFalse);
      expect(service.pendingScriptUpdates, isEmpty);

      // The repository later points its provider at a new file and adds
      // another provider: neither runs until the viewer allows it.
      plugins = const [
        ProviderPlugin(id: 'p', name: 'Provider', filename: 'provider-v2.js'),
        ProviderPlugin(id: 'q', name: 'Newcomer', filename: 'newcomer.js'),
      ];
      await service.load();
      expect(await service.streams(movie), isEmpty);
      expect(paused(service), isTrue);
      expect(service.pendingScriptUpdates[_alpha]?.keys, {
        'https://example.com/alpha/provider-v2.js',
        'https://example.com/alpha/newcomer.js',
      });

      await service.approveScriptUpdates(_alpha);
      await service.streams(movie);
      expect(paused(service), isFalse);
      expect(service.pendingScriptUpdates, isEmpty);

      // The approval survives a relaunch.
      final relaunched = ProviderPluginService(
        storage: StorageService(),
        networkDestinations: NetworkDestinationValidator(
          lookup: (_) async => [InternetAddress('93.184.216.34')],
        ),
        manifestReader: (url) async =>
            ProviderRepository(url: url, name: url, plugins: plugins),
        scriptReader: (_) async =>
            'module.exports.getStreams = async () => [];',
      );
      await relaunched.load();
      await relaunched.streams(movie);
      expect(paused(relaunched), isFalse);
    });

    test('repositories installed before tracking keep working', () async {
      // Saved by an older version: no record of the scripts at install.
      SharedPreferences.setMockInitialValues({
        'onfeed.nuvio.plugin.repositories': [_alpha],
      });
      final service = serviceWith(
        () => 'module.exports.getStreams = async () => [];',
      );
      await service.load();
      await service.streams(movie);
      expect(paused(service), isFalse);
      expect(service.pendingScriptUpdates, isEmpty);
    });
  });

  test('an unchanged manifest is not downloaded again', () async {
    SharedPreferences.setMockInitialValues({
      'onfeed.nuvio.plugin.repositories': [_alpha],
    });
    final files = await Directory.systemTemp.createTemp('manifest-cache-');
    addTearDown(() => files.delete(recursive: true));
    var version = 'v1';
    final conditions = <String?>[];
    final client = MockClient((request) async {
      conditions.add(request.headers['If-None-Match']);
      if (request.headers['If-None-Match'] == '"$version"') {
        return http.Response('', 304);
      }
      return http.Response(
        jsonEncode([
          {'id': 'p', 'name': 'Provider $version', 'filename': 'p.js'},
        ]),
        200,
        headers: {'etag': '"$version"'},
      );
    });
    ProviderPluginService service() => ProviderPluginService(
      storage: StorageService(filesDirectory: () async => files),
      networkDestinations: NetworkDestinationValidator(
        lookup: (_) async => [InternetAddress('93.184.216.34')],
      ),
      httpClient: client,
    );
    String providerName(ProviderPluginService service) =>
        service.repositories.single.plugins.single.name;

    final first = service();
    await first.load();
    expect(providerName(first), 'Provider v1');
    // The copy is saved in the background.
    final cache = File('${files.path}/provider_manifests.v1.json');
    for (var i = 0; i < 100 && !await cache.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    // Next launch: a conditional request, answered 304 from the cache.
    final second = service();
    await second.load();
    expect(conditions, [null, '"v1"']);
    expect(providerName(second), 'Provider v1');

    // A changed manifest is downloaded again.
    version = 'v2';
    await second.load();
    expect(providerName(second), 'Provider v2');
  });

  test('removal forgets approvals for scripts on other hosts', () async {
    SharedPreferences.setMockInitialValues({});
    const elsewhere = 'https://cdn.other.example/provider.js';
    final service = ProviderPluginService(
      storage: StorageService(),
      networkDestinations: NetworkDestinationValidator(
        lookup: (_) async => [InternetAddress('93.184.216.34')],
      ),
      manifestReader: (url) async => ProviderRepository(
        url: url,
        name: url,
        plugins: const [
          ProviderPlugin(id: 'p', name: 'Provider', filename: elsewhere),
        ],
      ),
      scriptReader: (_) async => 'module.exports.getStreams = async () => [];',
    );
    await service.install(_alpha);
    await service.streams(const MediaItem(id: '1', type: 'movie', name: 'F'));
    expect((await StorageService().providerScriptHashes()).keys, [elsewhere]);

    await service.remove(service.repositories.single);

    expect(await StorageService().providerScriptHashes(), isEmpty);
    expect(await StorageService().providerKnownScripts(), isEmpty);
  });

  test('concurrent lookups each keep their own message', () async {
    final service = _service(host);
    final loading = service.load();
    await pumpEventQueue();
    host.answerAll();
    await loading;
    const movie = MediaItem(id: '1', type: 'movie', name: 'Film');

    // One lookup has no allowed plugins; the other allows only an
    // unknown one. Both finish with nothing, for different reasons.
    final none = service.discoverStreams(movie, allowedPluginIds: {});
    final unknown = service.discoverStreams(
      const MediaItem(id: '2', type: 'movie', name: 'Other'),
      allowedPluginIds: {'https://elsewhere.example/manifest.json|x'},
    );
    await Future.wait([none.finished, unknown.finished]);

    expect(none.message, contains('No provider plugins are allowed'));
    expect(unknown.message, contains('None of your enabled providers'));
  });

  test('a lookup after an offline launch retries the repositories', () async {
    host.offline.addAll([_alpha, _beta]);
    final service = _service(host);
    await service.load();
    expect(service.repositories, isEmpty);

    final offlineLookup = await service.streams(
      const MediaItem(id: '1', type: 'movie', name: 'Film', poster: ''),
    );
    expect(offlineLookup, isEmpty);
    expect(service.lastLookupMessage, contains('could not be loaded'));
    expect(
      host.requested.where((url) => url == _alpha),
      hasLength(1),
      reason: 'a retry within 30 seconds of the last load is skipped',
    );
  });
}
