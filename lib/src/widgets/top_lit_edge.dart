// A rounded hairline edge lit from above, for artwork tiles that would
// otherwise sit flat on the dark page.
import 'package:flutter/widgets.dart';

/// A rounded hairline that is brightest along the top edge and fades down
/// the sides, as if lit from above. Use it as a `foregroundDecoration` over
/// a poster or icon clipped to the same [radius].
class TopLitEdge extends Decoration {
  const TopLitEdge({
    required this.radius,
    this.top = .22,
    this.bottom = .05,
    this.width = 1,
  });

  final double radius;

  /// White opacity of the edge at the top and at the bottom.
  final double top;
  final double bottom;

  /// Stroke width in logical pixels.
  final double width;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _TopLitPainter(this);
}

class _TopLitPainter extends BoxPainter {
  _TopLitPainter(this.edge);

  final TopLitEdge edge;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final rect = offset & size;
    final inset = edge.width / 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = edge.width
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color.fromRGBO(255, 255, 255, edge.top),
          Color.fromRGBO(255, 255, 255, edge.bottom),
        ],
        stops: const [0, .45],
      ).createShader(rect);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.deflate(inset),
        Radius.circular(edge.radius - inset),
      ),
      paint,
    );
  }
}
