// The Skip intro / Skip outro button the player shows while a segment from
// IntroDB plays. Shared by phone, TV and Windows: a tap, a click, Select on
// a focused button, or Select on the remote while the controls are hidden
// (handled by the player) all skip.

import 'package:flutter/material.dart';

import '../../intro_skip/skip_segments.dart';
import '../../theme/design_tokens.dart';
import '../../theme/glass_theme.dart';
import '../../theme/reelish_icons.dart';

class SkipSegmentButton extends StatelessWidget {
  const SkipSegmentButton({
    super.key,
    required this.segment,
    required this.onSkip,
    this.large = false,
  });

  /// The segment playing now; null hides the button.
  final SkipSegment? segment;
  final ValueChanged<SkipSegment> onSkip;

  /// TV: larger, to be read from across the room.
  final bool large;

  static String labelFor(SkipKind kind) =>
      kind == SkipKind.intro ? 'Skip intro' : 'Skip outro';

  @override
  Widget build(BuildContext context) {
    final segment = this.segment;
    final duration = AppMotion.resolve(context, AppMotion.standard);
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(.08, 0),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: segment == null
          ? const SizedBox.shrink(key: ValueKey('none'))
          : OutlinedButton.icon(
              key: ValueKey(segment.kind),
              onPressed: () => onSkip(segment),
              icon: Icon(ReelishIcons.skipIntro, size: large ? 24 : 20),
              label: Text(labelFor(segment.kind)),
              style:
                  OutlinedButton.styleFrom(
                    minimumSize: Size(0, large ? 56 : 46),
                    padding: EdgeInsets.symmetric(horizontal: large ? 26 : 20),
                    shape: const StadiumBorder(),
                    // The player's chrome stays dark in every theme.
                    backgroundColor: const Color(0xE6141419),
                    foregroundColor: Colors.white,
                    side: BorderSide(
                      color: GlassTheme.playerPrimary.withValues(alpha: .7),
                      width: 1.5,
                    ),
                    textStyle: TextStyle(
                      fontFamily: GlassTheme.fontFamily,
                      fontWeight: FontWeight.w700,
                      fontSize: large ? 18 : 15,
                    ),
                  ).copyWith(
                    // Focus (remote, keyboard) fills it with the accent.
                    backgroundColor: WidgetStateProperty.resolveWith(
                      (states) => states.contains(WidgetState.focused)
                          ? GlassTheme.playerPrimary
                          : const Color(0xE6141419),
                    ),
                  ),
            ),
    );
  }
}
