import 'api_service.dart';

class AttendanceReportDailyApi {
  static Future<Map<String, dynamic>> fetch({
    required String uid,
    required String from,
    required String to,
  }) async {
    try {
      final response = await ApiService.post({
        "action": "attendance_report_daily",
        "uid": uid,
        "from": from,
        "to": to,
      });

      // ✅ تحويل البيانات اليومية
      if (response["success"] == true && response["days"] != null) {
        response["days"] = _convertDailyData(response["days"]);
      }

      return response;
    } catch (e) {
      return {
        "success": false,
        "message": "خطأ في الاتصال: $e",
        "days": [],
      };
    }
  }

  // ✅ دالة لتحويل بيانات الأيام
  static List<Map<String, dynamic>> _convertDailyData(dynamic daysData) {
    if (daysData is! List) {
      return [];
    }

    final List<Map<String, dynamic>> convertedDays = [];

    for (final day in daysData) {
      if (day is Map<String, dynamic>) {
        final Map<String, dynamic> convertedDay = {};

        for (final key in day.keys) {
          final value = day[key];

          // المفاتيح المتوقعة: date, start, end, work
          if (key == 'date') {
            convertedDay[key] = value?.toString() ?? '';
          } else if (key == 'start' || key == 'end' || key == 'work') {
            convertedDay[key] = value?.toString() ?? '--';
          } else {
            // لأي مفاتيح إضافية
            convertedDay[key] = value;
          }
        }

        convertedDays.add(convertedDay);
      }
    }

    return convertedDays;
  }
}