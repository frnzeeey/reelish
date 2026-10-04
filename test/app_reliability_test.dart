import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('a corrupt saved entry does not break history or favorites', () async {
    final valid = jsonEncode(
      const MediaItem(id: '1', type: 'movie', name: 'Alpha').toJson(),
    );
    SharedPreferences.setMockInitialValues({
      'onfeed.history': ['{not json', valid, '[1, 2]'],
      'onfeed.favorites': ['', valid],
    });
    final storage = StorageService();

    expect((await storage.history()).map((item) => item.name), ['Alpha']);
    expect((await storage.favorites()).map((item) => item.name), ['Alpha']);

    // Saving progress keeps working and drops the unreadable entries.
    await storage.saveProgress(
      const MediaItem(id: '2', type: 'movie', name: 'Beta'),
      42000,
    );
    expect((await storage.history()).map((item) => item.name), [
      'Beta',
      'Alpha',
    ]);
  });

  test('opening a series loads details and seasons with one request', () async {
    final cacheRoot = await Directory.systemTemp.createTemp('reelish-series-');
    addTearDown(() async {
      for (var attempt = 0; await cacheRoot.exists(); attempt++) {
        try {
          await cacheRoot.delete(recursive: true);
        } on FileSystemException {
          if (attempt >= 20) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return http.Response(
        jsonEncode({
          'id': 7,
          'name': 'Show',
          'seasons': [
            {'season_number': 0, 'name': 'Specials'},
            {'season_number': 1, 'name': 'Season 1'},
          ],
          'credits': {'cast': <Object>[]},
        }),
        200,
      );
    });
    final cache = TmdbResponseCache(directory: cacheRoot);
    final tmdb = TmdbService(
      apiKey: 'test-key',
      testClient: client,
      network: NetworkDestinationValidator(
        lookup: (_) async => [InternetAddress('8.8.8.8')],
      ),
      cache: cache,
    );
    const show = MediaItem(id: '7', type: 'series', name: 'Show');

    final results = await Future.wait([tmdb.details(show), tmdb.seasons(show)]);
    final seasons = results[1] as List<Map<String, dynamic>>;
    expect(seasons.map((season) => season['season_number']), [1]);
    expect(requests, 1);
    await cache.flush();
    client.close();
  });
}
