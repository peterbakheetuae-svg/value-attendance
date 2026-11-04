import 'dart:convert';
import 'api_service.dart';

class DashboardApi {
  /// 🟢 بيانات لوحة التحكم الأساسية
  static Future<Map<String, dynamic>> getDashboardData(String uid) {
    return ApiService.post({
      "action": "get_dashboard_data",
      "uid": uid,
    });
  }

  /// 🟢 طلبات الإجازة
  static Future<Map<String, dynamic>> getLeaveRequests(String uid) {
    return ApiService.post({
      "action": "get_leave_requests",
      "uid": uid,
    });
  }

  /// 🟢 طلبات المالية (جميع الأنواع)
  static Future<Map<String, dynamic>> getLoanRequests(String uid) {
    return ApiService.post({
      "action": "get_loan_requests",
      "uid": uid,
    });
  }

  /// 🟢 إحصائيات اليوم
  static Future<Map<String, dynamic>> getTodayStats(String uid) {
    return ApiService.post({
      "action": "get_today_stats",
      "uid": uid,
    });
  }

  /// 🟢 الحضور حسب المشروع
  static Future<Map<String, dynamic>> getAttendanceByProject(String uid) {
    return ApiService.post({
      "action": "get_attendance_by_project",
      "uid": uid,
    });
  }

  /// 🟢 الموظفين الحاضرين اليوم
  static Future<Map<String, dynamic>> getTodayAttendance(String uid) {
    return ApiService.post({
      "action": "get_today_attendance",
      "uid": uid,
    });
  }

  /// 🟢 الموظفين في الاستراحة
  static Future<Map<String, dynamic>> getBreakEmployees(String uid) {
    return ApiService.post({
      "action": "get_break_employees",
      "uid": uid,
    });
  }

  /// 🟢 Check In / Check Out
  static Future<Map<String, dynamic>> checkIn(
      String uid,
      String name, {
        required String image,
        required String location,
      }) {
    return ApiService.post({
      "action": "checkin",
      "uid": uid,
      "name": name,
      "image": image,
      "location": location,
    });
  }

  /// ☕ Break Start
  static Future<Map<String, dynamic>> breakStart(String uid) {
    return ApiService.post({
      "action": "break_start",
      "uid": uid,
    });
  }

  /// ☕ Break End
  static Future<Map<String, dynamic>> breakEnd(String uid) {
    return ApiService.post({
      "action": "break_end",
      "uid": uid,
    });
  }

  /// ✅ الموافقة على طلب إجازة
  static Future<Map<String, dynamic>> approveLeaveRequest(String requestId, String uid) {
    return ApiService.post({
      "action": "approve_leave_request",
      "request_id": requestId,
      "uid": uid,
    });
  }

  /// ✅ رفض طلب إجازة
  static Future<Map<String, dynamic>> rejectLeaveRequest(String requestId, String uid) {
    return ApiService.post({
      "action": "reject_leave_request",
      "request_id": requestId,
      "uid": uid,
    });
  }

  /// ✅ الموافقة على طلب مالي (جميع الأنواع)
  static Future<Map<String, dynamic>> approveLoanRequest(String requestId, String uid) {
    // ترميز requestId للتأكد من سلامة النقل
    final encodedId = Uri.encodeComponent(requestId);

    return ApiService.post({
      "action": "approve_loan_request",
      "request_id": encodedId,
      "uid": uid,
    });
  }

  /// ✅ رفض طلب مالي (جميع الأنواع)
  static Future<Map<String, dynamic>> rejectLoanRequest(String requestId, String uid) {
    // ترميز requestId للتأكد من سلامة النقل
    final encodedId = Uri.encodeComponent(requestId);

    return ApiService.post({
      "action": "reject_loan_request",
      "request_id": encodedId,
      "uid": uid,
    });
  }

  /// 🟢 ديبق: طباعة تفاصيل الطلب
  static void debugRequest(String requestId, String uid, String action) {
    print('''
📋 === ديبق طلب API ===
🔍 الإجراء: $action
🆔 معرف الطلب: $requestId
👤 UID المستخدم: $uid
📅 التاريخ: ${DateTime.now()}
🔚 ===================
''');
  }

  /// 🟢 ديبق: طباعة النتيجة
  static void debugResponse(Map<String, dynamic> result, String action) {
    print('''
📋 === ديبق نتيجة API ===
🔍 الإجراء: $action
✅ النجاح: ${result["success"]}
📝 الرسالة: ${result["message"]}
📊 عدد العناصر: ${result.length}
🔚 =====================
''');
  }
}