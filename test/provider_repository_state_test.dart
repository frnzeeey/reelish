import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
    bool paused(ProviderPluginService service) =>
        service.lastLookupMessage?.contains('changed its code') ?? false;

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
