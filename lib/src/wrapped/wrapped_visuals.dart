// Reelish Wrapped's own look, shared by the story slides and the share
// cards so a card reads as Reelish before its logo does: the Reel (a lit
// ring of film sprockets around the year's big number), light leaks of the
// slide's palette on a near-black stage, and Montserrat at display sizes.
// Always dark, in every app theme, like the player; the colours are
// Wrapped's own, starting from Reelish coral, not the viewer's accent, so
// every card is recognisably the same brand. All painted in code.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The two lights of a slide or card over the stage.
class WrappedPalette {
  const WrappedPalette(this.a, this.b);

  final Color a;
  final Color b;

  static const stage = Color(0xFF0B0A10);

  /// Reelish coral.
  static const coral = Color(0xFFFF4D6D);

  static const premiere = WrappedPalette(coral, Color(0xFFFFB347));
  static const movies = WrappedPalette(Color(0xFFFFB347), Color(0xFFFF4D6D));
  static const hours = WrappedPalette(Color(0xFF8B5CFF), coral);
  static const genres = WrappedPalette(Color(0xFF22C3B5), Color(0xFF4D7CFF));
  static const actors = WrappedPalette(Color(0xFFFF5FA2), Color(0xFFFFC56B));
  static const series = WrappedPalette(Color(0xFF4D7CFF), Color(0xFF8B5CFF));
  static const milestones = WrappedPalette(
    Color(0xFF34D399),
    Color(0xFF22C3B5),
  );
  static const persona = WrappedPalette(Color(0xFFFFC56B), Color(0xFF8B5CFF));
  static const finale = WrappedPalette(coral, Color(0xFF8B5CFF));
}

/// The stage and its two light leaks, painted once.
class WrappedBackdrop extends StatelessWidget {
  const WrappedBackdrop({super.key, required this.palette, this.child});

  final WrappedPalette palette;
  final Widget? child;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _BackdropPainter(palette),
    isComplex: false,
    child: child ?? const SizedBox.expand(),
  );
}

class _BackdropPainter extends CustomPainter {
  const _BackdropPainter(this.palette);

  final WrappedPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = WrappedPalette.stage);
    final longest = math.max(size.width, size.height);
    void light(Alignment at, double radius, Color color) {
      final center = at.withinRect(rect);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }

    light(
      const Alignment(-1.1, -1.0),
      longest * .75,
      palette.a.withValues(alpha: .42),
    );
    light(
      const Alignment(1.15, 1.05),
      longest * .7,
      palette.b.withValues(alpha: .36),
    );
    // A faint band of light across the middle, like a projector beam.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: .035),
            Colors.white.withValues(alpha: 0),
          ],
          stops: const [.35, .5, .65],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.palette != palette;
}

/// The Reel: a ring of light with film sprockets around [child], Wrapped's
/// signature. [turns] spins the sprockets (0–1); still when not animated.
class WrappedReel extends StatelessWidget {
  const WrappedReel({
    super.key,
    required this.size,
    required this.palette,
    required this.child,
    this.turns = 0,
  });

  final double size;
  final WrappedPalette palette;
  final Widget child;
  final double turns;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _ReelPainter(palette, turns),
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(size * .16),
          child: FittedBox(child: child),
        ),
      ),
    ),
  );
}

class _ReelPainter extends CustomPainter {
  const _ReelPainter(this.palette, this.turns);

  final WrappedPalette palette;
  final double turns;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final ring = radius * .9;
    final width = radius * .1;
    // The glow behind the ring.
    canvas.drawCircle(
      center,
      ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 2.6
        ..color = palette.a.withValues(alpha: .18)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, width * 1.4),
    );
    final sweep = SweepGradient(
      transform: GradientRotation(math.pi * 2 * turns - math.pi / 2),
      colors: [palette.a, palette.b, palette.a],
    ).createShader(Rect.fromCircle(center: center, radius: ring));
    canvas.drawCircle(
      center,
      ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = sweep,
    );
    // Sprocket holes cut into the band.
    const holes = 28;
    final hole = Paint()..color = WrappedPalette.stage.withValues(alpha: .85);
    for (var i = 0; i < holes; i++) {
      final angle = math.pi * 2 * (i / holes + turns / 4);
      final at = center + Offset(math.cos(angle), math.sin(angle)) * ring;
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(angle);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: width * .42,
            height: width * .62,
          ),
          Radius.circular(width * .12),
        ),
        hole,
      );
      canvas.restore();
    }
    // A fine inner rule.
    canvas.drawCircle(
      center,
      ring - width * 1.1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, width * .12)
        ..color = Colors.white.withValues(alpha: .14),
    );
  }

  @override
  bool shouldRepaint(_ReelPainter old) =>
      old.palette != palette || old.turns != turns;
}

/// Wrapped's type, sized from [scale] (1 on a phone-width slide).
abstract final class WrappedType {
  static TextStyle hero(double scale) => TextStyle(
    color: Colors.white,
    fontSize: 96 * scale,
    fontWeight: FontWeight.w800,
    letterSpacing: -3 * scale,
    height: .95,
  );

  static TextStyle headline(double scale) => TextStyle(
    color: Colors.white,
    fontSize: 30 * scale,
    fontWeight: FontWeight.w800,
    letterSpacing: -.6 * scale,
    height: 1.12,
  );

  static TextStyle body(double scale) => TextStyle(
    color: Colors.white.withValues(alpha: .82),
    fontSize: 16 * scale,
    fontWeight: FontWeight.w500,
    height: 1.4,
  );

  static TextStyle eyebrow(double scale, Color color) => TextStyle(
    color: color,
    fontSize: 12 * scale,
    fontWeight: FontWeight.w700,
    letterSpacing: 2.4 * scale,
  );
}

/// A poster or portrait, never stretched: cover-cropped in its own box,
/// with a quiet tile when there is no image.
class WrappedArtwork extends StatelessWidget {
  const WrappedArtwork({
    super.key,
    required this.url,
    required this.width,
    required this.aspect,
    this.circle = false,
  });

  final String url;
  final double width;

  /// Width over height: 2/3 for posters, 1 for portraits.
  final double aspect;
  final bool circle;

  @override
  Widget build(BuildContext context) {
    final tile = ColoredBox(
      color: Colors.white.withValues(alpha: .08),
      child: url.isEmpty
          ? null
          : Image.network(
              url,
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
    );
    return SizedBox(
      width: width,
      height: width / aspect,
      child: circle
          ? ClipOval(child: tile)
          : ClipRRect(
              borderRadius: BorderRadius.circular(width * .08),
              child: tile,
            ),
    );
  }
}

/// `12 Oct`, from milliseconds since the epoch, in local time.
String wrappedShortDate(int ms) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.day} ${months[d.month - 1]}';
}

/// `1,234`.
String wrappedNumber(int n) {
  final text = '$n';
  final out = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    if (i > 0 && (text.length - i) % 3 == 0) out.write(',');
    out.write(text[i]);
  }
  return out.toString();
}
