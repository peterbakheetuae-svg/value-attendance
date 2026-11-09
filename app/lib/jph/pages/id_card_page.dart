import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart'; // ✅ أضف هذا

import '../services/app_controller.dart'; // ✅ أضف هذا
import '../l10n/app_localizations.dart'; // ✅ أضف هذا
import '../theme/app_colors.dart'; // ✅ أضف هذا
import '../widgets/glass_ui_widgets.dart';
import '../widgets/app_background.dart'; // ✅ أضف هذا - بدل GlassBackground
import '../widgets/app_nav.dart';
import '../widgets/glass_bottom_nav.dart';

class IdCardPage extends StatelessWidget {
  final String uid;
  final String name;
  final String role;

  const IdCardPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;
        final isRTL = appController.isRTL;

        return AppBackground( // ✅ استبدل GlassBackground بـ AppBackground
          child: Directionality(
            textDirection: isRTL ? TextDirection.rtl : TextDirection.ltr,
            child: Scaffold(
              extendBody: true,
              backgroundColor: Colors.transparent,
              bottomNavigationBar: GlassBottomNav(
                currentIndex: 1, // لأن IdCard هو الفهرس 1
                onTap: (index) => AppNav.go(context, index, current: -1, uid: uid, name: name, role: role),
              ),
              body: SafeArea(
                bottom: false,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
                  children: [
                    PageHeader(title: AppLocalizations.of(context, 'id_card')), // ✅ ترجمة
                    const SizedBox(height: 20),

                    GlassCard(
                      child: Column(
                        children: [
                          Icon(
                            Icons.badge,
                            size: 64,
                            color: isDark ? AppColors.primaryLight : AppColors.primary,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            name, // ✅ استخدم الاسم الحقيقي
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            "EMP-$uid", // ✅ استخدم uid الحقيقي
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: isDark ? AppColors.onSurfaceVariantDark : Colors.black45,
                            ),
                          ),
                          const SizedBox(height: 16),

                          IdRow(AppLocalizations.of(context, 'department'), "Construction"), // ✅ ترجمة
                          IdRow(AppLocalizations.of(context, 'role'), role), // ✅ استخدم الدور الحقيقي
                          IdRow(AppLocalizations.of(context, 'join_date'), "01/02/2023"), // ✅ ترجمة
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}