import 'package:flutter/material.dart';

/// AppTheme defines the signature aesthetic for "Ayen's Kwaderno".
/// Soft purple & pink palette, clean light surfaces, soft rounded corners,
/// and subtle, elegant shadows (inspired by GoodNotes & premium stationery).
class AppTheme {
  // Primary Palette (Soft Purple & Lilac)
  static const Color primaryPurple = Color(0xFF8E7CE6);
  static const Color primaryPurpleLight = Color(0xFFECE8FD);
  static const Color primaryPurpleDark = Color(0xFF6B58C9);

  // Accent Palette (Soft Blush Pink)
  static const Color accentPink = Color(0xFFFF85A1);
  static const Color accentPinkLight = Color(0xFFFFE6ED);
  static const Color accentPinkDark = Color(0xFFE56A88);

  // Background & Surfaces
  static const Color background = Color(0xFFFAF9FD);
  static const Color surfaceWhite = Color(0xFFFFFFFF);
  static const Color surfaceCard = Color(0xFFFFFFFF);
  static const Color dividerColor = Color(0xFFEEEAF7);

  // Text Colors
  static const Color textPrimary = Color(0xFF2D2640);
  static const Color textSecondary = Color(0xFF7F7695);
  static const Color textMuted = Color(0xFFA59EB5);

  // Annotation Palette Colors (Soft pastel highlighters)
  static const List<Color> highlighterColors = [
    Color(0x66FFEB3B), // Soft Yellow
    Color(0x66FF85A1), // Soft Pink
    Color(0x668E7CE6), // Soft Lilac
    Color(0x666EE7B7), // Soft Mint
    Color(0x6693C5FD), // Soft Sky Blue
    Color(0x66FDBA74), // Soft Peach
  ];

  // Soft box shadows for cards & floating bars
  static final List<BoxShadow> softShadow = [
    BoxShadow(
      color: const Color(0xFF4B3C70).withValues(alpha: 0.06),
      blurRadius: 20,
      offset: const Offset(0, 6),
    ),
    BoxShadow(
      color: const Color(0xFF4B3C70).withValues(alpha: 0.04),
      blurRadius: 6,
      offset: const Offset(0, 2),
    ),
  ];

  static final List<BoxShadow> floatingToolbarShadow = [
    BoxShadow(
      color: const Color(0xFF37275E).withValues(alpha: 0.12),
      blurRadius: 24,
      spreadRadius: 0,
      offset: const Offset(0, 8),
    ),
    BoxShadow(
      color: const Color(0xFF37275E).withValues(alpha: 0.04),
      blurRadius: 8,
      offset: const Offset(0, 2),
    ),
  ];

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: background,
      primaryColor: primaryPurple,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryPurple,
        primary: primaryPurple,
        secondary: accentPink,
        surface: surfaceWhite,
        brightness: Brightness.light,
      ),
      fontFamily: 'Roboto',
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: textPrimary),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
      ),
      cardTheme: CardThemeData(
        color: surfaceCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: dividerColor, width: 1),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: accentPink,
        foregroundColor: Colors.white,
        elevation: 4,
        highlightElevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryPurple,
          foregroundColor: Colors.white,
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.1,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryPurple,
          side: const BorderSide(color: primaryPurpleLight, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      iconTheme: const IconThemeData(
        color: textPrimary,
        size: 22,
      ),
    );
  }
}
