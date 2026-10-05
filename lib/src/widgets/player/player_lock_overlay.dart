import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'player_controls.dart';

/// Covers the whole player while controls are locked. It takes every touch,
/// so nothing beneath it (gestures, controls, the pause screen, the next
/// episode card) reacts; a tap only reveals the unlock button, and only that
/// button unlocks. Playback underneath is untouched.
class PlayerLockOverlay extends StatelessWidget {
  const PlayerLockOverlay({
    super.key,
    required this.unlockVisible,
    required this.onReveal,
    required this.onUnlock,
  });

  /// Whether the unlock button is showing; it hides again after a moment.
  final ValueListenable<bool> unlockVisible;
  final VoidCallback onReveal;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onReveal,
    // Claim drags and long presses too, so they cannot start anything.
    onVerticalDragStart: (_) {},
    onHorizontalDragStart: (_) {},
    onLongPress: () {},
    child: ValueListenableBuilder<bool>(
      valueListenable: unlockVisible,
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
              onTap: onUnlock,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Symbols.lock_open_rounded, size: 22),
                    SizedBox(width: 10),
                    Text(
                      'Tap to unlock',
                      style: TextStyle(fontWeight: FontWeight.w700),
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
}
