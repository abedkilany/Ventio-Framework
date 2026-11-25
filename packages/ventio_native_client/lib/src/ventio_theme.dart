import 'package:flutter/material.dart';

class VentioTheme {
  VentioTheme._();

  static const primary = Color(0xFF2563EB);
  static const cyan = Color(0xFF00B8FF);
  static const violet = Color(0xFF7B3FF2);
  static const dark = Color(0xFF0D1117);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData darkMode() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        brightness: brightness,
        primary: isDark ? const Color(0xFF60A5FA) : primary,
        surface: isDark ? dark : Colors.white,
      ),
      scaffoldBackgroundColor: isDark ? dark : const Color(0xFFF5F7FA),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(120, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}
