import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_colors.dart';
import 'glass_ui.dart';

/* ===================== PAGE HEADER ===================== */

class PageHeader extends StatelessWidget {
  final String title;
  final bool useTranslation;

  const PageHeader({
    super.key,
    required this.title,
    this.useTranslation = true,
  });

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    final textColor = isDark
        ? AppColors.onSurfaceDark
        : AppColors.onSurfaceLight;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        useTranslation ? AppLocalizations.of(context, title) : title,
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: textColor,
        ),
      ),
    );
  }
}

/* ===================== GLASS CARD ===================== */

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? backgroundColor;
  final bool showShadow;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 26,
    this.backgroundColor,
    this.showShadow = true,
  });

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    final bgColor = backgroundColor ?? Colors.transparent;
    final borderColor = isDark
        ? AppColors.outlineDark.withOpacity(0.3)
        : Colors.white.withOpacity(0.30);

    final shadowColor = isDark
        ? Colors.black.withOpacity(0.30)
        : Colors.black.withOpacity(0.12);

    final blurSigma = isDark ? 18.0 : 14.0;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: borderColor, width: 1.0),
            boxShadow: showShadow
                ? [
              BoxShadow(
                blurRadius: 28,
                offset: const Offset(0, 14),
                color: shadowColor,
              ),
            ]
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}

/* ===================== INFO TILE ===================== */

class InfoTile extends StatelessWidget {
  final String title;
  final String value;
  final bool useTranslation;

  const InfoTile({
    super.key,
    required this.title,
    required this.value,
    this.useTranslation = true,
  });

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    final titleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : Colors.black54;

    final valueColor = isDark
        ? AppColors.onSurfaceDark
        : Colors.black;

    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              useTranslation ? AppLocalizations.of(context, title) : title,
              style: TextStyle(color: titleColor),
            ),
            Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: valueColor,
              ),
            ),
          ],
        )
    );
  }
}

/* ===================== SETTING TILE ===================== */

class SettingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  final bool showTrailing;
  final Color? iconColor;

  const SettingTile({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.showTrailing = true,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    final textColor = isDark
        ? AppColors.onSurfaceDark
        : Colors.black;

    final iconColorFinal = iconColor ?? (isDark
        ? AppColors.primaryLight
        : AppColors.primary);

    final trailingColor = isDark
        ? AppColors.onSurfaceVariantDark
        : Ar.grey;

    return ListTile(
      leading: Icon(
        icon,
        color: iconColorFinal,
      ),
      title: Text(
        AppLocalizations.of(context, title),
        style: TextStyle(color: textColor),
      ),
      trailing: showTrailing
          ? Icon(Icons.chevron_right, color: trailingColor)
          : null,
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }
}

/* ===================== GLASS DIVIDER ===================== */

class GlassDivider extends StatelessWidget {
  final double thickness;
  final EdgeInsets margin;

  const GlassDivider({
    super.key,
    this.thickness = 1.0,
    this.margin = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    final color = isDark
        ? AppColors.outlineDark.withOpacity(0.2)
        : Colors.black.withOpacity(0.08);

    return Container(
      margin: margin,
      height: thickness,
      color: color,
    );
  }
}

/* ===================== ID ROW ===================== */

class IdRow extends StatelessWidget {
  final String title;
  final String value;
  final bool useTranslation;

  const IdRow(
      this.title,
      this.value, {
        super.key,
        this.useTranslation = true,
      });

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    final titleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : Colors.black54;

    final valueColor = isDark
        ? AppColors.onSurfaceDark
        : Colors.black;

    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              useTranslation ? AppLocalizations.of(context, title) : title,
              style: TextStyle(color: titleColor),
            ),
            Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: valueColor,
              ),
            ),
          ],
        )
    );
  }
}