// A count of what is new, on an icon: the Together badge on the phone dock,
// the TV rail and the Windows sidebar.
import 'package:flutter/material.dart';

import '../theme/glass_theme.dart';

/// [child] with [count] on its corner, in the accent; just [child] at 0.
/// Above 99 it reads 99+.
class CountBadge extends StatelessWidget {
  const CountBadge({
    super.key,
    required this.count,
    required this.child,
    this.inverted = false,
  });

  final int count;
  final Widget child;

  /// For a badge on an accent-filled place (a focused TV rail item): the
  /// page colour with accent text, so it still shows.
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return child;
    return Badge(
      label: Text(count > 99 ? '99+' : '$count'),
      backgroundColor: inverted ? GlassTheme.background : GlassTheme.primary,
      textColor: inverted ? GlassTheme.primary : Colors.white,
      child: child,
    );
  }
}
