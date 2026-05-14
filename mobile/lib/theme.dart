import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// iOS 26-style "liquid glass" palette.
class GlassPalette {
  static const Color accent = Color(0xFF0A84FF); // iOS systemBlue dark
  static const Color accentSoft = Color(0xFF5AC8FA);
  static const Color success = Color(0xFF30D158);
  static const Color warning = Color(0xFFFFD60A);
  static const Color danger = Color(0xFFFF453A);

  // Background gradient (deep navy → indigo, mimics iOS 26 home)
  static const List<Color> bgGradient = [
    Color(0xFF0B1020),
    Color(0xFF111935),
    Color(0xFF1A1444),
  ];

  static const Color surfaceTint = Color(0x33FFFFFF); // 20% white
  static const Color surfaceStroke = Color(0x40FFFFFF);
  static const Color textPrimary = Color(0xFFF5F7FB);
  static const Color textSecondary = Color(0xB3F5F7FB);
  static const Color textMuted = Color(0x80F5F7FB);
}

ThemeData buildGlassTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: GlassPalette.accent,
      brightness: Brightness.dark,
    ).copyWith(
      primary: GlassPalette.accent,
      surface: const Color(0xFF111935),
      onSurface: GlassPalette.textPrimary,
    ),
    scaffoldBackgroundColor: Colors.transparent,
  );
  return base.copyWith(
    textTheme: base.textTheme
        .apply(
          bodyColor: GlassPalette.textPrimary,
          displayColor: GlassPalette.textPrimary,
        )
        .copyWith(
          titleLarge: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: GlassPalette.textPrimary,
          ),
          titleMedium: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
            color: GlassPalette.textPrimary,
          ),
          bodyMedium: const TextStyle(
            fontSize: 15,
            color: GlassPalette.textSecondary,
          ),
          labelLarge: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: GlassPalette.textPrimary,
          ),
        ),
    iconTheme: const IconThemeData(color: GlassPalette.textPrimary),
    cupertinoOverrideTheme: const CupertinoThemeData(
      brightness: Brightness.dark,
      primaryColor: GlassPalette.accent,
    ),
  );
}
