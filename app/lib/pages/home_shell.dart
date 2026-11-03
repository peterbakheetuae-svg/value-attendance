import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../design/glass.dart';
import '../design/glass_bottom_nav.dart';
import 'attendance_page.dart';
import 'dashboard_page.dart';
import 'employees_page.dart';
import 'more_page.dart';
import 'requests_page.dart';

/// Root after sign-in: the original glass bottom navigation, with tabs chosen per role.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    final tabs = <(NavItem, Widget)>[
      (NavItem(Icons.home_rounded, t('dashboard')), DashboardPage(onOpenTab: _openByKey)),
      (NavItem(Icons.fingerprint_rounded, t('attendance')), const AttendancePage()),
      (NavItem(Icons.assignment_rounded, t('requests')), const RequestsPage()),
      if (s.seesTeam) (NavItem(Icons.group_rounded, t('employees')), const EmployeesPage()),
      (NavItem(Icons.grid_view_rounded, t('more')), const MorePage()),
    ];
    if (_index >= tabs.length) _index = 0;
    return Material(
      child: AppBackground(
        safeArea: false,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          extendBody: true,
          body: SafeArea(
            bottom: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: IndexedStack(index: _index, children: [for (final tab in tabs) tab.$2]),
              ),
            ),
          ),
          bottomNavigationBar: GlassBottomNav(
            currentIndex: _index,
            items: [for (final tab in tabs) tab.$1],
            onTap: (i) => setState(() => _index = i),
          ),
        ),
      ),
    );
  }

  void _openByKey(String key) {
    final s = context.read<Session>();
    final order = ['dashboard', 'attendance', 'requests', if (s.seesTeam) 'employees', 'more'];
    final i = order.indexOf(key);
    if (i >= 0) setState(() => _index = i);
  }
}
