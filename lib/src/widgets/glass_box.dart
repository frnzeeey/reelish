import 'package:flutter/material.dart';

import 'liquid_glass.dart';

/// Lightweight glass panel for content in scrolling pages and dialogs.
///
/// Uses the painted [LiquidGlassQuality.low] material, with no backdrop
/// blur, and presses in when [onTap] is set.
class GlassBox extends StatelessWidget {
  const GlassBox({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(14),
    this.radius = 20,
    this.onTap,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => ReelishGlassCard(
    padding: padding,
    borderRadius: radius,
    onTap: onTap,
    child: child,
  );
}
