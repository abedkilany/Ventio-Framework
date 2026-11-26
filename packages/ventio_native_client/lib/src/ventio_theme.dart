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
    final scheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: brightness,
          primary: isDark ? const Color(0xFF60A5FA) : primary,
          surface: isDark ? dark : Colors.white,
        ).copyWith(
          primaryContainer: isDark
              ? const Color(0xFF17345D)
              : const Color(0xFFE8F1FF),
          onPrimaryContainer: isDark
              ? const Color(0xFFBFD9FF)
              : const Color(0xFF1847A7),
          tertiaryContainer: isDark
              ? const Color(0xFF123E32)
              : const Color(0xFFE5F5EB),
          onTertiaryContainer: isDark
              ? const Color(0xFF9EE6C7)
              : const Color(0xFF17613F),
          outlineVariant: isDark
              ? const Color(0xFF303D4B)
              : const Color(0xFFDEE5EE),
        );
    final border = BorderSide(color: scheme.outlineVariant);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? dark : const Color(0xFFF4F7FB),
      dividerColor: scheme.outlineVariant,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: border,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 42),
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 42),
          shape: shape,
          side: border,
        ),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: border,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(9),
          borderSide: BorderSide(color: scheme.primary, width: 1.5),
        ),
      ),
    );
  }
}
