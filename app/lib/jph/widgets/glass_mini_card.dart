import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import '../theme/app_colors.dart';
import 'glass_ui.dart';

class GlassMiniCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData? icon;
  final Color? iconColor;
  final Color? backgroundColor;
  final double? height;

  const GlassMiniCard({
    super.key,
    required this.title,
    required this.value,
    this.icon,
    this.iconColor,
    this.backgroundColor,
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context, listen: false);
    final isDark = appController.isDark;

    // 🔥 الألوان الديناميكية بناءً على الثيم
    final defaultBgColor = isDark
        ? AppColors.surfaceVariantDark.withOpacity(0.7)
        : AppColors.surfaceVariantLight.withOpacity(0.7);

    final defaultTitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;

    final defaultValueColor = isDark
        ? AppColors.onSurfaceDark
        : AppColors.onSurfaceLight;

    final defaultIconColor = iconColor ?? (isDark
        ? AppColors.primaryLight
        : AppColors.primary);

    return Container(
      height: height ?? 90, // 🔥 ارتفاع مناسب
      // the dashboard's card (the «Ardena» glass square); a given colour still wins
      decoration: backgroundColor != null ? Glass.panel(isDark, r: 16).copyWith(color: backgroundColor, gradient: null) : Glass.panel(isDark, r: 16),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 🔥 الصف العلوي: الأيقونة + العنوان
            Row(
              children: [
                if (icon != null) ...[
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: defaultIconColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      icon,
                      size: 16,
                      color: defaultIconColor,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 12,
                      color: defaultTitleColor,
                      fontWeight: FontWeight.w500,
                      height: 1.2,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // 🔥 القيمة
            Text(
              value,
              style: TextStyle(
                fontSize: 18,
                color: defaultValueColor,
                fontWeight: FontWeight.w700,
                height: 1.1,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}