// The theme's soft light across the main pages (phone Home, the TV shell and
// the Windows shell): one glow from the upper left and a fainter answer from
// the lower right. Painted once inside a RepaintBoundary; no animation, no
// blur, no input. Classic has no ambient light, so its pages stay flat.
import 'package:flutter/material.dart';

import '../theme/glass_theme.dart';

class AmbientBackdrop extends StatelessWidget {
  const AmbientBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final light = GlassTheme.ambient;
    if (light == null) return const SizedBox.shrink();
    // Light pages need far less to show the same warmth.
    final strength = GlassTheme.surfaces.brightness == Brightness.dark
        ? 1.0
        : .55;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: _AmbientPainter(light, strength),
          ),
        ),
      ),
    );
  }
}

class _AmbientPainter extends CustomPainter {
  const _AmbientPainter(this.light, this.strength);

  final Color light;
  final double strength;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    for (final (center, radius, alpha) in [
      (const Alignment(-1, -1.1), .9, .13),
      (const Alignment(1.1, 1.05), .75, .06),
    ]) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: center,
            radius: radius,
            colors: [
              light.withValues(alpha: alpha * strength),
              light.withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(_AmbientPainter old) =>
      old.light != light || old.strength != strength;
}
