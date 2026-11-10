import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import '../l10n/app_localizations.dart';
import '../services/session_service.dart';
import '../theme/app_colors.dart';
import '../pages/attendance/attendance_report_page.dart'; // 🔥 استيراد صفحة تقارير الحضور الجديدة
import '../services/api_service.dart';
import '../pages/employees/employees_page.dart'; // أو المسار الصحيح

class GlassBottomNav extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const GlassBottomNav({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;
    final isRTL = appController.isRTL;

    // 🔥 ألوان ديناميكية
    final bgOpacity = isDark ? 0.15 : 0.15;
    final borderOpacity = isDark ? 0.25 : 0.25;
    final shadowOpacity = isDark ? 0.15 : 0.12;
    final blurSigma = isDark ? 14.0 : 12.0;

    final activeColor = isDark ? AppColors.primaryLight : AppColors.primary;
    final inactiveColor = isDark ? Colors.white70 : Colors.black54;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 22),
        child: RepaintBoundary(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(40),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: blurSigma,
                sigmaY: blurSigma,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(bgOpacity),
                  borderRadius: BorderRadius.circular(40),
                  border: Border.all(
                    color: Colors.white.withOpacity(borderOpacity),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(shadowOpacity),
                      blurRadius: 22,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: SizedBox(
                  height: 72,
                  child: Directionality(
                    textDirection: isRTL ? TextDirection.rtl : TextDirection.ltr,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _Item(
                          icon: Icons.home_rounded,
                          label: AppLocalizations.of(context, 'dashboard'),
                          active: currentIndex == 0,
                          onTap: () => onTap(0),
                          isDark: isDark,
                          activeColor: activeColor,
                          inactiveColor: inactiveColor,
                        ),
                        _Item(
                            icon: Icons.assignment_rounded,
                            label: AppLocalizations.of(context, 'attendance_report'),
                            active: currentIndex == 1,
                            onTap: () => onTap(1),
                            isDark: isDark,
                            activeColor: activeColor,
                            inactiveColor: inactiveColor,
                          ),
                        if (ApiService.can('employee.read_all'))
                        _Item(
                          icon: Icons.group_rounded,
                          label: AppLocalizations.of(context, 'Employees'),
                          active: currentIndex == 2,
                          onTap: () => onTap(2),
                          isDark: isDark,
                          activeColor: activeColor,
                          inactiveColor: inactiveColor,
                        ),
                        _Item(
                          icon: Icons.settings_rounded,
                          label: AppLocalizations.of(context, 'settings'),
                          active: currentIndex == 3,
                          onTap: () => onTap(3),
                          isDark: isDark,
                          activeColor: activeColor,
                          inactiveColor: inactiveColor,
                        ),
                        _Item(
                          icon: Icons.person_rounded,
                          label: AppLocalizations.of(context, 'profile'),
                          active: currentIndex == 4,
                          onTap: () => onTap(4),
                          isDark: isDark,
                          activeColor: activeColor,
                          inactiveColor: inactiveColor,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Item extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  final bool isDark;
  final Color activeColor;
  final Color inactiveColor;

  const _Item({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    required this.isDark,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    final foregroundColor = active ? Colors.white : inactiveColor;

    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: active ? activeColor.withOpacity(0.95) : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: [
            Icon(icon, color: foregroundColor, size: 22),
            if (active) ...[
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: foregroundColor,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}