// Opens and closes the real player many times on a device or emulator and
// checks that the app's memory settles, so players, engines, controllers and
// listeners are released instead of piling up over a long session:
//
//   flutter test integration_test/player_long_session_test.dart -d <device>
//
// Needs internet: it plays short public test streams.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/screens/player_screen.dart';
import 'package:onfeed/src/services/playback_settings_controller.dart';
import 'package:onfeed/src/services/player_engine.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/widgets/player/player_controls.dart';
import 'package:video_player/video_player.dart';

/// Public test streams: two open on Media3 (HTTPS), one on libmpv (HTTP).
const _streams = [
  StreamSource(
    name: 'MP4',
    providerName: 'Test',
    url:
        'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4',
  ),
  StreamSource(
    name: 'HLS',
    providerName: 'Test',
    url: 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
  ),
  StreamSource(
    name: 'HLS over HTTP',
    providerName: 'Test',
    url: 'http://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
  ),
];

int _residentMegabytes() {
  final line = File(
    '/proc/self/status',
  ).readAsLinesSync().firstWhere((line) => line.startsWith('VmRSS:'));
  return int.parse(RegExp(r'\d+').firstMatch(line)!.group(0)!) ~/ 1024;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'memory settles over repeated playback',
    (tester) async {
      PlayerEngineBootstrap.initialize();
      // On an emulator libmpv runs through MediaCodec output instead of
      // OpenGL (see PlayerEngineBootstrap), a path that intermittently
      // never presents a surface there. Phones use the OpenGL path, which
      // an emulator cannot run, so libmpv is only covered on real devices.
      final emulator =
          await const MethodChannel(
            'onfeed/player',
          ).invokeMethod<bool>('isEmulator') ??
          false;
      final streams = [
        for (final stream in _streams)
          if (!emulator || stream.url.startsWith('https:')) stream,
      ];
      // ignore: avoid_print
      print('STREAMS ${streams.map((stream) => stream.name).join(', ')}');
      final storage = StorageService();
      final settings = PlaybackSettingsController(storage: storage);
      await settings.load();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: const Scaffold(body: SizedBox.expand()),
        ),
      );

      Route<void> playerRoute(int episode) => MaterialPageRoute<void>(
        builder: (_) => PlayerScreen(
          item: const MediaItem(id: '1399', type: 'series', name: 'Session'),
          source: streams[episode % streams.length],
          sources: [streams[episode % streams.length]],
          storage: storage,
          playbackSettings: settings,
          season: 1,
          episode: episode,
        ),
      );

      /// Every controller that has played so far. While a route transition
      /// runs, the previous episode's player is still on screen and playing,
      /// so only a controller not seen before counts as the new episode.
      final seen = <VideoPlayerController>{};

      /// Episodes that ended on the player's error panel instead of playing.
      final failures = <String>[];

      /// Waits until the new episode plays, or shows its error panel. A
      /// player that does neither (stuck on its loading screen) fails the test.
      Future<void> waitForPlayback(int episode) async {
        final name = streams[episode % streams.length].name;
        // Let the route transition finish, so the previous episode's
        // player (and any error it showed) is gone.
        await tester.pump(const Duration(milliseconds: 800));
        final started = DateTime.now();
        final end = started.add(const Duration(seconds: 60));
        var state = 'no new video surface';
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 250));
          final elapsed = DateTime.now().difference(started).inMilliseconds;
          if (find.byType(PlayerErrorPanel).evaluate().isNotEmpty) {
            failures.add('$episode $name');
            // ignore: avoid_print
            print('EPISODE $episode $name showed its error after ${elapsed}ms');
            return;
          }
          final controller = find
              .byType(VideoPlayer)
              .evaluate()
              .map((element) => (element.widget as VideoPlayer).controller)
              .where((controller) => !seen.contains(controller))
              .firstOrNull;
          if (controller == null) continue;
          final value = controller.value;
          state =
              'playing=${value.isPlaying} position=${value.position} '
              'size=${value.size} error=${value.errorDescription}';
          if (value.isPlaying &&
              value.position > const Duration(milliseconds: 800)) {
            seen.add(controller);
            // ignore: avoid_print
            print('EPISODE $episode $name playing after ${elapsed}ms');
            return;
          }
        }
        throw TestFailure(
          'Episode $episode ($name) neither played nor showed an error: $state',
        );
      }

      final samples = <int>[];
      const sessions = 24;
      for (var episode = 1; episode <= sessions; episode++) {
        // Every other session replaces the playing player in place, as an
        // episode switch does; the rest close it and open a new one.
        final replace = episode.isEven && navigator.currentState!.canPop();
        if (replace) {
          navigator.currentState!.pushReplacement(playerRoute(episode));
        } else {
          if (navigator.currentState!.canPop()) navigator.currentState!.pop();
          await tester.pump(const Duration(milliseconds: 500));
          navigator.currentState!.push(playerRoute(episode));
        }
        await waitForPlayback(episode);
        // Watch a little, then let disposal from the previous step finish.
        await tester.pump(const Duration(seconds: 2));
        PaintingBinding.instance.imageCache.clear();
        samples.add(_residentMegabytes());
      }
      navigator.currentState!.pop();
      await tester.pump(const Duration(seconds: 3));
      await SystemChrome.setPreferredOrientations(const []);
      samples.add(_residentMegabytes());

      // ignore: avoid_print
      print('RSS_MB ${samples.join(' ')}');
      // ignore: avoid_print
      print(
        'FAILED_EPISODES ${failures.isEmpty ? 'none' : failures.join(', ')}',
      );
      // Every stream covered here must play.
      expect(failures, isEmpty);
      // After warming up (engines loaded, caches filled), each further player
      // must not leave memory behind.
      final warm = samples.sublist(6, 12).reduce((a, b) => a + b) ~/ 6;
      final late =
          samples.sublist(sessions - 6, sessions).reduce((a, b) => a + b) ~/ 6;
      expect(
        late - warm,
        lessThan(60),
        reason: 'memory kept growing: ${samples.join(', ')} MB',
      );
      settings.dispose();
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
