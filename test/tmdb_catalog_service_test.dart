import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/services/media_catalog_rules.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/paged_feed_controller.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met in time.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Directory cacheRoot;
  late NetworkDestinationValidator network;

  setUp(() async {
    cacheRoot = await Directory.systemTemp.createTemp('reelish-catalog-test-');
    network = NetworkDestinationValidator(
      lookup: (_) async => [InternetAddress('8.8.8.8')],
    );
  });

  tearDown(() async {
    for (var attempt = 0; await cacheRoot.exists(); attempt++) {
      try {
        await cacheRoot.delete(recursive: true);
      } on FileSystemException {
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  TmdbService service(
    http.Client client, {
    TmdbResponseCache? cache,
    String? language,
    String? region,
  }) => TmdbService(
    apiKey: 'test-key',
    testClient: client,
    network: network,
    cache: cache ?? TmdbResponseCache(directory: cacheRoot),
    wait: (_) async {},
    jitter: () => 0,
    language: language,
    region: region,
  );

  /// Entries it stores are already an hour old, so the service treats them
  /// as stale while the cache still serves them.
  TmdbResponseCache staleCache() => TmdbResponseCache(
    directory: cacheRoot,
    clock: () => DateTime.now().subtract(const Duration(hours: 1)),
  );

  String daysAgo(int days) => MediaFreshnessRules.tmdbDate(
    DateTime.now().toUtc().subtract(Duration(days: days)),
  );

  http.Response results(List<Object?> entries) =>
      http.Response(jsonEncode({'results': entries}), 200);

  Map<String, Object?> recentMovie(int id) => {
    'id': id,
    'title': 'Movie $id',
    'release_date': daysAgo(20),
    'vote_average': 7.8,
    'vote_count': 400,
  };

  Map<String, Object?> recentSeries(int id) => {
    'id': id,
    'name': 'Series $id',
    'first_air_date': daysAgo(20),
    'vote_average': 8.0,
    'vote_count': 400,
    'genre_ids': [18],
  };

  test('stale New releases refresh in the background with one update', () async {
    var requests = 0;
    final client = MockClient((request) async {
      requests++;
      return request.url.path.endsWith('/discover/movie')
          ? results([recentMovie(1)])
          : results([recentSeries(2)]);
    });
    final cache = staleCache();
    final tmdb = service(client, cache: cache);

    expect(await tmdb.newReleases(), hasLength(2));
    expect(requests, 3);

    var updates = 0;
    final stale = await tmdb.newReleases(onRevalidated: (_) => updates++);
    expect(stale, hasLength(2));
    await _until(() => requests == 6);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(updates, 1);

    await cache.flush();
    client.close();
  });

  test('a stale value during the failure cooldown starts no refresh and '
      'keeps no callback', () async {
    var requests = 0;
    var failing = false;
    final client = MockClient((request) async {
      requests++;
      if (failing) return http.Response('', 404);
      return results([
        {...recentMovie(1), 'media_type': 'movie'},
      ]);
    });
    final cache = staleCache();
    final tmdb = service(client, cache: cache);
    await tmdb.trending();
    failing = true;

    var updates = 0;
    // Stale: served at once, refresh fails in the background.
    expect(await tmdb.trending(onRevalidated: (_) => updates++), hasLength(1));
    await _until(() => requests == 2);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Inside the 30 s cooldown: stale value, no request, no callback.
    expect(await tmdb.trending(onRevalidated: (_) => updates++), hasLength(1));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requests, 2);
    expect(updates, 0);

    await cache.flush();
    client.close();
  });

  test('network errors never carry the API key', () async {
    final client = MockClient(
      (request) async => throw http.ClientException(
        'Connection closed while fetching ${request.url}',
        request.url,
      ),
    );
    final tmdb = service(client);

    Object? caught;
    try {
      await tmdb.trending();
    } catch (error) {
      caught = error;
    }
    expect(caught, isA<http.ClientException>());
    expect('$caught', isNot(contains('test-key')));
    expect((caught as http.ClientException).uri?.queryParameters, isEmpty);
    client.close();
  });

  test('sends language and region only when configured', () async {
    final urls = <Uri>[];
    final client = MockClient((request) async {
      urls.add(request.url);
      return results([recentMovie(1)]);
    });

    await service(client).newMovies();
    expect(urls.single.queryParameters.containsKey('language'), isFalse);
    expect(urls.single.queryParameters.containsKey('region'), isFalse);
    expect(urls.single.queryParameters['with_release_type'], '3|4');

    urls.clear();
    await service(client, language: 'en-US', region: 'PH').newMovies();
    expect(urls.single.queryParameters['language'], 'en-US');
    expect(urls.single.queryParameters['region'], 'PH');
    client.close();
  });

  test('New movies drops old titles even when TMDB returns them', () async {
    final client = MockClient(
      (_) async => results([
        recentMovie(1),
        {
          'id': 2,
          'title': 'Old Classic',
          'release_date': '1994-09-23',
          'vote_average': 9.3,
          'vote_count': 30000,
        },
      ]),
    );
    final movies = await service(client).newMovies();
    expect(movies.map((movie) => movie.id), ['1']);
    client.close();
  });

  test('search finds old titles and skips malformed records', () async {
    final client = MockClient(
      (_) async => results([
        {
          'id': 238,
          'media_type': 'movie',
          'title': 'The Godfather',
          'release_date': '1972-03-14',
          'vote_average': 8.7,
          'vote_count': 20000,
        },
        {'id': 1158, 'media_type': 'person', 'name': 'Al Pacino'},
        {'media_type': 'movie', 'title': 'No id'},
        {'id': 'abc', 'media_type': 'tv', 'name': 'Bad id'},
        {'id': 7, 'title': 'No media type'},
        {'id': 9, 'media_type': 'tv', 'name': 'Twice', 'vote_average': 'x'},
        {'id': 9, 'media_type': 'tv', 'name': 'Twice'},
        'garbage',
        null,
      ]),
    );
    final found = await service(client).search('godfather');
    expect(found.map((item) => item.name), ['The Godfather', 'Twice']);
    expect(found.first.year, '1972');
    expect(found.last.type, 'series');
    expect(found.last.rating, '');
    client.close();
  });

  test('a full memory cache evicts search entries before catalog', () async {
    final cache = TmdbResponseCache(directory: cacheRoot, maxEntries: 3);
    await cache.write('catalog-a', {'v': 1}, TmdbCacheTtl.catalog);
    await cache.write('catalog-b', {'v': 2}, TmdbCacheTtl.metadata);
    for (var i = 0; i < 4; i++) {
      await cache.write('search-$i', {'v': i}, TmdbCacheTtl.search);
    }

    expect((await cache.read('catalog-a'))?.fromMemory, isTrue);
    expect((await cache.read('catalog-b'))?.fromMemory, isTrue);
    expect((await cache.read('search-3'))?.fromMemory, isTrue);
    await cache.flush();
  });

  http.Response pageOf(List<Object?> entries, {int page = 1, int? total}) =>
      http.Response(
        jsonEncode({'page': page, 'results': entries, 'total_pages': ?total}),
        200,
      );

  test('New movies pages report TMDB paging and request one page', () async {
    final urls = <Uri>[];
    final client = MockClient((request) async {
      urls.add(request.url);
      final page = int.parse(request.url.queryParameters['page']!);
      return pageOf([recentMovie(page * 10)], page: page, total: 3);
    });
    final tmdb = service(client);

    final first = await tmdb.newMoviesPage();
    final third = await tmdb.newMoviesPage(page: 3);

    expect(urls.map((url) => url.queryParameters['page']), ['1', '3']);
    expect(first.items.single.id, '10');
    expect(first.hasMore, isTrue);
    expect(third.totalPages, 3);
    expect(third.hasMore, isFalse);
    client.close();
  });

  test('a response without total_pages ends the list', () async {
    final client = MockClient((_) async => results([recentSeries(1)]));
    final page = await service(client).streamingSeriesPage();
    expect(page.hasMore, isFalse);
    client.close();
  });

  test('the same page is served from cache until it expires', () async {
    // Entries are stamped this far in the past when stored.
    var age = Duration.zero;
    var requests = 0;
    final client = MockClient((_) async {
      requests++;
      return pageOf([recentMovie(1)], total: 5);
    });
    final cache = TmdbResponseCache(
      directory: cacheRoot,
      clock: () => DateTime.now().subtract(age),
    );
    final tmdb = service(client, cache: cache);

    final fresh = await tmdb.newMoviesPage();
    final cached = await tmdb.newMoviesPage();
    expect(requests, 1);
    expect(fresh.fromCache, isFalse);
    expect(cached.fromCache, isTrue);

    // Page 2 is a different cache entry.
    await tmdb.newMoviesPage(page: 2);
    expect(requests, 2);

    // Past the catalog lifetime the cached page is still shown, and a
    // background request renews it.
    age = TmdbCacheTtl.catalog + const Duration(minutes: 1);
    await tmdb.newMoviesPage(page: 3);
    expect(requests, 3);
    age = Duration.zero;
    CatalogPage? revalidated;
    final stale = await tmdb.newMoviesPage(
      page: 3,
      onRevalidated: (page) => revalidated = page,
    );
    expect(stale.fromCache, isTrue);
    await _until(() => revalidated != null);
    expect(requests, 4);
    expect(revalidated!.hasMore, isTrue);

    await cache.flush();
    client.close();
  });

  test('later New releases pages skip lists that have ended', () async {
    final urls = <Uri>[];
    final client = MockClient((request) async {
      urls.add(request.url);
      final page = int.parse(request.url.queryParameters['page']!);
      final query = request.url.queryParameters;
      // Movies have 3 pages, premieres 1, ongoing series 2.
      if (request.url.path.endsWith('/discover/movie')) {
        return pageOf([recentMovie(100 + page)], page: page, total: 3);
      }
      if (query.containsKey('first_air_date.gte')) {
        return pageOf([recentSeries(200 + page)], page: page, total: 1);
      }
      return pageOf([recentSeries(300 + page)], page: page, total: 2);
    });
    final tmdb = service(client);

    final first = await tmdb.newReleasesPage();
    expect(urls, hasLength(3));
    expect(first.sourceTotalPages, [3, 1, 2]);
    expect(first.hasMore, isTrue);

    urls.clear();
    final second = await tmdb.newReleasesPage(page: 2, previous: first);
    expect(urls, hasLength(2));
    expect(
      urls.where(
        (url) => url.queryParameters.containsKey('first_air_date.gte'),
      ),
      isEmpty,
    );
    expect(second.items.map((item) => item.id), containsAll(['102', '302']));

    urls.clear();
    final third = await tmdb.newReleasesPage(page: 3, previous: second);
    expect(urls.single.path, endsWith('/discover/movie'));
    expect(third.hasMore, isFalse);
    client.close();
  });

  test('Top 10 candidates page each seed and keep page 1 cache keys', () async {
    final urls = <Uri>[];
    final client = MockClient((request) async {
      urls.add(request.url);
      final page = int.parse(request.url.queryParameters['page'] ?? '1');
      return request.url.path.contains('/tv/')
          ? pageOf([recentSeries(500 + page)], page: page, total: 1)
          : pageOf([recentMovie(400 + page)], page: page, total: 4);
    });
    final tmdb = service(client);
    final seeds = [
      const MediaItem(id: '11', type: 'movie', name: 'Seed movie'),
      const MediaItem(id: '22', type: 'series', name: 'Seed series'),
    ];

    final first = await tmdb.recommendationCandidatesPage(seeds);
    expect(urls.map((url) => url.queryParameters['page']), [null, null]);
    expect(first.items.map((item) => item.id), ['401', '501']);

    urls.clear();
    final second = await tmdb.recommendationCandidatesPage(
      seeds,
      page: 2,
      previous: first,
    );
    // The series seed had one page; only the movie seed is asked again.
    expect(urls.single.path, '/3/movie/11/recommendations');
    expect(urls.single.queryParameters['page'], '2');
    expect(second.items.map((item) => item.id), ['402']);
    client.close();
  });

  test('MediaItem keeps genre data through storage', () {
    final item = MediaItem.fromTmdb({
      'id': 4,
      'name': 'Show',
      'genre_ids': [18, 80],
    }, mediaType: 'tv');
    expect(MediaItem.fromStorage(item.toJson()).genreIds, [18, 80]);
  });
}
