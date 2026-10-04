import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/services/stream_discovery.dart';

StreamSource source(String url) => StreamSource(name: url, url: url);

void main() {
  test('first valid source is available before discovery completes', () async {
    final discovery = StreamDiscovery();
    final slowProvider = Completer<void>();
    final receivedDone = Completer<void>();
    final received = <String>[];
    discovery.updates.listen(
      (entry) => received.add(entry.url),
      onDone: receivedDone.complete,
    );

    final fastProvider = Future<void>.microtask(
      () => discovery.add(source('https://fast.example/video.m3u8')),
    );
    final slowResult = () async {
      await slowProvider.future;
      discovery.add(source('https://slow.example/video.m3u8'));
    }();
    final allProviders = Future.wait([fastProvider, slowResult])
      ..whenComplete(discovery.complete);

    expect(
      (await discovery.firstSource)?.url,
      'https://fast.example/video.m3u8',
    );
    expect(discovery.sources, hasLength(1));

    slowProvider.complete();
    await allProviders;
    await discovery.finished;
    await receivedDone.future;

    expect(received, [
      'https://fast.example/video.m3u8',
      'https://slow.example/video.m3u8',
    ]);
  });

  test('replays discovered sources and removes duplicate URLs', () async {
    final discovery = StreamDiscovery();
    discovery.add(source('https://media.example/video.mp4'));
    discovery.add(source('https://media.example/video.mp4'));
    discovery.complete();

    expect(await discovery.updates.map((entry) => entry.url).toList(), [
      'https://media.example/video.mp4',
    ]);
  });

  test('cancelled discovery ignores later results', () async {
    final discovery = StreamDiscovery();
    discovery.cancel();
    discovery.add(source('https://media.example/video.mp4'));
    discovery.complete();

    expect(await discovery.firstSource, isNull);
    expect(discovery.sources, isEmpty);
  });

  test('expired sources are rejected during normalization', () {
    final entry = StreamSource.fromJson({
      'url': 'https://media.example/video.mp4',
      'expiresAt': DateTime.now()
          .subtract(const Duration(minutes: 1))
          .toIso8601String(),
    });

    expect(entry.isExpired, isTrue);
    expect(entry.isPlayable, isFalse);
  });

  group('startingSource', () {
    final torrent = StreamSource(
      name: 'torrent',
      url: 'magnet:?xt=urn:btih:${'a' * 40}',
    );

    test('a direct first result starts immediately', () async {
      final discovery = StreamDiscovery()
        ..add(source('https://direct.example/a.m3u8'));
      expect(
        (await discovery.startingSource(grace: Duration.zero))?.url,
        'https://direct.example/a.m3u8',
      );
    });

    test('a torrent first result waits briefly for a direct stream', () async {
      final discovery = StreamDiscovery()..add(torrent);
      final starting = discovery.startingSource();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      discovery.add(source('https://direct.example/b.mp4'));
      expect((await starting)?.url, 'https://direct.example/b.mp4');
    });

    test('keeps the torrent when no direct stream arrives in time', () async {
      final discovery = StreamDiscovery()..add(torrent);
      expect(
        await discovery.startingSource(grace: const Duration(milliseconds: 20)),
        same(torrent),
      );
    });

    test('keeps the torrent when discovery finishes without another', () async {
      final discovery = StreamDiscovery()..add(torrent);
      final starting = discovery.startingSource();
      discovery.complete();
      expect(await starting, same(torrent));
    });
  });
}
