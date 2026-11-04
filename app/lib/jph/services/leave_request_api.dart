import 'api_service.dart';

class LeaveRequestApi {
  static Future<Map<String, dynamic>> submitLeaveRequest({
    required String uid,
    required String leaveType,
    required String fromDate,
    required String toDate,
    required String reason,
    String? image,
  }) async {
    try {
      final data = {
        "action": "submitLeaveRequest",
        "uid": uid,
        "leaveType": leaveType,
        "fromDate": fromDate,
        "toDate": toDate,
        "reason": reason,
        "image": image ?? "",
      };

      print('📤 إرسال طلب إجازة: $data');
      return await ApiService.post(data);
    } catch (e) {
      print('❌ خطأ في إرسال طلب الإجازة: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e"
      };
    }
  }

  static Future<Map<String, dynamic>> getLeaveRequests(String uid) async {
    try {
      print('📤 جلب طلبات الإجازة لـ UID: $uid');

      final result = await ApiService.post({
        "action": "getLeaveRequests",
        "uid": uid,
      });

      print('📊 استجابة جلب طلبات الإجازة للمستخدم: ${result.toString()}');

      // تحسين معالجة الاستجابة
      if (result["success"] == true) {
        // الحصول على الإحصائيات من الاستجابة
        final stats = result["stats"] ?? {};

        return {
          "success": true,
          "stats": {
            "pending": stats["pending"] ?? 0,
            "approved": stats["approved"] ?? 0,
            "rejected": stats["rejected"] ?? 0,
            "cancelled": stats["cancelled"] ?? 0,
          },
          "requests": result["requests"] ?? [],
          "message": result["message"] ?? "تم جلب البيانات بنجاح",
        };
      } else {
        return {
          "success": result["success"] ?? false,
          "message": result["message"] ?? "حدث خطأ في جلب البيانات",
          "stats": {
            "pending": 0,
            "approved": 0,
            "rejected": 0,
            "cancelled": 0,
          },
          "requests": [],
        };
      }
    } catch (e) {
      print('❌ خطأ في جلب طلبات الإجازة للمستخدم: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e",
        "stats": {
          "pending": 0,
          "approved": 0,
          "rejected": 0,
          "cancelled": 0,
        },
        "requests": [],
      };
    }
  }

  static Future<Map<String, dynamic>> submitLeaveRequestByManager({
    required String uid, // المدير
    required String employeeId, // الموظف المختار
    required String leaveType,
    required String fromDate,
    required String toDate,
    required String reason,
    String? image,
  }) async {
    final data = {
      "action": "submitLeaveRequestByManager",
      "uid": uid, // المدير
      "employeeId": employeeId, // الموظف
      "leaveType": leaveType,
      "fromDate": fromDate,
      "toDate": toDate,
      "reason": reason,
      "image": image ?? "",
      "ceoConfirm": "مقبؤل",
      "reviewedBy": uid, // المدير
      "status": "مقبؤل",
    };

    print('📤 إرسال طلب إجازة من قبل المدير:');
    print('  action: ${data["action"]}');
    print('  uid (المدير): $uid');
    print('  employeeId: $employeeId');
    print('  leaveType: $leaveType');
    print('  fromDate: $fromDate');
    print('  toDate: $toDate');
    print('  reason: $reason');
    print('  image: ${image != null ? "موجود" : "غير موجود"}');

    return ApiService.post(data);
  }



  /// ✅ جلب جميع طلبات الإجازة (للمدير/صاحب العمل)
  static Future<Map<String, dynamic>> getAllLeaveRequests() async {
    try {
      print('👔 جلب جميع طلبات الإجازة (للمدير)');

      final result = await ApiService.post({
        "action": "getAllLeaveRequests",
      });

      print('📊 استجابة جلب جميع طلبات الإجازة: ${result.toString()}');

      // تحسين معالجة الاستجابة بناءً على تنسيق ReqBin
      if (result["success"] == true) {
        // البيانات تأتي بالفعل منسقة من الـ API
        final stats = result["stats"] ?? {};

        return {
          "success": true,
          "stats": {
            "pending": stats["pending"] ?? 0,
            "approved": stats["approved"] ?? 0,
            "rejected": stats["rejected"] ?? 0,
            "cancelled": stats["cancelled"] ?? 0,
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
            "pending": 0,
            "approved": 0,
            "rejected": 0,
            "cancelled": 0,
          },
          "requests": [],
          "count": 0,
        };
      }
    } catch (e) {
      print('❌ خطأ في جلب جميع طلبات الإجازة: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال بالخادم: $e",
        "stats": {
          "pending": 0,
          "approved": 0,
          "rejected": 0,
          "cancelled": 0,
        },
        "requests": [],
        "count": 0,
      };
    }
  }

  /// ✅ الموافقة على طلب إجازة
  static Future<Map<String, dynamic>> approveLeaveRequest(String requestId, String uid) async {
    try {
      print('✅ الموافقة على طلب إجازة: $requestId بواسطة $uid');
      return await ApiService.post({
        "action": "approve_leave_request",
        "request_id": requestId,
        "uid": uid,
      });
    } catch (e) {
      print('❌ خطأ في الموافقة على طلب الإجازة: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e"
      };
    }
  }

  /// ✅ رفض طلب إجازة
  static Future<Map<String, dynamic>> rejectLeaveRequest(String requestId, String uid) async {
    try {
      print('❌ رفض طلب إجازة: $requestId بواسطة $uid');
      return await ApiService.post({
        "action": "reject_leave_request",
        "request_id": requestId,
        "uid": uid,
      });
    } catch (e) {
      print('❌ خطأ في رفض طلب الإجازة: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e"
      };
    }
  }

  /// ✅ إلغاء طلب الإجازة
  static Future<Map<String, dynamic>> cancelLeaveRequest({
    required String uid,
    required String requestId,
  }) async {
    try {
      print('🗑️ إلغاء طلب الإجازة:');
      print('  uid: $uid');
      print('  requestId: $requestId');

      return await ApiService.post({
        "action": "cancelLeaveRequest",
        "uid": uid,
        "requestId": requestId,
      });
    } catch (e) {
      print('❌ خطأ في إلغاء طلب الإجازة: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e"
      };
    }
  }
}