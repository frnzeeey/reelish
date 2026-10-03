import 'package:flutter/material.dart';

import 'liquid_glass.dart';

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
  Widget build(BuildContext context) => LiquidGlass(
    quality: LiquidGlassQuality.low,
    opacity: .8,
    borderRadius: radius,
    padding: padding,
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    ),
  );
}
