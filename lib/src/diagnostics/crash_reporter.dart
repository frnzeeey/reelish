// Crash and error reporting. Android (phones, Android TV, Google TV) sends
// reports to Firebase Crashlytics, opt-in only; Windows keeps a local log,
// since Crashlytics does not support it. Like analytics, this is never
// needed for the app to work: nothing here throws or changes what an error
// does next.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analytics/analytics_service.dart';
import 'error_scrubber.dart';
import 'local_error_log.dart';

/// How bad an error is.
enum ErrorSeverity {
  /// Nothing caught it: part or all of the app may have stopped working.
  fatal,

  /// Caught and survived, but it should not have happened.
  nonFatal,

  /// An expected failure (network, a missing source). Kept as a note on
  /// later reports; never a report of its own.
  handled,
}

/// What a report says about the moment it happened. Values come from the
/// app's own enums, never from data; see [CrashReporter.setContext].
enum CrashContext {
  feature('feature'),
  playbackState('playback_state'),
  playbackEngine('playback_engine'),
  partyState('party_state'),
  partyRole('party_role');

  const CrashContext(this.key);

  final String key;
}

/// Records errors once the viewer agreed, and installs the error handlers.
class CrashReporter {
  CrashReporter({
    @visibleForTesting MethodChannel? channel,
    @visibleForTesting bool? sendsReports,
    @visibleForTesting LocalErrorLog? localLog,
  }) : _channel = channel ?? const MethodChannel('onfeed/crash_reports'),
       _sendsReports =
           sendsReports ??
           (!kIsWeb &&
               defaultTargetPlatform == TargetPlatform.android &&
               (!kDebugMode || testTriggers)),
       _localLog =
           localLog ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows
               ? LocalErrorLog()
               : null);

  static CrashReporter instance = CrashReporter();

  /// Where the choice is kept: `granted` or `denied`; absent until asked.
  static const consentKey = 'onfeed.crash_reports.consent.v1';

  /// Test-only triggers, compiled in with
  /// `--dart-define=REELISH_CRASH_TEST=true`. Release builds never set it.
  static const testTriggers = bool.fromEnvironment('REELISH_CRASH_TEST');

  /// Most distinct reports in one run. Crashlytics keeps only the last
  /// eight between launches, so more would be lost anyway.
  static const maxReports = 16;

  /// Errors held until the saved choice is known.
  static const maxPending = 8;

  final MethodChannel _channel;
  final bool _sendsReports;
  final LocalErrorLog? _localLog;

  /// Whether this build can send reports: Android with a Firebase
  /// configuration. Settles after [load].
  final ValueNotifier<bool> available = ValueNotifier(false);

  final ValueNotifier<AnalyticsConsent> consent = ValueNotifier(
    AnalyticsConsent.unknown,
  );

  bool get collecting =>
      available.value && consent.value == AnalyticsConsent.granted;

  /// The log on this computer, on the platforms that keep one.
  LocalErrorLog? get localLog => _localLog;

  Future<void>? _loading;
  bool _loaded = false;
  bool _installed = false;
  final _context = <CrashContext, String>{};
  final _seen = <String>{};
  final _pending = <Map<String, Object?>>[];

  /// Starts catching errors. Each handler reports and then does exactly
  /// what would have happened without it, so nothing is swallowed.
  void install() {
    if (_installed) return;
    _installed = true;
    final framework = FlutterError.onError;
    FlutterError.onError = (details) {
      recordFlutterError(details);
      framework?.call(details);
    };
    final dispatcher = PlatformDispatcher.instance;
    final platform = dispatcher.onError;
    dispatcher.onError = (error, stack) {
      recordUncaught(error, stack);
      return platform?.call(error, stack) ?? false;
    };
  }

  /// Reads the saved choice. Never throws and never waits on the network.
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    if (_sendsReports) {
      try {
        final saved = (await SharedPreferences.getInstance()).getString(
          consentKey,
        );
        consent.value = switch (saved) {
          'granted' => AnalyticsConsent.granted,
          'denied' => AnalyticsConsent.denied,
          _ => AnalyticsConsent.unknown,
        };
        available.value =
            await _channel.invokeMethod<bool>('isConfigured') ?? false;
        if (consent.value != AnalyticsConsent.unknown && available.value) {
          await _configure(enabled: collecting);
        }
      } catch (_) {
        available.value = false;
      }
    }
    _loaded = true;
    final held = List.of(_pending);
    _pending.clear();
    if (collecting) held.forEach(_send);
  }

  /// Saves the viewer's choice. Reports stored before agreeing are deleted
  /// rather than sent, and turning it off deletes those not yet sent.
  Future<void> setConsent(bool granted) async {
    if (!_sendsReports) return;
    consent.value = granted
        ? AnalyticsConsent.granted
        : AnalyticsConsent.denied;
    try {
      await (await SharedPreferences.getInstance()).setString(
        consentKey,
        granted ? 'granted' : 'denied',
      );
    } catch (_) {}
    if (available.value) await _configure(enabled: granted);
  }

  Future<void> _configure({required bool enabled}) async {
    try {
      await _channel.invokeMethod<bool>('configure', {'enabled': enabled});
      if (enabled) _context.forEach(_sendContext);
    } catch (_) {
      // Optional; the app works the same without it.
    }
  }

  /// Sets or, with null, clears what reports say about this moment. [value]
  /// must be a short word: anything else is dropped, so a stray
  /// title or code can never become a key.
  void setContext(CrashContext key, String? value) {
    if (value == null) {
      if (_context.remove(key) == null) return;
    } else {
      if (!_token.hasMatch(value) || _context[key] == value) return;
      _context[key] = value;
    }
    if (collecting) _sendContext(key, value ?? '');
  }

  static final _token = RegExp(r'^[a-zA-Z_]{1,32}$');

  void _sendContext(CrashContext key, String value) =>
      _invoke('setKey', {'key': key.key, 'value': value});

  /// A framework error: a widget failed to build, lay out or paint.
  void recordFlutterError(FlutterErrorDetails details) {
    if (details.silent) return;
    // A broken poster is the network's doing and already shows a fallback.
    final handled = details.library == 'image resource service';
    recordError(
      details.exception,
      details.stack,
      severity: handled ? ErrorSeverity.handled : ErrorSeverity.fatal,
    );
  }

  /// An error nothing caught, from any zone.
  void recordUncaught(Object error, StackTrace stack) =>
      recordError(error, stack, severity: ErrorSeverity.fatal);

  /// Reports [error]. An expected kind of failure is only ever noted, and
  /// the same error is reported once per run. Never throws. [reason]
  /// replaces the error's own message.
  void recordError(
    Object error,
    StackTrace? stack, {
    ErrorSeverity severity = ErrorSeverity.nonFatal,
    ErrorCategory? category,
    String? reason,
  }) {
    try {
      final kind = category ?? ErrorScrubber.categorize(error);
      final level = kind.isExpected ? ErrorSeverity.handled : severity;
      final type = error.runtimeType.toString();
      if (level == ErrorSeverity.handled) {
        note('${kind.name} $type');
        return;
      }
      final parsed = ParsedStack.of(stack);
      final message = reason != null
          ? ErrorScrubber.scrub(reason)
          : ErrorScrubber.safeMessage(error) ?? '';
      final place = parsed.frames
          .take(4)
          .map((frame) => '${frame.method}:${frame.line}')
          .join();
      if (_seen.length >= maxReports || !_seen.add('$type|$message|$place')) {
        return;
      }
      _writeLocal(level, kind, type, message, stack);
      final report = <String, Object?>{
        'type': type,
        'message': message,
        'severity': level.name,
        'category': kind.name,
        'raw': parsed.raw,
        'buildId': parsed.buildId,
        'frames': [
          for (final frame in parsed.frames)
            {
              'owner': frame.owner,
              'method': frame.method,
              'file': frame.file,
              'line': frame.line,
            },
        ],
      };
      if (!_loaded) {
        if (_sendsReports && _pending.length < maxPending) {
          _pending.add(report);
        }
      } else if (collecting) {
        _send(report);
      }
    } catch (_) {
      // Reporting a failure must never cause one.
    }
  }

  void _send(Map<String, Object?> report) => _invoke('record', report);

  /// A line kept with later reports, showing what led up to them.
  void note(String text) {
    try {
      final line = ErrorScrubber.scrub(text);
      if (collecting) _invoke('log', {'message': line});
      unawaited(_localLog?.append('${_time()} note $line'));
    } catch (_) {}
  }

  void _writeLocal(
    ErrorSeverity severity,
    ErrorCategory category,
    String type,
    String message,
    StackTrace? stack,
  ) {
    final log = _localLog;
    if (log == null) return;
    final context = _context.entries
        .map((entry) => '${entry.key.key}=${entry.value}')
        .join(' ');
    final entry = StringBuffer(
      '${_time()} ${severity.name} ${category.name} $type $message',
    );
    if (context.isNotEmpty) entry.write('\n  $context');
    final frames = ParsedStack.of(stack).frames;
    for (final frame in frames.take(20)) {
      entry.write(
        '\n  ${frame.owner}.${frame.method} ${frame.file}:${frame.line}',
      );
    }
    unawaited(log.append(entry.toString()));
  }

  static String _time() => DateTime.now().toUtc().toIso8601String();

  /// Test-only (see [testTriggers]): ends the process from the Android
  /// side, as a real crash would.
  Future<void> testNativeCrash() async {
    if (!testTriggers) return;
    await _channel.invokeMethod<void>('testCrash');
  }

  void _invoke(String method, Map<String, Object?> arguments) => unawaited(
    _channel.invokeMethod<void>(method, arguments).catchError((Object _) {}),
  );
}
