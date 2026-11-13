// Fetches intro and outro timestamps from IntroDB (https://api.introdb.app,
// `GET /segments`; reads need no key) and keeps them: in memory for the
// session, on disk across launches, misses included, so an episode is asked
// about at most once a day. Never blocks playback and never throws.
// docs/player/INTRO_OUTRO_IMPLEMENTATION.md.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'skip_segments.dart';

class IntroOutroService {
  IntroOutroService({
    this._client,
    Future<Directory> Function()? filesDirectory,
    DateTime Function()? clock,
  }) : _filesDirectory = filesDirectory ?? getApplicationSupportDirectory,
       _clock = clock ?? DateTime.now;

  /// The app's service; tests build their own.
  static IntroOutroService instance = IntroOutroService();

  /// Fixed host: nothing in a response can send a request elsewhere.
  static const host = 'api.introdb.app';

  static const requestTimeout = Duration(seconds: 6);
  static const maxResponseBytes = 64 * 1024;

  /// How long an answer is trusted. Found segments change rarely; an
  /// episode nobody has timed yet may be timed soon.
  static const foundTtl = Duration(days: 7);
  static const missingTtl = Duration(hours: 24);

  /// After a failed request (offline, server error, rate limit) the same
  /// episode is not asked again for this long in this session.
  static const failureCooldown = Duration(minutes: 10);

  /// Episodes kept on disk; the least recently fetched go first.
  static const maxStored = 400;

  static const _fileName = 'introdb_segments.v1.json';

  final http.Client? _client;
  final Future<Directory> Function() _filesDirectory;
  final DateTime Function() _clock;

  final _memory = <String, ({EpisodeSegments segments, DateTime at})>{};
  final _inFlight = <String, Future<EpisodeSegments>>{};
  final _failedAt = <String, DateTime>{};
  Future<void>? _loaded;
  Future<void> _writes = Future.value();

  /// Requests sent this session (counts only), for tests and diagnostics.
  int get requestCount => _requests;
  int _requests = 0;

  /// The segments for [key]: from memory, disk or IntroDB. Empty (never an
  /// error) when IntroDB has nothing, cannot be reached, or answers about
  /// another episode. Calls for the same episode at once share a request.
  Future<EpisodeSegments> segmentsFor(EpisodeKey key) {
    final cached = _fresh(key);
    if (cached != null) return Future.value(cached);
    return _inFlight[key.id] ??=
        _lookup(
          key,
          // A block body: `remove` returns this very future, and whenComplete
          // would wait for it, forever.
        ).whenComplete(() {
          _inFlight.remove(key.id);
        });
  }

  EpisodeSegments? _fresh(EpisodeKey key) {
    final entry = _memory[key.id];
    if (entry == null) return null;
    final ttl = entry.segments.isEmpty ? missingTtl : foundTtl;
    return _clock().difference(entry.at) < ttl ? entry.segments : null;
  }

  Future<EpisodeSegments> _lookup(EpisodeKey key) async {
    await (_loaded ??= _load());
    final cached = _fresh(key);
    if (cached != null) return cached;
    final failed = _failedAt[key.id];
    if (failed != null && _clock().difference(failed) < failureCooldown) {
      return EpisodeSegments.none(key);
    }
    final EpisodeSegments segments;
    try {
      segments = await _fetch(key);
    } catch (_) {
      // Not cached: a failure says nothing about the episode.
      _failedAt[key.id] = _clock();
      return EpisodeSegments.none(key);
    }
    _failedAt.remove(key.id);
    _remember(key, segments, _clock());
    unawaited(_save());
    return segments;
  }

  Future<EpisodeSegments> _fetch(EpisodeKey key) async {
    final uri = Uri.https(host, '/segments', {
      'imdb_id': key.imdbId,
      'season': '${key.season}',
      'episode': '${key.episode}',
    });
    final client = _client ?? http.Client();
    try {
      _requests++;
      final request = http.Request('GET', uri)
        // A redirect is not followed: it could lead anywhere.
        ..followRedirects = false
        ..headers['Accept'] = 'application/json'
        ..headers['User-Agent'] = 'Reelish';
      final response = await client.send(request).timeout(requestTimeout);
      if (response.statusCode != 200) {
        throw HttpException('IntroDB answered ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(requestTimeout)) {
        bytes.addAll(chunk);
        if (bytes.length > maxResponseBytes) {
          throw const HttpException('IntroDB response too large');
        }
      }
      final segments = EpisodeSegments.fromIntroDb(
        key,
        jsonDecode(utf8.decode(bytes)),
      );
      // An answer about another episode is treated as no answer at all,
      // and kept as such, so it is never applied and not asked again soon.
      return segments ?? EpisodeSegments.none(key);
    } finally {
      if (_client == null) client.close();
    }
  }

  void _remember(EpisodeKey key, EpisodeSegments segments, DateTime at) {
    _memory
      ..remove(key.id)
      ..[key.id] = (segments: segments, at: at);
    while (_memory.length > maxStored) {
      _memory.remove(_memory.keys.first);
    }
  }

  Future<File> _file() async => File(
    '${(await _filesDirectory()).path}${Platform.pathSeparator}$_fileName',
  );

  Future<void> _load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return;
      for (final raw in decoded) {
        if (raw is! Map) continue;
        final at = DateTime.tryParse('${raw['at'] ?? ''}');
        final data = raw['data'];
        if (at == null || data is! Map) continue;
        final key = EpisodeKey.of(
          '${data['imdb_id'] ?? ''}',
          data['season'] is int ? data['season'] as int : null,
          data['episode'] is int ? data['episode'] as int : null,
        );
        if (key == null) continue;
        // Stored entries go through the same checks as IntroDB's answers.
        final segments = EpisodeSegments.fromIntroDb(key, {
          ...data,
          'is_movie': false,
        });
        if (segments != null && !_memory.containsKey(key.id)) {
          _remember(key, segments, at);
        }
      }
    } catch (_) {
      // An unreadable cache is a cold cache.
    }
  }

  /// Writes one at a time, through a temporary file, so an interrupted
  /// write never leaves a corrupt cache.
  Future<void> _save() => _writes = _writes.then((_) async {
    try {
      final file = await _file();
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode([
          for (final entry in _memory.values)
            {
              'at': entry.at.toUtc().toIso8601String(),
              'data': entry.segments.toJson(),
            },
        ]),
        flush: true,
      );
      await tmp.rename(file.path);
    } catch (_) {
      // The memory copy still serves this session.
    }
  });

  /// Waits for pending disk writes (tests).
  @visibleForTesting
  Future<void> flush() => _writes;
}
