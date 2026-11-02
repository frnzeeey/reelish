// Measures the TMDB response cache with realistic sizes and prints the
// numbers. Skipped unless REELISH_BENCH=1 (it writes many MB of temp files):
//   $env:REELISH_BENCH='1'; flutter test test/tmdb_cache_benchmark_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';

/// A TMDB-like body of about [kb] KB once encoded.
Map<String, dynamic> _body(int kb, int seed) => {
  'id': seed,
  'results': [
    for (var i = 0; i < kb * 4; i++)
      {
        'id': seed * 1000 + i,
        'title': 'Title $seed $i',
        'overview': 'x' * 180,
        'vote_average': 7.1,
      },
  ],
};

void main() {
  final skip = Platform.environment['REELISH_BENCH'] == '1'
      ? false
      : 'Set REELISH_BENCH=1 to run the cache benchmarks.';
  test('relaunch: Home entries still on disk after browsing', () async {
    final root = await Directory.systemTemp.createTemp('tmdb-bench-');
    addTearDown(() => root.delete(recursive: true));
    final cache = TmdbResponseCache(directory: root);
    // Windows Home: catalog rows, Top 10, releases, recommendations and
    // Spotlight logos.
    final home = [for (var i = 0; i < 30; i++) 'home/$i'];
    for (final key in home) {
      await cache.write(
        key,
        _body(i(key) < 12 ? 2 : 40, i(key)),
        TmdbCacheTtl.catalog,
      );
    }
    // 25 titles opened: details, recommendations, a season.
    for (var t = 0; t < 25; t++) {
      for (final part in ['details', 'recommendations', 'season']) {
        await cache.write(
          'title/$t/$part',
          _body(50, t),
          TmdbCacheTtl.metadata,
        );
      }
    }
    await cache.flush();
    // Let the scheduled cleanup run, then start again as a new launch.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final relaunched = TmdbResponseCache(directory: root);
    var hits = 0;
    for (final key in home) {
      if (await relaunched.read(key) != null) hits++;
    }
    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'));
    final bytes = files.fold<int>(0, (sum, f) => sum + f.lengthSync());
    // ignore: avoid_print
    print(
      'BENCH relaunch home hits=$hits/${home.length} '
      'diskFiles=${files.length} diskMB=${(bytes / 1048576).toStringAsFixed(1)}',
    );
  }, skip: skip);

  test('cleanup cost with a full disk cache', () async {
    for (final count in [64, 256]) {
      final root = await Directory.systemTemp.createTemp('tmdb-bench-');
      final dir = Directory('${root.path}/tmdb_response_cache')..createSync();
      // Files as the cache writes them, about 60 KB each.
      for (var n = 0; n < count; n++) {
        File('${dir.path}/$n.json').writeAsStringSync(
          jsonEncode({
            'requestKey': 'key/$n',
            'storedAt': DateTime.now().toUtc().toIso8601String(),
            'ttlMs': TmdbCacheTtl.metadata.inMilliseconds,
            'value': _body(60, n),
          }),
        );
      }
      final cache = TmdbResponseCache(
        directory: root,
        maxEntries: 10000,
        maxBytes: 1 << 40,
      );
      final watch = Stopwatch()..start();
      await cache.debugCleanup();
      // ignore: avoid_print
      print('BENCH cleanup files=$count ms=${watch.elapsedMilliseconds}');
      await root.delete(recursive: true);
    }
  }, skip: skip);

  test('pruning: full decode versus header read, same warm files', () async {
    final root = await Directory.systemTemp.createTemp('tmdb-bench-');
    addTearDown(() => root.delete(recursive: true));
    final files = [
      for (var n = 0; n < 128; n++)
        File('${root.path}/$n.json')..writeAsStringSync(
          jsonEncode({
            'requestKey': 'key/$n',
            'storedAt': DateTime.now().toUtc().toIso8601String(),
            'ttlMs': 1000,
            'value': _body(60, n),
          }),
        ),
    ];
    Future<int> full() async {
      final watch = Stopwatch()..start();
      for (final file in files) {
        final raw = jsonDecode(await file.readAsString()) as Map;
        expect(raw['ttlMs'], 1000);
      }
      return watch.elapsedMilliseconds;
    }

    Future<int> header() async {
      final watch = Stopwatch()..start();
      for (final file in files) {
        final (_, ttl) = await TmdbResponseCache.debugReadHeader(file);
        expect(ttl, 1000);
      }
      return watch.elapsedMilliseconds;
    }

    await full();
    await header();
    final runs = <String>[];
    for (var round = 0; round < 3; round++) {
      runs.add('full=${await full()}ms header=${await header()}ms');
    }
    // ignore: avoid_print
    print('BENCH prune 128 files x60KB: ${runs.join(' | ')}');
  }, skip: skip);
}

int i(String key) => int.parse(key.split('/').last);
