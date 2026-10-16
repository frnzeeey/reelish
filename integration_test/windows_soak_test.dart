// Repeats the heaviest flows and records resident memory, to catch leaks in
// the player (libmpv, textures) and the provider runtime (QuickJS isolates):
//
//   flutter test integration_test/windows_soak_test.dart -d windows
//
// Plays Mux's public HLS test stream (Big Buck Bunny, CC BY 3.0).
@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/screens/player_screen.dart';
import 'package:onfeed/src/services/playback_settings_controller.dart';
import 'package:onfeed/src/services/provider_runner.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

const _hls = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

int _rssMb() => ProcessInfo.currentRss ~/ (1024 * 1024);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'opening and closing the player does not grow memory',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final files = await tester.runAsync(
        () => Directory.systemTemp.createTemp('reelish-soak-'),
      );
      final storage = StorageService(filesDirectory: () async => files!);
      // Mux's HLS test stream is served from a CDN that tolerates repeated
      // opens. (The player refuses loopback URLs, by design.)
      const url = _hls;
      final settings = PlaybackSettingsController(storage: storage);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.tv,
          navigatorKey: navigator,
          home: const Scaffold(body: Text('Home')),
        ),
      );

      Future<void> until(bool Function() condition, String what) async {
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) fail('Timed out: $what');
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        }
      }

      bool playing() {
        final players = find.byType(VideoPlayer);
        return players.evaluate().isNotEmpty &&
            tester
                .widget<VideoPlayer>(players.first)
                .controller
                .value
                .isPlaying;
      }

      Future<void> cycle() async {
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (_) => PlayerScreen(
              item: const MediaItem(id: '10378', type: 'movie', name: 'Clip'),
              source: const StreamSource(name: 'Clip', url: url),
              sources: const [StreamSource(name: 'Clip', url: url)],
              storage: storage,
              playbackSettings: settings,
            ),
          ),
        );
        await until(playing, 'playback');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)),
        );
        navigator.currentState!.pop();
        await until(
          () => find.byType(PlayerScreen).evaluate().isEmpty,
          'player closed',
        );
        // Give the engine its asynchronous dispose.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(seconds: 2)),
        );
        await tester.pump();
      }

      // Warm up: first use loads libmpv, shaders and the HTTP stack.
      await cycle();
      await cycle();
      final baseline = _rssMb();
      final samples = <int>[];
      for (
        var i = 0;
        i < const int.fromEnvironment('SOAK_CYCLES', defaultValue: 20);
        i++
      ) {
        await cycle();
        samples.add(_rssMb());
      }
      // ignore: avoid_print
      print('SOAK_PLAYER rss_mb baseline=$baseline after_each=$samples');
      // Measured on Windows: +~85 MB over the first ~13 cycles (HLS variant
      // buffers, allocator), then ~0.7 MB per cycle. A leaked decoder, its
      // frame buffers or the video texture would add tens of MB per cycle.
      expect(samples.last - baseline, lessThan(150));
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'repeated provider runs do not grow memory',
    () async {
      ProviderRunRequest request() => const ProviderRunRequest(
        pluginId: 'soak',
        code: '''
        module.exports.getStreams = async (id) => {
          const filler = [];
          for (let i = 0; i < 20000; i++) filler.push({ i, s: 'x'.repeat(32) });
          return [{ name: 'soak', url: 'https://cdn.example/' + id + '.m3u8' }];
        };
      ''',
        codeUrl: 'https://repo.example/soak.js',
        tmdbId: '603',
        mediaType: 'movie',
      );
      for (var i = 0; i < 5; i++) {
        await ProviderRunner.run(request());
      }
      final baseline = _rssMb();
      final samples = <int>[];
      for (var round = 0; round < 6; round++) {
        for (var i = 0; i < 5; i++) {
          await ProviderRunner.run(request());
        }
        samples.add(_rssMb());
      }
      // ignore: avoid_print
      print('SOAK_PROVIDER rss_mb baseline=$baseline after_every_5=$samples');
      // Each run allocates ~2 MB inside a 64 MiB QuickJS heap in its own
      // isolate; anything retained across 30 runs would show here.
      expect(samples.last - baseline, lessThan(40));
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
