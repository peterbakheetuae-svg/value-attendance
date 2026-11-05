import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'device_id.dart';
import 'shift_tracker.dart';

/// Signed-in user, permissions and the API client. Permissions only shape the UI —
/// the server enforces every one of them independently.
class Session extends ChangeNotifier {
  final ApiClient api;
  Map<String, dynamic>? me;
  Map<String, dynamic>? company;
  Set<String> permissions = {};
  bool mustChangePassword = false;
  bool restoring = true;

  Session(this.api) {
    api.onUnauthorized = () {
      if (api.token != null) _clear();
    };
  }

  bool get signedIn => api.token != null && me != null;
  String get id => me?['id']?.toString() ?? '';
  String get name => me?['full_name']?.toString() ?? '';
  String get role => me?['role_key']?.toString() ?? '';
  bool has(String p) => permissions.contains(p);
  bool get managesTeam => me?['manages_team'] == true || role == 'sales_manager';
  bool get gpsRequired => company?['gps_required'] == true;
  bool get allowPin => company?['allow_pin'] == true;
  bool get canUsePin => allowPin && (role == 'sales_employee' || role == 'sales_manager');

  bool get isOwner => role == 'owner';
  bool get canApprove => has('request.approve_manager') || has('request.approve_hr');
  bool get seesTeam => has('employee.read_all') || has('employee.read_team');
  bool get seesReports => has('report.read_all') || has('report.read_team');
  bool get seesPayroll => has('report.payroll') || has('finance.read');
  bool get configuresKpi => has('kpi.config');
  bool get isAdmin => has('org.manage') || has('attendance.config') || has('settings.manage') || has('roles.manage');

  Future<void> restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      final tok = p.getString('token');
      if (tok != null) {
        api.token = tok;
        // open instantly from the last known profile; refresh from the server in the background
        final cached = p.getString('me_cache');
        if (cached != null) {
          try {
            _apply(jsonDecode(cached) as Map<String, dynamic>);
            refreshMe().catchError((_) {});
            return;
          } catch (_) {}
        }
        await refreshMe();
      }
    } catch (_) {
      api.token = null;
    } finally {
      restoring = false;
      notifyListeners();
    }
  }

  Future<void> login(String identifier, String password) async {
    String? device;
    try { device = await DeviceId.get(); } catch (_) {}
    final r = await api.post('/auth/login', {'identifier': identifier, 'password': password,
      if (device != null) 'deviceId': device, 'deviceLabel': DeviceId.label()});
    api.token = r['token'] as String;
    try { (await SharedPreferences.getInstance()).setString('token', api.token!); } catch (_) {}
    await refreshMe();
  }

  Future<void> refreshMe() async {
    final r = await api.get('/me');
    try { (await SharedPreferences.getInstance()).setString('me_cache', jsonEncode(r)); } catch (_) {}
    _apply(r);
  }

  void _apply(Map<String, dynamic> r) {
    me = r['employee'] as Map<String, dynamic>;
    company = r['company'] as Map<String, dynamic>?;
    permissions = ((r['permissions'] as List?) ?? const []).map((e) => e.toString()).toSet();
    mustChangePassword = me?['must_change_password'] == true;
    notifyListeners();
  }

  Future<void> changePassword(String current, String next) async {
    await api.post('/auth/change-password', {'currentPassword': current, 'newPassword': next});
    mustChangePassword = false;
    await refreshMe();
  }

  Future<void> logout() async {
    // send anything recorded offline first, but never let a slow network keep the user signed in
    try { await api.flushQueue().timeout(const Duration(seconds: 6)); } catch (_) {}
    try { await api.post('/auth/logout').timeout(const Duration(seconds: 4)); } catch (_) {}
    await ApiClient.clearOffline();
    await _clear();
  }

  Future<void> _clear() async {
    await ShiftTracker.instance.stop();
    api.token = null;
    me = null;
    permissions = {};
    try {
      final p = await SharedPreferences.getInstance();
      await p.remove('token');
      await p.remove('me_cache');
    } catch (_) {}
    notifyListeners();
  }
}
