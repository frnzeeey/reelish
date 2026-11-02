import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';

void main() {
  late Directory root;
  late Directory dir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('reelish-cache-test-');
    dir = Directory('${root.path}/tmdb_response_cache')..createSync();
  });
  tearDown(() => root.delete(recursive: true));

  File cacheFile(String name, Map<String, Object?> json) =>
      File('${dir.path}/$name.json')..writeAsStringSync(jsonEncode(json));

  test('pruning drops expired entries, keeps live ones, and recovers from '
      'corrupt files and the older field order', () async {
    final now = DateTime.now().toUtc();
    final live = cacheFile('live', {
      'requestKey': 'live',
      'storedAt': now.toIso8601String(),
      'ttlMs': const Duration(hours: 1).inMilliseconds,
      'value': {'a': 1},
    });
    final expired = cacheFile('expired', {
      'requestKey': 'expired',
      'storedAt': now.subtract(const Duration(days: 30)).toIso8601String(),
      'ttlMs': 1000,
      'value': {'a': 1},
    });
    // Same data, value first: read by the full-decode fallback.
    final reordered = cacheFile('reordered', {
      'value': {'a': 1},
      'ttlMs': const Duration(hours: 1).inMilliseconds,
      'storedAt': now.toIso8601String(),
      'requestKey': 'reordered',
    });
    final corrupt = File('${dir.path}/corrupt.json')
      ..writeAsStringSync('{"requestKey":"x", truncated');

    await TmdbResponseCache(directory: root).debugCleanup();

    expect(live.existsSync(), isTrue);
    expect(reordered.existsSync(), isTrue);
    expect(expired.existsSync(), isFalse);
    expect(corrupt.existsSync(), isFalse);
  });

  test('the header is read from the start of a file the cache wrote', () async {
    final cache = TmdbResponseCache(directory: root);
    await cache.write('key', {
      'results': List.filled(2000, 'x' * 50),
    }, TmdbCacheTtl.metadata);
    await cache.flush();
    final file = dir.listSync().whereType<File>().single;
    expect(file.lengthSync(), greaterThan(4096));
    final (storedAt, ttl) = await TmdbResponseCache.debugReadHeader(file);
    expect(storedAt, isNotNull);
    expect(ttl, TmdbCacheTtl.metadata.inMilliseconds);
  });

  test('sameJson compares decoded JSON all the way down', () {
    expect(
      sameJson({
        'a': [
          1,
          {'b': null},
        ],
        'c': 'x',
      }, jsonDecode('{"c":"x","a":[1,{"b":null}]}')),
      isTrue,
    );
    expect(sameJson({'a': 1}, {'a': 1.5}), isFalse);
    expect(sameJson({'a': 1}, {'a': 1, 'b': 2}), isFalse);
    expect(sameJson([1, 2], [2, 1]), isFalse);
    expect(sameJson({'a': null}, {'b': null}), isFalse);
  });
}
