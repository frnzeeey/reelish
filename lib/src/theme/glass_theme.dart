import 'package:flutter/material.dart';

abstract final class GlassTheme {
  static const background = Color(0xFF080B12);
  static const cyan = Color(0xFF72F2D0);
  static const violet = Color(0xFF9582FF);
  static const muted = Color(0xFF9BA5B7);
  static const surface = Color(0xFF121722);
  static const border = Color(0xFF252D3B);
  static const gradient = LinearGradient(colors: [cyan, violet]);
  static ThemeData get dark => ThemeData(
    brightness: Brightness.dark,
    fontFamily: 'Montserrat',
    scaffoldBackgroundColor: background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: cyan,
      brightness: Brightness.dark,
    ),
    useMaterial3: true,
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: const Color(0xFF0D111A),
      indicatorColor: cyan.withValues(alpha: .15),
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          color: states.contains(WidgetState.selected) ? cyan : muted,
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
        ),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Color(0xFF202838),
      contentTextStyle: TextStyle(color: Colors.white),
      actionTextColor: cyan,
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
