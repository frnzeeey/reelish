// Torrent playback on Windows through the bundled engine DLL and libmpv,
// with a freely licensed torrent (Big Buck Bunny, CC BY 3.0, the WebTorrent
// sample). Needs the network and a live swarm:
//
//   flutter test integration_test/windows_torrent_test.dart -d windows
@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_go_torrent_streamer/flutter_go_torrent_streamer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/player_screen.dart';
import 'package:onfeed/src/services/playback_settings_controller.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/services/torrent_source_preparer.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

const _bigBuckBunny = StreamSource(
  name: 'Big Buck Bunny',
  providerName: 'Test',
  url:
      'magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c'
      '&dn=Big+Buck+Bunny'
      '&tr=udp%3A%2F%2Fexplodie.org%3A6969'
      '&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce'
      '&tr=udp%3A%2F%2Ftracker.torrent.eu.org%3A451%2Fannounce',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'Windows plays a torrent and stops its session',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final files = await tester.runAsync(
        () => Directory.systemTemp.createTemp('reelish-torrent-'),
      );
      final storage = StorageService(filesDirectory: () async => files!);
      await tester.runAsync(DeviceCapabilities.load);
      expect(
        TorrentSupport.available,
        isTrue,
        reason: 'torrent_streamer.dll is bundled and loads',
      );

      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.tv,
          navigatorKey: navigatorKey,
          home: const Scaffold(body: Text('Home')),
        ),
      );

      VideoPlayerController? controller() {
        final players = find.byType(VideoPlayer);
        return players.evaluate().isEmpty
            ? null
            : tester.widget<VideoPlayer>(players.first).controller;
      }

      // Fully live: the engine draws frames itself, so no pump is needed.
      Future<void> wait(Duration duration) =>
          tester.runAsync(() => Future<void>.delayed(duration));
      Future<void> until(
        bool Function() condition,
        String what,
        Duration timeout,
      ) async {
        final deadline = DateTime.now().add(timeout);
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Timed out waiting: $what');
          }
          await wait(const Duration(milliseconds: 200));
        }
      }

      Future<int> liveSessions() async => (await tester.runAsync(
        () => FlutterTorrentStreamer().getAllSessions(),
      ))!.where((session) => session.state != 'Stopped').length;

      void open() => navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(
            item: const MediaItem(id: '10378', type: 'movie', name: 'Bunny'),
            source: _bigBuckBunny,
            sources: const [_bigBuckBunny],
            storage: storage,
            playbackSettings: PlaybackSettingsController(storage: storage),
          ),
        ),
      );

      final clock = Stopwatch()..start();
      open();
      await until(
        () =>
            (controller()?.value.isPlaying ?? false) &&
            controller()!.value.position > const Duration(seconds: 2),
        'the torrent to play',
        const Duration(minutes: 3),
      );
      // ignore: avoid_print
      print('TORRENT playing after ${clock.elapsedMilliseconds}ms');
      expect(controller()!.value.size.width, greaterThan(0), reason: 'picture');
      expect(await liveSessions(), 1);

      // Seeking ahead needs pieces that were not downloaded yet.
      final target = controller()!.value.position + const Duration(minutes: 3);
      clock.reset();
      await controller()!.seekTo(target);
      await until(
        () =>
            controller()!.value.isPlaying &&
            controller()!.value.position > target + const Duration(seconds: 2),
        'playback after a seek',
        const Duration(minutes: 2),
      );
      // ignore: avoid_print
      print('TORRENT resumed after a seek in ${clock.elapsedMilliseconds}ms');

      // Closing the player stops its session.
      navigatorKey.currentState!.pop();
      await until(
        () => find.byType(PlayerScreen).evaluate().isEmpty,
        'the player to close',
        const Duration(seconds: 10),
      );
      await wait(const Duration(seconds: 2));
      expect(await liveSessions(), 0, reason: 'session after close');

      // Closing while it still starts stops that session too.
      open();
      await wait(const Duration(seconds: 2));
      navigatorKey.currentState!.pop();
      await wait(const Duration(seconds: 6));
      expect(await liveSessions(), 0, reason: 'session after an early close');

      // The engine keeps its data in its own app-data folder, not Documents.
      final engine = await tester.runAsync(
        FlutterTorrentStreamer.engineDirectory,
      );
      final cache = await tester.runAsync(getApplicationCacheDirectory);
      expect(engine!.path, startsWith(cache!.path));
      expect(
        Directory(
          '${engine.path}\\flutter_torrent_streamer_global',
        ).existsSync(),
        isTrue,
      );
      final documents = await tester.runAsync(getApplicationDocumentsDirectory);
      expect(
        Directory(
          '${documents!.path}\\flutter_torrent_streamer_global',
        ).existsSync(),
        isFalse,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
