import 'api_service.dart';

class NotificationApi {
  /// إرسال إشعار جديد
  static Future<Map<String, dynamic>> sendNotification({
    required String senderId,
    required String senderName,
    required List<String> recipients,
    required String category,
    required String title,
    required String content,
  }) async {
    try {
      print('📤 إرسال إشعار جديد:');
      print('  المرسل: $senderName ($senderId)');
      print('  الفئة: $category');
      print('  المستلمين: ${recipients.length}');
      print('  العنوان: $title');

      final data = {
        "action": "sendNotification",
        "senderId": senderId,
        "senderName": senderName,
        "recipients": recipients,
        "category": category,
        "title": title,
        "content": content,
      };

      return await ApiService.post(data);
    } catch (e) {
      print('❌ خطأ في إرسال الإشعار: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e"
      };
    }
  }

  /// جلب الإشعارات المرسلة من قبل مستخدم
  static Future<Map<String, dynamic>> getSentNotifications(String senderId) async {
    try {
      print('📤 جلب الإشعارات المرسلة للمستخدم: $senderId');

      final result = await ApiService.post({
        "action": "getSentNotifications",
        "senderId": senderId,
      });

      print('📊 استجابة جلب الإشعارات المرسلة: ${result.toString()}');

      if (result["success"] == true) {
        return {
          "success": true,
          "notifications": result["notifications"] ?? [],
          "count": result["count"] ?? 0,
          "message": result["message"] ?? "تم جلب البيانات بنجاح",
        };
      } else {
        return {
          "success": result["success"] ?? false,
          "message": result["message"] ?? "حدث خطأ في جلب البيانات",
          "notifications": [],
          "count": 0,
        };
      }
    } catch (e) {
      print('❌ خطأ في جلب الإشعارات المرسلة: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e",
        "notifications": [],
        "count": 0,
      };
    }
  }

  /// جلب إشعارات مستلمة لمستخدم
  static Future<Map<String, dynamic>> getReceivedNotifications(String userId) async {
    try {
      print('📤 جلب الإشعارات المستلمة للمستخدم: $userId');

      final result = await ApiService.post({
        "action": "getReceivedNotifications",
        "userId": userId,
      });

      print('📊 استجابة جلب الإشعارات المستلمة: ${result.toString()}');

      if (result["success"] == true) {
        return {
          "success": true,
          "notifications": result["notifications"] ?? [],
          "count": result["count"] ?? 0,
          "message": result["message"] ?? "تم جلب البيانات بنجاح",
        };
      } else {
        return {
          "success": result["success"] ?? false,
          "message": result["message"] ?? "حدث خطأ في جلب البيانات",
          "notifications": [],
          "count": 0,
        };
      }
    } catch (e) {
      print('❌ خطأ في جلب الإشعارات المستلمة: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e",
        "notifications": [],
        "count": 0,
      };
    }
  }

  /// تعليم إشعار كمقروء
  static Future<Map<String, dynamic>> markAsRead(String notificationId, String userId) async {
    try {
      print('✅ تعليم إشعار كمقروء: $notificationId');
      return await ApiService.post({
        "action": "markNotificationAsRead",
        "notificationId": notificationId,
        "userId": userId,
      });
    } catch (e) {
      print('❌ خطأ في تعليم الإشعار كمقروء: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e"
      };
    }
  }

  /// حذف إشعار
  static Future<Map<String, dynamic>> deleteNotification(String notificationId, String userId) async {
    try {
      print('🗑️ حذف إشعار: $notificationId');
      return await ApiService.post({
        "action": "deleteNotification",
        "notificationId": notificationId,
        "userId": userId,
      });
    } catch (e) {
      print('❌ خطأ في حذف الإشعار: $e');
      return {
        "success": false,
        "message": "حدث خطأ في الاتصال: $e"
      };
    }
  }
}