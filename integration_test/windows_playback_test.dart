// Plays real media through Reelish's Windows engine (libmpv via media_kit):
//
//   flutter test integration_test/windows_playback_test.dart -d windows
//
// Uses public test media: Mux's HLS test stream, Akamai's DASH reference
// stream and test-videos.co.uk's Big Buck Bunny clips (CC BY 3.0).
@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/playable_source.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/models/stream_type.dart';
import 'package:onfeed/src/services/player_engine.dart';
import 'package:video_player/video_player.dart';

const _hls = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
const _dash = 'https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd';
const _mp4 =
    'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/'
    'Big_Buck_Bunny_360_10s_1MB.mp4';
const _mkv =
    'https://test-videos.co.uk/vids/bigbuckbunny/mkv/360/'
    'Big_Buck_Bunny_360_10s_1MB.mkv';

PlayableSource _source(
  String url,
  StreamType type, {
  Map<String, String> headers = const {},
}) => PlayableSource(
  source: StreamSource(name: 'test', url: url, headers: headers),
  uri: Uri.parse(url),
  headers: headers,
  streamType: type,
);

Future<void> _waitFor(
  VideoPlayerController controller,
  bool Function(VideoPlayerValue value) condition, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition(controller.value)) {
    final error = controller.value.errorDescription;
    if (error != null) fail('Player error: $error');
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out; last value: ${controller.value}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Opens [source] on the platform's default engine, plays it and waits
/// until playback has moved at least [advance].
Future<VideoPlayerController> _play(
  PlayableSource source, {
  Duration advance = const Duration(seconds: 2),
}) async {
  final engine = PlayerEngineFactory.forCurrentPlatform();
  expect(engine, isA<MpvPlayerEngine>());
  engine.activate();
  final controller = engine.createController(source);
  await controller.initialize().timeout(const Duration(seconds: 45));
  await controller.setVolume(0);
  await controller.play();
  await _waitFor(controller, (value) => value.position >= advance);
  return controller;
}

/// Like `runApp`, pumps a first frame so the window is shown and frames
/// run, then executes [body] with real async I/O.
void _liveTest(String description, Future<void> Function() body) {
  testWidgets(description, (tester) async {
    await tester.pumpWidget(const SizedBox.expand());
    await tester.runAsync(body);
  }, timeout: const Timeout(Duration(minutes: 2)));
}

void main() {
  // Run frames the framework requests, as the app does; media_kit creates
  // its video output after a frame.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  _liveTest('HLS plays, reports its size and duration, and seeks', () async {
    final controller = await _play(_source(_hls, StreamType.hls));
    addTearDown(controller.dispose);
    expect(controller.value.isInitialized, isTrue);
    expect(controller.value.duration, greaterThan(const Duration(minutes: 1)));
    expect(controller.value.size.width, greaterThan(0));

    await controller.seekTo(const Duration(seconds: 60));
    await _waitFor(
      controller,
      (value) => value.position >= const Duration(seconds: 61),
    );
  });

  _liveTest('DASH plays', () async {
    final controller = await _play(_source(_dash, StreamType.dash));
    addTearDown(controller.dispose);
    expect(controller.value.size.width, greaterThan(0));
  });

  _liveTest('MP4 and MKV play, and playback speed applies', () async {
    for (final url in [_mp4, _mkv]) {
      final controller = await _play(
        _source(url, StreamType.progressive),
        advance: const Duration(seconds: 1),
      );
      await controller.setPlaybackSpeed(2);
      final start = controller.value.position;
      final watch = Stopwatch()..start();
      await _waitFor(
        controller,
        (value) => value.position - start >= const Duration(seconds: 3),
        timeout: const Duration(seconds: 20),
      );
      // At 2x, 3 s of media takes well under 3 s of wall-clock time.
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 2900)));
      expect(controller.value.playbackSpeed, 2);
      await controller.dispose();
    }
  });

  _liveTest(
    'provider headers reach the server and redirects are followed',
    () async {
      final media = await HttpClient()
          .getUrl(Uri.parse(_mp4))
          .then((request) => request.close())
          .then(
            (response) => response.fold<List<int>>([], (a, b) => a..addAll(b)),
          );
      final seen = <Map<String, String?>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final response = request.response;
        if (request.uri.path == '/redirect') {
          response
            ..statusCode = HttpStatus.found
            ..headers.set('location', '/video.mp4');
          await response.close();
          return;
        }
        seen.add({
          'user-agent': request.headers.value('user-agent'),
          'referer': request.headers.value('referer'),
        });
        // Like a provider host: refuse requests without its Referer.
        if (request.headers.value('referer') != 'https://provider.example/') {
          response.statusCode = HttpStatus.forbidden;
          await response.close();
          return;
        }
        response.headers.contentType = ContentType('video', 'mp4');
        response.headers.set('accept-ranges', 'none');
        response.contentLength = media.length;
        response.add(media);
        await response.close();
      });

      final controller = await _play(
        _source(
          'http://127.0.0.1:${server.port}/redirect',
          StreamType.progressive,
          headers: const {
            'User-Agent': 'ReelishTest/1.0',
            'Referer': 'https://provider.example/',
          },
        ),
        advance: const Duration(seconds: 1),
      );
      addTearDown(controller.dispose);
      expect(seen, isNotEmpty);
      expect(seen.first['user-agent'], 'ReelishTest/1.0');
      expect(seen.first['referer'], 'https://provider.example/');
    },
  );

  _liveTest('a player can be closed and another opened', () async {
    for (var round = 0; round < 3; round++) {
      final controller = await _play(
        _source(_mp4, StreamType.progressive),
        advance: const Duration(milliseconds: 500),
      );
      await controller.dispose();
    }
  });

  _liveTest('a dead stream reports an error instead of hanging', () async {
    final engine = PlayerEngineFactory.forCurrentPlatform()..activate();
    final controller = engine.createController(
      _source('http://127.0.0.1:9/missing.mp4', StreamType.progressive),
    );
    addTearDown(controller.dispose);
    Object? failure;
    try {
      await controller.initialize().timeout(const Duration(seconds: 30));
    } catch (error) {
      failure = error;
    }
    expect(
      failure != null || controller.value.errorDescription != null,
      isTrue,
    );
  });
}
