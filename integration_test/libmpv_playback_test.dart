// Opens a stream on libmpv with its FFmpeg protocol allowlist in place,
// on a device or emulator (needs internet):
//
//   flutter test integration_test/libmpv_playback_test.dart -d <device>
//
// libmpv sets up its Android video output on the frame pipeline, so this is
// a widget test that keeps frames pumping while the engine opens. Skipped on
// emulators: there libmpv renders through MediaCodec output instead of
// OpenGL (see PlayerEngineBootstrap), and that path fails to start playback
// about half the time, with or without the allowlist. Phones use OpenGL.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/playable_source.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/models/stream_type.dart';
import 'package:onfeed/src/services/player_engine.dart';
import 'package:video_player/video_player.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'libmpv plays HTTP HLS with the protocol allowlist',
    (tester) async {
      final emulator =
          await const MethodChannel(
            'onfeed/player',
          ).invokeMethod<bool>('isEmulator') ??
          false;
      if (emulator) {
        markTestSkipped('libmpv playback is unreliable on emulators.');
        return;
      }
      PlayerEngineBootstrap.initialize();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      const url = 'http://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
      const engine = MpvPlayerEngine();
      await PlayerEngineGate.activate(engine);
      final controller = engine.createController(
        PlayableSource(
          source: const StreamSource(name: 'HLS', url: url),
          uri: Uri.parse(url),
          headers: const {},
          streamType: StreamType.hls,
        ),
      );
      var ready = false;
      controller.initialize().then((_) => ready = true);
      final end = DateTime.now().add(const Duration(seconds: 60));
      while (!ready && DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(ready, isTrue, reason: 'libmpv did not initialize');
      await tester.pumpWidget(MaterialApp(home: VideoPlayer(controller)));
      controller.play();
      while (controller.value.position < const Duration(seconds: 2) &&
          DateTime.now().isBefore(end)) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      // ignore: avoid_print
      print('MPV_POSITION ${controller.value.position}');
      expect(
        controller.value.position,
        greaterThan(const Duration(seconds: 2)),
      );
      await tester.pumpWidget(const SizedBox());
      await controller.dispose();
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
