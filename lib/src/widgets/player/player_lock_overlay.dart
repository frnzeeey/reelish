import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'player_controls.dart';

/// Covers the whole player while controls are locked. It takes every touch,
/// so nothing beneath it (gestures, controls, the pause screen, the next
/// episode card) reacts; a tap only reveals the unlock button, and only that
/// button unlocks. Playback underneath is untouched.
///
/// With [handleKeys] (desktop), it also holds focus and takes the keyboard
/// and a game controller the same way: no key reaches the player's
/// shortcuts. Any key or controller press reveals the unlock button, and
/// Enter (or the controller's A) while it shows unlocks, so one stray key
/// never does. Space never unlocks. Fullscreen (F, F11), Escape and
/// Backspace pass through to their usual handling, where Back while locked
/// shows the unlock button instead of leaving; so do system key
/// combinations.
class PlayerLockOverlay extends StatefulWidget {
  const PlayerLockOverlay({
    super.key,
    required this.unlockVisible,
    required this.onReveal,
    required this.onUnlock,
    this.hint = 'Tap to unlock',
    this.handleKeys = false,
  });

  /// Whether the unlock button is showing; it hides again after a moment.
  final ValueListenable<bool> unlockVisible;
  final VoidCallback onReveal;
  final VoidCallback onUnlock;

  /// The unlock button's text.
  final String hint;

  /// Whether the keyboard and a game controller are locked too (desktop).
  final bool handleKeys;

  /// Keys that still do what they do elsewhere while locked: fullscreen and
  /// Back (which, on a locked player, shows the unlock button), and the
  /// system's own volume keys.
  static final _passThrough = {
    LogicalKeyboardKey.f11,
    LogicalKeyboardKey.keyF,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.backspace,
    LogicalKeyboardKey.audioVolumeUp,
    LogicalKeyboardKey.audioVolumeDown,
    LogicalKeyboardKey.audioVolumeMute,
  };

  static final _unlockKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.gameButtonA,
  };

  static final _modifiers = {
    ...LogicalKeyboardKey.expandSynonyms({
      LogicalKeyboardKey.shift,
      LogicalKeyboardKey.control,
      LogicalKeyboardKey.alt,
      LogicalKeyboardKey.meta,
    }),
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.meta,
  };

  @override
  State<PlayerLockOverlay> createState() => _PlayerLockOverlayState();
}

class _PlayerLockOverlayState extends State<PlayerLockOverlay> {
  final _focus = FocusNode(debugLabel: 'Player lock');

  @override
  void initState() {
    super.initState();
    if (widget.handleKeys) {
      // Locking hides the control that had focus; take it so keys come here.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// Enter or the controller's A: unlocks once the button shows, otherwise
  /// shows it.
  void _activate() {
    if (widget.unlockVisible.value) {
      widget.onUnlock();
    } else {
      widget.onReveal();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (PlayerLockOverlay._passThrough.contains(key) ||
        PlayerLockOverlay._modifiers.contains(key) ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent) {
      if (PlayerLockOverlay._unlockKeys.contains(key)) {
        _activate();
      } else {
        widget.onReveal();
      }
    }
    // Repeats and releases too: nothing beneath sees the key.
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final overlay = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onReveal,
      // Claim drags and long presses too, so they cannot start anything.
      onVerticalDragStart: (_) {},
      onHorizontalDragStart: (_) {},
      onLongPress: () {},
      child: ValueListenableBuilder<bool>(
        valueListenable: widget.unlockVisible,
        builder: (context, visible, child) => IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: playerFade,
            curve: Curves.easeOutCubic,
            child: child,
          ),
        ),
        child: Center(
          child: Semantics(
            button: true,
            label: 'Unlock controls',
            excludeSemantics: true,
            child: Material(
              color: const Color(0xCC101015),
              shape: const StadiumBorder(
                side: BorderSide(color: Color(0x2EFFFFFF)),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: widget.onUnlock,
                // With keys handled above, the button needs no focus of its
                // own (Space on a focused button would unlock it).
                canRequestFocus: !widget.handleKeys,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 14,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Symbols.lock_open_rounded, size: 22),
                      const SizedBox(width: 10),
                      Text(
                        widget.hint,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (!widget.handleKeys) return overlay;
    // A game controller acts on the focused widget: A activates, the stick
    // and D-pad move focus. Here they reveal or unlock instead.
    return Actions(
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: (_) {
            widget.onReveal();
            return null;
          },
        ),
      },
      child: Focus(focusNode: _focus, onKeyEvent: _onKey, child: overlay),
    );
  }
}
