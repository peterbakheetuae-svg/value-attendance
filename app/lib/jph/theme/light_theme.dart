import 'package:flutter/material.dart';
import 'app_colors.dart';
import '../widgets/glass_ui.dart';

class LightTheme {
  static ThemeData get theme {
    final baseTheme = ThemeData.light();

    return baseTheme.copyWith(
      useMaterial3: true,
      colorScheme: const ColorScheme.light(
        primary: AppColors.primary,
        onPrimary: AppColors.onPrimary,
        secondary: AppColors.secondary,
        onSecondary: AppColors.onSecondary,
        background: AppColors.backgroundLight,
        onBackground: AppColors.onBackgroundLight,
        surface: AppColors.surfaceLight,
        onSurface: AppColors.onSurfaceLight,
        error: AppColors.error,
        onError: AppColors.onPrimary,
      ),

      // ✅ تعريف كامل لـ textTheme مع الألوان المحددة
      textTheme: TextTheme(
        displayLarge: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 34,
          fontWeight: FontWeight.bold,
          color: AppColors.onSurfaceLight,
        ),
        displayMedium: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 26,
          fontWeight: FontWeight.bold,
          color: AppColors.onSurfaceLight,
        ),
        displaySmall: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: AppColors.onSurfaceLight,
        ),
        headlineLarge: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: AppColors.onSurfaceLight,
        ),
        headlineMedium: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: AppColors.onSurfaceLight,
        ),
        headlineSmall: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: AppColors.onSurfaceLight,
        ),
        titleLarge: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: AppColors.onSurfaceLight,
        ),
        titleMedium: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: AppColors.onSurfaceLight,
        ),
        titleSmall: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: AppColors.onSurfaceVariantLight,
        ),
        bodyLarge: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 15,
          color: AppColors.onSurfaceLight,
        ),
        bodyMedium: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 14,
          color: AppColors.onSurfaceLight,
        ),
        bodySmall: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 12.5,
          color: AppColors.onSurfaceVariantLight,
        ),
        labelLarge: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
          color: AppColors.onPrimary,
        ),
        labelMedium: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          color: AppColors.onPrimary,
        ),
        labelSmall: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 11,
          color: AppColors.onSurfaceVariantLight,
        ),
      ),

      // ✅ تعريف primaryTextTheme أيضًا
      primaryTextTheme: TextTheme(
        bodyLarge: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 16,
          color: AppColors.onPrimary,
        ),
        bodyMedium: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 14,
          color: AppColors.onPrimary,
        ),
        labelLarge: TextStyle(
          fontFamily: 'Cairo',
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AppColors.onPrimary,
        ),
      ),

      // pop-up messages: floating, rounded, translucent like the rest of the glass UI
      // pages fade in and rise a little (the «Ardena» site), on every platform
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: GlassPageTransitions(),
        TargetPlatform.iOS: GlassPageTransitions(),
        TargetPlatform.windows: GlassPageTransitions(),
        TargetPlatform.macOS: GlassPageTransitions(),
        TargetPlatform.linux: GlassPageTransitions(),
        TargetPlatform.fuchsia: GlassPageTransitions(),
      }),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: const Color(0xE6303040),
        contentTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: Color(0x40FFFFFF))),
      ),
      // the page behind a form / sheet stays in the dark (it must not show through)
      bottomSheetTheme: BottomSheetThemeData(modalBarrierColor: Colors.black.withOpacity(0.45)),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xEBFFFFFF),
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26), side: const BorderSide(color: Color(0x40FFFFFF))),
      ),
      cardTheme: baseTheme.cardTheme.copyWith(
        color: AppColors.surfaceLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        margin: EdgeInsets.zero,
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        ),
      ),
    );
  }
}