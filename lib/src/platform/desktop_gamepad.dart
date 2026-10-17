import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'desktop_window.dart';
import 'device_capabilities.dart';

/// What a controller asks the interface to do.
enum GamepadCommand { up, down, left, right, activate, back }

/// Turns raw controller state into navigation commands: the D-pad or left
/// stick moves (once on press, then repeating while held), A activates, B
/// goes back. Buttons act once per press, so a held A never opens twice.
///
/// The state is XInput's (`XINPUT_GAMEPAD`): a button bitmask and the left
/// stick's axes from -32768 to 32767, with up positive.
class GamepadNavigator {
  GamepadNavigator({
    required this.onCommand,
    this.repeatDelay = const Duration(milliseconds: 380),
    this.repeatInterval = const Duration(milliseconds: 110),
  });

  final void Function(GamepadCommand command) onCommand;
  final Duration repeatDelay;
  final Duration repeatInterval;

  static const dpadUp = 0x0001;
  static const dpadDown = 0x0002;
  static const dpadLeft = 0x0004;
  static const dpadRight = 0x0008;
  static const start = 0x0010;
  static const buttonA = 0x1000;
  static const buttonB = 0x2000;

  /// The stick counts as pushed past this, and released below
  /// [stickRelease], so a stick resting near the edge does not flicker.
  static const stickPress = 16000;
  static const stickRelease = 11000;

  int _buttons = 0;
  GamepadCommand? _held;
  bool _stickHeld = false;
  Timer? _repeat;

  /// The latest state of every connected controller, merged.
  void update(int buttons, int stickX, int stickY) {
    final pressed = buttons & ~_buttons;
    _buttons = buttons;
    if (pressed & (buttonA | start) != 0) onCommand(GamepadCommand.activate);
    if (pressed & buttonB != 0) onCommand(GamepadCommand.back);
    _setHeld(_direction(buttons, stickX, stickY));
  }

  /// The D-pad wins over the stick; on the stick, the axis pushed further.
  GamepadCommand? _direction(int buttons, int x, int y) {
    if (buttons & dpadUp != 0) return GamepadCommand.up;
    if (buttons & dpadDown != 0) return GamepadCommand.down;
    if (buttons & dpadLeft != 0) return GamepadCommand.left;
    if (buttons & dpadRight != 0) return GamepadCommand.right;
    final threshold = _stickHeld ? stickRelease : stickPress;
    final ax = x.abs();
    final ay = y.abs();
    if (ax < threshold && ay < threshold) {
      _stickHeld = false;
      return null;
    }
    _stickHeld = true;
    if (ax >= ay) return x > 0 ? GamepadCommand.right : GamepadCommand.left;
    return y > 0 ? GamepadCommand.up : GamepadCommand.down;
  }

  void _setHeld(GamepadCommand? direction) {
    if (direction == _held) return;
    _repeat?.cancel();
    _repeat = null;
    _held = direction;
    if (direction == null) return;
    onCommand(direction);
    _repeat = Timer(repeatDelay, () {
      _repeat = Timer.periodic(repeatInterval, (_) => onCommand(direction));
    });
  }

  /// Releases everything, e.g. when Reelish loses the foreground.
  void reset() => update(0, 0, 0);

  void dispose() {
    _repeat?.cancel();
    _repeat = null;
  }
}

/// Controller navigation for the Windows interface.
///
/// The runner polls XInput controllers (Xbox and compatible pads) while
/// Reelish is the foreground window and reports state changes on the
/// `reelish/gamepad` channel (`windows/runner/gamepad_channel.cpp`). Each
/// command is sent through Flutter's own focus and action system from the
/// focused widget, exactly as the keyboard does:
///
/// * directions: [DirectionalFocusIntent], like the arrow keys;
/// * A (or Start): [ActivateIntent], like Enter;
/// * B: the same Back as Escape ([DesktopShortcuts.goBack]).
///
/// So rows scroll the focused card into view, details pages restore focus
/// when closed, and no screen needs controller-specific code. While the
/// controller is in use focus rings stay visible; the next mouse or touch
/// input returns Flutter to its usual highlight mode.
class DesktopGamepad extends StatefulWidget {
  const DesktopGamepad({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  static const channel = MethodChannel('reelish/gamepad');

  @override
  State<DesktopGamepad> createState() => _DesktopGamepadState();
}

class _DesktopGamepadState extends State<DesktopGamepad> {
  late final _navigator = GamepadNavigator(onCommand: _onCommand);

  @override
  void initState() {
    super.initState();
    if (!DeviceCapabilities.isDesktopPlatform) return;
    DesktopGamepad.channel.setMethodCallHandler(_onCall);
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  @override
  void dispose() {
    if (DeviceCapabilities.isDesktopPlatform) {
      DesktopGamepad.channel.setMethodCallHandler(null);
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
      _useControllerHighlights(false);
    }
    _navigator.dispose();
    super.dispose();
  }

  Future<void> _onCall(MethodCall call) async {
    if (call.method != 'state') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    int read(String key) => (arguments[key] as num?)?.toInt() ?? 0;
    _navigator.update(read('buttons'), read('lx'), read('ly'));
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent) _useControllerHighlights(false);
  }

  bool _controllerHighlights = false;

  void _useControllerHighlights(bool value) {
    if (value == _controllerHighlights) return;
    _controllerHighlights = value;
    FocusManager.instance.highlightStrategy = value
        ? FocusHighlightStrategy.alwaysTraditional
        : FocusHighlightStrategy.automatic;
  }

  void _onCommand(GamepadCommand command) {
    _useControllerHighlights(true);
    if (command == GamepadCommand.back) {
      DesktopShortcuts.goBack(widget.navigatorKey);
      return;
    }
    final direction = command != GamepadCommand.activate;
    if (direction && DesktopShortcuts.focusFirstControl()) return;
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null || !context.mounted) return;
    final Intent intent = switch (command) {
      GamepadCommand.up => const DirectionalFocusIntent(TraversalDirection.up),
      GamepadCommand.down => const DirectionalFocusIntent(
        TraversalDirection.down,
      ),
      GamepadCommand.left => const DirectionalFocusIntent(
        TraversalDirection.left,
      ),
      GamepadCommand.right => const DirectionalFocusIntent(
        TraversalDirection.right,
      ),
      _ => const ActivateIntent(),
    };
    Actions.maybeInvoke(context, intent);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
