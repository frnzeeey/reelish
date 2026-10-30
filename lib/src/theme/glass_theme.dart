import 'package:flutter/material.dart';

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
  static const background = Color(0xFF0B0B0F);
  static const textPrimary = Color(0xFFF7F7F9);
  static const muted = Color(0xFFA5A5B2);
  static const disabled = Color(0xFF62626D);
  static const surface = Color(0xFF15151C);
  static const elevatedSurface = Color(0xFF202029);
  static const border = Color(0x1AFFFFFF);
  static const glassBackground = Color(0x0FFFFFFF);
  static const glassStrong = Color(0x17FFFFFF);

  /// Status colours, fixed whatever the accent: cautions and pending
  /// approvals, and failures. Pair them with an icon or words, never colour
  /// alone.
  static const warning = Color(0xFFFFB547);
  static const danger = Color(0xFFFF5252);
  static LinearGradient get gradient =>
      LinearGradient(colors: [coralBright, primary]);

  /// The app's font. Set on the theme's text styles; a button `textStyle`
  /// given in a `styleFrom` replaces those, so it must name it too.
  static const fontFamily = 'Montserrat';
  static ThemeData get dark => ThemeData(
    brightness: Brightness.dark,
    fontFamily: fontFamily,
    scaffoldBackgroundColor: background,
    colorScheme:
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: Brightness.dark,
        ).copyWith(
          primary: primary,
          onPrimary: background,
          secondary: coralBright,
          onSecondary: textPrimary,
          surface: surface,
          onSurface: textPrimary,
        ),
    useMaterial3: true,
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: glassBackground,
      indicatorColor: coralGlow,
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.selected) ? primary : muted,
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: elevatedSurface,
      contentTextStyle: TextStyle(color: Colors.white),
      actionTextColor: primary,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(15),
        borderSide: const BorderSide(color: border),
      ),
    ),
  );

  /// [dark] for Android TV. Same palette and components; focus, the only
  /// cursor a remote has, is drawn as a coral tint on every [InkWell] and a
  /// tint plus ring on Material buttons, so it is visible from across the
  /// room. Call sites that set their own `side` keep it and show the tint.
  static ThemeData get tv {
    final base = dark;
    WidgetStateProperty<Color?> overlay(Color focused) =>
        WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? focused
              : states.contains(WidgetState.pressed)
              ? Colors.white.withValues(alpha: .12)
              : null,
        );
    WidgetStateProperty<BorderSide?> ring(Color color, {BorderSide? rest}) =>
        WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? BorderSide(color: color, width: 2.5)
              : rest,
        );
    final tint = primary.withValues(alpha: .26);
    return base.copyWith(
      focusColor: tint,
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          overlayColor: overlay(Colors.white.withValues(alpha: .22)),
          side: ring(Colors.white),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          overlayColor: overlay(tint),
          side: ring(
            coralBright,
            rest: BorderSide(color: Colors.white.withValues(alpha: .3)),
          ),
        ),
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
