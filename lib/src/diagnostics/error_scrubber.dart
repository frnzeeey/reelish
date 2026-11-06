// Decides what of an error may leave the app or reach the local error log,
// and which kind of problem it is. Pure Dart, so the rules are easy to test.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Which kind of problem an error is. Stays short and low-cardinality: it is
/// a filter in crash reports.
enum ErrorCategory {
  network,
  timeout,
  storage,
  framework,
  playback,
  party,
  unknown;

  /// Failures the app expects and recovers from: a viewer's connection is
  /// not a bug in Reelish, so these never become crash reports.
  bool get isExpected => this == network || this == timeout;
}

/// Removes anything personal or secret from error text.
///
/// Error text is built from remote responses, stream addresses and provider
/// scripts, so it is treated as untrusted: [safeMessage] keeps the message
/// only of error types whose text comes from Reelish's own code, and [scrub]
/// cleans even those.
class ErrorScrubber {
  const ErrorScrubber._();

  static const maxLength = 300;

  static final _rules = <(RegExp, String)>[
    (RegExp(r'\b[a-z][a-z0-9+.-]*://\S+', caseSensitive: false), '<url>'),
    (RegExp(r'\bmagnet:\S+', caseSensitive: false), '<url>'),
    (RegExp(r'[\w.+-]+@[\w-]+(\.[\w-]+)+'), '<email>'),
    (RegExp(r'\b(bearer|basic)\s+\S+', caseSensitive: false), '<token>'),
    (RegExp(r'\beyJ[\w-]{10,}(\.[\w-]+)*'), '<token>'),
    (RegExp(r'\brn[a-z]_\w+'), '<token>'),
    (
      RegExp(
        r'\b(access_token|refresh_token|token|api_key|apikey|key|auth|'
        r'authorization|cookie|password|signature|sig|code)\s*[=:]\s*\S+',
        caseSensitive: false,
      ),
      '<secret>',
    ),
    (RegExp(r'\b[A-Za-z]:[\\/]\S+'), '<path>'),
    (RegExp(r'/(data|storage|home|Users|sdcard|mnt|var|tmp)/\S+'), '<path>'),
    (RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b'), '<ip>'),
    (
      RegExp(
        r'\b([a-z0-9-]+\.)+(com|net|org|io|to|tv|me|cc|co|xyz|app|dev|info|'
        r'site|online|live|stream)\b',
        caseSensitive: false,
      ),
      '<host>',
    ),
    // Watch Party codes (eight digits, however they are grouped), and any
    // other long number or identifier.
    (RegExp(r'\b\d{4}[- ]\d{4}\b'), '<number>'),
    (RegExp(r'\b\d{6,}\b'), '<number>'),
    (RegExp(r'\b[A-Fa-f0-9]{24,}\b'), '<id>'),
    (RegExp(r'\b[A-Za-z0-9+/_-]{32,}={0,2}'), '<id>'),
  ];

  /// [text] without addresses, tokens, paths or long identifiers, on one
  /// line and at most [maxLength] characters.
  static String scrub(String text) {
    var result = text;
    for (final (pattern, replacement) in _rules) {
      result = result.replaceAll(pattern, replacement);
    }
    result = result.replaceAll(RegExp(r'\s+'), ' ').trim();
    return result.length > maxLength ? result.substring(0, maxLength) : result;
  }

  /// The message of [error] when it may be kept, otherwise null.
  ///
  /// Only programming errors qualify. The others (network, parsing,
  /// platform and plain exceptions) quote what a server or provider sent,
  /// so only their type is reported.
  static String? safeMessage(Object error) {
    if (error is FlutterError) {
      return scrub(error.message.split('\n').first);
    }
    if (error is TypeError ||
        error is RangeError ||
        error is NoSuchMethodError ||
        error is ConcurrentModificationError ||
        error is StateError ||
        error is UnsupportedError ||
        error is AssertionError ||
        error is OutOfMemoryError ||
        error is StackOverflowError) {
      return scrub(error.toString());
    }
    return null;
  }

  static ErrorCategory categorize(Object error) => switch (error) {
    TimeoutException() => ErrorCategory.timeout,
    SocketException() ||
    HttpException() ||
    TlsException() ||
    WebSocketException() ||
    http.ClientException() => ErrorCategory.network,
    FileSystemException() => ErrorCategory.storage,
    FlutterError() => ErrorCategory.framework,
    _ => ErrorCategory.unknown,
  };
}

/// One frame of a Dart stack trace, as a crash report needs it.
typedef DartFrame = ({String owner, String method, String file, int line});

/// A stack trace taken apart. Release builds give addresses instead of
/// names (they are obfuscated with --split-debug-info), and [raw] is what
/// `flutter symbolize` reads to turn those back into names.
class ParsedStack {
  const ParsedStack._(this.frames, this.raw, this.buildId);

  factory ParsedStack.of(StackTrace? stack) {
    final text = stack?.toString() ?? '';
    final frames = <DartFrame>[];
    for (final line in text.split('\n')) {
      if (frames.length == maxFrames) break;
      final frame = _parse(line.trim());
      if (frame != null) frames.add(frame);
    }
    return ParsedStack._(
      frames,
      // Addresses only in release. Elsewhere frames name source paths, and
      // a debug build's paths can name the developer.
      frames.any((frame) => frame.file == 'libapp.so')
          ? (text.length > maxRaw ? text.substring(0, maxRaw) : text)
          : '',
      _buildId.firstMatch(text)?.group(1),
    );
  }

  static const maxFrames = 40;
  static const maxRaw = 6000;

  static final _buildId = RegExp(r"build_id: '([0-9a-f]+)'");

  /// `#0  Owner.method (package:onfeed/file.dart:12:3)`.
  static final _symbolic = RegExp(
    r'^#\d+\s+(.+?)\s+\((.+?)(?::(\d+))?(?::\d+)?\)$',
  );

  /// `#00 abs 0000007f virt 00000012 _kDartIsolateSnapshotInstructions+0x12`.
  static final _address = RegExp(
    r'^#\d+\s+abs\s+[0-9a-f]+\s+(?:virt\s+[0-9a-f]+\s+)?(\S+)',
  );

  static DartFrame? _parse(String line) {
    final address = _address.firstMatch(line);
    if (address != null) {
      return (
        owner: 'dart',
        method: address.group(1)!,
        file: 'libapp.so',
        line: 0,
      );
    }
    final symbolic = _symbolic.firstMatch(line);
    if (symbolic == null) return null;
    final name = symbolic.group(1)!;
    final dot = name.indexOf('.');
    return (
      owner: dot > 0 ? name.substring(0, dot) : 'dart',
      method: dot > 0 ? name.substring(dot + 1) : name,
      // The last segment only: the rest of a path can name the developer.
      file: symbolic.group(2)!.split(RegExp(r'[\\/]')).last,
      line: int.tryParse(symbolic.group(3) ?? '') ?? 0,
    );
  }

  final List<DartFrame> frames;
  final String raw;
  final String? buildId;
}
