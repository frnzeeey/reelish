import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';

import 'provider_fetch_bridge.dart';

/// Everything one provider run needs. All fields can cross an isolate
/// boundary.
class ProviderRunRequest {
  const ProviderRunRequest({
    required this.pluginId,
    required this.code,
    required this.codeUrl,
    required this.tmdbId,
    required this.mediaType,
    this.season,
    this.episode,
    this.bundle,
    this.needsCheerio = false,
    this.needsCryptoJs = false,
    this.memoryLimit = 64 * 1024 * 1024,
    this.interruptAfter = const Duration(seconds: 40),
  });

  final String pluginId;
  final String code;
  final String codeUrl;
  final String tmdbId;
  final String mediaType;
  final int? season;
  final int? episode;

  /// The Cheerio/CryptoJS bundle, sent only when the script refers to it.
  final String? bundle;
  final bool needsCheerio;
  final bool needsCryptoJs;

  /// QuickJS heap limit in bytes. Null only where the native library lacks
  /// the memory-limit symbol (desktop test builds of flutter_js).
  final int? memoryLimit;

  /// Script code still running this long after the run starts is stopped,
  /// synchronous loops included, where the platform's QuickJS supports it.
  /// Null leaves only the engine's own timeout.
  final Duration? interruptAfter;
}

/// Thrown on the calling isolate when a provider run fails. Its text is the
/// provider's own error message.
class ProviderRunException implements Exception {
  const ProviderRunException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Runs provider scripts on a background isolate.
///
/// QuickJS evaluates synchronously through FFI on the calling isolate. On the
/// UI isolate, parsing the 700 KB Cheerio/CryptoJS bundle and running provider
/// code dropped frames during every stream search. Each run gets a fresh
/// isolate holding its own QuickJS runtime, fetch bridge and timers, so the
/// provider sandbox is unchanged; only the thread it runs on moved.
abstract final class ProviderRunner {
  /// Longest a whole provider run may take; a backstop behind
  /// [ProviderRunRequest.interruptAfter]. Synchronous script code (an
  /// endless loop, a runaway regular expression) runs inside native QuickJS
  /// and only stops when the engine interrupts it: the QuickJS builds in use
  /// ignore their own timeout for such code, so the run's interrupt
  /// deadline does it where the native library supports one (Android).
  /// Where it does not, the caller still gets a timeout here and frees the
  /// provider's runtime slot, so one stuck provider cannot stall every later
  /// stream search, though the stuck isolate keeps running.
  static const hardTimeout = Duration(seconds: 45);

  /// Returns the raw stream objects from the provider's `getStreams`.
  /// Throws [TimeoutException] or [ProviderRunException] on failure.
  static Future<List<Map<String, dynamic>>> run(
    ProviderRunRequest request, {
    @visibleForTesting Duration timeout = hardTimeout,
  }) async {
    final result = await Isolate.run(() => _run(request)).timeout(
      timeout,
      onTimeout: () =>
          throw TimeoutException('Provider ${request.pluginId} timed out.'),
    );
    if (result.timedOut) {
      throw TimeoutException('Provider ${request.pluginId} timed out.');
    }
    final error = result.error;
    if (error != null) throw ProviderRunException(error);
    return result.streams;
  }

  static Future<
    ({List<Map<String, dynamic>> streams, String? error, bool timedOut})
  >
  _run(ProviderRunRequest request) async {
    final interruptAfter = request.interruptAfter;
    final deadline = interruptAfter == null
        ? null
        : DateTime.now().add(interruptAfter);
    QuickJsRuntime2? runtime;
    ProviderFetchBridge? fetchBridge;
    try {
      // The local flutter_js bridge resolves Android's exported QuickJS
      // memory-limit symbol so each provider keeps a bounded JS heap.
      final activeRuntime = QuickJsRuntime2(
        timeout: 20000,
        memoryLimit: request.memoryLimit,
        hostPromiseRejectionHandler: (reason) {
          if (!kDebugMode) return;
          // ignore: avoid_print
          print(
            '[Provider JS] ${request.pluginId} unhandled rejection: '
            '${safeProviderDiagnostic(reason)}',
          );
        },
      )..enableHandlePromises();
      runtime = activeRuntime;
      if (deadline != null) activeRuntime.setInterruptDeadline(deadline);
      fetchBridge = ProviderFetchBridge(activeRuntime);
      final bundle = request.bundle;
      if (bundle != null) {
        final loadedBundle = activeRuntime.evaluate(bundle);
        if (loadedBundle.isError) {
          throw ProviderRunException(loadedBundle.stringResult);
        }
        void expectModule(String global, String name) {
          final status = activeRuntime.evaluate(
            'typeof globalThis.$global + ":" + String(!!globalThis.$global)',
          );
          if (status.isError ||
              !const {
                'function:true',
                'object:true',
              }.contains(status.stringResult)) {
            throw ProviderRunException(
              'The bundled $name module did not initialize '
              '(${status.stringResult}).',
            );
          }
        }

        if (request.needsCheerio) expectModule('__onfeedCheerio', 'Cheerio');
        if (request.needsCryptoJs) {
          expectModule('__onfeedCryptoJs', 'CryptoJS');
        }
      }
      final setup = activeRuntime.evaluate('''
        globalThis.module = { exports: {} };
        globalThis.exports = globalThis.module.exports;
        globalThis.SCRAPER_ID = ${jsonEncode(request.pluginId)};
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
      if (setup.isError) throw ProviderRunException(setup.stringResult);
      final loaded = activeRuntime.evaluate(
        '(function() {\n${request.code}\n})();',
        sourceUrl: request.codeUrl,
      );
      if (loaded.isError) throw ProviderRunException(loaded.stringResult);
      final call = await activeRuntime.evaluateAsync('''
        (async function() {
          const provider = globalThis.module.exports || globalThis.exports || {};
          const getStreams = provider.getStreams || globalThis.getStreams;
          if (typeof getStreams !== 'function') {
            throw new Error('Provider must export getStreams(tmdbId, mediaType, season, episode).');
          }
          const streams = await getStreams(
            ${jsonEncode(request.tmdbId)}, ${jsonEncode(request.mediaType)},
            ${request.season?.toString() ?? 'undefined'}, ${request.episode?.toString() ?? 'undefined'}
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
      // An empty result is normal for a title a provider does not index.
      final List<dynamic> entries = decoded is List
          ? decoded
          : (decoded is Map && decoded['streams'] is List
                ? decoded['streams'] as List
                : const []);
      return (
        streams: [
          for (final entry in entries.whereType<Map>())
            Map<String, dynamic>.from(entry),
        ],
        error: null,
        timedOut: false,
      );
    } on TimeoutException {
      return (streams: <Map<String, dynamic>>[], error: null, timedOut: true);
    } catch (error) {
      // An interrupted script fails with QuickJS's "interrupted" error.
      if (deadline != null && !DateTime.now().isBefore(deadline)) {
        return (streams: <Map<String, dynamic>>[], error: null, timedOut: true);
      }
      return (
        streams: <Map<String, dynamic>>[],
        error: error.toString(),
        timedOut: false,
      );
    } finally {
      try {
        fetchBridge?.dispose();
      } finally {
        final activeRuntime = runtime;
        if (activeRuntime != null) {
          final runtimeId = activeRuntime.getEngineInstanceId();
          try {
            activeRuntime.dispose();
          } finally {
            JavascriptRuntime.channelFunctionsRegistered.remove(runtimeId);
          }
        }
      }
    }
  }

  /// Provider text with URLs reduced to their host, for development logs.
  static String safeProviderDiagnostic(Object? error) {
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
