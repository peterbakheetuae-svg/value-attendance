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
import '../pages/leads/leads_api.dart' show seesLeads, tr;
import '../services/jph_bridge.dart';

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

    // نظام الليدز: المدير العام / المحاسب get «لوحة السيلز» in «الموظفين»'s place; a salesman gets it before «المزيد»
    // instead of «الملف الشخصي» (which stays in «المزيد»)
    final role = JphBridge.session.role;
    final gmOrAccountant = role == 'owner' || role == 'manager' || role == 'accountant'; // المالك / المدير العام / المحاسب
    final leads = seesLeads;
    final leadsItem = _Item(
      icon: Icons.leaderboard_rounded,
      label: tr('لوحة السيلز'),
      active: currentIndex == 6,
      onTap: () => onTap(6),
      isDark: isDark,
      activeColor: Glass.blue,
      inactiveColor: Glass.ink(isDark).withOpacity(0.85),
    );

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
            borderRadius: BorderRadius.circular(26),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: 24,
                sigmaY: 24,
              ),
              child: DecoratedBox(
                decoration: Glass.panel(isDark, r: 26),
                child: SizedBox(
                  height: 66,
                  child: Directionality(
                    textDirection: isRTL ? TextDirection.rtl : TextDirection.ltr,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: AppNav.settled
                          ? [
                              _Item(
                                icon: Icons.assignment_rounded,
                                label: AppLocalizations.of(context, 'attendance_report'),
                                active: currentIndex == 1 || currentIndex == 0,
                                onTap: () => onTap(1),
                                isDark: isDark,
                                activeColor: activeColor,
                                inactiveColor: inactiveColor,
                              ),
                              _Item(
                                icon: Icons.more_horiz_rounded,
                                label: 'المزيد',
                                active: currentIndex == 3,
                                onTap: () => AppMenu.showMore(context),
                                isDark: isDark,
                                activeColor: activeColor,
                                inactiveColor: inactiveColor,
                              ),
                            ]
                          : [
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
                        // المدير العام / المحاسب: «لوحة السيلز» before تقرير الحضور (no «الموظفين» on the bar; it is in «المزيد»)
                        if (leads && gmOrAccountant) leadsItem,
                        _Item(
                            icon: Icons.assignment_rounded,
                            label: AppLocalizations.of(context, 'attendance_report'),
                            active: currentIndex == 1,
                            onTap: () => onTap(1),
                            isDark: isDark,
                            activeColor: activeColor,
                            inactiveColor: inactiveColor,
                          ),
                        if (ApiService.can('employee.read_all') && !(leads && gmOrAccountant))
                        _Item(
                          icon: Icons.group_rounded,
                          label: AppLocalizations.of(context, 'Employees'),
                          active: currentIndex == 2,
                          onTap: () => onTap(2),
                          isDark: isDark,
                          activeColor: activeColor,
                          inactiveColor: inactiveColor,
                        ),
                        if (leads && !gmOrAccountant && !AppNav.financeTab) leadsItem,
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
                        if (!AppNav.financeTab && !leads)
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
            Icon(icon, color: foregroundColor, size: 20),
            if (active) ...[
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: foregroundColor,
                  fontWeight: FontWeight.w600,
                  fontSize: 10.5,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}