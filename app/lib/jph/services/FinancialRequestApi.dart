// lib/services/financial_request_api.dart
import 'dart:convert';
import './api_service.dart';

class FinancialRequestApi {
  static Future<Map<String, dynamic>> getAllFinancialRequests() async {
    try {
      print('📡 جلب جميع الطلبات المالية...');

      // استخدام ApiService.post مباشرة
      final response = await ApiService.post({
        'action': 'getAllFinancialRequests',
      });

      print('📊 استجابة السرفر: ${response.toString()}');

      // تأكد من أن response هو Map<String, dynamic>
      if (response is Map<String, dynamic>) {
        if (response["success"] == true) {
          print('✅ تم جلب البيانات بنجاح');
          return response;
        } else {
          print('❌ فشل في جلب البيانات: ${response["message"]}');
          return {
            "success": false,
            "message": response["message"] ?? "فشل في جلب البيانات",
            "requests": [],
            "stats": {
              'total': 0,
              'confirmed': 0,
              'pending': 0,
              'rejected': 0,
              'cancelled': 0,
              'totalAmount': 0.0,
            },
            "count": 0
          };
        }
      } else {
        print('❌ استجابة غير صالحة: $response');
        return {
          "success": false,
          "message": "استجابة غير صالحة من الخادم",
          "requests": [],
          "stats": {
            'total': 0,
            'confirmed': 0,
            'pending': 0,
            'rejected': 0,
            'cancelled': 0,
            'totalAmount': 0.0,
          },
          "count": 0
        };
      }
    } catch (e) {
      print('❌ خطأ في getAllFinancialRequests: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e",
        "requests": [],
        "stats": {
          'total': 0,
          'confirmed': 0,
          'pending': 0,
          'rejected': 0,
          'cancelled': 0,
          'totalAmount': 0.0,
        },
        "count": 0
      };
    }
  }

  static Future<Map<String, dynamic>> approveLoanRequest(String requestId, String uid) async {
    try {
      print('✅ محاولة الموافقة على الطلب المالي: $requestId');

      // ترميز requestId للتأكد من سلامة النقل
      final encodedId = Uri.encodeComponent(requestId);

      final response = await ApiService.post({
        'action': 'approve_loan_request',
        'request_id': encodedId,
        'uid': uid,
      });

      print('📊 استجابة الموافقة: ${response.toString()}');

      if (response is Map<String, dynamic>) {
        return response;
      } else {
        return {
          "success": false,
          "message": "استجابة غير صالحة من الخادم"
        };
      }
    } catch (e) {
      print('❌ خطأ في approveLoanRequest: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e"
      };
    }
  }

  static Future<Map<String, dynamic>> rejectLoanRequest(String requestId, String uid) async {
    try {
      print('❌ محاولة رفض الطلب المالي: $requestId');

      // ترميز requestId للتأكد من سلامة النقل
      final encodedId = Uri.encodeComponent(requestId);

      final response = await ApiService.post({
        'action': 'reject_loan_request',
        'request_id': encodedId,
        'uid': uid,
      });

      print('📊 استجابة الرفض: ${response.toString()}');

      if (response is Map<String, dynamic>) {
        return response;
      } else {
        return {
          "success": false,
          "message": "استجابة غير صالحة من الخادم"
        };
      }
    } catch (e) {
      print('❌ خطأ في rejectLoanRequest: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e"
      };
    }
  }

  // دالة إضافية للإلغاء (يمكن استخدام rejectLoanRequest أو إنشاء واحدة جديدة)
  static Future<Map<String, dynamic>> cancelFinancialRequest(
      String requestId,
      String uid
      ) async {
    try {
      print('🚫 محاولة إلغاء الطلب المالي: $requestId');

      // ترميز requestId للتأكد من سلامة النقل
      final encodedId = Uri.encodeComponent(requestId);

      final response = await ApiService.post({
        'action': 'reject_loan_request', // استخدم نفس دالة الرفض للإلغاء
        'request_id': encodedId,
        'uid': uid,
        'is_cancel': true, // أضف علامة للإلغاء إذا كان السيرفر يدعمها
      });

      print('📊 استجابة الإلغاء: ${response.toString()}');

      if (response is Map<String, dynamic>) {
        return response;
      } else {
        return {
          "success": false,
          "message": "استجابة غير صالحة من الخادم"
        };
      }
    } catch (e) {
      print('❌ خطأ في cancelFinancialRequest: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e"
      };
    }
  }
}