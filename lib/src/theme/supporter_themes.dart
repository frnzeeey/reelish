// Profile themes for Reelish Supporters. Each restyles only the profile card:
// its backdrop, the ring around the avatar and the card's own accents. The
// accent the user picked for the rest of the app is untouched, and text stays
// white on a dark surface, so a theme never costs readability.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'design_tokens.dart';

/// The ornament a theme adds to its backdrop, drawn once and cheaply.
enum ThemeOrnament { none, stars, aurora, sheen }

@immutable
class SupporterTheme {
  const SupporterTheme({
    required this.id,
    required this.name,
    required this.glow,
    required this.second,
    required this.deep,
    required this.ink,
    this.ornament = ThemeOrnament.none,
  });

  /// Saved in the profile; never rename one.
  final String id;
  final String name;

  /// The main light, glowing from behind the avatar.
  final Color glow;

  /// The answering light across the card.
  final Color second;

  /// The card's dark base, tinted toward the theme.
  final Color deep;

  /// Light text and outlines that belong to the theme.
  final Color ink;
  final ThemeOrnament ornament;

  static const royalViolet = SupporterTheme(
    id: 'royal_violet',
    name: 'Royal Violet',
    glow: Color(0xFF8B6CF0),
    second: Color(0xFF4C46D8),
    deep: Color(0xFF15122A),
    ink: Color(0xFFD6CBFF),
    ornament: ThemeOrnament.sheen,
  );

  static const celestial = SupporterTheme(
    id: 'celestial',
    name: 'Celestial',
    glow: Color(0xFF5E8BFF),
    second: Color(0xFF2A3A8C),
    deep: Color(0xFF0C1124),
    ink: Color(0xFFCAD8FF),
    ornament: ThemeOrnament.stars,
  );

  static const aurora = SupporterTheme(
    id: 'aurora',
    name: 'Aurora',
    glow: Color(0xFF2CCFB8),
    second: Color(0xFF7A5CF5),
    deep: Color(0xFF0B1820),
    ink: Color(0xFFBDF4EA),
    ornament: ThemeOrnament.aurora,
  );

  static const roseLuxe = SupporterTheme(
    id: 'rose_luxe',
    name: 'Rose Luxe',
    glow: Color(0xFFEE8FB2),
    second: Color(0xFF9A3B66),
    deep: Color(0xFF1D1018),
    ink: Color(0xFFFFD3E2),
    ornament: ThemeOrnament.sheen,
  );

  static const goldenHour = SupporterTheme(
    id: 'golden_hour',
    name: 'Golden Hour',
    glow: Color(0xFFE9BE86),
    second: Color(0xFFB8733A),
    deep: Color(0xFF1B140E),
    ink: Color(0xFFFFE3BE),
    ornament: ThemeOrnament.sheen,
  );

  static const all = [royalViolet, celestial, aurora, roseLuxe, goldenHour];

  /// Saved when a supporter turns themes off for the usual profile.
  static const classicId = 'classic';

  /// What a supporter sees before choosing.
  static const standard = royalViolet;

  static SupporterTheme? byId(String? id) {
    for (final theme in all) {
      if (theme.id == id) return theme;
    }
    return null;
  }

  /// The theme to draw for a saved choice: none when the supporter chose the
  /// classic look, [standard] when they have not chosen yet.
  static SupporterTheme? resolve(String? savedId) =>
      savedId == classicId ? null : byId(savedId) ?? standard;
}

/// A theme's backdrop: its two lights over the tinted base, and its ornament.
/// Static, so it is painted once and kept by a [RepaintBoundary].
class SupporterThemeBackdrop extends StatelessWidget {
  const SupporterThemeBackdrop({super.key, required this.theme});

  final SupporterTheme theme;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(painter: _BackdropPainter(theme), size: Size.infinite),
  );
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter(this.theme);

  final SupporterTheme theme;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(theme.deep, theme.second, .18)!,
            theme.deep,
            const Color(0xFF101015),
          ],
          stops: const [0, .55, 1],
        ).createShader(rect),
    );
    final longest = math.max(size.width, size.height);
    _light(
      canvas,
      rect,
      const Alignment(-.85, -.9),
      longest * .75,
      theme.glow.withValues(alpha: .34),
    );
    _light(
      canvas,
      rect,
      const Alignment(1.05, 1.1),
      longest * .7,
      theme.second.withValues(alpha: .26),
    );

    switch (theme.ornament) {
      case ThemeOrnament.none:
        break;
      case ThemeOrnament.sheen:
        // One soft diagonal highlight, like light across a lacquered card.
        final sheen = Path()
          ..moveTo(size.width * .52, 0)
          ..lineTo(size.width * .70, 0)
          ..lineTo(size.width * .42, size.height)
          ..lineTo(size.width * .24, size.height)
          ..close();
        canvas.drawPath(
          sheen,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                theme.ink.withValues(alpha: .07),
                theme.ink.withValues(alpha: 0),
              ],
            ).createShader(rect),
        );
      case ThemeOrnament.stars:
        // Fixed positions, so the sky is the same on every paint.
        final random = math.Random(7);
        final star = Paint();
        for (var i = 0; i < 46; i++) {
          final x = random.nextDouble() * size.width;
          final y = random.nextDouble() * size.height;
          final bright = random.nextDouble();
          star.color = theme.ink.withValues(alpha: .15 + bright * .45);
          canvas.drawCircle(Offset(x, y), .5 + bright * 1.0, star);
        }
      case ThemeOrnament.aurora:
        // Two broad ribbons of light, drawn as blurred-looking gradients.
        for (final (offset, color) in [
          (.30, theme.glow),
          (.55, theme.second),
        ]) {
          final ribbon = Path()
            ..moveTo(0, size.height * (offset + .25))
            ..cubicTo(
              size.width * .3,
              size.height * (offset - .15),
              size.width * .65,
              size.height * (offset + .35),
              size.width,
              size.height * (offset - .05),
            )
            ..lineTo(size.width, size.height * (offset + .12))
            ..cubicTo(
              size.width * .65,
              size.height * (offset + .52),
              size.width * .3,
              size.height * offset,
              0,
              size.height * (offset + .42),
            )
            ..close();
          canvas.drawPath(
            ribbon,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  color.withValues(alpha: 0),
                  color.withValues(alpha: .16),
                  color.withValues(alpha: 0),
                ],
              ).createShader(rect)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
          );
        }
    }
  }

  void _light(
    Canvas canvas,
    Rect rect,
    Alignment center,
    double radius,
    Color color,
  ) {
    final point = center.withinRect(rect);
    canvas.drawCircle(
      point,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: point, radius: radius)),
    );
  }

  @override
  bool shouldRepaint(_BackdropPainter oldDelegate) =>
      oldDelegate.theme != theme;
}

/// The avatar's frame in a theme: a ring of its lights with a soft glow.
class SupporterAvatarRing extends StatelessWidget {
  const SupporterAvatarRing({
    super.key,
    required this.theme,
    required this.child,
  });

  final SupporterTheme theme;
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: SweepGradient(
        colors: [theme.ink, theme.glow, theme.second, theme.glow, theme.ink],
        stops: const [0, .3, .55, .8, 1],
      ),
      boxShadow: [
        BoxShadow(color: theme.glow.withValues(alpha: .38), blurRadius: 26),
      ],
    ),
    child: Padding(
      padding: const EdgeInsets.all(2.5),
      child: DecoratedBox(
        decoration: BoxDecoration(shape: BoxShape.circle, color: theme.deep),
        child: Padding(
          padding: const EdgeInsets.all(AppSpace.xxs),
          child: child,
        ),
      ),
    ),
  );
}
