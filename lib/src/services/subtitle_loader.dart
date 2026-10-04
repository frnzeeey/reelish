import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/stream_source.dart';
import 'network_target_policy.dart';

/// One timed subtitle line, in seconds.
class SubtitleCue {
  const SubtitleCue(this.start, this.end, this.text);

  final double start, end;
  final String text;
}

class SubtitleLoadException implements Exception {
  const SubtitleLoadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Decodes subtitle bytes without assuming ASCII: UTF-8 (with or without a
/// BOM), UTF-16 with a BOM, and Latin-1 for legacy single-byte files that are
/// not valid UTF-8. Never throws.
String decodeSubtitleBytes(List<int> bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
          (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    final littleEndian = bytes[0] == 0xFF;
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add(
        littleEndian
            ? bytes[i] | (bytes[i + 1] << 8)
            : (bytes[i] << 8) | bytes[i + 1],
      );
    }
    return String.fromCharCodes(units);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// Parses SRT, WebVTT and ASS/SSA into cues sorted by start time.
List<SubtitleCue> parseSubtitles(String raw) {
  final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final cues = text.contains(RegExp(r'^\[Events\]', multiLine: true))
      ? _parseAss(text)
      : _parseSrtOrVtt(text);
  cues.sort((a, b) => a.start.compareTo(b.start));
  return cues;
}

final _timing = RegExp(
  r'((?:\d{1,2}:)?\d{1,2}:\d{2}[,.]\d{1,3})\s*-->\s*((?:\d{1,2}:)?\d{1,2}:\d{2}[,.]\d{1,3})',
);

double _seconds(String value) {
  final parts = value.replaceAll(',', '.').split(':');
  final hours = parts.length == 3 ? int.parse(parts[0]) : 0;
  final minutes = int.parse(parts[parts.length - 2]);
  final secondParts = parts.last.split('.');
  final fraction = secondParts.length > 1
      ? int.parse(secondParts[1].padRight(3, '0').substring(0, 3)) / 1000
      : 0.0;
  return hours * 3600 + minutes * 60 + int.parse(secondParts[0]) + fraction;
}

String _cleanText(String value) => value
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&nbsp;', ' ')
    .trim();

List<SubtitleCue> _parseSrtOrVtt(String text) {
  final cues = <SubtitleCue>[];
  for (final block in text.split(RegExp(r'\n\s*\n'))) {
    final lines = block.split('\n');
    final index = lines.indexWhere(_timing.hasMatch);
    if (index < 0) continue;
    final match = _timing.firstMatch(lines[index])!;
    final cueText = _cleanText(lines.skip(index + 1).join('\n'));
    if (cueText.isEmpty) continue;
    cues.add(
      SubtitleCue(
        _seconds(match.group(1)!),
        _seconds(match.group(2)!),
        cueText,
      ),
    );
  }
  return cues;
}

List<SubtitleCue> _parseAss(String text) {
  final cues = <SubtitleCue>[];
  var textField = 9; // Default ASS/SSA event format.
  var startField = 1, endField = 2;
  for (final line in text.split('\n')) {
    if (line.startsWith('Format:')) {
      final fields = line
          .substring(7)
          .split(',')
          .map((field) => field.trim().toLowerCase())
          .toList();
      if (fields.contains('text')) {
        textField = fields.indexOf('text');
        startField = fields.indexOf('start');
        endField = fields.indexOf('end');
      }
      continue;
    }
    if (!line.startsWith('Dialogue:')) continue;
    // The text field may itself contain commas.
    final parts = line.substring(9).split(',');
    if (parts.length <= textField || startField < 0 || endField < 0) continue;
    final cueText = _cleanText(
      parts
          .sublist(textField)
          .join(',')
          .replaceAll(RegExp(r'\{[^}]*\}'), '')
          .replaceAll(RegExp(r'\\[Nn]'), '\n')
          .replaceAll(r'\h', ' '),
    );
    if (cueText.isEmpty) continue;
    try {
      cues.add(
        SubtitleCue(
          _seconds(parts[startField].trim()),
          _seconds(parts[endField].trim()),
          cueText,
        ),
      );
    } on FormatException {
      continue;
    }
  }
  return cues;
}

List<SubtitleCue> _decodeAndParse(List<int> bytes) =>
    parseSubtitles(decodeSubtitleBytes(bytes));

/// Downloads and parses subtitle files for the player's own renderer, which
/// works the same on every engine and never interrupts playback.
///
/// Only the subtitle the viewer selects is downloaded. Parsed files are kept
/// in a small in-memory cache, so switching back to a subtitle is instant.
class SubtitleLoader {
  SubtitleLoader({
    NetworkDestinationValidator? network,
    http.Client? testClient,
  }) : _network = network ?? NetworkDestinationValidator(),
       _testClient = testClient;

  final NetworkDestinationValidator _network;
  final http.Client? _testClient;

  static const _maxCached = 8;
  static final LinkedHashMap<String, List<SubtitleCue>> _cache =
      LinkedHashMap();
  static final Map<String, Future<List<SubtitleCue>>> _inFlight = {};

  @visibleForTesting
  static void resetCache() {
    _cache.clear();
    _inFlight.clear();
  }

  Future<List<SubtitleCue>> load(SubtitleTrack track) {
    final key = track.url;
    final cached = _cache.remove(key);
    if (cached != null) {
      _cache[key] = cached; // most recently used
      return Future.value(cached);
    }
    final pending = _inFlight[key];
    if (pending != null) return pending;
    final future = _load(track).then((cues) {
      _cache[key] = cues;
      while (_cache.length > _maxCached) {
        _cache.remove(_cache.keys.first);
      }
      return cues;
    });
    _inFlight[key] = future;
    future.whenComplete(() => _inFlight.remove(key)).ignore();
    return future;
  }

  Future<List<SubtitleCue>> _load(SubtitleTrack track) async {
    final clock = Stopwatch()..start();
    final List<int> bytes;
    try {
      bytes = await _fetch(track);
    } on SubtitleLoadException {
      rethrow;
    } catch (error) {
      _log('[Subtitle][Download] success=false error=${error.runtimeType}');
      throw const SubtitleLoadException('Unable to load subtitles.');
    }
    var data = bytes;
    if (data.length >= 2 && data[0] == 0x1F && data[1] == 0x8B) {
      try {
        data = gzip.decode(data);
      } on FormatException {
        throw const SubtitleLoadException('The subtitle file is damaged.');
      }
    }
    if (data.length >= 4 &&
        data[0] == 0x50 &&
        data[1] == 0x4B &&
        data[2] == 0x03 &&
        data[3] == 0x04) {
      // A ZIP archive, not a subtitle file.
      throw const SubtitleLoadException(
        'This subtitle format is not supported.',
      );
    }
    // Large files are parsed off the UI isolate.
    final cues = data.length > 256 * 1024
        ? await compute(_decodeAndParse, data)
        : _decodeAndParse(data);
    _log(
      '[Subtitle][Download] success=${cues.isNotEmpty} '
      'source=${track.source.name} bytes=${data.length} cues=${cues.length} '
      'duration=${clock.elapsedMilliseconds}ms',
    );
    if (cues.isEmpty) {
      throw const SubtitleLoadException('This subtitle file has no captions.');
    }
    return cues;
  }

  Future<List<int>> _fetch(SubtitleTrack track) async {
    var current = Uri.parse(track.url);
    final headers = Map<String, String>.of(track.headers);
    for (var redirects = 0; redirects <= 5; redirects++) {
      final request = http.Request('GET', current)
        ..followRedirects = false
        ..headers.addAll(headers);
      final response = await _network.sendForBytes(
        request,
        allowedSchemes: const {'https'},
        maxResponseBytes: 4 * 1024 * 1024,
        timeout: const Duration(seconds: 15),
        testClient: _testClient,
      );
      if (![301, 302, 303, 307, 308].contains(response.statusCode)) {
        if (response.statusCode == 429) {
          throw const SubtitleLoadException(
            'Subtitles are busy. Try again in a moment.',
          );
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw const SubtitleLoadException('Unable to load subtitles.');
        }
        return response.bodyBytes;
      }
      final location = response.headers['location'];
      if (location == null || redirects == 5) break;
      final next = await _network.validateRedirect(
        current,
        location,
        allowedSchemes: const {'https'},
      );
      final sameOrigin =
          current.scheme == next.scheme &&
          current.host.toLowerCase() == next.host.toLowerCase() &&
          current.port == next.port;
      if (!sameOrigin) {
        headers.removeWhere(
          (name, _) =>
              !const {'accept', 'user-agent'}.contains(name.toLowerCase()),
        );
      }
      current = next;
    }
    throw const SubtitleLoadException('Unable to load subtitles.');
  }

  static void _log(String message) {
    if (kDebugMode) debugPrint(message);
  }
}
