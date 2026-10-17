import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onfeed/src/platform/desktop_gamepad.dart';
import 'package:onfeed/src/desktop/desktop_shell.dart';
import 'package:onfeed/src/platform/desktop_window.dart';
import 'package:onfeed/src/screens/tv/tv_home_shell.dart' show TvDestination;
import 'package:onfeed/src/theme/glass_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _up = GamepadNavigator.dpadUp;
const _right = GamepadNavigator.dpadRight;
const _a = GamepadNavigator.buttonA;
const _b = GamepadNavigator.buttonB;

/// Sends one state report, as windows/runner/gamepad_channel.cpp does.
Future<void> _send(
  WidgetTester tester, {
  int buttons = 0,
  int lx = 0,
  int ly = 0,
}) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    DesktopGamepad.channel.name,
    const StandardMethodCodec().encodeMethodCall(
      MethodCall('state', {'buttons': buttons, 'lx': lx, 'ly': ly}),
    ),
    (_) {},
  );
  await tester.pumpAndSettle();
}

/// Presses and releases.
Future<void> _press(WidgetTester tester, int buttons) async {
  await _send(tester, buttons: buttons);
  await _send(tester);
}

final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

void main() {
  group('GamepadNavigator', () {
    testWidgets('a D-pad press moves once, then repeats while held', (
      tester,
    ) async {
      {
        final commands = <GamepadCommand>[];
        final pad = GamepadNavigator(onCommand: commands.add);
        pad.update(_right, 0, 0);
        expect(commands, [GamepadCommand.right]);

        // Still held: nothing until the repeat delay...
        await tester.pump(const Duration(milliseconds: 300));
        expect(commands, hasLength(1));
        // ...then one step every interval.
        await tester.pump(const Duration(milliseconds: 80 + 110 * 3));
        expect(commands, hasLength(4));

        pad.update(0, 0, 0);
        await tester.pump(const Duration(seconds: 2));
        expect(commands, hasLength(4));
        pad.dispose();
      }
    });

    testWidgets('A and B act once per press, however long they are held', (
      tester,
    ) async {
      {
        final commands = <GamepadCommand>[];
        final pad = GamepadNavigator(onCommand: commands.add);
        pad.update(_a, 0, 0);
        pad.update(_a, 0, 0);
        await tester.pump(const Duration(seconds: 3));
        pad.update(_a | _b, 0, 0);
        pad.update(0, 0, 0);
        pad.update(_a, 0, 0);
        expect(commands, [
          GamepadCommand.activate,
          GamepadCommand.back,
          GamepadCommand.activate,
        ]);
        pad.dispose();
      }
    });

    testWidgets(
      'the stick moves along the axis pushed furthest, with hysteresis',
      (tester) async {
        {
          final commands = <GamepadCommand>[];
          final pad = GamepadNavigator(onCommand: commands.add);
          // Inside the dead zone: nothing.
          pad.update(0, 9000, 4000);
          expect(commands, isEmpty);
          pad.update(0, 20000, -6000);
          expect(commands, [GamepadCommand.right]);
          // Easing off but above the release threshold: still held.
          pad.update(0, 13000, -6000);
          expect(commands, hasLength(1));
          pad.update(0, 3000, 0);
          // Up on the stick is positive Y.
          pad.update(0, 2000, 30000);
          pad.update(0, 0, 0);
          pad.update(0, -1000, -30000);
          expect(commands, [
            GamepadCommand.right,
            GamepadCommand.up,
            GamepadCommand.down,
          ]);
          pad.dispose();
        }
      },
    );

    test('the D-pad wins over the stick', () {
      final commands = <GamepadCommand>[];
      final pad = GamepadNavigator(onCommand: commands.add);
      pad.update(_up, 30000, 0);
      expect(commands, [GamepadCommand.up]);
      pad.dispose();
    });
  });

  _coldStartTests();

  group('DesktopGamepad', () {
    late GlobalKey<NavigatorState> navigator;
    late List<String> pressed;
    late Map<String, FocusNode> nodes;

    Future<void> pump(WidgetTester tester) async {
      navigator = GlobalKey<NavigatorState>();
      pressed = [];
      nodes = {
        for (final name in ['first', 'second', 'third']) name: FocusNode(),
      };
      addTearDown(() {
        for (final node in nodes.values) {
          node.dispose();
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => DesktopGamepad(
            navigatorKey: navigator,
            child: DesktopShortcuts(navigatorKey: navigator, child: child!),
          ),
          home: Scaffold(
            body: Row(
              children: [
                for (final name in ['first', 'second', 'third'])
                  TextButton(
                    focusNode: nodes[name],
                    onPressed: () => pressed.add(name),
                    child: Text(name),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
    }

    String? focusedButton(WidgetTester tester) {
      for (final MapEntry(:key, :value) in nodes.entries) {
        if (value.hasPrimaryFocus) return key;
      }
      return null;
    }

    testWidgets(
      'the D-pad moves focus, A activates, as the keyboard does',
      (tester) async {
        await pump(tester);
        // The first press gives focus a starting point, like an arrow key.
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(focusedButton(tester), 'first');

        await _press(tester, _right);
        expect(focusedButton(tester), 'second');
        // The stick works too.
        await _send(tester, lx: 30000);
        await _send(tester);
        expect(focusedButton(tester), 'third');
        await _press(tester, _a);
        expect(pressed, ['third']);
        // Focus rings stay visible while the controller is in use.
        expect(
          FocusManager.instance.highlightMode,
          FocusHighlightMode.traditional,
        );
      },
      variant: _windows,
    );

    testWidgets('B goes back, the same as Escape', (tester) async {
      await pump(tester);
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('details')),
      );
      await tester.pumpAndSettle();
      expect(find.text('details'), findsOneWidget);
      await _press(tester, _b);
      expect(find.text('details'), findsNothing);
      // On the first screen Back does nothing (it never closes the app).
      await _press(tester, _b);
      expect(find.text('first'), findsOneWidget);
    }, variant: _windows);

    testWidgets('stops listening when removed', (tester) async {
      await pump(tester);
      await tester.pumpWidget(const SizedBox());
      // No handler left: a late report is simply dropped.
      await _send(tester, buttons: _a);
      expect(pressed, isEmpty);
    }, variant: _windows);
  });
}

/// Controller and keyboard from a cold start in the real shell, where
/// nothing but the shell's holder has focus.
void _coldStartTests() {
  group('from a cold start in the shell', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    for (final viaPad in [true, false]) {
      testWidgets('the first ${viaPad ? 'D-pad' : 'arrow'} press lands on the '
          'sidebar, the next one in the content', (tester) async {
        tester.view.physicalSize = const Size(1400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final navigator = GlobalKey<NavigatorState>();
        final content = FocusNode();
        addTearDown(content.dispose);
        final destinations = <TvDestination>[];
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: GlassTheme.tv,
            builder: (context, child) => DesktopGamepad(
              navigatorKey: navigator,
              child: DesktopShortcuts(navigatorKey: navigator, child: child!),
            ),
            home: DesktopShell(
              destination: TvDestination.home,
              onDestinationChanged: destinations.add,
              pageBuilder: (context, _) => Center(
                child: TextButton(
                  focusNode: content,
                  onPressed: () {},
                  child: const Text('content'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        Future<void> right() async {
          if (viaPad) {
            await _press(tester, _right);
          } else {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
            await tester.pumpAndSettle();
          }
        }

        await right();
        // On the sidebar: activating it selects Home.
        expect(content.hasPrimaryFocus, isFalse);
        if (viaPad) {
          await _press(tester, _a);
        } else {
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
        }
        expect(destinations, [TvDestination.home]);

        await right();
        expect(content.hasPrimaryFocus, isTrue);
      }, variant: _windows);
    }
  });
}
