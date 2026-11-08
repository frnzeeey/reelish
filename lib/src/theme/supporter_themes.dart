// App themes for Reelish Supporters (Settings > Appearance). A theme is a
// whole look: the page colours every screen reads through GlassTheme
// (ThemeSurfaces), the accent across the app, and the profile card's lights,
// ring and ornament. New themes are new entries here; no screen names one.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'glass_theme.dart';
import 'theme_tokens.dart';

/// The ornament a theme adds to its backdrop, drawn once and cheaply.
enum ThemeOrnament { none, stars, aurora, sheen }

@immutable
class SupporterTheme {
  const SupporterTheme({
    required this.id,
    required this.name,
    required this.description,
    required this.surfaces,
    required this.primary,
    required this.light,
    required this.deepAccent,
    required this.glow,
    required this.second,
    required this.deep,
    required this.ink,
    this.ornament = ThemeOrnament.none,
    this.replaces = const [],
  });

  /// Saved on the device; never rename one.
  final String id;
  final String name;

  /// One line for the picker.
  final String description;

  /// The page colours every screen reads while this theme is on.
  final ThemeSurfaces surfaces;

  /// The accent: buttons, selection, progress and links.
  final Color primary;

  /// The accent's lighter partner: highlights and gradients.
  final Color light;

  /// The accent's deeper partner: pressed states and gradient ends.
  final Color deepAccent;

  /// The profile card's main light, glowing from behind the avatar.
  final Color glow;

  /// The answering light across the card.
  final Color second;

  /// The card's dark base, tinted toward the theme.
  final Color deep;

  /// Light text and outlines that belong to the theme.
  final Color ink;
  final ThemeOrnament ornament;

  /// Ids of retired themes that now open as this one, so a saved choice
  /// keeps working.
  final List<String> replaces;

  /// The accent the theme sets across the app.
  AccentPalette get accent => AccentPalette(
    id: 'theme:$id',
    label: name,
    primary: primary,
    bright: light,
    dark: deepAccent,
  );

  /// Reelish's flagship look.
  static const velvetCinema = SupporterTheme(
    id: 'velvet_cinema',
    name: 'Velvet Cinema',
    description: 'Midnight and deep violet, lit in lavender',
    surfaces: ThemeSurfaces(
      background: Color(0xFF0D0B14),
      surface: Color(0xFF191522),
      raised: Color(0xFF211B30),
      textPrimary: Color(0xFFF5F3FF),
      textSecondary: Color(0xFFA9A2B8),
      ambient: Color(0xFFA78BFA),
    ),
    primary: Color(0xFFA78BFA),
    light: Color(0xFFC4B5FD),
    deepAccent: Color(0xFF7C3AED),
    glow: Color(0xFFA78BFA),
    second: Color(0xFF7C3AED),
    deep: Color(0xFF16112A),
    ink: Color(0xFFC4B5FD),
    ornament: ThemeOrnament.sheen,
    replaces: ['royal_violet'],
  );

  static const aurora = SupporterTheme(
    id: 'aurora',
    name: 'Aurora',
    description: 'Northern lights in teal and emerald',
    surfaces: ThemeSurfaces(
      background: Color(0xFF071311),
      surface: Color(0xFF10201E),
      raised: Color(0xFF17302B),
      textPrimary: Color(0xFFECFDF5),
      textSecondary: Color(0xFF9CBAB1),
      ambient: Color(0xFF54D6C0),
    ),
    primary: Color(0xFF54D6C0),
    light: Color(0xFF67E8F9),
    deepAccent: Color(0xFF2BA98F),
    glow: Color(0xFF54D6C0),
    second: Color(0xFF34D399),
    deep: Color(0xFF0A1C19),
    ink: Color(0xFFC6F7EC),
    ornament: ThemeOrnament.aurora,
  );

  static const obsidianGold = SupporterTheme(
    id: 'obsidian_gold',
    name: 'Obsidian Gold',
    description: 'Obsidian black with champagne gold',
    surfaces: ThemeSurfaces(
      background: Color(0xFF0D0D0C),
      surface: Color(0xFF191816),
      raised: Color(0xFF24211B),
      textPrimary: Color(0xFFF8F5ED),
      textSecondary: Color(0xFFB9B0A0),
      ambient: Color(0xFFD6B36A),
    ),
    primary: Color(0xFFD6B36A),
    light: Color(0xFFE9D5A3),
    deepAccent: Color(0xFFB58A45),
    glow: Color(0xFFD6B36A),
    second: Color(0xFFB58A45),
    deep: Color(0xFF17140F),
    ink: Color(0xFFE9D5A3),
    ornament: ThemeOrnament.sheen,
    replaces: ['golden_hour'],
  );

  static const ember = SupporterTheme(
    id: 'ember',
    name: 'Ember',
    description: 'A dark theatre in warm, glowing light',
    surfaces: ThemeSurfaces(
      background: Color(0xFF140B0A),
      surface: Color(0xFF211312),
      raised: Color(0xFF301A18),
      textPrimary: Color(0xFFFFF4F0),
      textSecondary: Color(0xFFC2A39D),
      ambient: Color(0xFFFF795F),
    ),
    primary: Color(0xFFFF795F),
    light: Color(0xFFFFAD70),
    deepAccent: Color(0xFFE5484D),
    glow: Color(0xFFFF795F),
    second: Color(0xFFE5484D),
    deep: Color(0xFF1F0F0D),
    ink: Color(0xFFFFD6C8),
    ornament: ThemeOrnament.sheen,
  );

  static const arctic = SupporterTheme(
    id: 'arctic',
    name: 'Arctic',
    description: 'Deep navy and clear, icy blue',
    surfaces: ThemeSurfaces(
      background: Color(0xFF08111C),
      surface: Color(0xFF111E2D),
      raised: Color(0xFF192A3C),
      textPrimary: Color(0xFFF0F9FF),
      textSecondary: Color(0xFFA5B9CA),
      ambient: Color(0xFF8CCBFF),
    ),
    primary: Color(0xFF8CCBFF),
    light: Color(0xFFBAE6FD),
    deepAccent: Color(0xFF60A5FA),
    glow: Color(0xFF8CCBFF),
    second: Color(0xFF60A5FA),
    deep: Color(0xFF0C1828),
    ink: Color(0xFFBAE6FD),
    ornament: ThemeOrnament.stars,
    replaces: ['celestial'],
  );

  static const roseNoir = SupporterTheme(
    id: 'rose_noir',
    name: 'Rosé Noir',
    description: 'Dark plum with muted rose and mauve',
    surfaces: ThemeSurfaces(
      background: Color(0xFF140D14),
      surface: Color(0xFF211622),
      raised: Color(0xFF302033),
      textPrimary: Color(0xFFFFF1F7),
      textSecondary: Color(0xFFC4A9BA),
      ambient: Color(0xFFF18EB5),
    ),
    primary: Color(0xFFF18EB5),
    light: Color(0xFFF7B6CF),
    deepAccent: Color(0xFFD979A3),
    glow: Color(0xFFF18EB5),
    second: Color(0xFFC4A0D2),
    deep: Color(0xFF1D121D),
    ink: Color(0xFFFFD3E2),
    ornament: ThemeOrnament.sheen,
    replaces: ['rose_luxe'],
  );

  /// The light theme: ivory pages and dark text. Artwork areas (heroes,
  /// detail backdrops) stay dark with white titles ([ThemeSurfaces.artworkScrim]),
  /// and the player keeps its dark chrome.
  static const ivoryStudio = SupporterTheme(
    id: 'ivory_studio',
    name: 'Ivory Studio',
    description: 'Warm ivory and bronze, in daylight',
    surfaces: ThemeSurfaces(
      brightness: Brightness.light,
      background: Color(0xFFFAF8F3),
      surface: Color(0xFFFFFFFF),
      raised: Color(0xFFF4F0E8),
      textPrimary: Color(0xFF28251F),
      // #777064 in the palette, a step deeper so captions keep AA on the
      // cream dialogs too.
      textSecondary: Color(0xFF6F685C),
      ambient: Color(0xFFB49B78),
    ),
    // The palette's bronze (#B49B78) is too faint for small accent text on
    // ivory, so the accent is a deeper bronze and #B49B78 its light partner.
    primary: Color(0xFF856D4C),
    light: Color(0xFFB49B78),
    deepAccent: Color(0xFF6E5A3E),
    // The profile card stays a dark card, lit in bronze, in every theme.
    glow: Color(0xFFB49B78),
    second: Color(0xFF8F7756),
    deep: Color(0xFF2A251E),
    ink: Color(0xFFE5DFD4),
    ornament: ThemeOrnament.sheen,
  );

  /// The themes offered, flagship first.
  static const all = [
    velvetCinema,
    aurora,
    ember,
    arctic,
    ivoryStudio,
    obsidianGold,
    roseNoir,
  ];

  /// The picker's choice for no theme: the accent the user picked.
  static const classicId = 'classic';

  /// The offered theme saved as [id], including the ids of the themes it
  /// replaced.
  static SupporterTheme? byId(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final theme in all) {
      if (theme.id == id || theme.replaces.contains(id)) return theme;
    }
    return null;
  }
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
