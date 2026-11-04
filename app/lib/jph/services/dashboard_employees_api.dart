import 'api_service.dart';

class DashboardApi {
  /// 🟢 Dashboard Today
  static Future<Map<String, dynamic>> today(String uid) {
    return ApiService.post({
      "action": "dashboard_today",
      "uid": uid,
    });
  }

  /// Dashboard Month
  static Future<Map<String, dynamic>> month(String uid) {
    return ApiService.post({
      "action": "dashboard_month",
      "uid": uid,
    });
  }

  /// 🟢 Check In / Check Out
  static Future<Map<String, dynamic>> checkIn(
      String uid,
      String name, {
        required String image,
        required String location,
        /// Stable id of the captured photo, so a retry of the same capture is
        /// treated as a retry rather than a new upload. Optional: older callers
        /// that omit it keep working unchanged.
        String? uploadId,
      }) {
    return ApiService.post({
      "action": "checkin",
      "uid": uid,
      "name": name,
      "image": image,
      "location": location,
      if (uploadId != null) "uploadId": uploadId,
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
}