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
import 'app_nav.dart';
import 'app_menu.dart';
import 'glass_ui.dart';

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


    // the website on a computer: the side bar takes the bottom bar's place
    if (AppMenu.wide(context)) return const SizedBox.shrink();

    // the «Ardena» dock: smoked glass, the chosen tab filled with our blue
    const activeColor = Glass.blue;
    final inactiveColor = Glass.ink(isDark).withOpacity(0.85);

    return SafeArea(
      top: false,
      // on a wide screen (the website on a computer) the bar keeps a phone-like width, centred
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 22),
        child: RepaintBoundary(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(40),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: 24,
                sigmaY: 24,
              ),
              child: DecoratedBox(
                decoration: Glass.panel(isDark, r: 40),
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
                        // المالك / المدير العام and the accountant: «المالية» right after the home
                        if (AppNav.financeTab)
                          _Item(
                            icon: Icons.account_balance_wallet_rounded,
                            label: 'المالية',
                            active: currentIndex == 5,
                            onTap: () => onTap(5),
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
                        // «المزيد»: every page of the app in one sheet (the settings page is inside it)
                        _Item(
                          icon: Icons.more_horiz_rounded,
                          label: 'المزيد',
                          active: currentIndex == 3,
                          onTap: () => AppMenu.showMore(context),
                          isDark: isDark,
                          activeColor: activeColor,
                          inactiveColor: inactiveColor,
                        ),
                        if (!AppNav.financeTab)
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
        duration: const Duration(milliseconds: 350),
        curve: Glass.ease,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: active ? activeColor : Colors.transparent,
          boxShadow: active ? [BoxShadow(color: activeColor.withOpacity(0.35), blurRadius: 14, offset: const Offset(0, 5))] : null,
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