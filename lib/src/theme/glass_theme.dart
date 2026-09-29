import 'package:flutter/material.dart';

abstract final class GlassTheme {
  static const primary = Color(0xFFFF4D6D);
  static const coralBright = Color(0xFFFF6B85);
  static const coralDark = Color(0xFFD93655);
  static const coralGlow = Color(0x33FF4D6D);
  static const background = Color(0xFF0B0B0F);
  static const textPrimary = Color(0xFFF7F7F9);
  static const muted = Color(0xFFA5A5B2);
  static const disabled = Color(0xFF62626D);
  static const surface = Color(0xFF15151C);
  static const elevatedSurface = Color(0xFF202029);
  static const border = Color(0x1AFFFFFF);
  static const glassBackground = Color(0x0FFFFFFF);
  static const glassStrong = Color(0x17FFFFFF);
  static const gradient = LinearGradient(colors: [coralBright, primary]);
  static ThemeData get dark => ThemeData(
    brightness: Brightness.dark,
    fontFamily: 'Montserrat',
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
    snackBarTheme: const SnackBarThemeData(
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
}
