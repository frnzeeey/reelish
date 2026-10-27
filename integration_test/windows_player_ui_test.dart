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
import 'package:onfeed/src/widgets/player/player_volume_control.dart';
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

      /// Whether the playback controls show: they fade out (and stop taking
      /// input) rather than leave the tree.
      bool controlsShown() {
        final lock = find.bySemanticsLabel('Lock controls');
        if (lock.evaluate().isEmpty) return false;
        return tester
            .widgetList<AnimatedOpacity>(
              find.ancestor(of: lock, matching: find.byType(AnimatedOpacity)),
            )
            .every((fade) => fade.opacity > 0);
      }

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
      // No rotation lock on desktop; the screen lock is there.
      expect(find.bySemanticsLabel('Lock to landscape'), findsNothing);
      expect(find.bySemanticsLabel('Lock controls'), findsOneWidget);

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

      // Down lowers the volume while no control is focused; M mutes and
      // restores it.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await until(
        () => controller()!.value.volume < 1,
        'Down to lower the volume',
        timeout: const Duration(seconds: 5),
      );
      final lowered = controller()!.value.volume;
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await until(
        () => controller()!.value.volume == 0,
        'M to mute',
        timeout: const Duration(seconds: 5),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await until(
        () => (controller()!.value.volume - lowered).abs() < .001,
        'M to unmute',
        timeout: const Duration(seconds: 5),
      );

      // The screen lock: nothing from the keyboard, the wheel or the mouse
      // reaches playback until Enter unlocks (while the button shows).
      await mouse.moveTo(const Offset(440, 340));
      await until(
        () => controlsShown(),
        'controls with the lock button',
        timeout: const Duration(seconds: 5),
      );
      await tester.tap(find.bySemanticsLabel('Lock controls'));
      await tester.pump();
      expect(controller()!.value.isPlaying, isFalse);
      final lockedAt = controller()!.value.position;
      final lockedVolume = controller()!.value.volume;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 4)),
      );
      await tester.pump();
      // The unlock button has hidden again: keys and the wheel now.
      expect(find.bySemanticsLabel('Unlock controls'), findsNothing);
      for (final key in [
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.keyM,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pump();
      }
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(400, 300),
          scrollDelta: Offset(0, -40),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pump();
      expect(controller()!.value.isPlaying, isFalse, reason: 'Space');
      expect(controller()!.value.position, lockedAt, reason: 'Right arrow');
      expect(
        controller()!.value.volume,
        lockedVolume,
        reason: 'M, Down, wheel',
      );
      // A key showed the unlock button, not the controls.
      expect(find.bySemanticsLabel('Unlock controls'), findsOneWidget);
      expect(controlsShown(), isFalse);
      // Escape (windowed) does not leave a locked player.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(PlayerScreen), findsOneWidget);
      // Fullscreen is window management, not playback: F still enters it
      // and Escape still leaves it, and the player stays locked.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await until(() => DesktopWindow.fullscreen.value, 'F while locked');
      expect(controlsShown(), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await until(() => !DesktopWindow.fullscreen.value, 'Escape while locked');
      expect(find.byType(PlayerScreen), findsOneWidget);
      expect(controlsShown(), isFalse);
      expect(controller()!.value.isPlaying, isFalse);
      // Moving the mouse shows only the unlock button too.
      await mouse.moveTo(const Offset(460, 360));
      await tester.pump();
      expect(find.bySemanticsLabel('Unlock controls'), findsOneWidget);
      expect(controlsShown(), isFalse);

      // Enter unlocks while the button shows; the shortcuts work again.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await until(
        () => controlsShown(),
        'Enter to unlock',
        timeout: const Duration(seconds: 5),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await until(() => controller()!.value.isPlaying, 'Space after unlock');
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await until(() => !controller()!.value.isPlaying, 'pause again');

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

  testWidgets(
    'desktop player: mute carries over to another source',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final files = await tester.runAsync(
        () => Directory.systemTemp.createTemp('reelish-player-volume-'),
      );
      final storage = StorageService(filesDirectory: () async => files!);
      await tester.runAsync(DeviceCapabilities.load);
      // Two names for one clip: choosing the other opens a new player.
      const first = StreamSource(name: 'First', providerName: 'A', url: _clip);
      const second = StreamSource(
        name: 'Second',
        providerName: 'B',
        url: _clip,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: GlassTheme.tv,
          home: PlayerScreen(
            item: const MediaItem(id: '10378', type: 'movie', name: 'Clip'),
            source: first,
            sources: const [first, second],
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

      // Fully live: the engine draws frames itself, so no pump is needed.
      Future<void> until(bool Function() condition, String what) async {
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Timed out waiting: $what');
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
        }
      }

      await until(
        () => controller()?.value.isPlaying ?? false,
        'playback to start',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
      await until(() => controller()!.value.volume == 0, 'M to mute');
      final muted = controller();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 300));
      await mouse.moveTo(const Offset(420, 320));
      await until(
        () => find
            .bySemanticsLabel(RegExp('Choose source'))
            .evaluate()
            .isNotEmpty,
        'the source button',
      );
      await tester.tap(find.bySemanticsLabel(RegExp('Choose source')).first);
      await until(
        () => find.textContaining('B · Second').evaluate().isNotEmpty,
        'the source sheet',
      );
      // The sheet slides in; tap once it has settled.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 800)),
      );
      final option = find.textContaining('B · Second').last;
      await tester.ensureVisible(option);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 500)),
      );
      await tester.tap(option);
      await until(
        () =>
            controller() != null &&
            !identical(controller(), muted) &&
            controller()!.value.isPlaying,
        'the other source to play',
      );
      expect(controller()!.value.volume, 0, reason: 'still muted');
      await mouse.removePointer();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'desktop player: the volume control sets the engine volume without '
    'disturbing playback, and the next video opens at it',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final files = await tester.runAsync(
        () => Directory.systemTemp.createTemp('reelish-player-volume-ui-'),
      );
      final storage = StorageService(filesDirectory: () async => files!);
      await tester.runAsync(DeviceCapabilities.load);
      final settings = PlaybackSettingsController(storage: storage);
      Widget player(String id) => MaterialApp(
        theme: GlassTheme.tv,
        home: PlayerScreen(
          key: ValueKey(id),
          item: MediaItem(id: id, type: 'movie', name: 'Clip $id'),
          source: const StreamSource(name: 'Test clip', url: _clip),
          sources: const [StreamSource(name: 'Test clip', url: _clip)],
          storage: storage,
          playbackSettings: settings,
        ),
      );

      VideoPlayerController? controller() {
        final players = find.byType(VideoPlayer);
        return players.evaluate().isEmpty
            ? null
            : tester.widget<VideoPlayer>(players.first).controller;
      }

      Future<void> wait(int milliseconds) => tester.runAsync(
        () => Future<void>.delayed(Duration(milliseconds: milliseconds)),
      );

      Future<void> until(bool Function() condition, String what) async {
        final deadline = DateTime.now().add(const Duration(seconds: 40));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Timed out waiting: $what');
          }
          await wait(100);
          await tester.pump();
        }
      }

      await tester.pumpWidget(player('10378'));
      await until(
        () => controller()?.value.isPlaying ?? false,
        'playback to start',
      );
      final playing = controller();
      expect(playing!.value.volume, 1);

      // The pointer over the speaker shows the controls and opens the slider.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(400, 300));
      await mouse.moveTo(const Offset(420, 320));
      await until(
        () => find.bySemanticsLabel('Mute (M)').evaluate().isNotEmpty,
        'the volume control',
      );
      await mouse.moveTo(tester.getCenter(find.bySemanticsLabel('Mute (M)')));
      await until(
        () => find.text('100%').evaluate().isNotEmpty,
        'the volume slider to open',
      );
      await wait(400);

      // Dragging the slider to about half: the engine follows, and playback
      // goes on in the same player from where it was.
      final before = playing.value.position;
      final slider = find.byType(Slider);
      // From the thumb at the right end (100%), left by a third of the
      // track; a press in the middle would jump straight to 50%.
      final width = tester.getSize(slider).width;
      await tester.dragFrom(
        tester.getCenter(slider) + Offset(width / 2 - 16, 0),
        Offset(-width / 3, 0),
        kind: PointerDeviceKind.mouse,
      );
      await until(
        () => playing.value.volume < .8 && playing.value.volume > .2,
        'the slider to lower the engine volume',
      );
      final level = playing.value.volume;
      await wait(600);
      expect(identical(controller(), playing), isTrue, reason: 'same player');
      expect(playing.value.isPlaying, isTrue);
      expect(
        playing.value.position,
        greaterThanOrEqualTo(before),
        reason: 'no restart',
      );

      // The speaker mutes, and unmuting returns to the slider's level.
      // A click with the mouse, after a nudge that brings the controls back
      // (they hide a few seconds after the pointer stops).
      Future<void> clickSpeaker() async {
        await mouse.moveTo(const Offset(430, 330));
        await mouse.moveTo(const Offset(420, 320));
        // The speaker icon itself: with the slider open, the label's widget
        // spans the whole control.
        final speaker = find.byIcon(
          PlayerVolumeControl.iconFor(playing.value.volume),
        );
        await until(
          () => speaker.evaluate().isNotEmpty,
          'the controls to come back',
        );
        await wait(400);
        await tester.pump();
        final at = tester.getCenter(speaker);
        await mouse.moveTo(at);
        await wait(200);
        await tester.pump();
        await mouse.down(at);
        await mouse.up();
      }

      await clickSpeaker();
      await until(() => playing.value.volume == 0, 'the speaker to mute');
      await clickSpeaker();
      await until(
        () => (playing.value.volume - level).abs() < .001,
        'unmute to restore the level',
      );

      // Saved once it settles, and the next video opens at it.
      await until(
        () => (settings.value.desktopVolume - level).abs() < .001,
        'the level to be saved',
      );
      await mouse.removePointer();
      await tester.pumpWidget(player('10379'));
      await until(
        () =>
            controller() != null &&
            !identical(controller(), playing) &&
            controller()!.value.isPlaying,
        'the next video to play',
      );
      expect(
        controller()!.value.volume,
        closeTo(level, .001),
        reason: 'the remembered level',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
