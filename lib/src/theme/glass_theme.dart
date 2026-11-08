import 'package:flutter/material.dart';

import '../widgets/glass_button.dart';
import 'design_tokens.dart';
import 'theme_tokens.dart';

abstract final class GlassTheme {
  static const coral = AccentPalette(
    id: 'coral',
    label: 'Coral',
    primary: Color(0xFFFF4D6D),
    bright: Color(0xFFFF6B85),
    dark: Color(0xFFD93655),
  );
  static const violet = AccentPalette(
    id: 'violet',
    label: 'Violet',
    primary: Color(0xFF9B7BFF),
    bright: Color(0xFFB39BFF),
    dark: Color(0xFF7555D9),
  );
  static const blue = AccentPalette(
    id: 'blue',
    label: 'Blue',
    primary: Color(0xFF4DA3FF),
    bright: Color(0xFF78B9FF),
    dark: Color(0xFF347ACC),
  );
  static const green = AccentPalette(
    id: 'green',
    label: 'Green',
    primary: Color(0xFF42CFA0),
    bright: Color(0xFF70E0B8),
    dark: Color(0xFF2BA77D),
  );
  static const amber = AccentPalette(
    id: 'amber',
    label: 'Amber',
    primary: Color(0xFFFFB547),
    bright: Color(0xFFFFCA73),
    dark: Color(0xFFD98D24),
  );
  static const orange = AccentPalette(
    id: 'orange',
    label: 'Orange',
    primary: Color(0xFFFF7849),
    bright: Color(0xFFFF966F),
    dark: Color(0xFFD9572A),
  );
  static const teal = AccentPalette(
    id: 'teal',
    label: 'Teal',
    primary: Color(0xFF27C4C1),
    bright: Color(0xFF62DAD5),
    dark: Color(0xFF169A98),
  );
  static const indigo = AccentPalette(
    id: 'indigo',
    label: 'Indigo',
    primary: Color(0xFF6577FF),
    bright: Color(0xFF8997FF),
    dark: Color(0xFF4859D9),
  );
  static const rose = AccentPalette(
    id: 'rose',
    label: 'Rose',
    primary: Color(0xFFFF5FA2),
    bright: Color(0xFFFF85B9),
    dark: Color(0xFFD9407F),
  );
  static const lime = AccentPalette(
    id: 'lime',
    label: 'Lime',
    primary: Color(0xFFA6D93C),
    bright: Color(0xFFBDE86A),
    dark: Color(0xFF84B021),
  );
  static const slate = AccentPalette(
    id: 'slate',
    label: 'Slate',
    primary: Color(0xFF9AA9C2),
    bright: Color(0xFFB6C2D6),
    dark: Color(0xFF74839C),
  );

  /// The presets in the order they are offered: the default first, then
  /// round the colour wheel, then the neutral.
  static const accents = [
    coral,
    orange,
    amber,
    lime,
    green,
    teal,
    blue,
    indigo,
    violet,
    rose,
    slate,
  ];
  static AccentPalette _accent = coral;
  static AccentPalette get accent => _accent;
  static void setAccent(AccentPalette value) => _accent = value;

  static Color get primary => _accent.primary;
  static Color get coralBright => _accent.bright;
  static Color get coralDark => _accent.dark;
  static Color get coralGlow => _accent.primary.withValues(alpha: .2);

  /// The page colours in effect: [ThemeSurfaces.classic], or the app
  /// theme's. Set by `AccentSettingsController`; the getters below follow it.
  static ThemeSurfaces _surfaces = ThemeSurfaces.classic;
  static ThemeSurfaces get surfaces => _surfaces;
  static void setSurfaces(ThemeSurfaces value) => _surfaces = value;

  static Color get background => _surfaces.background;
  static Color get textPrimary => _surfaces.textPrimary;
  static Color get muted => _surfaces.textSecondary;
  static Color get disabled => _surfaces.disabled;
  static Color get surface => _surfaces.surface;
  static Color get elevatedSurface => _surfaces.raised;
  static Color get border => _surfaces.border;
  static Color get divider => _surfaces.divider;
  static Color get glassBackground => _surfaces.glassBackground;
  static Color get glassStrong => _surfaces.glassStrong;

  /// The body of glass surfaces and smoked-glass controls.
  static Color get glassTint => _surfaces.glassTint;

  /// The shade over artwork behind white titles; the page colour in dark
  /// themes.
  static Color get artworkScrim => _surfaces.artworkScrim;

  /// The theme's soft page light, or null for flat pages (Classic).
  static Color? get ambient => _surfaces.ambient;

  /// The player's chrome and sheets: dark in every theme. See
  /// [ThemeSurfaces.forPlayer].
  static ThemeSurfaces get playerSurfaces => _surfaces.forPlayer;

  /// Whether the theme is light (Ivory Studio): dark text on light pages.
  static bool get isLight => _surfaces.brightness == Brightness.light;

  /// Titles and labels over [artworkScrim]: white on a light theme, whose
  /// page text is dark; the theme's own text colour on a dark one.
  static Color get onArtwork => isLight ? Colors.white : _surfaces.textPrimary;

  /// The accent on the player's dark chrome: the theme's own, or on a light
  /// theme its lighter partner, which reads on dark where the page accent
  /// (deep enough for ivory) would not.
  static AccentPalette get playerAccent =>
      _surfaces.brightness == Brightness.dark
      ? _accent
      : AccentPalette(
          id: _accent.id,
          label: _accent.label,
          primary: _accent.bright,
          bright: Color.lerp(_accent.bright, Colors.white, .25)!,
          dark: _accent.primary,
        );

  /// [primary] for the player's chrome.
  static Color get playerPrimary => playerAccent.primary;

  /// The Material theme inside the player, for the look in effect; [tv]
  /// adds the remote's focus styling.
  static ThemeData player({required bool tv}) => tv
      ? buildTv(playerAccent, playerSurfaces)
      : build(playerAccent, playerSurfaces);

  /// Status colours, fixed whatever the theme: cautions and pending
  /// approvals, failures, completed actions and neutral notes. Pair them
  /// with an icon or words, never colour alone.
  static const warning = Color(0xFFFFB547);
  static const danger = Color(0xFFFF5252);
  static const success = Color(0xFF4ADE80);
  static const info = Color(0xFF60A5FA);
  static LinearGradient get gradient =>
      LinearGradient(colors: [coralBright, primary]);

  /// The app's font. Set on the theme's text styles; a button `textStyle`
  /// given in a `styleFrom` replaces those, so it must name it too.
  static const fontFamily = 'Montserrat';

  /// The phone and Windows theme for the look in effect.
  static ThemeData get dark => build(_accent, _surfaces);

  /// [dark] for Android TV, for the look in effect.
  static ThemeData get tv => buildTv(_accent, _surfaces);

  /// The Material theme for [accent] over [s]. Everything Material draws
  /// (dialogs, sheets, menus, fields, chips, switches, sliders, progress)
  /// takes its colours from here, so a theme reaches them without any
  /// screen knowing it. Also used to preview a theme before it applies.
  static ThemeData build(AccentPalette accent, ThemeSurfaces s) {
    final primary = accent.primary;
    final radius = BorderRadius.circular(AppRadius.lg);
    return ThemeData(
      brightness: s.brightness,
      fontFamily: fontFamily,
      scaffoldBackgroundColor: s.background,
      canvasColor: s.background,
      dividerColor: s.divider,
      colorScheme:
          ColorScheme.fromSeed(
            seedColor: primary,
            brightness: s.brightness,
          ).copyWith(
            primary: primary,
            onPrimary: s.background,
            primaryContainer: primary.withValues(alpha: .22),
            onPrimaryContainer: s.textPrimary,
            secondary: accent.bright,
            onSecondary: s.textPrimary,
            tertiary: accent.dark,
            surface: s.surface,
            onSurface: s.textPrimary,
            onSurfaceVariant: s.textSecondary,
            surfaceDim: s.background,
            surfaceBright: s.raised,
            surfaceContainerLowest: s.background,
            surfaceContainerLow: s.surface,
            surfaceContainer: s.surface,
            surfaceContainerHigh: s.raised,
            surfaceContainerHighest: Color.lerp(s.raised, s.textPrimary, .06),
            surfaceTint: Colors.transparent,
            outline: s.textPrimary.withValues(alpha: .22),
            outlineVariant: s.border,
            error: danger,
            onError: Colors.white,
            inverseSurface: s.textPrimary,
            onInverseSurface: s.background,
            shadow: Colors.black,
            scrim: Colors.black,
          ),
      useMaterial3: true,
      // Buttons carry the Liquid Glass finish (painted, never blurred): the
      // primary on the accent, the secondary as smoked glass. Text and icon
      // buttons stay flat so the glass marks the actions that matter.
      filledButtonTheme: FilledButtonThemeData(
        style: GlassButtonStyle.filled(ring: s.textPrimary),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: GlassButtonStyle.outlined(
          tint: s.glassTint,
          ring: accent.bright,
        ),
      ),
      // Menus are the same smoked glass, near-opaque so their text reads over
      // anything, with a hairline edge instead of Material's tint.
      popupMenuTheme: PopupMenuThemeData(
        color: Color.alphaBlend(
          s.textPrimary.withValues(alpha: .04),
          s.glassTint,
        ).withValues(alpha: .97),
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shadowColor: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: s.border),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(s.raised),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(color: s.border),
            ),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: s.raised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          side: BorderSide(color: s.border),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: s.raised,
        modalBackgroundColor: s.raised,
        surfaceTintColor: Colors.transparent,
        dragHandleColor: s.textSecondary.withValues(alpha: .5),
      ),
      cardTheme: CardThemeData(
        color: s.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.card),
          side: BorderSide(color: s.border),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: s.glassBackground,
        selectedColor: primary.withValues(alpha: .22),
        side: BorderSide(color: s.border),
        labelStyle: TextStyle(color: s.textPrimary, fontFamily: fontFamily),
        secondaryLabelStyle: TextStyle(color: primary, fontFamily: fontFamily),
        checkmarkColor: primary,
        shape: const StadiumBorder(),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: s.raised,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: s.border),
        ),
        textStyle: TextStyle(color: s.textPrimary, fontSize: 12),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: s.glassStrong,
        circularTrackColor: Colors.transparent,
      ),
      tabBarTheme: TabBarThemeData(
        indicatorColor: primary,
        labelColor: s.textPrimary,
        unselectedLabelColor: s.textSecondary,
        dividerColor: s.divider,
      ),
      dividerTheme: DividerThemeData(color: s.divider, space: 1),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: primary,
        selectionColor: primary.withValues(alpha: .35),
        selectionHandleColor: primary,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: s.glassBackground,
        indicatorColor: primary.withValues(alpha: .2),
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected)
                ? primary
                : s.textSecondary,
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: s.raised,
        contentTextStyle: TextStyle(color: s.textPrimary),
        actionTextColor: primary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: s.background,
        surfaceTintColor: Colors.transparent,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: s.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(color: s.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(color: s.border),
        ),
      ),
    );
  }

  /// [build] for Android TV. Same palette and components; focus, the only
  /// cursor a remote has, is drawn as an accent tint on every [InkWell] and a
  /// tint plus ring on Material buttons, so it is visible from across the
  /// room. Call sites that set their own `side` keep it and show the tint.
  static ThemeData buildTv(AccentPalette accent, ThemeSurfaces s) {
    final base = build(accent, s);
    final primary = accent.primary;
    WidgetStateProperty<Color?> overlay(Color focused) =>
        WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? focused
              : states.contains(WidgetState.pressed)
              ? s.textPrimary.withValues(alpha: .12)
              : null,
        );
    WidgetStateProperty<BorderSide?> ring(Color color, {BorderSide? rest}) =>
        WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? BorderSide(color: color, width: 2.5)
              : rest,
        );
    final tint = primary.withValues(alpha: .26);
    // TV focus wins over the glass styles; their finish fills in the rest.
    return base.copyWith(
      focusColor: tint,
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          overlayColor: overlay(s.textPrimary.withValues(alpha: .22)),
          side: ring(s.textPrimary),
        ).merge(base.filledButtonTheme.style),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          overlayColor: overlay(tint),
          side: ring(
            accent.bright,
            rest: BorderSide(color: s.textPrimary.withValues(alpha: .3)),
          ),
        ).merge(base.outlinedButtonTheme.style),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(overlayColor: overlay(tint), side: ring(primary)),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(overlayColor: overlay(tint), side: ring(primary)),
      ),
    );
  }
}

class AccentPalette {
  const AccentPalette({
    required this.id,
    required this.label,
    required this.primary,
    required this.bright,
    required this.dark,
  });

  /// A palette from any colour the user picks, with its lightness raised
  /// until it reads on the page background (and dark text reads on it), as
  /// the presets do. Its [id] is `custom:rrggbb`, the colour actually used.
  factory AccentPalette.custom(Color color) {
    final hsl = HSLColor.fromColor(color.withValues(alpha: 1));
    var lightness = hsl.lightness.clamp(.45, .8).toDouble();
    // 4.5:1 against the page background needs a luminance of about .2.
    while (lightness < .8 &&
        hsl.withLightness(lightness).toColor().computeLuminance() < .2) {
      lightness += .01;
    }
    final primary = hsl.withLightness(lightness).toColor();
    final hex = (primary.toARGB32() & 0xFFFFFF)
        .toRadixString(16)
        .padLeft(6, '0');
    return AccentPalette(
      id: '$customPrefix$hex',
      label: 'Custom',
      primary: primary,
      bright: hsl.withLightness((lightness + .08).clamp(0, .88)).toColor(),
      dark: hsl.withLightness((lightness - .12).clamp(.2, 1)).toColor(),
    );
  }

  /// The saved form of a custom accent starts with this.
  static const customPrefix = 'custom:';

  /// The palette saved as [id], or null when it is neither a preset nor a
  /// well-formed custom colour.
  static AccentPalette? fromId(String? id) {
    if (id == null) return null;
    if (id.startsWith(customPrefix)) {
      final hex = id.substring(customPrefix.length);
      final rgb = hex.length == 6 ? int.tryParse(hex, radix: 16) : null;
      return rgb == null ? null : AccentPalette.custom(Color(0xFF000000 | rgb));
    }
    for (final accent in GlassTheme.accents) {
      if (accent.id == id) return accent;
    }
    return null;
  }

  final String id;
  final String label;
  final Color primary;
  final Color bright;
  final Color dark;

  bool get isCustom => id.startsWith(customPrefix);
}
