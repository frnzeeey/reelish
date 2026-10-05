import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Central freshness policy for TMDB response types.
abstract final class TmdbCacheTtl {
  static const catalog = Duration(minutes: 20);
  static const newReleases = Duration(minutes: 20);
  static const recommendations = Duration(minutes: 20);
  static const search = Duration(minutes: 3);
  static const metadata = Duration(hours: 24);
  static const identifiers = Duration(days: 7);
  static const fallback = Duration(minutes: 15);
}

class TmdbCacheEntry {
  const TmdbCacheEntry({
    required this.requestKey,
    required this.value,
    required this.storedAt,
    required this.ttl,
  });

  final String requestKey;
  final Map<String, dynamic> value;
  final DateTime storedAt;
  final Duration ttl;

  bool isFresh(DateTime now) => now.difference(storedAt) < ttl;
  bool isUsable(DateTime now, Duration staleGrace) =>
      now.difference(storedAt) < ttl + staleGrace;
}

class TmdbCachedResponse {
  const TmdbCachedResponse(this.entry, {required this.fromMemory});

  final TmdbCacheEntry entry;
  final bool fromMemory;
}

/// Small bounded disk cache. Its directory is the OS-managed app cache, so it
/// persists across normal restarts but may be cleared by the operating system.
class TmdbResponseCache {
  TmdbResponseCache({
    Directory? directory,
    DateTime Function()? clock,
    this.maxEntries = 64,
    this.maxBytes = 8 * 1024 * 1024,
    this.maxEntryBytes = 512 * 1024,
    this.staleGrace = const Duration(days: 7),
  }) : _providedDirectory = directory,
       _clock = clock ?? DateTime.now;

  final Directory? _providedDirectory;
  final DateTime Function() _clock;
  final int maxEntries;
  final int maxBytes;
  final int maxEntryBytes;
  final Duration staleGrace;
  final Map<String, TmdbCacheEntry> _memory = {};
  Directory? _directory;
  Future<void>? _cleanupFuture;
  DateTime? _lastCleanup;

  Future<TmdbCachedResponse?> read(String requestKey) async {
    final now = _clock();
    final inMemory = _memory.remove(requestKey);
    if (inMemory != null) {
      if (inMemory.isUsable(now, staleGrace)) {
        _remember(inMemory);
        return TmdbCachedResponse(inMemory, fromMemory: true);
      }
      return null;
    }

    try {
      final file = File(
        '${(await _cacheDirectory()).path}/${_fileKey(requestKey)}.json',
      );
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['requestKey'] != requestKey) {
        await file.delete();
        return null;
      }
      final storedAt = DateTime.tryParse('${decoded['storedAt'] ?? ''}');
      final ttlMs = decoded['ttlMs'];
      final value = decoded['value'];
      if (storedAt == null ||
          ttlMs is! int ||
          value is! Map ||
          value.keys.any((key) => key is! String)) {
        await file.delete();
        return null;
      }
      final entry = TmdbCacheEntry(
        requestKey: requestKey,
        value: Map<String, dynamic>.from(value),
        storedAt: storedAt,
        ttl: Duration(milliseconds: ttlMs),
      );
      if (!entry.isUsable(now, staleGrace)) {
        await file.delete();
        return null;
      }
      _remember(entry);
      return TmdbCachedResponse(entry, fromMemory: false);
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  final Set<Future<void>> _pendingWrites = {};

  /// Completes when disk writes started so far have finished. Writes run in
  /// the background so responses are not held up by flushing to disk.
  Future<void> flush() => Future.wait(_pendingWrites.toList());

  /// Stores [value] in memory immediately and on disk in the background.
  Future<void> write(
    String requestKey,
    Map<String, dynamic> value,
    Duration ttl,
  ) {
    final pending = _write(requestKey, value, ttl);
    _pendingWrites.add(pending);
    return pending.whenComplete(() => _pendingWrites.remove(pending));
  }

  Future<void> _write(
    String requestKey,
    Map<String, dynamic> value,
    Duration ttl,
  ) async {
    final entry = TmdbCacheEntry(
      requestKey: requestKey,
      value: value,
      storedAt: _clock(),
      ttl: ttl,
    );
    _remember(entry);
    try {
      final encoded = jsonEncode({
        'requestKey': requestKey,
        'storedAt': entry.storedAt.toUtc().toIso8601String(),
        'ttlMs': ttl.inMilliseconds,
        'value': value,
      });
      final bytes = utf8.encode(encoded).length;
      if (bytes <= maxEntryBytes) {
        final directory = await _cacheDirectory();
        final file = File('${directory.path}/${_fileKey(requestKey)}.json');
        final temporary = File('${file.path}.tmp');
        await temporary.writeAsString(encoded, flush: true);
        if (await file.exists()) await file.delete();
        await temporary.rename(file.path);
        _scheduleCleanup();
      }
    } on FileSystemException {
      // Disk cache failures must not make a successful API response fail.
    }
  }

  Future<void> clear() async {
    _memory.clear();
    try {
      final directory = await _cacheDirectory();
      if (await directory.exists()) await directory.delete(recursive: true);
      _directory = null;
    } on FileSystemException {
      // Best effort; a later request can continue with network data.
    }
  }

  /// Search results live only minutes and are rarely reused, so when the
  /// cache is full they are evicted before catalog and metadata entries.
  static bool _isEphemeral(Duration ttl) => ttl <= TmdbCacheTtl.search;

  void _remember(TmdbCacheEntry entry) {
    _memory.remove(entry.requestKey);
    _memory[entry.requestKey] = entry;
    while (_memory.length > maxEntries) {
      // Oldest ephemeral entry first, never the one just stored; otherwise
      // the least recently used entry.
      final ephemeral = _memory.entries
          .where(
            (candidate) =>
                candidate.key != entry.requestKey &&
                _isEphemeral(candidate.value.ttl),
          )
          .map((candidate) => candidate.key)
          .firstOrNull;
      _memory.remove(ephemeral ?? _memory.keys.first);
    }
  }

  Future<Directory> _cacheDirectory() async {
    final existing = _directory;
    if (existing != null) return existing;
    final parent = _providedDirectory ?? await getTemporaryDirectory();
    final directory = Directory('${parent.path}/tmdb_response_cache');
    await directory.create(recursive: true);
    _directory = directory;
    return directory;
  }

  void _scheduleCleanup() {
    final now = _clock();
    if (_lastCleanup != null &&
        now.difference(_lastCleanup!) < const Duration(hours: 6)) {
      return;
    }
    _lastCleanup = now;
    _cleanupFuture ??= _cleanup().whenComplete(() => _cleanupFuture = null);
  }

  Future<void> _cleanup() async {
    try {
      final directory = await _cacheDirectory();
      final files = <File>[];
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is File && entity.path.endsWith('.json')) files.add(entity);
      }
      final records =
          <({File file, int length, DateTime modified, bool ephemeral})>[];
      var totalBytes = 0;
      final now = _clock();
      for (final file in files) {
        try {
          final stat = await file.stat();
          final raw = jsonDecode(await file.readAsString());
          final storedAt = raw is Map
              ? DateTime.tryParse('${raw['storedAt'] ?? ''}')
              : null;
          final ttlMs = raw is Map ? raw['ttlMs'] : null;
          if (storedAt == null ||
              ttlMs is! int ||
              now.difference(storedAt) >=
                  Duration(milliseconds: ttlMs) + staleGrace) {
            await file.delete();
            continue;
          }
          totalBytes += stat.size;
          records.add((
            file: file,
            length: stat.size,
            modified: stat.modified,
            ephemeral: _isEphemeral(Duration(milliseconds: ttlMs)),
          ));
        } on FileSystemException {
          // Ignore a cache file removed while cleanup is scanning.
        } on FormatException {
          try {
            await file.delete();
          } on FileSystemException {
            // Ignore a concurrent removal.
          }
        }
      }
      // Trim search entries first, then the oldest of the rest.
      records.sort((a, b) {
        if (a.ephemeral != b.ephemeral) return a.ephemeral ? -1 : 1;
        return a.modified.compareTo(b.modified);
      });
      while (records.length > maxEntries || totalBytes > maxBytes) {
        final oldest = records.removeAt(0);
        totalBytes -= oldest.length;
        try {
          await oldest.file.delete();
        } on FileSystemException {
          // Ignore a concurrent removal.
        }
      }
    } on FileSystemException {
      // Cache pruning is best effort.
    }
  }

  static String _fileKey(String value) {
    var hash = 0xcbf29ce484222325;
    for (final byte in utf8.encode(value)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xffffffffffffffff;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }
}
