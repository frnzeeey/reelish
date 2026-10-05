import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onfeed/src/models/app_update.dart';
import 'package:onfeed/src/screens/home_screen.dart';
import 'package:onfeed/src/widgets/category_chip.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/media_catalog_rules.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';

/// Waits in real time until [condition] holds. TmdbService reads its disk
/// cache before calling the client, so a request does not reach the client
/// within a single event-loop turn.
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
  const popularBody =
      '{"results":[{"id":1,"media_type":"movie",'
      '"title":"Alpha","poster_path":null,"backdrop_path":null,'
      '"release_date":"2024-01-01","vote_average":7.2,"overview":""}]}';

  late Directory cacheRoot;
  late NetworkDestinationValidator network;

  setUp(() async {
    cacheRoot = await Directory.systemTemp.createTemp('reelish-tmdb-test-');
    network = NetworkDestinationValidator(
      lookup: (_) async => [InternetAddress('8.8.8.8')],
    );
  });

  tearDown(() async {
    // The cache writes responses in the background after returning them;
    // on Windows the directory stays locked until that write finishes.
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
    int maxConcurrentRequests = 4,
    Future<void> Function(Duration)? wait,
  }) => TmdbService(
    apiKey: 'test-key',
    testClient: client,
    network: network,
    cache: cache ?? TmdbResponseCache(directory: cacheRoot),
    maxConcurrentRequests: maxConcurrentRequests,
    wait: wait ?? (_) async {},
    jitter: () => 0,
  );

  test('coalesces concurrent identical catalog requests', () async {
    var requests = 0;
    final responseCompleter = Completer<http.Response>();
    final client = MockClient((request) {
      requests++;
      return responseCompleter.future;
    });
    final tmdb = service(client);

    final first = tmdb.popular('movie');
    final second = tmdb.popular('movie');
    final third = tmdb.popular('movie');
    await _until(() => requests > 0);
    // Give a duplicate request time to start if coalescing were broken.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(requests, 1);
    responseCompleter.complete(http.Response(popularBody, 200));
    final results = await Future.wait([first, second, third]);
    expect(results.map((items) => items.single.name), everyElement('Alpha'));
    expect(requests, 1);
    client.close();
  });

  test('persists successful responses for a new service instance', () async {
    var requests = 0;
    final firstClient = MockClient((_) async {
      requests++;
      return http.Response(popularBody, 200);
    });
    final firstCache = TmdbResponseCache(directory: cacheRoot);
    await service(firstClient, cache: firstCache).popular('movie');
    // The disk copy is written in the background after the response returns.
    await firstCache.flush();
    firstClient.close();

    final secondClient = MockClient((_) async {
      requests++;
      return http.Response(popularBody, 200);
    });
    final result = await service(
      secondClient,
      cache: TmdbResponseCache(directory: cacheRoot),
    ).popular('movie');

    expect(result.single.name, 'Alpha');
    expect(requests, 1);
    secondClient.close();
  });

  test(
    'retries rate limits using Retry-After and honors the request cap',
    () async {
      var requests = 0;
      final delays = <Duration>[];
      final client = MockClient((_) async {
        requests++;
        if (requests == 1) {
          return http.Response('', 429, headers: {'retry-after': '0'});
        }
        return http.Response(popularBody, 200);
      });
      final tmdb = service(client, wait: (delay) async => delays.add(delay));

      await tmdb.popular('movie');

      expect(requests, 2);
      expect(delays, [Duration.zero]);
      client.close();
    },
  );

  test('bounds simultaneous distinct TMDB requests', () async {
    var active = 0;
    var peak = 0;
    // Hold every response until the cap has been reached, so the test does
    // not depend on how quickly requests get past the disk cache.
    final release = Completer<void>();
    final client = MockClient((request) async {
      active++;
      if (active > peak) peak = active;
      await release.future;
      active--;
      return http.Response(popularBody, 200);
    });
    final tmdb = service(client, maxConcurrentRequests: 2);

    final all = Future.wait([
      tmdb.popular('movie'),
      tmdb.popular('series'),
      tmdb.trending(),
      tmdb.search('different title'),
    ]);
    await _until(() => active == 2);
    // A third request would start here if the cap were not enforced.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(active, 2);
    release.complete();
    await all;

    expect(peak, 2);
    client.close();
  });

  String daysAgo(int days) => MediaFreshnessRules.tmdbDate(
    DateTime.now().toUtc().subtract(Duration(days: days)),
  );

  Map<String, Object?> movieJson(int id, String title) => {
    'id': id,
    'title': title,
    'release_date': daysAgo(30),
    'vote_average': 7.6,
    'vote_count': 800,
    'popularity': 50,
    'genre_ids': [28],
  };

  Map<String, Object?> seriesJson(int id, String name) => {
    'id': id,
    'name': name,
    'first_air_date': daysAgo(400),
    'vote_average': 8.1,
    'vote_count': 900,
    'popularity': 40,
    'genre_ids': [18],
  };

  http.Response results(List<Map<String, Object?>> entries) =>
      http.Response(jsonEncode({'results': entries}), 200);

  /// New releases are the only discover queries with a rating floor.
  bool isNewReleasesQuery(Uri url) =>
      url.path.contains('/discover/') &&
      url.queryParameters.containsKey('vote_average.gte');

  /// Serves the home catalog, Trending and recommendations. Deferred rows
  /// answer with [deferredStatus] when it is set.
  http.Response homeResponse(http.Request request, {int? deferredStatus}) {
    final url = request.url;
    final deferred =
        isNewReleasesQuery(url) || url.path.contains('/recommendations');
    if (deferred && deferredStatus != null) {
      return http.Response('', deferredStatus);
    }
    if (url.path.endsWith('/trending/all/day')) {
      return results([
        {...movieJson(900, 'Trending Hit'), 'media_type': 'movie'},
      ]);
    }
    if (url.path.contains('/recommendations')) {
      return results([movieJson(500, 'Recommended Pick')]);
    }
    if (url.path.endsWith('/discover/movie')) {
      return results([movieJson(1, 'Fresh Movie')]);
    }
    if (url.path.endsWith('/discover/tv')) {
      return results([seriesJson(2, 'Scripted Drama')]);
    }
    return http.Response('', 404);
  }

  Future<AccentSettingsController> pumpHome(
    WidgetTester tester,
    TmdbService tmdb,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final accentSettings = AccentSettingsController();
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          accentSettings: accentSettings,
          tmdbService: tmdb,
          updateChecker: () async =>
              const UpdateCheckResult(UpdateCheckStatus.upToDate),
        ),
      ),
    );
    return accentSettings;
  }

  // The TMDB disk cache uses real file I/O, which cannot complete inside
  // the widget test's fake-async zone; let it run in real time.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  Future<void> disposeHome(
    WidgetTester tester,
    AccentSettingsController accentSettings,
    http.Client client,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    accentSettings.dispose();
    client.close();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }

  testWidgets('home startup defers recommendations and new releases', (
    tester,
  ) async {
    // Short enough that the deferred sections start beyond the viewport plus
    // the scroll view's 250 px cache extent with this small catalog.
    tester.view.physicalSize = const Size(600, 200);
    tester.view.devicePixelRatio = 1;
    final urls = <Uri>[];
    final client = MockClient((request) async {
      urls.add(request.url);
      return homeResponse(request);
    });
    final accentSettings = await pumpHome(tester, service(client));
    await settle(tester);

    // The catalog loads New movies and scripted series from discover.
    final catalog = urls.where((url) => !isNewReleasesQuery(url)).toList();
    expect(
      catalog.map((url) => url.path),
      containsAll(['/3/discover/movie', '/3/discover/tv']),
    );
    final seriesQuery = catalog.firstWhere(
      (url) => url.path == '/3/discover/tv',
    );
    expect(seriesQuery.queryParameters['with_type'], '2|4');
    expect(
      seriesQuery.queryParameters['without_genres'],
      '10767|10763|10764|10766',
    );
    expect(urls.where((url) => url.path.contains('recommendations')), isEmpty);
    expect(urls.where(isNewReleasesQuery), isEmpty);

    for (var i = 0; i < 5; i++) {
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -500),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    await settle(tester);
    expect(urls.where((url) => url.path.contains('recommendations')), isNotEmpty);
    final releaseQueries = urls.where(isNewReleasesQuery).toList();
    expect(releaseQueries, hasLength(3));
    final movieReleases = releaseQueries.firstWhere(
      (url) => url.path == '/3/discover/movie',
    );
    // Festival premieres and limited runs are not counted as releases.
    expect(movieReleases.queryParameters['with_release_type'], '3|4');

    await disposeHome(tester, accentSettings, client);
  });

  for (final status in [401, 429, 503]) {
    testWidgets(
      'a failed deferred row ($status) waits for Retry instead of looping',
      (tester) async {
        // Tall enough that both deferred rows are on screen at startup.
        tester.view.physicalSize = const Size(500, 2400);
        tester.view.devicePixelRatio = 1;
        var releaseRequests = 0;
        var recommendationRequests = 0;
        final client = MockClient((request) async {
          if (isNewReleasesQuery(request.url)) releaseRequests++;
          if (request.url.path.contains('/recommendations')) {
            recommendationRequests++;
          }
          return homeResponse(request, deferredStatus: status);
        });
        final accentSettings = await pumpHome(tester, service(client));
        await settle(tester);

        // Retryable statuses use the service's own retries (maxRetries 2).
        final attempts = status == 401 ? 1 : 3;
        expect(releaseRequests, 3 * attempts);
        expect(recommendationRequests, 2 * attempts);
        expect(find.text('Retry'), findsNWidgets(2));

        // Still visible and rebuilt many times: no new requests.
        await settle(tester);
        await settle(tester);
        expect(releaseRequests, 3 * attempts);
        expect(recommendationRequests, 2 * attempts);

        // Retry is the way to try again; it sends one new round.
        await tester.tap(find.text('Retry').last);
        await settle(tester);
        expect(releaseRequests, 6 * attempts);
        expect(recommendationRequests, 2 * attempts);

        await disposeHome(tester, accentSettings, client);
      },
    );
  }

  testWidgets('Trending never leaks into the other home categories', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 2400);
    tester.view.devicePixelRatio = 1;
    var trendingRequests = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/trending/all/day')) trendingRequests++;
      return homeResponse(request);
    });
    final accentSettings = await pumpHome(tester, service(client));
    await settle(tester);

    Future<void> open(String category) async {
      await tester.tap(find.widgetWithText(CategoryChip, category));
      await settle(tester);
    }

    await open('Trending');
    expect(find.text('Trending Hit'), findsWidgets);
    expect(find.text('Fresh Movie'), findsNothing);

    await open('Movies');
    expect(find.text('Fresh Movie'), findsWidgets);
    expect(find.text('Trending Hit'), findsNothing);

    await open('Series');
    expect(find.text('Scripted Drama'), findsWidgets);
    expect(find.text('Fresh Movie'), findsNothing);
    expect(find.text('Trending Hit'), findsNothing);

    await open('For you');
    expect(find.text('New movies'), findsOneWidget);
    expect(find.text('Popular movies'), findsNothing);
    expect(find.text('Trending Hit'), findsNothing);

    await open('Trending');
    expect(find.text('Trending Hit'), findsWidgets);
    // The second visit is served from the fresh TMDB cache.
    expect(trendingRequests, 1);

    await open('Movies');
    expect(find.text('Fresh Movie'), findsWidgets);
    expect(find.text('Trending Hit'), findsNothing);

    await disposeHome(tester, accentSettings, client);
  });
}
