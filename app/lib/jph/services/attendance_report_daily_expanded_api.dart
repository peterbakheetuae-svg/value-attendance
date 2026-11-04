import 'api_service.dart';

class AttendanceReportDailyExpandedApi {
  static Future<Map<String, dynamic>> fetch({
    required String uid,
    required String from,
    required String to,
  }) async {
    try {
      final response = await ApiService.post({
        "action": "attendance_report_daily_expanded",
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

          // التحويل الآمن للقيم
          if (value == null) {
            convertedDay[key] = '--';
          } else if (key == 'startImage' || key == 'endImage') {
            // الحفاظ على رابط الصورة
            convertedDay[key] = value.toString();
          } else {
            convertedDay[key] = value.toString();
          }
        }

        // 🔥 إضافة حقل معرف فريد للبطاقة
        convertedDay['cardId'] = '${day['date']}_${day['startTime']}_${DateTime.now().microsecondsSinceEpoch}';

        convertedDays.add(convertedDay);
      }
    }

    return convertedDays;
  }
}