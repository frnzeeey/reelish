import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/playable_source.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/models/stream_type.dart';
import 'package:onfeed/src/services/network_target_policy.dart';
import 'package:onfeed/src/services/playback_coordinator.dart';
import 'package:onfeed/src/services/player_engine.dart';
import 'package:onfeed/src/services/provider_fetch_bridge.dart';
import 'package:onfeed/src/services/provider_script_cache.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

StreamSource _source(String name, {String provider = 'A', String url = ''}) =>
    StreamSource(
      name: name,
      url: url.isEmpty ? 'https://$name.example/video.m3u8' : url,
      providerName: provider,
    );

void main() {
  group('failure classification', () {
    PlaybackFailure classify(Object error) => PlaybackFailure.classify(error);

    test('audio without a picture is a rendering failure', () {
      final failure = classify(PlaybackFailure.noPicture);
      expect(failure.kind, PlaybackFailureKind.rendering);
      expect(failure.canTryAnotherEngine, isTrue);
      expect(failure.userMessage, 'The video could not be displayed.');
    });

    test('network, HTTP, DNS and timeout failures skip the engine retry', () {
      for (final error in <Object>[
        TimeoutException('initialize'),
        PlatformException(
          code: 'VideoError',
          message: 'HTTP error 403 Forbidden',
        ),
        const SocketException('Failed host lookup: cdn.example'),
        SourcePreparationException(const FormatException('non-public')),
        Exception('Connection reset by peer'),
      ]) {
        final failure = classify(error);
        expect(failure.canTryAnotherEngine, isFalse, reason: '$error');
        expect(failure.canTryAnotherSource, isTrue, reason: '$error');
      }
    });

    test('engine-specific failures allow one retry on the other engine', () {
      for (final message in [
        'Video player had error androidx.media3.exoplayer.ExoPlaybackException: Source error',
        'MediaCodecVideoRenderer error, decoder init failed',
        'Failed to recognize file format.',
        'Cleartext HTTP traffic to cdn.example not permitted',
      ]) {
        expect(
          classify(
            PlatformException(code: 'VideoError', message: message),
          ).canTryAnotherEngine,
          isTrue,
          reason: message,
        );
      }
    });

    test('words inside a stream URL do not decide the failure kind', () {
      final failure = classify(
        Exception(
          'Failed host lookup for https://cdn.example/render/codec/master.m3u8?token=abc',
        ),
      );
      expect(failure.kind, PlaybackFailureKind.network);
    });

    test('reads HTTP status codes for the error message', () {
      final failure = classify(Exception('Response code: 404'));
      expect(failure.kind, PlaybackFailureKind.http);
      expect(failure.statusCode, 404);
      expect(failure.userMessage, contains('404'));
    });

    test('cancellation never moves to another source', () {
      final failure = classify(
        StateError('Playback initialization was cancelled.'),
      );
      expect(failure.kind, PlaybackFailureKind.cancelled);
      expect(failure.canTryAnotherSource, isFalse);
    });
  });

  group('PlaybackCoordinator', () {
    test('an engine retry does not use up the source budget', () {
      final coordinator = PlaybackCoordinator(maxAutomaticAttempts: 2);
      final first = _source('one', provider: 'A');
      final second = _source('two', provider: 'B');
      coordinator.replaceCandidates([first, second]);

      coordinator.beginAttempt(first, PlayerEngineId.media3);
      coordinator.beginAttempt(first, PlayerEngineId.mediaKit);
      expect(coordinator.attemptedCount, 1);
      expect(coordinator.nextAfterFailure(first), second);
    });

    test('ranks other providers, then direct streams before torrents', () {
      final coordinator = PlaybackCoordinator();
      final failed = _source('failed', provider: 'A');
      final sameProvider = _source('same', provider: 'A');
      final torrent = StreamSource(
        name: 'torrent',
        url: 'magnet:?xt=urn:btih:${'a' * 40}',
        providerName: 'B',
      );
      final direct = _source('direct', provider: 'C');
      coordinator.replaceCandidates([failed, sameProvider, torrent, direct]);
      coordinator.beginAttempt(failed, PlayerEngineId.media3);
      coordinator.recordFailure(failed);

      expect(coordinator.nextAfterFailure(failed), direct);
      coordinator.beginAttempt(direct, PlayerEngineId.media3);
      coordinator.recordFailure(direct);
      // A direct stream still beats a torrent, which needs metadata first.
      expect(coordinator.nextAfterFailure(direct), sameProvider);
      coordinator.beginAttempt(sameProvider, PlayerEngineId.media3);
      expect(coordinator.nextAfterFailure(sameProvider), torrent);
    });

    test('lowers providers that already failed this session', () {
      final coordinator = PlaybackCoordinator();
      final a1 = _source('a1', provider: 'A');
      final b1 = _source('b1', provider: 'B');
      final a2 = _source('a2', provider: 'A');
      final c1 = _source('c1', provider: 'C');
      coordinator.replaceCandidates([a1, b1, a2, c1]);
      coordinator.beginAttempt(a1, PlayerEngineId.media3);
      coordinator.recordFailure(a1);
      coordinator.beginAttempt(b1, PlayerEngineId.media3);
      coordinator.recordFailure(b1);

      // a2's provider failed and so did b1's; c1 has no failures yet.
      expect(coordinator.nextAfterFailure(b1), c1);
    });

    test('ranking keeps discovery order between equal candidates', () {
      final coordinator = PlaybackCoordinator();
      final failed = _source('failed', provider: 'A');
      final b = _source('b', provider: 'B');
      final c = _source('c', provider: 'C');
      coordinator.replaceCandidates([failed, b, c]);
      coordinator.beginAttempt(failed, PlayerEngineId.media3);
      expect(coordinator.nextAfterFailure(failed), b);
    });
  });

  group('engine selection', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('cleartext and non-HTTP stream URLs go straight to libmpv', () {
      const media3 = Media3PlayerEngine();
      for (final url in [
        'http://cdn.example/video.mp4',
        'http://127.0.0.1:8080/stream',
        'rtmp://live.example/app/key',
      ]) {
        expect(
          PlayerEngineFactory.forSource(url, media3),
          isA<MpvPlayerEngine>(),
          reason: url,
        );
        expect(PlayerEngineFactory.canOpen(media3, url), isFalse, reason: url);
      }
      expect(
        PlayerEngineFactory.forSource('https://cdn.example/a.m3u8', media3),
        isA<Media3PlayerEngine>(),
      );
    });

    test('a session preference for libmpv is kept for HTTPS too', () {
      expect(
        PlayerEngineFactory.forSource(
          'https://cdn.example/a.m3u8',
          const MpvPlayerEngine(),
        ),
        isA<MpvPlayerEngine>(),
      );
    });

    test('activating an engine again keeps the same platform instance', () {
      VideoPlayerMediaKit.registerWith();
      final mediaKit = VideoPlayerPlatform.instance;
      VideoPlayerMediaKit.registerWith();
      expect(identical(VideoPlayerPlatform.instance, mediaKit), isTrue);

      const Media3PlayerEngine().activate();
      final media3 = VideoPlayerPlatform.instance;
      const Media3PlayerEngine().activate();
      expect(identical(VideoPlayerPlatform.instance, media3), isTrue);

      // Switching back reuses the instance that owns libmpv's players.
      VideoPlayerMediaKit.registerWith();
      expect(identical(VideoPlayerPlatform.instance, mediaKit), isTrue);
    });

    test(
      'another engine is selected only once the open player is gone',
      () async {
        final controller = const MpvPlayerEngine().createController(
          PlayableSource(
            source: const StreamSource(name: 'a', url: 'http://cdn.example/a'),
            uri: Uri.parse('http://cdn.example/a'),
            headers: const {},
            streamType: StreamType.hls,
          ),
        );
        expect(PlayerEngineGate.liveCount(PlayerEngineId.mediaKit), 1);

        var switched = false;
        final switching = PlayerEngineGate.activate(
          const FlutterPlatformPlayerEngine(),
        ).then((_) => switched = true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(switched, isFalse);

        await controller.dispose();
        await switching.timeout(const Duration(seconds: 1));
        expect(switched, isTrue);
        expect(PlayerEngineGate.liveCount(PlayerEngineId.mediaKit), 0);

        // With nothing open, a switch does not wait at all.
        await PlayerEngineGate.activate(
          const FlutterPlatformPlayerEngine(),
        ).timeout(const Duration(milliseconds: 100));
      },
    );
  });

  group('NAT64 destinations', () {
    NetworkDestinationValidator resolvingTo(String address) =>
        NetworkDestinationValidator(
          lookup: (_) async => [InternetAddress(address)],
        );

    test('accepts a synthesized address for a public IPv4 host', () async {
      final addresses = await resolvingTo(
        '64:ff9b::5db8:d822', // 93.184.216.34
      ).resolveDestination(Uri.parse('https://cdn.example.com/a'));
      expect(addresses, hasLength(1));
    });

    test('rejects a synthesized address for a private IPv4 host', () async {
      await expectLater(
        resolvingTo(
          '64:ff9b::c0a8:0101', // 192.168.1.1
        ).resolveDestination(Uri.parse('https://cdn.example.com/a')),
        throwsFormatException,
      );
    });
  });

  group('ProviderScriptCache', () {
    test(
      'reuses a script within the TTL and shares concurrent fetches',
      () async {
        var now = DateTime(2026, 1, 1);
        var fetches = 0;
        final cache = ProviderScriptCache(clock: () => now);
        Future<String> fetch() async {
          fetches++;
          return 'script $fetches';
        }

        final results = await Future.wait([
          cache.get('https://repo.example/a.js', fetch),
          cache.get('https://repo.example/a.js', fetch),
        ]);
        expect(results, ['script 1', 'script 1']);
        expect(await cache.get('https://repo.example/a.js', fetch), 'script 1');
        expect(fetches, 1);

        now = now.add(const Duration(minutes: 31));
        expect(await cache.get('https://repo.example/a.js', fetch), 'script 2');
      },
    );

    test('falls back to a recent copy when a refresh fails', () async {
      var now = DateTime(2026, 1, 1);
      final cache = ProviderScriptCache(clock: () => now);
      await cache.get('u', () async => 'cached');
      now = now.add(const Duration(hours: 1));
      expect(
        await cache.get('u', () async => throw const SocketException('down')),
        'cached',
      );
      now = now.add(const Duration(days: 2));
      await expectLater(
        cache.get('u', () async => throw const SocketException('down')),
        throwsA(isA<SocketException>()),
      );
    });

    test('a failed first fetch is not cached', () async {
      final cache = ProviderScriptCache();
      await expectLater(
        cache.get('u', () async => throw const SocketException('down')),
        throwsA(isA<SocketException>()),
      );
      expect(await cache.get('u', () async => 'ok'), 'ok');
    });
  });

  group('provider redirect headers', () {
    final from = Uri.parse('https://api.example/resolve');

    test('keeps provider headers across origins like OkHttp', () {
      final headers = ProviderFetchBridge.redirectHeaders(
        {
          'Referer': 'https://site.example/',
          'Origin': 'https://site.example',
          'X-Requested-With': 'XMLHttpRequest',
          'User-Agent': 'UA',
          'Authorization': 'Bearer secret',
          'Cookie': 'session=1',
        },
        from: from,
        to: Uri.parse('https://cdn.example/video'),
        changesToGet: false,
      );
      expect(headers['Referer'], 'https://site.example/');
      expect(headers['Origin'], 'https://site.example');
      expect(headers['X-Requested-With'], 'XMLHttpRequest');
      expect(headers['User-Agent'], 'UA');
      expect(headers.containsKey('Authorization'), isFalse);
      expect(headers.containsKey('Cookie'), isFalse);
    });

    test('keeps credentials on the same origin', () {
      final headers = ProviderFetchBridge.redirectHeaders(
        {'Authorization': 'Bearer secret', 'Cookie': 'session=1'},
        from: from,
        to: Uri.parse('https://api.example/next'),
        changesToGet: false,
      );
      expect(headers['Authorization'], 'Bearer secret');
      expect(headers['Cookie'], 'session=1');
      expect(headers['Referer'], from.toString());
    });

    test('drops body headers when the method becomes GET', () {
      final headers = ProviderFetchBridge.redirectHeaders(
        {'Content-Type': 'application/json', 'Content-Length': '12'},
        from: from,
        to: Uri.parse('https://api.example/result'),
        changesToGet: true,
      );
      expect(headers.containsKey('Content-Type'), isFalse);
      expect(headers.containsKey('Content-Length'), isFalse);
    });
  });
}
