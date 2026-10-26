import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/models/stream_source.dart';
import 'package:onfeed/src/widgets/player/gesture_touch_layer.dart';
import 'package:onfeed/src/widgets/player/player_controls.dart';
import 'package:onfeed/src/widgets/player/player_lock_overlay.dart';
import 'package:onfeed/src/widgets/player/player_marquee_text.dart';
import 'package:onfeed/src/widgets/player/player_progress_bar.dart';
import 'package:onfeed/src/widgets/player/stream_selector_sheet.dart';
import 'package:video_player/video_player.dart';

/// A controller whose state the test sets directly; it is never initialized,
/// so no platform player is involved.
VideoPlayerController _controller({
  Duration duration = const Duration(minutes: 100),
  Duration position = const Duration(minutes: 10),
  bool playing = true,
}) {
  final controller = VideoPlayerController.networkUrl(
    Uri.parse('https://cdn.example/video.m3u8'),
  );
  controller.value = controller.value.copyWith(
    duration: duration,
    position: position,
    isPlaying: playing,
    isInitialized: true,
    size: const Size(1920, 1080),
  );
  return controller;
}

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData.dark(),
  home: Scaffold(backgroundColor: Colors.black, body: child),
);

void main() {
  testWidgets('desktop: a click plays or pauses, a double click toggles '
      'fullscreen and plays nothing, a drag does neither', (tester) async {
    var clicks = 0, doubleClicks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: DesktopPointerLayer(
          onClick: () => clicks++,
          onDoubleClick: () => doubleClicks++,
          child: const SizedBox.expand(),
        ),
      ),
    );
    const center = Offset(400, 300);
    await tester.tapAt(center, kind: PointerDeviceKind.mouse);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    expect((clicks, doubleClicks), (1, 0));

    await tester.tapAt(center, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(center, kind: PointerDeviceKind.mouse);
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    expect((clicks, doubleClicks), (1, 1));

    final drag = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    await drag.moveBy(const Offset(0, -200));
    await drag.up();
    await tester.pump(kDoubleTapTimeout + const Duration(milliseconds: 50));
    expect((clicks, doubleClicks), (1, 1));
  });

  testWidgets('progress updates do not rebuild the play button', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    var builds = 0;
    await tester.pumpWidget(
      _app(
        PlayerValueSelector<bool>(
          controller: controller,
          selector: (value) => value.isPlaying,
          builder: (context, playing) {
            builds++;
            return Text(playing ? 'Pause' : 'Play');
          },
        ),
      ),
    );
    for (var second = 1; second <= 5; second++) {
      controller.value = controller.value.copyWith(
        position: Duration(minutes: 10, seconds: second),
      );
      await tester.pump();
    }
    expect(builds, 1);

    controller.value = controller.value.copyWith(isPlaying: false);
    await tester.pump();
    expect(builds, 2);
    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets('scrubbing seeks to the dragged position and shows the time', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    Duration? seeked;
    final scrubbing = <bool>[];
    await tester.pumpWidget(
      _app(
        Center(
          child: SizedBox(
            width: 400,
            child: PlayerProgressBar(
              controller: controller,
              onSeek: (target) => seeked = target,
              onScrubChanged: scrubbing.add,
            ),
          ),
        ),
      ),
    );
    final bar = tester.getRect(find.byType(PlayerProgressBar));
    final gesture = await tester.startGesture(
      bar.centerLeft + const Offset(40, 0),
    );
    await gesture.moveBy(const Offset(60, 0));
    await gesture.moveBy(const Offset(100, 0));
    await tester.pump();
    // Halfway along a 100 minute video.
    expect(find.text('50:00'), findsOneWidget);
    await gesture.up();
    await tester.pump();

    expect(seeked, const Duration(minutes: 50));
    expect(scrubbing, [true, false]);
    expect(find.text('50:00'), findsNothing);
  });

  testWidgets('a mouse over the bar shows where a click would seek', (
    tester,
  ) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    final seeks = <Duration>[];
    await tester.pumpWidget(
      _app(
        Center(
          child: SizedBox(
            width: 400,
            child: PlayerProgressBar(controller: controller, onSeek: seeks.add),
          ),
        ),
      ),
    );
    final bar = tester.getRect(find.byType(PlayerProgressBar));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: bar.centerLeft - const Offset(20, 0));
    await mouse.moveTo(bar.centerLeft + const Offset(100, 0));
    await tester.pump();
    // A quarter of a 100 minute video; hovering does not seek.
    expect(find.text('25:00'), findsOneWidget);
    expect(seeks, isEmpty);
    await mouse.moveTo(bar.centerLeft - const Offset(20, 0));
    await tester.pump();
    expect(find.text('25:00'), findsNothing);
  });

  testWidgets('overlay controls call through and hide unused actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _controller();
    addTearDown(controller.dispose);
    var toggles = 0;
    final seeks = <Duration>[];
    await tester.pumpWidget(
      _app(
        PlayerControlsOverlay(
          controller: controller,
          title: 'The Show',
          subtitle: 'Season 2 · Episode 3',
          sourceLabel: '1080p · Provider',
          subtitleEnabled: false,
          showAudio: false,
          showSources: true,
          landscapeLocked: true,
          onBack: () {},
          onTogglePlay: () => toggles++,
          onSeekBy: seeks.add,
          onSeekTo: (_) {},
          onScrubChanged: (_) {},
          onSubtitles: () {},
          onAudio: () {},
          onSources: () {},
          onSettings: () {},
          onPip: () {},
          onRotate: () {},
        ),
      ),
    );

    expect(find.text('The Show'), findsOneWidget);
    expect(find.text('Season 2 · Episode 3'), findsOneWidget);
    expect(find.text('1080p · Provider'), findsOneWidget);
    expect(find.bySemanticsLabel('Choose audio track'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Pause'));
    await tester.tap(find.bySemanticsLabel('Forward 10 seconds'));
    await tester.tap(find.bySemanticsLabel('Back 10 seconds'));
    expect(toggles, 1);
    expect(seeks, [const Duration(seconds: 10), const Duration(seconds: -10)]);

    // A finished video offers Replay instead of Play.
    controller.value = controller.value.copyWith(
      isPlaying: false,
      isCompleted: true,
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Replay'), findsOneWidget);
  });

  testWidgets('double-tap feedback accumulates and then fades', (tester) async {
    final flashes = ValueNotifier<SeekFlash?>(null);
    addTearDown(flashes.dispose);
    await tester.pumpWidget(_app(PlayerSeekFeedback(flashes: flashes)));

    flashes.value = const SeekFlash(forward: true, seconds: 10, id: 1);
    await tester.pump();
    expect(find.text('10 seconds'), findsOneWidget);
    flashes.value = const SeekFlash(forward: true, seconds: 20, id: 2);
    await tester.pump();
    expect(find.text('20 seconds'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump(const Duration(milliseconds: 200));
    final opacity = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(opacity.opacity, 0);
  });

  testWidgets('short buffering does not flash the spinner', (tester) async {
    final controller = _controller();
    addTearDown(controller.dispose);
    final controlsVisible = ValueNotifier(false);
    addTearDown(controlsVisible.dispose);
    await tester.pumpWidget(
      _app(
        PlayerBufferingIndicator(
          controller: controller,
          controlsVisible: controlsVisible,
        ),
      ),
    );
    double opacity() =>
        tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity;

    controller.value = controller.value.copyWith(isBuffering: true);
    await tester.pump(const Duration(milliseconds: 200));
    controller.value = controller.value.copyWith(isBuffering: false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(opacity(), 0);

    controller.value = controller.value.copyWith(isBuffering: true);
    await tester.pump(const Duration(milliseconds: 500));
    expect(opacity(), 1);

    // The play button shows its own ring while controls are visible.
    controlsVisible.value = true;
    await tester.pump();
    expect(opacity(), 0);
  });

  testWidgets('single taps are immediate when double-tap seek is off', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        GestureTouchLayer(onTap: () => taps++, child: const SizedBox.expand()),
      ),
    );
    await tester.tap(find.byType(GestureTouchLayer));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('double tap reports the tapped side', (tester) async {
    final sides = <bool>[];
    var taps = 0;
    await tester.pumpWidget(
      _app(
        GestureTouchLayer(
          onTap: () => taps++,
          onDoubleTap: sides.add,
          child: const SizedBox.expand(),
        ),
      ),
    );
    final size = tester.getSize(find.byType(GestureTouchLayer));
    final right = Offset(size.width * .8, size.height / 2);
    await tester.tapAt(right);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(right);
    await tester.pumpAndSettle();
    expect(sides, [true]);
    expect(taps, 0);
  });

  testWidgets('the source sheet takes sources found while it is open', (
    tester,
  ) async {
    // Providers finish at different times: PlayIMDB and Torrentio in about a
    // second, others after several. The sheet opens with what has arrived.
    const fast = StreamSource(
      name: 'Fast',
      url: 'https://a.example/1.m3u8',
      providerName: 'PlayIMDB',
    );
    const slow = StreamSource(
      name: 'Slow',
      url: 'https://b.example/2.mp4',
      providerName: 'MoviesDrive',
    );
    final updates = StreamController<StreamSource>();
    final finished = Completer<void>();
    await tester.pumpWidget(
      _app(
        StreamSelectorSheet(
          streams: const [fast],
          selected: fast,
          updates: updates.stream,
          finished: finished.future,
        ),
      ),
    );
    expect(find.textContaining('PlayIMDB'), findsOneWidget);
    expect(find.textContaining('MoviesDrive'), findsNothing);
    expect(find.text('Still searching providers…'), findsOneWidget);

    updates
      ..add(slow)
      ..add(fast); // A repeat is not listed twice.
    await tester.pump();
    expect(find.textContaining('MoviesDrive'), findsOneWidget);
    expect(find.textContaining('PlayIMDB'), findsOneWidget);
    // Added after the first, so a focused row never moves.
    expect(
      tester.getTopLeft(find.textContaining('MoviesDrive')).dy,
      greaterThan(tester.getTopLeft(find.textContaining('PlayIMDB')).dy),
    );

    finished.complete();
    await updates.close();
    await tester.pump();
    expect(find.text('Still searching providers…'), findsNothing);
  });

  test('source quality comes from the quality field or the name', () {
    expect(
      StreamSelectorSheet.qualityOf(
        const StreamSource(name: 'x', url: 'u', quality: '720p'),
      ),
      '720p',
    );
    expect(
      StreamSelectorSheet.qualityOf(
        const StreamSource(name: 'Movie 1080p WEB', url: 'u'),
      ),
      '1080p',
    );
    expect(
      StreamSelectorSheet.qualityOf(
        const StreamSource(name: 'Movie 4K HDR', url: 'u'),
      ),
      '4K',
    );
    expect(
      StreamSelectorSheet.qualityOf(
        const StreamSource(name: 'Server 2', url: 'u'),
      ),
      '',
    );
  });

  group('marquee title', () {
    Future<void> pumpMarquee(
      WidgetTester tester,
      String text, {
      bool tickers = true,
      bool reduceMotion = false,
    }) => tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: _app(
          TickerMode(
            enabled: tickers,
            child: Center(
              child: SizedBox(width: 120, child: PlayerMarqueeText(text)),
            ),
          ),
        ),
      ),
    );

    double offset(WidgetTester tester) {
      final transforms = find.descendant(
        of: find.byType(PlayerMarqueeText),
        matching: find.byType(Transform),
      );
      if (transforms.evaluate().isEmpty) return 0;
      return tester
          .widget<Transform>(transforms.first)
          .transform
          .getTranslation()
          .x;
    }

    const long =
        'A very long series title that cannot possibly fit on one line';

    testWidgets('text that fits does not animate', (tester) async {
      await pumpMarquee(tester, 'Short');
      await tester.pump(const Duration(seconds: 3));
      expect(offset(tester), 0);
    });

    testWidgets('overflowing text scrolls after a pause', (tester) async {
      await pumpMarquee(tester, long);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1000));
      expect(offset(tester), 0);
      await tester.pump(const Duration(seconds: 3));
      expect(offset(tester), lessThan(0));
    });

    testWidgets('does not move while its tickers are muted', (tester) async {
      await pumpMarquee(tester, long, tickers: false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      expect(offset(tester), 0);
    });

    testWidgets('respects reduce motion', (tester) async {
      await pumpMarquee(tester, long, reduceMotion: true);
      await tester.pump(const Duration(seconds: 4));
      expect(
        find.descendant(
          of: find.byType(PlayerMarqueeText),
          matching: find.byType(Transform),
        ),
        findsNothing,
      );
      expect(
        tester.widget<Text>(find.text(long)).overflow,
        TextOverflow.ellipsis,
      );
    });
  });

  testWidgets('the speed pill resets playback speed', (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _controller();
    addTearDown(controller.dispose);
    controller.value = controller.value.copyWith(playbackSpeed: 1.5);
    var resets = 0;
    await tester.pumpWidget(
      _app(
        PlayerControlsOverlay(
          controller: controller,
          title: 'Title',
          subtitle: '',
          sourceLabel: '',
          subtitleEnabled: false,
          showAudio: false,
          showSources: false,
          landscapeLocked: false,
          onBack: () {},
          onTogglePlay: () {},
          onSeekBy: (_) {},
          onSeekTo: (_) {},
          onScrubChanged: (_) {},
          onSubtitles: () {},
          onAudio: () {},
          onSources: () {},
          onSettings: () {},
          onPip: () {},
          onRotate: () {},
          onSpeedReset: () => resets++,
        ),
      ),
    );
    expect(find.text('1.5×'), findsOneWidget);
    await tester.tap(find.text('1.5×'));
    expect(resets, 1);

    controller.value = controller.value.copyWith(playbackSpeed: 1);
    await tester.pump();
    expect(find.text('1.5×'), findsNothing);
  });

  testWidgets('the next-episode card names the episode', (tester) async {
    await tester.pumpWidget(
      _app(
        Center(
          child: NextEpisodeCard(
            seriesName: 'The Show',
            nextLabel: 'S2 · E4 · The Crossing',
            countdown: 8,
            onPlay: () {},
            onDismiss: () {},
          ),
        ),
      ),
    );
    expect(find.text('S2 · E4 · The Crossing'), findsOneWidget);
    expect(find.text('NEXT EPISODE IN 8'), findsOneWidget);
  });

  testWidgets('lock overlay blocks player touches until unlocked', (
    tester,
  ) async {
    var taps = 0, doubleTaps = 0, swipes = 0, holds = 0;
    var reveals = 0, unlocks = 0;
    final unlockVisible = ValueNotifier(false);
    addTearDown(unlockVisible.dispose);
    await tester.pumpWidget(
      _app(
        Stack(
          fit: StackFit.expand,
          children: [
            GestureTouchLayer(
              onTap: () => taps++,
              onDoubleTap: (_) => doubleTaps++,
              onSwipe: (_, _) => swipes++,
              onLongPressStart: () => holds++,
              child: const SizedBox.expand(),
            ),
            PlayerLockOverlay(
              unlockVisible: unlockVisible,
              onReveal: () {
                reveals++;
                unlockVisible.value = true;
              },
              onUnlock: () => unlocks++,
            ),
          ],
        ),
      ),
    );

    // The hidden unlock button cannot be hit by accident.
    expect(find.bySemanticsLabel('Unlock controls'), findsNothing);
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 400));
    expect(unlocks, 0);
    expect(reveals, 1);

    await tester.tapAt(const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(100, 100));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.drag(find.byType(PlayerLockOverlay), const Offset(0, -200));
    await tester.longPressAt(const Offset(100, 100));
    await tester.pumpAndSettle();
    expect([taps, doubleTaps, swipes, holds], [0, 0, 0, 0]);

    expect(find.bySemanticsLabel('Unlock controls'), findsOneWidget);
    await tester.tap(find.text('Tap to unlock'));
    expect(unlocks, 1);
  });

  group('desktop lock: keyboard and controller', () {
    late List<LogicalKeyboardKey> reachedPlayer;
    late int reveals, unlocks;
    late ValueNotifier<bool> unlockVisible;

    /// The player's shortcuts beneath the lock, as on Windows: a Focus that
    /// records every key that gets past the overlay.
    Future<void> pumpLocked(WidgetTester tester, {bool desktop = true}) async {
      reachedPlayer = [];
      reveals = 0;
      unlocks = 0;
      unlockVisible = ValueNotifier(false);
      addTearDown(unlockVisible.dispose);
      await tester.pumpWidget(
        _app(
          Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent) reachedPlayer.add(event.logicalKey);
              return KeyEventResult.handled;
            },
            child: PlayerLockOverlay(
              unlockVisible: unlockVisible,
              onReveal: () {
                reveals++;
                unlockVisible.value = true;
              },
              onUnlock: () => unlocks++,
              handleKeys: desktop,
              hint: desktop
                  ? 'Click or press Enter to unlock'
                  : 'Tap to unlock',
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('playback keys never reach the player', (tester) async {
      await pumpLocked(tester);
      for (final key in [
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.keyM,
        LogicalKeyboardKey.mediaPlayPause,
        LogicalKeyboardKey.mediaTrackNext,
        LogicalKeyboardKey.tab,
      ]) {
        await tester.sendKeyEvent(key);
      }
      expect(reachedPlayer, isEmpty);
      // They only show the unlock button; Space never unlocks.
      expect(reveals, greaterThan(0));
      expect(unlocks, 0);
    });

    testWidgets('Enter unlocks only once the button shows', (tester) async {
      await pumpLocked(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect((reveals, unlocks), (1, 0));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(unlocks, 1);
      expect(reachedPlayer, isEmpty);
    });

    testWidgets('fullscreen, Back and system keys pass through', (
      tester,
    ) async {
      await pumpLocked(tester);
      for (final key in [
        LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.f11,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.backspace,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f4);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      expect(reachedPlayer, [
        LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.f11,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.backspace,
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.f4,
      ]);
      expect(unlocks, 0);
    });

    testWidgets('a controller reveals, then unlocks with A', (tester) async {
      await pumpLocked(tester);
      final focused = FocusManager.instance.primaryFocus!.context!;
      // As DesktopGamepad sends them to the focused widget.
      Actions.invoke(
        focused,
        const DirectionalFocusIntent(TraversalDirection.right),
      );
      expect((reveals, unlocks), (1, 0));
      Actions.invoke(focused, const ActivateIntent());
      expect(unlocks, 1);
    });

    testWidgets('the phone lock leaves the keyboard alone', (tester) async {
      await pumpLocked(tester, desktop: false);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(reachedPlayer, [LogicalKeyboardKey.space]);
      expect(find.text('Tap to unlock'), findsOneWidget);
    });
  });

  testWidgets('lock button shows only when the player offers it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = _controller();
    addTearDown(controller.dispose);
    var locks = 0;
    Widget overlay({VoidCallback? onLock}) => _app(
      PlayerControlsOverlay(
        controller: controller,
        title: 'Title',
        subtitle: '',
        sourceLabel: '',
        subtitleEnabled: false,
        showAudio: false,
        showSources: false,
        landscapeLocked: false,
        onBack: () {},
        onTogglePlay: () {},
        onSeekBy: (_) {},
        onSeekTo: (_) {},
        onScrubChanged: (_) {},
        onSubtitles: () {},
        onAudio: () {},
        onSources: () {},
        onSettings: () {},
        onPip: () {},
        onRotate: () {},
        onLock: onLock,
      ),
    );

    await tester.pumpWidget(overlay());
    expect(find.bySemanticsLabel('Lock controls'), findsNothing);

    await tester.pumpWidget(overlay(onLock: () => locks++));
    await tester.tap(find.bySemanticsLabel('Lock controls'));
    expect(locks, 1);
  });
}
