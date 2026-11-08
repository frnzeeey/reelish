// The Liquid Glass finish on buttons: the theme paints it behind every
// FilledButton and OutlinedButton, and custom controls and fields (the
// player's buttons, search fields) wrap their content in GlassFinish. Also
// the busy indicator for a button's icon slot. Painted gradients only, never
// a backdrop blur, so it is cheap in lists and on TV.

import 'package:flutter/material.dart';

import '../theme/glass_theme.dart';
import 'liquid_glass.dart';

/// How a button's glass is lit.
enum GlassButtonTone {
  /// Over an opaque fill (the accent): sheen, lower shade and lit edges.
  accent,

  /// Over a translucent fill: the same optics, quieter.
  neutral,
}

/// Button styles and layers that give Material buttons the glass finish.
///
/// The fill stays the button's own `backgroundColor`, so a call site that
/// colours its button keeps that colour and gains the finish on top. The
/// layer follows the default stadium shape; a button with another shape
/// passes its corner radius to [layer].
abstract final class GlassButtonStyle {
  /// The tint of secondary glass: [LiquidGlass]'s default tint, so buttons
  /// and panels are the same material.
  static const smokedGlass = Color(0xFF111722);

  /// Paints the finish behind a button's content for its current states.
  static ButtonLayerBuilder layer({
    GlassButtonTone tone = GlassButtonTone.accent,
    double? radius,
  }) =>
      (context, states, child) => CustomPaint(
        painter: GlassButtonPainter(
          tone: tone,
          radius: radius,
          light: lightFor(states),
          press: states.contains(WidgetState.pressed) ? 1 : 0,
        ),
        child: child,
      );

  /// How strongly the glass catches light in [states]: brighter on hover,
  /// dimmer when pressed, faint when disabled.
  static double lightFor(Set<WidgetState> states) {
    if (states.contains(WidgetState.disabled)) return .35;
    if (states.contains(WidgetState.pressed)) return .55;
    if (states.contains(WidgetState.hovered)) return 1.35;
    return 1;
  }

  /// A keyboard focus ring in [color]; no side otherwise.
  static WidgetStateProperty<BorderSide?> focusRing(Color color) =>
      WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? BorderSide(color: color, width: 2)
            : BorderSide.none,
      );

  /// The theme's primary button: the accent fill with the glass finish.
  static ButtonStyle filled() => ButtonStyle(
    backgroundBuilder: layer(),
    side: focusRing(GlassTheme.textPrimary),
  );

  /// The theme's secondary button: smoked glass, readable over artwork,
  /// lighter than the primary one.
  static ButtonStyle outlined() => ButtonStyle(
    backgroundBuilder: layer(tone: GlassButtonTone.neutral),
    backgroundColor: WidgetStateProperty.resolveWith(
      (states) => smokedGlass.withValues(
        alpha: states.contains(WidgetState.disabled)
            ? .22
            : states.contains(WidgetState.pressed)
            ? .62
            : states.contains(WidgetState.hovered)
            ? .52
            : .42,
      ),
    ),
    side: focusRing(GlassTheme.coralBright),
  );
}

/// A button's busy indicator, in place of its icon.
///
/// It takes the icon's size, so the button keeps its dimensions when work
/// starts, and the button's foreground colour at full strength: a busy
/// button is usually disabled, and the faded disabled colour would hide it.
class GlassButtonProgress extends StatelessWidget {
  const GlassButtonProgress({super.key});

  @override
  Widget build(BuildContext context) {
    final icon = IconTheme.of(context);
    final size = icon.size ?? 18;
    return SizedBox.square(
      dimension: size,
      child: Padding(
        padding: EdgeInsets.all(size * .08),
        child: CircularProgressIndicator(
          strokeWidth: (size / 9).clamp(1.6, 2.6).toDouble(),
          color: (icon.color ?? GlassTheme.textPrimary).withValues(alpha: 1),
        ),
      ),
    );
  }
}

/// Wraps content in the glass finish, for controls that draw their own
/// [Material] (the player's play and pill buttons) and for fields with a
/// translucent fill (search).
class GlassFinish extends StatelessWidget {
  const GlassFinish({
    super.key,
    required this.child,
    this.tone = GlassButtonTone.neutral,
    this.radius,
    this.light = 1,
  });

  final Widget child;
  final GlassButtonTone tone;

  /// Corner radius; null follows a stadium or circle.
  final double? radius;
  final double light;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: GlassButtonPainter(tone: tone, radius: radius, light: light),
    child: child,
  );
}

/// The glass finish, drawn under a button's content: a sheen falling off
/// from the top edge, a specular highlight at the upper left, a shade along
/// the bottom, then [LiquidGlassEdgePainter]'s inner rim and lit edge, the
/// same light as every other glass surface.
class GlassButtonPainter extends CustomPainter {
  const GlassButtonPainter({
    required this.tone,
    this.radius,
    this.light = 1,
    this.press = 0,
  });

  final GlassButtonTone tone;

  /// Corner radius; null is half the shorter side (stadium or circle).
  final double? radius;

  /// Highlight strength: 1 at rest, see [GlassButtonStyle.lightFor].
  final double light;

  /// 0 at rest, 1 pressed: the lower shade deepens.
  final double press;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final r = (radius ?? size.shortestSide / 2)
        .clamp(0.0, size.shortestSide / 2)
        .toDouble();
    final shape = RRect.fromRectAndRadius(rect, Radius.circular(r));
    final accent = tone == GlassButtonTone.accent;
    final sheen = (accent ? .24 : .12) * light;

    // Lower shade: the pane is thicker toward the bottom.
    canvas.drawRRect(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(
              alpha: ((accent ? .16 : .12) * (1 + .7 * press)).clamp(0, 1),
            ),
          ],
          stops: const [.45, 1],
        ).createShader(rect),
    );
    // Sheen from the top edge to the middle.
    canvas.drawRRect(
      shape,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: [
            Colors.white.withValues(alpha: sheen.clamp(0, 1)),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
    // Specular highlight toward the upper left, kept inside the shape.
    canvas
      ..save()
      ..clipRRect(shape);
    final spot = Rect.fromCenter(
      center: Offset(size.width * .28, size.height * .02),
      width: size.width * .9,
      height: size.height * 1.1,
    );
    canvas.drawOval(
      spot,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.white.withValues(
              alpha: ((accent ? .7 : .4) * sheen).clamp(0, 1),
            ),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(spot),
    );
    canvas.restore();

    LiquidGlassEdgePainter(
      radius: r,
      opacity: .85,
      highlight: light.clamp(0, 1.2).toDouble(),
    ).paint(canvas, size);
  }

  @override
  bool shouldRepaint(GlassButtonPainter old) =>
      old.tone != tone ||
      old.radius != radius ||
      old.light != light ||
      old.press != press;
}
