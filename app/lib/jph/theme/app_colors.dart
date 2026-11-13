import 'package:flutter/material.dart';

class AppColors {
  // =================== PRIMARY COLORS ===================
  static const Color primary = Color(0xFF4F46E5);
  static const Color primaryLight = Color(0xFF6A67F5);
  static const Color primaryDark = Color(0xFF3730A3);
  static const Color primaryContainer = Color(0xFFE0E7FF);
  static const Color onPrimary = Color(0xFFFFFFFF);

  // =================== SECONDARY COLORS ===================
  static const Color secondary = Color(0xFF14B8A6);
  static const Color secondaryLight = Color(0xFF2DD4BF);
  static const Color secondaryDark = Color(0xFF0D9488);
  static const Color onSecondary = Color(0xFFFFFFFF);

  // =================== ACCENT COLORS ===================
  static const Color accent = Color(0xFFF59E0B);
  static const Color accentLight = Color(0xFFFBBF24);
  static const Color accentDark = Color(0xFFD97706);

  // =================== ERROR & SUCCESS ===================
  static const Color error = Color(0xFFEF4444);
  static const Color errorLight = Color(0xFFFEE2E2);
  static const Color success = Color(0xFF10B981);
  static const Color successLight = Color(0xFFD1FAE5);
  static const Color warning = Color(0xFFF59E0B);
  static const Color warningLight = Color(0xFFFEF3C7);

  // =================== NEUTRAL COLORS (Light Mode) — the «Ardena» warm paper / ink ===================
  static const Color backgroundLight = Color(0xFFE9E6E1);
  static const Color surfaceLight = Color(0xFFFBFAF7);
  static const Color surfaceVariantLight = Color(0xFFF1EEE9);
  static const Color onBackgroundLight = Color(0xFF1C1B19);
  static const Color onSurfaceLight = Color(0xFF1C1B19);
  static const Color onSurfaceVariantLight = Color(0xFF59554E);

  static const Color outlineLight = Color(0xFFDDD8CF);
  static const Color shadowLight = Color(0x1A000000);

  // =================== NEUTRAL COLORS (Dark Mode) — the «Ardena» smoked glass ===================
  static const Color backgroundDark = Color(0xFF1B1B1A);
  static const Color surfaceDark = Color(0xFF262624);
  static const Color surfaceVariantDark = Color(0xFF35342F);
  static const Color onBackgroundDark = Color(0xFFF6F5F2);
  static const Color onSurfaceDark = Color(0xFFF6F5F2);
  static const Color onSurfaceVariantDark = Color(0xFFC9C6BF);

  static const Color outlineDark = Color(0xFF4A4843);
  static const Color shadowDark = Color(0x33000000);

  // =================== GLASS EFFECT COLORS ===================
  static const Color glassLight = Color(0x20FFFFFF);
  static const Color glassDark = Color(0x101E293B);

  // =================== GRADIENT COLORS ===================
  static const List<Color> primaryGradient = [
    Color(0xFF4F46E5),
    Color(0xFF6A67F5),
  ];

  static const List<Color> secondaryGradient = [
    Color(0xFF14B8A6),
    Color(0xFF2DD4BF),
  ];

  // =================== FUNCTIONAL COLORS ===================
  static Color get textPrimary => onSurfaceLight;
  static Color get textSecondary => onSurfaceVariantLight;
  static Color get textDisabled => onSurfaceVariantLight.withOpacity(0.6);

  static Color get divider => outlineLight;
  static Color get icon => onSurfaceVariantLight;
  static Color get iconActive => primary;

  // =================== CARD COLORS ===================
  static Color get cardBackground => surfaceLight;
  static Color get cardShadow => shadowLight;

  // =================== BUTTON COLORS ===================
  static Color get buttonPrimary => primary;
  static Color get buttonPrimaryText => onPrimary;
  static Color get buttonSecondary => primaryContainer;
  static Color get buttonSecondaryText => primary;
  static Color get buttonDisabled => onSurfaceVariantLight.withOpacity(0.12);
  static Color get buttonDisabledText => onSurfaceVariantLight.withOpacity(0.38);

  // =================== FOR DARK MODE ===================
  static Color darkTextPrimary = onSurfaceDark;
  static Color darkTextSecondary = onSurfaceVariantDark;
  static Color darkTextDisabled = onSurfaceVariantDark.withOpacity(0.6);

  static Color darkDivider = outlineDark;
  static Color darkIcon = onSurfaceVariantDark;
  static Color darkIconActive = primaryLight;

  static Color darkCardBackground = surfaceDark;
  static Color darkCardShadow = shadowDark;

  static Color darkButtonPrimary = primaryLight;
  static Color darkButtonPrimaryText = onPrimary;
  static Color darkButtonSecondary = surfaceVariantDark;
  static Color darkButtonSecondaryText = primaryLight;
  static Color darkButtonDisabled = onSurfaceVariantDark.withOpacity(0.12);
  static Color darkButtonDisabledText = onSurfaceVariantDark.withOpacity(0.38);
}