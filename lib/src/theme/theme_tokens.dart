// The colours a Reelish theme gives every page: background, surfaces, text,
// borders and the tint of its glass. Classic is the look without a theme;
// each app theme (supporter_themes.dart) brings its own set. GlassTheme reads
// the active set, so every screen follows the theme without knowing which.
import 'package:flutter/material.dart';

@immutable
class ThemeSurfaces {
  const ThemeSurfaces({
    required this.background,
    required this.surface,
    required this.raised,
    required this.textPrimary,
    required this.textSecondary,
    this.brightness = Brightness.dark,
    this.disabledOverride,
    this.borderOverride,
    this.glassTintOverride,
    this.sidebarOverride,
    this.ambient,
  });

  /// Dark themes draw light text on dark pages. Light themes are not offered
  /// yet: much of the interface still assumes light text.
  final Brightness brightness;

  /// The page behind everything.
  final Color background;

  /// Cards, fields, list groups: one step above the page.
  final Color surface;

  /// Dialogs, sheets, menus and anything floating: a step above [surface].
  final Color raised;

  final Color textPrimary;

  /// Captions, descriptions and inactive labels.
  final Color textSecondary;

  /// Set where the derived [disabled], [border] or [glassTint] is not wanted.
  final Color? disabledOverride;
  final Color? borderOverride;
  final Color? glassTintOverride;
  final Color? sidebarOverride;

  /// The soft light a theme casts across its pages (AmbientBackdrop);
  /// none for Classic, whose pages stay flat.
  final Color? ambient;

  /// Text and icons of controls that cannot be used.
  Color get disabled =>
      disabledOverride ?? Color.lerp(textSecondary, background, .45)!;

  /// Hairlines and outlines.
  Color get border => borderOverride ?? textPrimary.withValues(alpha: .10);

  /// Dividers: quieter than borders.
  Color get divider => textPrimary.withValues(alpha: .07);

  /// The body colour of glass surfaces and smoked-glass controls.
  Color get glassTint =>
      glassTintOverride ?? Color.lerp(surface, background, .35)!;

  /// A faint lift on the page, for chips and grouped rows.
  Color get glassBackground => textPrimary.withValues(alpha: .06);

  /// A stronger lift, for secondary buttons and selected rows.
  Color get glassStrong => textPrimary.withValues(alpha: .09);

  /// The shade laid over artwork (heroes, detail backdrops) so white titles
  /// read on it. Dark themes fade the artwork into the page; a light theme
  /// keeps the artwork area dark, as its text there stays white.
  Color get artworkScrim => brightness == Brightness.dark
      ? background
      : Color.lerp(textPrimary, Colors.black, .35)!;

  /// The colours of the player's chrome and sheets, which sit over video
  /// and stay dark in every theme: this theme's own colours when it is dark,
  /// so the player still feels like the theme, or a dark counterpart built
  /// from its ink when it is light.
  ThemeSurfaces get forPlayer {
    if (brightness == Brightness.dark) return this;
    final ink = artworkScrim;
    return ThemeSurfaces(
      background: ink,
      surface: Color.lerp(ink, Colors.white, .06)!,
      raised: Color.lerp(ink, Colors.white, .1)!,
      textPrimary: background,
      textSecondary: Color.lerp(background, ink, .32)!,
      ambient: ambient,
    );
  }

  /// The Windows sidebar: a step darker than the page, so artwork leads.
  Color get sidebar =>
      sidebarOverride ??
      (brightness == Brightness.dark
          ? Color.lerp(background, Colors.black, .12)!
          : Color.lerp(background, textPrimary, .05)!);

  /// The look without a theme.
  static const classic = ThemeSurfaces(
    background: Color(0xFF0B0B0F),
    surface: Color(0xFF15151C),
    raised: Color(0xFF202029),
    textPrimary: Color(0xFFF7F7F9),
    textSecondary: Color(0xFFA5A5B2),
    disabledOverride: Color(0xFF62626D),
    borderOverride: Color(0x1AFFFFFF),
    glassTintOverride: Color(0xFF111722),
    sidebarOverride: Color(0xFF0D0D12),
  );

  @override
  bool operator ==(Object other) =>
      other is ThemeSurfaces &&
      other.brightness == brightness &&
      other.background == background &&
      other.surface == surface &&
      other.raised == raised &&
      other.textPrimary == textPrimary &&
      other.textSecondary == textSecondary &&
      other.disabled == disabled &&
      other.border == border &&
      other.glassTint == glassTint &&
      other.sidebar == sidebar &&
      other.ambient == ambient;

  @override
  int get hashCode => Object.hash(
    brightness,
    background,
    surface,
    raised,
    textPrimary,
    textSecondary,
    disabled,
    border,
    glassTint,
    sidebar,
    ambient,
  );
}
