import 'api_service.dart';

class PublicHolidaysApi {
  // جلب جميع العطلات الرسمية
  static Future<Map<String, dynamic>> getAllHolidays() async {
    try {
      print('📅 جلب جميع العطلات الرسمية');

      final result = await ApiService.post({
        "action": "getAllPublicHolidays",
      });

      print('📊 استجابة جلب العطلات: ${result.toString()}');

      if (result["success"] == true) {
        return {
          "success": true,
          "holidays": result["holidays"] ?? [],
          "count": result["count"] ?? 0,
          "message": result["message"] ?? "تم جلب البيانات بنجاح",
        };
      } else {
        return {
          "success": false,
          "message": result["message"] ?? "حدث خطأ في جلب البيانات",
          "holidays": [],
          "count": 0,
        };
      }
    } catch (e) {
      print('❌ خطأ في جلب العطلات: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال بالخادم: $e",
        "holidays": [],
        "count": 0,
      };
    }
  }

  // إضافة عطلة جديدة
  static Future<Map<String, dynamic>> addHoliday({
    required String fromDate,
    required String toDate,
    required String holidayType,
    String? description,
  }) async {
    try {
      print('➕ إضافة عطلة جديدة');
      print('  من تاريخ: $fromDate');
      print('  إلى تاريخ: $toDate');
      print('  نوع الإجازة: $holidayType');
      print('  الوصف: ${description ?? "لا يوجد"}');

      return await ApiService.post({
        "action": "addPublicHoliday",
        "fromDate": fromDate,
        "toDate": toDate,
        "holidayType": holidayType,
        "description": description ?? "",
      });
    } catch (e) {
      print('❌ خطأ في إضافة العطلة: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e",
      };
    }
  }

  // تحديث عطلة
  static Future<Map<String, dynamic>> updateHoliday({
    required String holidayId,
    required String fromDate,
    required String toDate,
    required String holidayType,
    String? description,
  }) async {
    try {
      print('✏️ تحديث العطلة: $holidayId');
      print('  من تاريخ: $fromDate');
      print('  إلى تاريخ: $toDate');
      print('  نوع الإجازة: $holidayType');
      print('  الوصف: ${description ?? "لا يوجد"}');

      return await ApiService.post({
        "action": "updatePublicHoliday",
        "holidayId": holidayId,
        "fromDate": fromDate,
        "toDate": toDate,
        "holidayType": holidayType,
        "description": description ?? "",
      });
    } catch (e) {
      print('❌ خطأ في تحديث العطلة: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e",
      };
    }
  }

  // حذف عطلة
  static Future<Map<String, dynamic>> deleteHoliday({
    required String holidayId,
  }) async {
    try {
      print('🗑️ حذف العطلة: $holidayId');

      return await ApiService.post({
        "action": "deletePublicHoliday",
        "holidayId": holidayId,
      });
    } catch (e) {
      print('❌ خطأ في حذف العطلة: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e",
      };
    }
  }

  // جلب العطلات حسب السنة
  static Future<Map<String, dynamic>> getHolidaysByYear({
    required int year,
  }) async {
    try {
      print('📅 جلب العطلات للسنة: $year');

      final result = await ApiService.post({
        "action": "getHolidaysByYear",
        "year": year.toString(),
      });

      if (result["success"] == true) {
        return {
          "success": true,
          "holidays": result["holidays"] ?? [],
          "count": result["count"] ?? 0,
          "message": result["message"] ?? "تم جلب البيانات بنجاح",
        };
      } else {
        return {
          "success": false,
          "message": result["message"] ?? "حدث خطأ في جلب البيانات",
          "holidays": [],
          "count": 0,
        };
      }
    } catch (e) {
      print('❌ خطأ في جلب العطلات حسب السنة: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال بالخادم: $e",
        "holidays": [],
        "count": 0,
      };
    }
  }

  // جلب إحصائيات العطلات
  static Future<Map<String, dynamic>> getHolidaysStats() async {
    try {
      print('📊 جلب إحصائيات العطلات');

      final result = await ApiService.post({
        "action": "getHolidaysStats",
      });

      if (result["success"] == true) {
        return {
          "success": true,
          "stats": result["stats"] ?? {
            "total": 0,
            "thisYear": 0,
            "nextYear": 0,
            "byType": {},
            "byMonth": {},
          },
          "message": result["message"] ?? "تم جلب البيانات بنجاح",
        };
      } else {
        return {
          "success": false,
          "message": result["message"] ?? "حدث خطأ في جلب البيانات",
          "stats": {
            "total": 0,
            "thisYear": 0,
            "nextYear": 0,
            "byType": {},
            "byMonth": {},
          },
        };
      }
    } catch (e) {
      print('❌ خطأ في جلب إحصائيات العطلات: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال بالخادم: $e",
        "stats": {
          "total": 0,
          "thisYear": 0,
          "nextYear": 0,
          "byType": {},
          "byMonth": {},
        },
      };
    }
  }
}