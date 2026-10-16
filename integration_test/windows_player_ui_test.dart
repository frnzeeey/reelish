// Drives Reelish's player screen on Windows with the desktop keyboard and
// mouse, playing a public test clip (Big Buck Bunny, CC BY 3.0):
//
//   flutter test integration_test/windows_player_ui_test.dart -d windows
@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:onfeed/src/models/media_item.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/platform/desktop_window.dart';
import 'package:onfeed/src/platform/device_capabilities.dart';
import 'package:onfeed/src/screens/player_screen.dart';
import 'package:onfeed/src/services/playback_settings_controller.dart';
import 'package:onfeed/src/services/storage_service.dart';
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

const _clip =
    'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/'
    'Big_Buck_Bunny_360_10s_1MB.mp4';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'desktop player: keyboard, mouse and fullscreen',
    (tester) async {
      // Keep the test away from the app's real settings and history.
      SharedPreferences.setMockInitialValues({});
      final files = await tester.runAsync(
        () => Directory.systemTemp.createTemp('reelish-player-ui-'),
      );
      final storage = StorageService(filesDirectory: () async => files!);
      await tester.runAsync(DeviceCapabilities.load);
      expect(DeviceCapabilities.isDesktop, isTrue);
      expect(DeviceCapabilities.usesTvLayout, isTrue);
      expect(DeviceCapabilities.isTv, isFalse);

      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.tv,
          navigatorKey: navigatorKey,
          builder: (context, child) =>
              DesktopShortcuts(navigatorKey: navigatorKey, child: child!),
          home: const Scaffold(body: Text('Home')),
        ),
      );
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(
            item: const MediaItem(id: '10378', type: 'movie', name: 'Clip'),
            source: const StreamSource(name: 'Test clip', url: _clip),
            sources: const [StreamSource(name: 'Test clip', url: _clip)],
            storage: storage,
            playbackSettings: PlaybackSettingsController(storage: storage),
          ),
        ),
      );

      VideoPlayerController? controller() {
        final players = find.byType(VideoPlayer);
        return players.evaluate().isEmpty
            ? null
            : tester.widget<VideoPlayer>(players.first).controller;
      }

      Future<void> until(
        bool Function() condition,
        String what, {
        Duration timeout = const Duration(seconds: 40),
      }) async {
        final deadline = DateTime.now().add(timeout);
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Timed out waiting: $what');
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pump();
        }
      }

      await until(
        () => controller()?.value.isPlaying ?? false,
        'playback to start',
      );
      expect(controller()!.value.size.width, greaterThan(0));

      // Space pauses and resumes.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await until(() => !controller()!.value.isPlaying, 'Space to pause');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await until(() => controller()!.value.isPlaying, 'Space to resume');

      // Moving the mouse brings up the controls, including the fullscreen
      // button that only the desktop player has.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 300));
      await mouse.moveTo(const Offset(420, 320));
      await until(
        () =>
            find.byTooltip('Full screen (F)').evaluate().isNotEmpty ||
            find.bySemanticsLabel('Full screen (F)').evaluate().isNotEmpty,
        'controls with a fullscreen button',
        timeout: const Duration(seconds: 5),
      );
      // No rotation lock or touch lock on desktop.
      expect(find.bySemanticsLabel('Lock to landscape'), findsNothing);

      // F enters fullscreen; Escape leaves it before anything else.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await until(() => DesktopWindow.fullscreen.value, 'F for fullscreen');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await until(() => !DesktopWindow.fullscreen.value, 'Escape to exit');
      expect(find.byType(PlayerScreen), findsOneWidget);

      // Right arrow seeks forward while the controls have no focused button.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await until(() => !controller()!.value.isPlaying, 'pause before seek');
      final before = controller()!.value.position;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await until(
        () =>
            controller()!.value.position >= before + const Duration(seconds: 4),
        'Right arrow to seek',
        timeout: const Duration(seconds: 10),
      );

      // Escape (windowed) leaves the player like Back.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await until(
        () => find.byType(PlayerScreen).evaluate().isEmpty,
        'Escape to close the player',
        timeout: const Duration(seconds: 10),
      );
      expect(find.text('Home'), findsOneWidget);
      await mouse.removePointer();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
