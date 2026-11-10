import 'package:flutter/material.dart';

import '../pages/attendance/attendance_report_page.dart';
import '../pages/dashboard_employees/dashboard_page_team.dart';
import '../pages/dashboard_employers/dashboard_page.dart';
import '../pages/employees/employees_page.dart';
import '../pages/profile/profile_page.dart';
import '../pages/settings/settings_page.dart';
import '../services/api_service.dart';
import '../services/jph_bridge.dart';

/// One place that decides where the bottom-bar tabs go, so an employee never lands on
/// the admin home or the employees list (the server refuses the data anyway).
class AppNav {
  /// Managers / HR / owner get the admin home (company or team totals); everyone else the employee home.
  static bool get adminHome =>
      JphBridge.session.role == 'owner' || ApiService.can('attendance.read_all') || ApiService.can('attendance.read_team');

  /// how many home pages are alive (set by the two home pages) — the home is always the bottom of the stack
  static int homeAlive = 0;

  static bool get seesEmployees => ApiService.can('employee.read_all') || ApiService.can('employee.read_team');

  static Widget home({required String uid, required String name, required String role, String photo = ''}) => adminHome
      ? DashboardPage(uid: uid, name: name, role: role, photo: photo)
      : DashboardPageTeam(uid: uid, name: name, role: role, photo: photo);

  /// Tabs: 0 home · 1 attendance report · 2 employees · 3 settings · 4 profile.
  static void go(BuildContext context, int index,
      {required int current, required String uid, required String name, required String role, String photo = ''}) {
    if (index == current) return;
    if (index == 0) {
      // the home is already open under this page: go back to it as it is (no reloading the whole app)
      if (homeAlive > 0) {
        Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => home(uid: uid, name: name, role: role, photo: photo)), (r) => false);
      return;
    }
    final Widget? page = switch (index) {
      1 => AttendanceReportPage(uid: uid, name: name, role: role),
      2 => seesEmployees ? EmployeesPage(currentUserId: uid, currentUserName: name, currentUserRole: role) : null,
      3 => SettingsPage(uid: uid, name: name, role: role),
      4 => ProfilePage(uid: uid, name: name, role: role, photo: photo),
      _ => null,
    };
    if (page != null) Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }
}
