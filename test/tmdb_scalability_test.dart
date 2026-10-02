import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:onfeed/src/screens/home_screen.dart';
import 'package:onfeed/src/services/accent_settings_controller.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/tmdb_response_cache.dart';
import 'package:onfeed/src/services/tmdb_service.dart';

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
    if (await cacheRoot.exists()) await cacheRoot.delete(recursive: true);
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
    await Future<void>.delayed(Duration.zero);
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
    await service(firstClient).popular('movie');
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
    final client = MockClient((request) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 3));
      active--;
      return http.Response(popularBody, 200);
    });
    final tmdb = service(client, maxConcurrentRequests: 2);

    await Future.wait([
      tmdb.popular('movie'),
      tmdb.popular('series'),
      tmdb.trending(),
      tmdb.search('different title'),
    ]);

    expect(peak, lessThanOrEqualTo(2));
    expect(peak, 2);
    client.close();
  });

  testWidgets('home startup defers recommendations and new releases', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1;
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add(request.url.path);
      return http.Response(popularBody, 200);
    });
    final tmdb = service(client);
    final accentSettings = AccentSettingsController();
    addTearDown(accentSettings.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          accentSettings: accentSettings,
          tmdbService: tmdb,
          updateChecker: () async => null,
        ),
      ),
    );
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }

    expect(paths, containsAll(['/3/movie/popular', '/3/tv/popular']));
    expect(paths.where((path) => path.contains('recommendations')), isEmpty);
    expect(paths.where((path) => path.contains('/discover/')), isEmpty);

    for (var i = 0; i < 5; i++) {
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -500),
      );
      await tester.pump(const Duration(milliseconds: 60));
    }
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(paths.where((path) => path.contains('recommendations')), isNotEmpty);
    expect(paths.where((path) => path.contains('/discover/')), isNotEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    client.close();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
