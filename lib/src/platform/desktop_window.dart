import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'device_capabilities.dart';

/// The desktop window: fullscreen through the Windows runner's
/// `reelish/window` channel. Does nothing on other platforms.
abstract final class DesktopWindow {
  static const _channel = MethodChannel('reelish/window');

  static final ValueNotifier<bool> _fullscreen = ValueNotifier(false);

  /// Whether the window covers its whole monitor.
  static ValueListenable<bool> get fullscreen => _fullscreen;

  static Future<void> setFullscreen(bool value) async {
    if (!DeviceCapabilities.isDesktopPlatform) return;
    try {
      final result = await _channel.invokeMethod<bool>('setFullscreen', value);
      _fullscreen.value = result ?? value;
    } on PlatformException {
      // Keep the current state.
    } on MissingPluginException {
      // Keep the current state.
    }
  }

  static Future<void> toggleFullscreen() => setFullscreen(!_fullscreen.value);
}

/// Desktop keys that apply on every screen: F11 toggles fullscreen; Escape
/// leaves fullscreen first, then goes back; Backspace goes back unless text
/// is being edited. Going back is [Navigator.maybePop], which runs each
/// screen's own back handling (the same path as Android's Back button), and
/// never closes the app from its first screen.
class DesktopShortcuts extends StatelessWidget {
  const DesktopShortcuts({
    super.key,
    required this.navigatorKey,
    required this.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  static bool _editingText() {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        context.findAncestorStateOfType<EditableTextState>() != null;
  }

  static final _arrows = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };

  /// When focus rests on a container (the shell holds it at startup so its
  /// shortcuts work) rather than a control, an arrow key or a controller's
  /// D-pad has nowhere to go: no control lies beside a node that covers the
  /// window. The first press then moves to the first control in order,
  /// the sidebar's first item, as on TV. Returns whether it moved focus.
  static bool focusFirstControl() {
    final node = FocusManager.instance.primaryFocus;
    if (node == null || node.traversalDescendants.isEmpty) return false;
    return node.nextFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (_arrows.contains(key) && !_editingText() && focusFirstControl()) {
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f11) {
      if (event is KeyDownEvent) DesktopWindow.toggleFullscreen();
      return KeyEventResult.handled;
    }
    final back =
        key == LogicalKeyboardKey.escape ||
        (key == LogicalKeyboardKey.backspace && !_editingText());
    if (!back || event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.escape) {
      goBack(navigatorKey);
    } else {
      navigatorKey.currentState?.maybePop();
    }
    return KeyEventResult.handled;
  }

  /// Escape's Back, also used by a controller's B button: leaves
  /// fullscreen first, otherwise goes back.
  static void goBack(GlobalKey<NavigatorState> navigatorKey) {
    if (DesktopWindow.fullscreen.value) {
      DesktopWindow.setFullscreen(false);
      return;
    }
    navigatorKey.currentState?.maybePop();
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _onKey,
    child: child,
  );
}
