import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Windows Spotlight's logo lookup: one cached images request, an
/// English PNG preferred, and nothing when there is none to draw.
void main() {
  late Directory cacheRoot;
  final requests = <Uri>[];
  late Map<String, dynamic> answer;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    requests.clear();
    cacheRoot = await Directory.systemTemp.createTemp('reelish-logo-');
  });
  tearDown(() async {
    try {
      await cacheRoot.delete(recursive: true);
    } catch (_) {}
  });

  TmdbService tmdb() => TmdbService(
    apiKey: 'test-key',
    testClient: MockClient((request) async {
      requests.add(request.url);
      return http.Response(jsonEncode(answer), 200);
    }),
    network: NetworkDestinationValidator(
      lookup: (_) async => [InternetAddress('8.8.8.8')],
    ),
    cache: TmdbResponseCache(directory: cacheRoot),
  );

  test('prefers an English PNG and skips SVGs', () async {
    answer = {
      'logos': [
        {'file_path': '/fr.png', 'iso_639_1': 'fr'},
        {'file_path': '/en.svg', 'iso_639_1': 'en'},
        {'file_path': '/en.png', 'iso_639_1': 'en'},
      ],
    };
    final service = tmdb();
    const show = MediaItem(id: '7', type: 'series', name: 'Show');
    expect(await service.logo(show), 'https://image.tmdb.org/t/p/w500/en.png');
    expect(requests.single.path, endsWith('/tv/7/images'));
    expect(
      requests.single.queryParameters['include_image_language'],
      'en,null',
    );
    // Cached: asking again sends nothing.
    await service.logo(show);
    expect(requests, hasLength(1));
  });

  test('falls back to a text-free logo, then to none', () async {
    answer = {
      'logos': [
        {'file_path': '/plain.png', 'iso_639_1': null},
      ],
    };
    const film = MediaItem(id: '8', type: 'movie', name: 'Film');
    expect(
      await tmdb().logo(film),
      'https://image.tmdb.org/t/p/w500/plain.png',
    );
    answer = {'logos': <Object>[]};
    const other = MediaItem(id: '9', type: 'movie', name: 'Other');
    expect(await tmdb().logo(other), '');
  });

  test('a title without a TMDB id asks nothing', () async {
    answer = {};
    const imported = MediaItem(id: 'tt123', type: 'movie', name: 'Imported');
    expect(await tmdb().logo(imported), '');
    expect(requests, isEmpty);
  });
}
