// The golden laurel of Sovereign Edition, the Founder's own profile card
// (FounderPerk.founderProfileCard): the branch geometry, the engraved seal the
// card's background carries, and the "Sovereign Edition" designation by the
// name. All drawn in code and painted once; nothing here moves. The leaves
// follow the Sovereign avatar frame's laurel (avatar_frame.dart), so the card
// and the frame read as one collection.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/design_tokens.dart';
import '../theme/profile_styles.dart';

/// One laurel branch along an arc of [radius] round [center], from [from] to
/// [to] degrees (clockwise, 0 to the right); the tip is at [to]. [leaf] is
/// the length of the outer leaves, which shorten toward the tip.
({Path stem, Path leaves}) laurelBranch({
  required Offset center,
  required double radius,
  required double from,
  required double to,
  required double leaf,
  int pairs = 6,
}) {
  Offset on(double degrees) =>
      center +
      Offset(
            math.cos(degrees * math.pi / 180),
            math.sin(degrees * math.pi / 180),
          ) *
          radius;
  final sign = (to - from).sign;
  final stem = Path()..moveTo(on(from).dx, on(from).dy);
  for (var i = 1; i <= 24; i++) {
    final point = on(from + (to - from) * i / 24);
    stem.lineTo(point.dx, point.dy);
  }
  final leaves = Path();
  for (var i = 0; i < pairs; i++) {
    final t = (i + .5) / pairs;
    final at = from + (to - from) * t;
    final forward = at * math.pi / 180 + sign * math.pi / 2;
    final grow = 1 - t * .35;
    // Outward, then inward and shorter, both leaning toward the tip.
    leaves
      ..addPath(
        _leaf(on(at), forward - sign * .62, leaf * grow, leaf * .3 * grow),
        Offset.zero,
      )
      ..addPath(
        _leaf(on(at), forward + sign * .5, leaf * .66 * grow, leaf * .2 * grow),
        Offset.zero,
      );
  }
  leaves.addPath(
    _leaf(
      on(to),
      to * math.pi / 180 + sign * math.pi / 2,
      leaf * .7,
      leaf * .21,
    ),
    Offset.zero,
  );
  return (stem: stem, leaves: leaves);
}

/// A pointed oval from [base] along [direction] (radians).
Path _leaf(Offset base, double direction, double length, double width) {
  final d = Offset(math.cos(direction), math.sin(direction));
  final n = Offset(-d.dy, d.dx);
  final mid = base + d * (length / 2);
  final tip = base + d * length;
  return Path()
    ..moveTo(base.dx, base.dy)
    ..quadraticBezierTo(
      (mid + n * width).dx,
      (mid + n * width).dy,
      tip.dx,
      tip.dy,
    )
    ..quadraticBezierTo(
      (mid - n * width).dx,
      (mid - n * width).dy,
      base.dx,
      base.dy,
    )
    ..close();
}

/// The engraved seal on the card's background: an open laurel wreath, tied
/// at the foot, in faint champagne, as if pressed into the card.
void paintSovereignSeal(Canvas canvas, Offset center, double radius) {
  final ink = SovereignColors.champagne.withValues(alpha: .075);
  final leaf = radius * .3;
  final stemWidth = math.max(1.0, radius * .018);
  for (final (from, to) in [(104.0, 252.0), (76.0, -72.0)]) {
    final branch = laurelBranch(
      center: center,
      radius: radius,
      from: from,
      to: to,
      leaf: leaf,
      pairs: 8,
    );
    canvas
      ..drawPath(
        branch.stem,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stemWidth
          ..strokeCap = StrokeCap.round
          ..color = ink,
      )
      ..drawPath(branch.leaves, Paint()..color = ink);
  }
  // A fine inner ring, as an engraver's guide line.
  canvas.drawCircle(
    center,
    radius * .78,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(.8, radius * .008)
      ..color = SovereignColors.champagne.withValues(alpha: .05),
  );
}

/// "Sovereign Edition" between two laurel sprigs, in champagne gold: the
/// card's designation, set above the name. Quiet beside the name, which
/// stays the card's first line to read.
class SovereignEditionMark extends StatelessWidget {
  const SovereignEditionMark({super.key, this.tv = false});

  final bool tv;

  static const label = 'SOVEREIGN EDITION';

  @override
  Widget build(BuildContext context) {
    final height = tv ? 26.0 : 20.0;
    final sprig = Size(height * .62, height);
    return Semantics(
      label: 'Sovereign Edition',
      excludeSemantics: true,
      child: RepaintBoundary(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(size: sprig, painter: const _SprigPainter(left: true)),
            const SizedBox(width: AppSpace.xs),
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                color: SovereignColors.champagne,
                fontSize: tv ? AppTextSize.label : 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: tv ? 3.2 : 2.6,
                height: 1,
              ),
            ),
            const SizedBox(width: AppSpace.xs),
            CustomPaint(size: sprig, painter: const _SprigPainter(left: false)),
          ],
        ),
      ),
    );
  }
}

/// One sprig: a short laurel branch curving up beside the words, its tip at
/// the top, the left one mirroring the right.
class _SprigPainter extends CustomPainter {
  const _SprigPainter({required this.left});

  final bool left;

  @override
  void paint(Canvas canvas, Size size) {
    // The arc of a circle whose near side is the sprig's outer edge.
    final radius = size.height * .56;
    final center = Offset(
      left ? radius + size.width * .08 : size.width - radius - size.width * .08,
      size.height / 2,
    );
    final branch = laurelBranch(
      center: center,
      radius: radius,
      from: left ? 128 : 52,
      to: left ? 226 : -46,
      leaf: size.height * .3,
      pairs: 3,
    );
    final metal = SovereignColors.metal.createShader(Offset.zero & size);
    canvas
      ..drawPath(
        branch.stem,
        Paint()
          ..isAntiAlias = true
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(.9, size.height * .045)
          ..strokeCap = StrokeCap.round
          ..shader = metal,
      )
      ..drawPath(
        branch.leaves,
        Paint()
          ..isAntiAlias = true
          ..shader = metal,
      );
  }

  @override
  bool shouldRepaint(_SprigPainter old) => old.left != left;
}
