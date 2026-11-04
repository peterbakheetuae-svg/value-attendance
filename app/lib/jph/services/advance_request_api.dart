// services/advance_request_api.dart
import 'api_service.dart';

class AdvanceRequestApi {
  // إرسال طلب سلف/مصاريف جديد (للموظف نفسه)
  static Future<Map<String, dynamic>> submitAdvanceRequest({
    required String uid,
    required String requestType,
    required String month,
    required double amount,
    required String note,
    String? image,
  }) async {
    final data = {
      "action": "submitAdvanceRequest",
      "uid": uid,
      "requestType": requestType,
      "month": month,
      "amount": amount,
      "note": note,
      "image": image ?? "",
    };

    print('📤 إرسال طلب سلفة/مصاريف:');
    print('  action: ${data["action"]}');
    print('  uid: $uid');
    print('  requestType: $requestType');
    print('  month: $month');
    print('  amount: $amount');
    print('  note: ${note.length} حرف');
    print('  image: ${image != null ? "موجود" : "غير موجود"}');

    return ApiService.post(data);
  }

  // إرسال طلب سلف/مصاريف بواسطة المدير لموظف آخر
  static Future<Map<String, dynamic>> submitAdvanceRequestByManager({
    required String uid, // المدير
    required String employeeId, // الموظف المختار
    required String requestType,
    required String month,
    required double amount,
    required String note,
    String? image,
    String ceoConfirm = "مؤكد",
    String status = "مؤكد",
  }) async {
    final data = {
      "action": "submitAdvanceRequestByManager",
      "uid": uid, // المدير
      "employeeId": employeeId, // الموظف
      "requestType": requestType,
      "month": month,
      "amount": amount,
      "note": note,
      "image": image ?? "",
      "ceoConfirm": ceoConfirm,
      "reviewedBy": uid, // المدير
      "status": status,
    };

    print('📤 إرسال طلب سلفة/مصاريف من قبل المدير:');
    print('  action: ${data["action"]}');
    print('  uid (المدير): $uid');
    print('  employeeId: $employeeId');
    print('  requestType: $requestType');
    print('  month: $month');
    print('  amount: $amount');
    print('  note: ${note.length} حرف');
    print('  image: ${image != null ? "موجود" : "غير موجود"}');
    print('  ceoConfirm: $ceoConfirm');
    print('  status: $status');

    return ApiService.post(data);
  }

  // جلب طلبات السلف والمصاريف للمستخدم
  static Future<Map<String, dynamic>> getAdvanceRequests(String uid) async {
    print('📤 جلب طلبات السلف/المصاريف لـ UID: $uid');

    final result = await ApiService.post({
      "action": "getAdvanceRequests",
      "uid": uid,
    });

    // التأكد من أن stats موجودة
    if (result["success"] == true && result["stats"] != null) {
      return {
        "success": true,
        "stats": result["stats"],
        "requests": result["requests"] ?? [],
      };
    } else {
      return {
        "success": result["success"] ?? false,
        "message": result["message"] ?? "حدث خطأ في جلب البيانات",
        "stats": {
          "total": 0,
          "confirmed": 0,
          "pending": 0,
          "rejected": 0,
          "cancelled": 0,
          "totalAmount": 0.0,
        },
        "requests": [],
      };
    }
  }

  // إلغاء طلب سلف/مصاريف
  static Future<Map<String, dynamic>> cancelAdvanceRequest({
    required String uid,
    required String requestId,
  }) async {
    print('🗑️ إلغاء طلب السلف/المصاريف:');
    print('  uid: $uid');
    print('  requestId: $requestId');

    return ApiService.post({
      "action": "cancelAdvanceRequest",
      "uid": uid,
      "requestId": requestId,
    });
  }

  // جلب جميع طلبات السلف والمصاريف (للمدير/صاحب العمل)
  static Future<Map<String, dynamic>> getAllAdvanceRequests() async {
    try {
      print('👔 جلب جميع طلبات السلف/المصاريف (للمدير)');

      final result = await ApiService.post({
        "action": "getAllAdvanceRequests",
      });

      print('📊 استجابة جلب جميع طلبات السلف/المصاريف: ${result.toString()}');

      if (result["success"] == true) {
        final stats = result["stats"] ?? {};

        return {
          "success": true,
          "stats": {
            "total": stats["total"] ?? 0,
            "confirmed": stats["confirmed"] ?? 0,
            "pending": stats["pending"] ?? 0,
            "rejected": stats["rejected"] ?? 0,
            "cancelled": stats["cancelled"] ?? 0,
            "totalAmount": stats["totalAmount"] ?? 0.0,
          },
          "requests": result["requests"] ?? [],
          "count": result["count"] ?? (result["requests"]?.length ?? 0),
          "message": result["message"] ?? "تم جلب البيانات بنجاح",
        };
      } else {
        return {
          "success": result["success"] ?? false,
          "message": result["message"] ?? "حدث خطأ في جلب البيانات",
          "stats": {
            "total": 0,
            "confirmed": 0,
            "pending": 0,
            "rejected": 0,
            "cancelled": 0,
            "totalAmount": 0.0,
          },
          "requests": [],
          "count": 0,
        };
      }
    } catch (e) {
      print('❌ خطأ في جلب جميع طلبات السلف/المصاريف: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال بالخادم: $e",
        "stats": {
          "total": 0,
          "confirmed": 0,
          "pending": 0,
          "rejected": 0,
          "cancelled": 0,
          "totalAmount": 0.0,
        },
        "requests": [],
        "count": 0,
      };
    }
  }

  // الموافقة على طلب سلف/مصاريف
  static Future<Map<String, dynamic>> approveAdvanceRequest(String requestId, String uid) async {
    try {
      print('✅ الموافقة على طلب سلفة/مصاريف: $requestId بواسطة $uid');
      return await ApiService.post({
        "action": "approveAdvanceRequest",
        "requestId": requestId,
        "uid": uid,
      });
    } catch (e) {
      print('❌ خطأ في الموافقة على طلب السلفة/المصاريف: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e"
      };
    }
  }

  // رفض طلب سلف/مصاريف
  static Future<Map<String, dynamic>> rejectAdvanceRequest(String requestId, String uid) async {
    try {
      print('❌ رفض طلب سلفة/مصاريف: $requestId بواسطة $uid');
      return await ApiService.post({
        "action": "rejectAdvanceRequest",
        "requestId": requestId,
        "uid": uid,
      });
    } catch (e) {
      print('❌ خطأ في رفض طلب السلفة/المصاريف: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e"
      };
    }
  }

  // تأكيد استلام طلب سلف/مصاريف
  static Future<Map<String, dynamic>> confirmReceiptAdvanceRequest(String requestId, String uid) async {
    try {
      print('✅ تأكيد استلام طلب سلفة/مصاريف: $requestId بواسطة $uid');
      return await ApiService.post({
        "action": "confirmReceiptAdvanceRequest",
        "requestId": requestId,
        "uid": uid,
      });
    } catch (e) {
      print('❌ خطأ في تأكيد استلام طلب السلفة/المصاريف: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e"
      };
    }
  }
}