import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/glass_theme.dart';

enum LiquidGlassQuality { low, balanced, high }

/// A bounded, reusable glass surface.
///
/// The material is painted, not filtered: a top-lit body that darkens toward
/// the bottom, a curved specular sheen, an inner rim for thickness and a
/// directional edge stroke, all from gradients in two [CustomPainter]s with
/// no mask-filter blur or offscreen layer. That depth survives on
/// [LiquidGlassQuality.low], the lightweight fallback with no backdrop.
/// [balanced] and [high] add one clipped backdrop blur, composed with a mild
/// saturation lift so colors behind the glass diffuse through it instead of
/// turning gray. True refraction would need a fragment shader per surface,
/// so the bright inner rim stands in for light bending at the edge.
class LiquidGlass extends StatelessWidget {
  const LiquidGlass({
    super.key,
    required this.child,
    this.quality = LiquidGlassQuality.balanced,
    this.blurSigma = 10,
    this.opacity = .72,
    this.borderRadius = 20,
    this.padding = EdgeInsets.zero,
    this.tintColor = const Color(0xFF111722),
    this.accentColor,
    this.showShadow = true,
    this.showBorder = true,
    this.showTopHighlight = true,
    this.groupBackdrop = false,
    this.elevation = 1,
    this.highlightIntensity = 1,
    this.accentStrength = 0,
    this.pressDepth = 0,
  }) : assert(blurSigma >= 0),
       assert(opacity >= 0 && opacity <= 1),
       assert(elevation >= 0),
       assert(accentStrength >= 0 && accentStrength <= 1),
       assert(pressDepth >= 0 && pressDepth <= 1);

  final Widget child;
  final LiquidGlassQuality quality;
  final double blurSigma;
  final double opacity;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final Color tintColor;

  /// Color of the ambient reflection when [accentStrength] is above zero;
  /// defaults to the theme accent.
  final Color? accentColor;
  final bool showShadow;

  /// The directional edge stroke and inner rim.
  final bool showBorder;

  /// The curved specular sheen across the upper surface.
  final bool showTopHighlight;

  /// Shares one backdrop capture with other grouped glass under the nearest
  /// [BackdropGroup]. Only for surfaces that never overlap each other, such
  /// as the panels on cards in one row; without a group it has no effect.
  final bool groupBackdrop;

  /// Scales the drop shadow; 0 sits flat on the background.
  final double elevation;

  /// Scales the sheen and edge lighting.
  final double highlightIntensity;

  /// Coral ambient light for selected or emphasized glass. Neutral glass
  /// leaves it at 0.
  final double accentStrength;

  /// 0 at rest, 1 fully pressed: the surface dims its highlights, deepens
  /// its lower shade and settles closer to the background.
  final double pressDepth;

  /// Caps every surface's quality, e.g. [LiquidGlassQuality.low] to drop all
  /// backdrop blurs on a device that cannot afford them.
  static LiquidGlassQuality qualityCeiling = LiquidGlassQuality.high;

  double get _effectiveBlur {
    final effective = quality.index <= qualityCeiling.index
        ? quality
        : qualityCeiling;
    return switch (effective) {
      LiquidGlassQuality.low => 0,
      LiquidGlassQuality.balanced => blurSigma.clamp(0.0, 12.0).toDouble(),
      LiquidGlassQuality.high => blurSigma.clamp(0.0, 20.0).toDouble(),
    };
  }

  /// Raises saturation around 1.2× and lifts brightness slightly, so
  /// posters behind the glass read as diffused color.
  static const _vibrancy = ColorFilter.matrix(<double>[
    1.142, -.143, -.015, 0, 4, //
    -.043, 1.057, -.015, 0, 4, //
    -.043, -.143, 1.185, 0, 4, //
    0, 0, 0, 1, 0, //
  ]);

  @override
  Widget build(BuildContext context) {
    final blur = _effectiveBlur;
    final radius = BorderRadius.circular(borderRadius);
    final accent = accentColor ?? GlassTheme.primary;
    final lift = elevation * (1 - .45 * pressDepth);
    final light = highlightIntensity * (1 - .3 * pressDepth);

    Widget surface = CustomPaint(
      painter: LiquidGlassBodyPainter(
        radius: borderRadius,
        opacity: opacity,
        tint: tintColor,
        highlight: showTopHighlight ? light : 0,
        accent: accent,
        accentStrength: accentStrength,
        depth: 1 + .6 * pressDepth,
      ),
      foregroundPainter: showBorder
          ? LiquidGlassEdgePainter(
              radius: borderRadius,
              opacity: opacity,
              highlight: light,
              accent: accent,
              accentStrength: accentStrength,
            )
          : null,
      child: Padding(padding: padding, child: child),
    );

    if (blur > 0) {
      final filter = ImageFilter.compose(
        outer: _vibrancy,
        inner: ImageFilter.blur(
          sigmaX: blur,
          sigmaY: blur,
          tileMode: TileMode.clamp,
        ),
      );
      surface = ClipRRect(
        borderRadius: radius,
        child: groupBackdrop
            ? BackdropFilter.grouped(filter: filter, child: surface)
            : BackdropFilter(filter: filter, child: surface),
      );
    }

    if (!showShadow || lift <= 0) return surface;
    return CustomPaint(
      painter: _GlassShadowPainter(
        radius: borderRadius,
        shadows: liquidGlassShadows(opacity: opacity, elevation: lift),
      ),
      child: surface,
    );
  }
}

/// Paints shadows only outside the glass. A plain [BoxShadow] sits under the
/// whole pane and shows through it as a dark smudge on bright backgrounds;
/// cutting the pane's shape out keeps the glass clear. Same blur cost as the
/// decoration it replaces, plus one path clip.
class _GlassShadowPainter extends CustomPainter {
  const _GlassShadowPainter({required this.radius, required this.shadows});

  final double radius;
  final List<BoxShadow> shadows;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final shape = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    canvas
      ..save()
      ..clipPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(shape.outerRect.inflate(80))
          ..addRRect(shape),
      );
    for (final shadow in shadows) {
      canvas.drawRRect(
        shape.shift(shadow.offset).inflate(shadow.spreadRadius),
        shadow.toPaint(),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlassShadowPainter old) =>
      old.radius != radius || !listEquals(old.shadows, shadows);
}

/// A soft ambient shadow plus a tight contact shadow: the pair reads as
/// lift, where a single dark blur reads as a smudge.
List<BoxShadow> liquidGlassShadows({
  double opacity = 1,
  double elevation = 1,
}) => [
  BoxShadow(
    color: Colors.black.withValues(alpha: .30 * opacity * elevation),
    blurRadius: 26,
    spreadRadius: -6,
    offset: Offset(0, 14 * elevation),
  ),
  BoxShadow(
    color: Colors.black.withValues(alpha: .22 * opacity * elevation),
    blurRadius: 5,
    offset: Offset(0, 2 * elevation),
  ),
];

/// The glass body: a top-lit tint that darkens toward the bottom, a curved
/// specular sheen, and optional accent light from the lower edge.
class LiquidGlassBodyPainter extends CustomPainter {
  const LiquidGlassBodyPainter({
    required this.radius,
    required this.opacity,
    required this.tint,
    required this.highlight,
    required this.accent,
    required this.accentStrength,
    this.depth = 1,
  });

  final double radius;
  final double opacity;
  final Color tint;
  final double highlight;
  final Color accent;
  final double accentStrength;
  final double depth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final o = opacity;

    // Top-lit body: lighter where light enters, darker at the lower edge,
    // which is what makes the surface read as thick and raised.
    canvas.drawRRect(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.lerp(tint, Colors.white, .16)!.withValues(alpha: .56 * o),
            tint.withValues(alpha: .66 * o),
            Color.lerp(
              tint,
              Colors.black,
              (.32 * depth).clamp(0, 1),
            )!.withValues(alpha: (.80 * o).clamp(0, 1)),
          ],
          stops: const [0, .5, 1],
        ).createShader(rect),
    );

    if (highlight > 0) {
      // Convex sheen: falls off from the top edge toward the middle.
      canvas.drawRRect(
        shape,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.center,
            colors: [
              Colors.white.withValues(alpha: .10 * o * highlight),
              Colors.white.withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
      // Curved specular reflection near the upper-left, stretched along
      // the long side so wide surfaces get an ellipse, not a dot.
      canvas.drawRRect(
        shape,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-.55, -1.05),
            radius: .95,
            colors: [
              Colors.white.withValues(alpha: .14 * o * highlight),
              Colors.white.withValues(alpha: 0),
            ],
            transform: _StretchToAspect(size),
          ).createShader(rect),
      );
    }

    if (accentStrength > 0) {
      canvas.drawRRect(
        shape,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(.75, 1.15),
            radius: 1.1,
            colors: [
              accent.withValues(alpha: .34 * accentStrength),
              accent.withValues(alpha: 0),
            ],
            transform: _StretchToAspect(size),
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(LiquidGlassBodyPainter old) =>
      old.radius != radius ||
      old.opacity != opacity ||
      old.tint != tint ||
      old.highlight != highlight ||
      old.accent != accent ||
      old.accentStrength != accentStrength ||
      old.depth != depth;
}

/// Glass edges drawn over the content: a bright, thin outer stroke lit from
/// the upper left that fades and darkens around the corners, and a soft
/// inner rim, bright along the top and shaded along the bottom, that gives
/// the pane visible thickness and stands in for edge refraction.
class LiquidGlassEdgePainter extends CustomPainter {
  const LiquidGlassEdgePainter({
    required this.radius,
    this.opacity = 1,
    this.highlight = 1,
    this.accent = const Color(0xFFFF4D6D),
    this.accentStrength = 0,
    this.sheen = false,
  });

  final double radius;
  final double opacity;
  final double highlight;
  final Color accent;
  final double accentStrength;

  /// Adds a faint top-down sheen inside the edge, for opaque content such
  /// as posters that has no glass body of its own.
  final bool sheen;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final o = opacity;
    final h = highlight;

    if (sheen) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(radius)),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: const Alignment(0, -.3),
            colors: [
              Colors.white.withValues(alpha: .09 * o * h),
              Colors.white.withValues(alpha: 0),
            ],
          ).createShader(rect),
      );
    }

    // Inner rim: the thickness of the pane.
    final rim = RRect.fromRectAndRadius(
      rect.deflate(1.75),
      Radius.circular((radius - 1.75).clamp(0, radius)),
    );
    canvas.drawRRect(
      rim,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: .13 * o * h),
            Colors.white.withValues(alpha: .02 * o * h),
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: .16 * o),
          ],
          stops: const [0, .3, .65, 1],
        ).createShader(rect),
    );

    // Outer edge: directional, never a uniform outline. Light comes from
    // the upper left on cards; on wide surfaces the tilt flattens toward
    // vertical so the whole top edge stays lit and the bottom stays shaded.
    final tilt = (.9 * (size.height / size.width) * (size.height / size.width))
        .clamp(0.0, .9);
    final lowerEdge = accentStrength > 0
        ? Color.lerp(
            Colors.black.withValues(alpha: .24 * o),
            accent.withValues(alpha: .55 * o),
            accentStrength,
          )!
        : Colors.black.withValues(alpha: .24 * o);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        rect.deflate(.5),
        Radius.circular((radius - .5).clamp(0, radius)),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment(-tilt, -1),
          end: Alignment(tilt, 1),
          colors: [
            Colors.white.withValues(alpha: .52 * o * h),
            Colors.white.withValues(alpha: .20 * o * h),
            Colors.white.withValues(alpha: .07 * o),
            lowerEdge,
          ],
          stops: const [0, .28, .62, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(LiquidGlassEdgePainter old) =>
      old.radius != radius ||
      old.opacity != opacity ||
      old.highlight != highlight ||
      old.accent != accent ||
      old.accentStrength != accentStrength ||
      old.sheen != sheen;
}

/// Keeps radial gradients proportional on long, thin surfaces. They are
/// sized from the shortest side, so on a wide dock a highlight would be a
/// small circle; this stretches it along the long side into an ellipse.
class _StretchToAspect extends GradientTransform {
  const _StretchToAspect(this.size);

  final Size size;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    final aspect = bounds.width / bounds.height;
    final center = bounds.center;
    return Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(
        aspect.clamp(1.0, 3.0),
        (1 / aspect).clamp(1.0, 3.0),
        1,
        1,
      )
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }

  @override
  bool operator ==(Object other) =>
      other is _StretchToAspect && other.size == size;

  @override
  int get hashCode => size.hashCode;
}

/// Tappable [LiquidGlass] that presses in like a physical pane: it scales
/// down slightly, dims its highlights and settles its shadow, then springs
/// back on release. Only the press animates; nothing runs at rest.
class ReelishGlassCard extends StatefulWidget {
  const ReelishGlassCard({
    super.key,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(14),
    this.borderRadius = 20,
    this.quality = LiquidGlassQuality.low,
    this.blurSigma = 10,
    this.opacity = .8,
    this.elevation = 1,
    this.highlightIntensity = 1,
    this.accentStrength = 0,
    this.selected = false,
    this.tintColor = const Color(0xFF111722),
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final LiquidGlassQuality quality;
  final double blurSigma;
  final double opacity;
  final double elevation;
  final double highlightIntensity;
  final double accentStrength;

  /// Adds coral ambient light, for the selected item among glass choices.
  final bool selected;
  final Color tintColor;

  @override
  State<ReelishGlassCard> createState() => _ReelishGlassCardState();
}

class _ReelishGlassCardState extends State<ReelishGlassCard> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.borderRadius);
    final content = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: widget.onTap,
        onHighlightChanged: widget.onTap == null ? null : _setPressed,
        borderRadius: radius,
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.white.withValues(alpha: .035),
        child: Padding(padding: widget.padding, child: widget.child),
      ),
    );
    final accent = widget.selected
        ? widget.accentStrength.clamp(.6, 1.0).toDouble()
        : widget.accentStrength;
    if (widget.onTap == null) return _glass(content, 0, accent);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _pressed ? 1 : 0),
      // Presses in quickly, releases a little slower, without overshoot.
      duration: Duration(
        milliseconds: reduceMotion ? 0 : (_pressed ? 120 : 220),
      ),
      curve: Curves.easeOutCubic,
      builder: (context, press, child) => Transform.scale(
        scale: 1 - .018 * press,
        child: _glass(child!, press, accent),
      ),
      child: content,
    );
  }

  Widget _glass(Widget child, double press, double accent) => LiquidGlass(
    quality: widget.quality,
    blurSigma: widget.blurSigma,
    opacity: widget.opacity,
    borderRadius: widget.borderRadius,
    tintColor: widget.tintColor,
    elevation: widget.elevation,
    highlightIntensity: widget.highlightIntensity,
    accentStrength: accent,
    pressDepth: press,
    child: child,
  );
}
