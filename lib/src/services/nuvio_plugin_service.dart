import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;

import '../models/media_item.dart';
import '../models/nuvio_plugin.dart';
import '../models/stream_source.dart';
import 'provider_fetch_bridge.dart';
import 'network_target_policy.dart';
import 'storage_service.dart';
import 'stream_discovery.dart';
import 'stream_normalizer.dart';
import 'stream_validator.dart';
import 'provider_execution_scheduler.dart';

class NuvioPluginService extends ChangeNotifier {
  static Future<String>? _cheerioBundle;
  NuvioPluginService({
    StorageService? storage,
    ProviderExecutionScheduler? scheduler,
  }) : _storage = storage ?? StorageService(),
       _scheduler = scheduler ?? ProviderExecutionScheduler();

  final StorageService _storage;
  final ProviderExecutionScheduler _scheduler;
  final List<NuvioPluginRepository> repositories = [];
  final NetworkDestinationValidator _networkDestinations =
      NetworkDestinationValidator();
  static const StreamNormalizer _streamNormalizer = StreamNormalizer();
  static const StreamValidator _streamValidator = StreamValidator();
  final Map<String, String> errors = {};
  final Map<String, StreamDiscovery> _inflightDiscoveries = {};
  Map<String, bool> _enabledOverrides = {};
  String? lastLookupMessage;

  Future<void> load() async {
    repositories.clear();
    errors.clear();
    _enabledOverrides = await _storage.nuvioPluginEnabledOverrides();
    for (final url in await _storage.nuvioPluginRepositoryUrls()) {
      try {
        repositories.add(_applyOverrides(await _readRepository(url)));
      } catch (error) {
        errors[url] = _friendly(error);
      }
    }
    notifyListeners();
  }

  Future<NuvioPluginRepository> install(String rawUrl) async {
    final url = await _normalizeUrl(rawUrl);
    if (repositories.any((repo) => repo.url == url)) {
      throw Exception('This Nuvio plugin repository is already installed.');
    }
    final repository = _applyOverrides(await _readRepository(url));
    if (repository.plugins.isEmpty) {
      throw Exception('The repository manifest contains no valid providers.');
    }
    repositories.add(repository);
    await _storage.saveNuvioPluginRepositoryUrls(
      repositories.map((repo) => repo.url).toList(),
    );
    notifyListeners();
    return repository;
  }

  Future<void> remove(NuvioPluginRepository repo) async {
    repositories.removeWhere((entry) => entry.url == repo.url);
    _enabledOverrides.removeWhere((key, _) => key.startsWith('${repo.url}|'));
    await _storage.saveNuvioPluginEnabledOverrides(_enabledOverrides);
    await _storage.saveNuvioPluginRepositoryUrls(
      repositories.map((entry) => entry.url).toList(),
    );
    notifyListeners();
  }

  Future<void> setPluginEnabled(
    NuvioPluginRepository repository,
    NuvioPlugin plugin,
    bool enabled,
  ) async {
    final key = '${repository.url}|${plugin.id}';
    _enabledOverrides[key] = enabled;
    final updated = NuvioPluginRepository(
      url: repository.url,
      name: repository.name,
      plugins: repository.plugins
          .map(
            (entry) => entry.id == plugin.id
                ? entry.copyWith(enabled: enabled)
                : entry,
          )
          .toList(),
    );
    final index = repositories.indexWhere(
      (entry) => entry.url == repository.url,
    );
    if (index >= 0) repositories[index] = updated;
    await _storage.saveNuvioPluginEnabledOverrides(_enabledOverrides);
    notifyListeners();
  }

  NuvioPluginRepository _applyOverrides(NuvioPluginRepository repository) =>
      NuvioPluginRepository(
        url: repository.url,
        name: repository.name,
        plugins: repository.plugins
            .map(
              (plugin) => plugin.copyWith(
                enabled:
                    _enabledOverrides['${repository.url}|${plugin.id}'] ??
                    plugin.enabled,
              ),
            )
            .toList(),
      );

  Future<void> removeFailed(String url) async {
    errors.remove(url);
    final urls = await _storage.nuvioPluginRepositoryUrls()
      ..remove(url);
    await _storage.saveNuvioPluginRepositoryUrls(urls);
    notifyListeners();
  }

  Future<NuvioPluginRepository> _readRepository(String url) async {
    final response = await _secureGet(
      Uri.parse(url),
      timeout: const Duration(seconds: 15),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Plugin manifest request failed (${response.statusCode}).',
      );
    }
    final decoded = jsonDecode(response.body);
    final List<dynamic> entries;
    String? repositoryName;
    if (decoded is List) {
      entries = decoded;
    } else if (decoded is Map) {
      if (decoded.containsKey('pluginLists') ||
          decoded.containsKey('manifestVersion')) {
        throw Exception(
          'That link is a CloudStream repository. Use a Nuvio provider manifest from nuvioplugin.com.',
        );
      }
      repositoryName =
          decoded['repositoryName']?.toString() ?? decoded['name']?.toString();
      final wrapped = _providerList(decoded);
      if (wrapped != null) {
        entries = wrapped;
      } else if (_isProvider(decoded)) {
        entries = [decoded];
      } else if (decoded.containsKey('resources')) {
        throw Exception(
          'That link is an add-on manifest, not a Nuvio provider manifest. Copy the plugin manifest URL from nuvioplugin.com.',
        );
      } else {
        throw Exception(
          'The link returned JSON, but it is not a Nuvio provider manifest. Copy the plugin manifest URL from nuvioplugin.com.',
        );
      }
    } else {
      throw Exception(
        'The link did not return a Nuvio provider manifest. Copy the plugin manifest URL from nuvioplugin.com.',
      );
    }
    final name = Uri.parse(
      url,
    ).pathSegments.where((segment) => segment.isNotEmpty).toList();
    return NuvioPluginRepository.fromJson(
      url,
      repositoryName?.isNotEmpty == true
          ? repositoryName!
          : (name.length > 1
                ? name[name.length - 2]
                : 'Nuvio plugin repository'),
      entries,
    );
  }

  List<dynamic>? _providerList(Map<dynamic, dynamic> value) {
    for (final key in const [
      'plugins',
      'providers',
      'scrapers',
      'plugin',
      'provider',
      'manifest',
      'data',
    ]) {
      final candidate = value[key];
      if (candidate is List) return candidate;
      if (candidate is Map && _isProvider(candidate)) return [candidate];
    }
    return null;
  }

  bool _isProvider(Map<dynamic, dynamic> value) =>
      value['id'] != null &&
      (value['filename'] != null ||
          value['file'] != null ||
          value['script'] != null);

  StreamDiscovery discoverStreams(
    MediaItem item, {
    int? season,
    int? episode,
    Set<String>? allowedPluginIds,
    bool allowTorrents = true,
  }) {
    final filterKey = allowedPluginIds == null
        ? '*'
        : (allowedPluginIds.toList()..sort()).join(',');
    final key =
        '${item.type}|${item.id}|${season ?? ''}|${episode ?? ''}|$filterKey|$allowTorrents';
    final existing = _inflightDiscoveries[key];
    if (existing != null && !existing.isCancelled) return existing;

    final discovery = StreamDiscovery();
    _inflightDiscoveries[key] = discovery;
    unawaited(() async {
      try {
        await streams(
          item,
          season: season,
          episode: episode,
          allowedPluginIds: allowedPluginIds,
          allowTorrents: allowTorrents,
          onSource: discovery.add,
          onCandidate: discovery.recordCandidate,
          isCancelled: () => discovery.isCancelled,
        );
      } catch (error) {
        lastLookupMessage = _friendly(error);
      } finally {
        discovery.complete();
        if (identical(_inflightDiscoveries[key], discovery)) {
          _inflightDiscoveries.remove(key);
        }
      }
    }());
    return discovery;
  }

  Future<List<StreamSource>> streams(
    MediaItem item, {
    int? season,
    int? episode,
    Set<String>? allowedPluginIds,
    bool allowTorrents = true,
    void Function(StreamSource source)? onSource,
    void Function()? onCandidate,
    bool Function()? isCancelled,
  }) async {
    final mediaType = item.type == 'series' ? 'tv' : 'movie';
    final providers = repositories
        .expand((repo) => repo.plugins.map((plugin) => (repo, plugin)))
        .toList();
    final enabled = providers.where((entry) => entry.$2.enabled).toList();
    final available =
        enabled
            .where(
              (entry) =>
                  allowedPluginIds == null ||
                  allowedPluginIds.contains('${entry.$1.url}|${entry.$2.id}'),
            )
            .where((entry) => _supportsMediaType(entry.$2, mediaType))
            .toList()
          ..sort((a, b) {
            return b.$2.priority.compareTo(a.$2.priority);
          });
    if (repositories.isEmpty) {
      lastLookupMessage =
          'No Nuvio providers are installed. Open Plugins and install a provider manifest from nuvioplugin.com.';
      return [];
    }
    if (enabled.isEmpty) {
      lastLookupMessage =
          'Your installed providers are switched off. Open Plugins and enable at least one provider.';
      return [];
    }
    if (available.isEmpty) {
      lastLookupMessage = allowedPluginIds != null && allowedPluginIds.isEmpty
          ? 'No provider plugins are allowed for automatic stream selection. Update Allowed plugins in Playback settings.'
          : 'None of your enabled providers supports ${item.type == 'series' ? 'series' : 'movies'}.';
      return [];
    }

    lastLookupMessage = null;
    final discoveryStartedAt = DateTime.now();
    final lookupErrors = <String, String>{};
    final results = <StreamSource>[];
    var nextProviderIndex = 0;
    var stopStartingProviders = false;
    Future<void> runProviderWorker() async {
      while (!stopStartingProviders &&
          !(isCancelled?.call() ?? false) &&
          nextProviderIndex < available.length) {
        // Claim the index before the first await so each worker gets a
        // distinct provider. A small worker pool prevents 90+ enabled
        // providers from creating 90+ simultaneous QuickJS runtimes.
        final (repo, plugin) = available[nextProviderIndex++];
        final errorKey = '${plugin.name} (${repo.name})';
        errors.remove(errorKey);
        if (kDebugMode) {
          // ignore: avoid_print
          print(
            '[Provider Perf] ${plugin.id} started at '
            '${DateTime.now().difference(discoveryStartedAt).inMilliseconds}ms',
          );
        }
        try {
          final codeUrl = Uri.parse(repo.url).resolve(plugin.filename);
          final codeResponse = await _secureGet(
            codeUrl,
            timeout: const Duration(seconds: 20),
          );
          if (codeResponse.statusCode < 200 || codeResponse.statusCode >= 300) {
            throw Exception(
              'Provider script request failed (${codeResponse.statusCode}).',
            );
          }
          if (stopStartingProviders || (isCancelled?.call() ?? false)) return;
          await _scheduler.acquireRuntime();
          QuickJsRuntime2? runtime;
          ProviderFetchBridge? fetchBridge;
          try {
            if (stopStartingProviders || (isCancelled?.call() ?? false)) return;
            // The local flutter_js bridge resolves Android's exported QuickJS
            // memory-limit symbol so each provider keeps a bounded JS heap.
            final activeRuntime = QuickJsRuntime2(
              timeout: 20000,
              memoryLimit: 64 * 1024 * 1024,
              hostPromiseRejectionHandler: (reason) {
                if (!kDebugMode) return;
                // ignore: avoid_print
                print(
                  '[Provider JS] ${plugin.id} unhandled rejection: '
                  '${_safeProviderDiagnostic(reason)}',
                );
              },
            )..enableHandlePromises();
            runtime = activeRuntime;
            fetchBridge = ProviderFetchBridge(
              activeRuntime,
              null,
              _networkDestinations,
            );
            // Provider scripts often build package names dynamically, so
            // matching only literal require('...') calls misses valid module
            // requests such as `require(packageName)`. Detect the package
            // references anywhere in the source and install the compatible
            // modules before evaluating the provider.
            final normalizedProviderCode = codeResponse.body.toLowerCase();
            final needsCheerio = normalizedProviderCode.contains('cheerio');
            // Providers sometimes join "crypto" and "js" at runtime, so a
            // literal "crypto-js" search is not enough to find the import.
            final needsCryptoJs = normalizedProviderCode.contains('crypto');
            if (needsCheerio || needsCryptoJs) {
              final bundle = await (_cheerioBundle ??= rootBundle.loadString(
                'assets/js/cheerio_bundle.js',
              ));
              final loadedBundle = activeRuntime.evaluate(bundle);
              if (loadedBundle.isError) {
                throw Exception(loadedBundle.stringResult);
              }
              if (needsCheerio) {
                final status = activeRuntime.evaluate(
                  'typeof globalThis.__onfeedCheerio + ":" + '
                  'String(!!globalThis.__onfeedCheerio)',
                );
                if (status.isError ||
                    !const {
                      'function:true',
                      'object:true',
                    }.contains(status.stringResult)) {
                  throw StateError(
                    'The bundled Cheerio module did not initialize '
                    '(${status.stringResult}).',
                  );
                }
              }
              if (needsCryptoJs) {
                final status = activeRuntime.evaluate(
                  'typeof globalThis.__onfeedCryptoJs + ":" + '
                  'String(!!globalThis.__onfeedCryptoJs)',
                );
                if (status.isError ||
                    !const {
                      'function:true',
                      'object:true',
                    }.contains(status.stringResult)) {
                  throw StateError(
                    'The bundled CryptoJS module did not initialize '
                    '(${status.stringResult}).',
                  );
                }
              }
            }
            final setup = activeRuntime.evaluate('''
            globalThis.module = { exports: {} };
            globalThis.exports = globalThis.module.exports;
            globalThis.SCRAPER_ID = ${jsonEncode(plugin.id)};
            globalThis.SCRAPER_SETTINGS = {};
            globalThis.require = function(name) {
              const requestedModule = String(name).replace(/^node:/, '').toLowerCase();
              if ((requestedModule === 'cheerio' || requestedModule === 'cheerio-without-node-native' || requestedModule === 'react-native-cheerio') && globalThis.__onfeedCheerio) {
                return globalThis.__onfeedCheerio;
              }
              if (requestedModule === 'crypto-js' && globalThis.__onfeedCryptoJs) {
                return globalThis.__onfeedCryptoJs;
              }
              throw new Error('Unsupported provider module: ' + requestedModule);
            };
            globalThis.global = globalThis;
            globalThis.window = globalThis;
            globalThis.self = globalThis;
            globalThis.__providerLogs = [];
            const __captureProviderLog = (...args) => {
              if (globalThis.__providerLogs.length >= 20) globalThis.__providerLogs.shift();
              globalThis.__providerLogs.push(args.map(String).join(' ').slice(0, 400));
            };
            globalThis.console = {
              log: __captureProviderLog,
              warn: __captureProviderLog,
              error: __captureProviderLog
            };
          ''');
            if (setup.isError) throw Exception(setup.stringResult);
            final loaded = activeRuntime.evaluate(
              '(function() {\n${codeResponse.body}\n})();',
              sourceUrl: codeUrl.toString(),
            );
            if (loaded.isError) throw Exception(loaded.stringResult);
            final call = await activeRuntime.evaluateAsync('''
            (async function() {
              const provider = globalThis.module.exports || globalThis.exports || {};
              const getStreams = provider.getStreams || globalThis.getStreams;
              if (typeof getStreams !== 'function') {
                throw new Error('Provider must export getStreams(tmdbId, mediaType, season, episode).');
              }
              const streams = await getStreams(
                ${jsonEncode(item.id)}, ${jsonEncode(mediaType)},
                ${season?.toString() ?? 'undefined'}, ${episode?.toString() ?? 'undefined'}
              );
              return JSON.stringify({
                streams: Array.isArray(streams) ? streams : [],
                logs: globalThis.__providerLogs
              });
            })()
          ''');
            final value = await activeRuntime
                .handlePromise(call)
                .timeout(const Duration(seconds: 20));
            final decoded = jsonDecode(value.stringResult);
            final List<dynamic> streamEntries;
            if (decoded is List) {
              streamEntries = decoded;
            } else if (decoded is Map && decoded['streams'] is List) {
              streamEntries = decoded['streams'] as List;
              // An empty result is normal for a title a provider does not
              // index. Keep its logs out of the persistent provider-error list.
            } else {
              streamEntries = const [];
            }
            if (kDebugMode) {
              // ignore: avoid_print
              print(
                '[Provider Perf] ${plugin.id} returned ${streamEntries.length} candidates at '
                '${DateTime.now().difference(discoveryStartedAt).inMilliseconds}ms',
              );
            }
            for (final entry in streamEntries.whereType<Map>()) {
              onCandidate?.call();
              final normalized = _streamNormalizer.normalize(
                Map<String, dynamic>.from(entry),
                providerId: plugin.id,
                providerName: plugin.name,
              );
              final source = normalized.source;
              try {
                _streamValidator.validate(source);
              } catch (_) {
                continue;
              }
              if (source.isPlayable) {
                if (!allowTorrents && source.isTorrent) continue;
                results.add(source);
                onSource?.call(source);
              }
            }
          } finally {
            try {
              fetchBridge?.dispose();
            } finally {
              final activeRuntime = runtime;
              try {
                if (activeRuntime != null) {
                  final runtimeId = activeRuntime.getEngineInstanceId();
                  try {
                    activeRuntime.dispose();
                  } finally {
                    JavascriptRuntime.channelFunctionsRegistered.remove(
                      runtimeId,
                    );
                  }
                }
              } finally {
                _scheduler.releaseRuntime();
              }
            }
          }
        } catch (error) {
          final message = _friendly(error);
          if (kDebugMode) {
            // ignore: avoid_print
            print(
              '[Provider Perf] ${plugin.id} failed: '
              '${_safeProviderDiagnostic(message)}',
            );
          }
          errors[errorKey] = message;
          lookupErrors[errorKey] = message;
        }
      }
    }

    // Fetch scripts concurrently; the shared runtime gate bounds JS heaps.
    final workerCount = _scheduler.workersFor(available.length);
    // Large repositories can contain dozens of providers, and each worker may
    // encounter a slow script host or provider endpoint. Source selection is
    // progressive, so this longer cap only affects lookups still finding no
    // usable source.
    const searchTimeout = Duration(seconds: 60);
    var searchTimedOut = false;
    try {
      await Future.wait(
        List.generate(workerCount, (_) => runProviderWorker()),
      ).timeout(searchTimeout);
    } on TimeoutException {
      // Stop workers from starting additional providers. Active provider
      // runtimes finish their own bounded request and clean themselves up.
      searchTimedOut = true;
      stopStartingProviders = true;
    }
    final unique = <String, StreamSource>{};
    for (final stream in results) {
      final headersKey = stream.headers.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final key =
          '${stream.url}|${jsonEncode(headersKey.map((e) => [e.key, e.value]).toList())}';
      unique.putIfAbsent(key, () => stream);
    }
    if (searchTimedOut) {
      final timeoutSeconds = searchTimeout.inSeconds;
      lastLookupMessage = unique.isEmpty
          ? 'Provider search stopped after $timeoutSeconds seconds without finding a stream. Try fewer enabled providers or try again.'
          : 'Showing sources found in $timeoutSeconds seconds. Some providers did not finish.';
    }
    if (unique.isEmpty) {
      if (searchTimedOut) {
        // Keep the timeout message as the useful result for this lookup.
      } else if (lookupErrors.isNotEmpty) {
        final first = lookupErrors.entries.first;
        lastLookupMessage = '${first.key}: ${first.value}';
        if (lookupErrors.length > 1) {
          lastLookupMessage =
              '$lastLookupMessage Open Plugins to see the other provider errors.';
        }
      } else {
        lastLookupMessage =
            'The enabled Nuvio providers returned no streams for this title. Try another title or provider.';
      }
    }
    if (lookupErrors.isNotEmpty) notifyListeners();
    return unique.values.toList();
  }

  bool _supportsMediaType(NuvioPlugin plugin, String requestedType) {
    String normalize(String type) => switch (type.toLowerCase()) {
      'tv' || 'series' || 'show' || 'shows' => 'tv',
      'movie' || 'movies' || 'film' || 'films' => 'movie',
      _ => type.toLowerCase(),
    };
    return plugin.supportedTypes.any(
      (type) => normalize(type) == requestedType,
    );
  }

  Future<String> _normalizeUrl(String raw) async {
    final url = raw.trim();
    final uri = Uri.tryParse(url);
    if (uri == null) {
      throw Exception(
        'Use an HTTPS URL for a Nuvio plugin repository or manifest.',
      );
    }
    await _networkDestinations.resolveDestination(uri);

    // Plugin directories commonly provide either a raw manifest link or a
    // GitHub repository/file link. Convert those links to the raw manifest
    // that the Nuvio repository format uses.
    if (uri.host == 'github.com' || uri.host == 'www.github.com') {
      final segments = uri.pathSegments
          .where((part) => part.isNotEmpty)
          .toList();
      if (segments.length < 2) {
        throw Exception('The GitHub link must identify a repository.');
      }
      final owner = segments[0];
      final repository = segments[1].replaceFirst(RegExp(r'\.git$'), '');
      if (segments.length >= 5 &&
          (segments[2] == 'blob' || segments[2] == 'raw')) {
        final filePath = segments.skip(4).join('/');
        if (filePath.split('/').last != 'manifest.json') {
          throw Exception('Choose the repository manifest.json file.');
        }
        return Uri.https(
          'raw.githubusercontent.com',
          '$owner/$repository/${segments.skip(3).join('/')}',
        ).toString();
      }

      // A repository root or tree link needs its default branch to construct
      // the raw manifest URL.
      final response = await _secureGet(
        Uri.https('api.github.com', 'repos/$owner/$repository'),
        headers: const {'User-Agent': 'Onfeed'},
        timeout: const Duration(seconds: 15),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'Could not read that GitHub repository (${response.statusCode}). Paste its raw manifest.json URL instead.',
        );
      }
      final data = jsonDecode(response.body);
      final branch = data is Map ? '${data['default_branch'] ?? ''}' : '';
      if (branch.isEmpty) {
        throw Exception('Could not determine the GitHub repository branch.');
      }
      return Uri.https(
        'raw.githubusercontent.com',
        '$owner/$repository/$branch/manifest.json',
      ).toString();
    }

    if (!uri.path.toLowerCase().endsWith('/manifest.json') &&
        uri.path.toLowerCase() != 'manifest.json') {
      throw Exception(
        'Paste a Nuvio manifest.json URL or a GitHub repository/file link.',
      );
    }
    return uri.toString();
  }

  Future<http.Response> _secureGet(
    Uri uri, {
    Map<String, String> headers = const {},
    required Duration timeout,
  }) async {
    var current = uri;
    final requestHeaders = Map<String, String>.of(headers);
    for (var redirects = 0; redirects <= 5; redirects++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(requestHeaders);
      final response = await _networkDestinations.sendForBytes(
        request,
        allowedSchemes: const {'https'},
        maxResponseBytes: 4 * 1024 * 1024,
        timeout: timeout,
      );
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
        return response;
      }
      final location = response.headers['location'];
      if (location == null || redirects == 5) {
        throw const FormatException('Invalid plugin redirect.');
      }
      final target = await _networkDestinations.validateRedirect(
        current,
        location,
        allowedSchemes: const {'https'},
      );
      final sameOrigin =
          current.scheme == target.scheme &&
          current.host.toLowerCase() == target.host.toLowerCase() &&
          current.port == target.port;
      if (!sameOrigin) {
        requestHeaders.removeWhere(
          (name, _) =>
              !const {'accept', 'user-agent'}.contains(name.toLowerCase()),
        );
      }
      current = target;
    }
    throw const FormatException('Too many plugin redirects.');
  }

  String _friendly(Object error) {
    if (error is TimeoutException) {
      return 'This provider took too long to respond. Try again later or use another provider.';
    }
    return error.toString().replaceFirst(
      RegExp(r'^[A-Za-z0-9_]*Exception:\s*'),
      '',
    );
  }

  String _safeProviderDiagnostic(Object? error) {
    final message = '$error'.replaceAllMapped(
      RegExp(r"""https?://[^\s"'<>]+""", caseSensitive: false),
      (match) {
        final host = Uri.tryParse(match.group(0)!)?.host;
        return host == null || host.isEmpty ? '[URL]' : host;
      },
    );
    return message.length > 400 ? '${message.substring(0, 397)}...' : message;
  }
}
