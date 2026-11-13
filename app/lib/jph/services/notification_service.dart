import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'api_service.dart';
import '../widgets/glass_ui.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();

  factory NotificationService() => _instance;

  NotificationService._internal();

  static final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
  FlutterLocalNotificationsPlugin();

  // أنواع الإشعارات
  static const String channelId = 'attendance_channel';
  static const String channelName = 'Value Attendance';
  static const String channelDesc = 'إشعارات نظام الحضور والانصراف';

  // Callback functions
  Function(String)? onNotificationTap;

  Future<void> initialize({Function(String)? onNotificationTapCallback}) async {
    try {
      print('🚀 بدء تهيئة خدمة الإشعارات...');

      this.onNotificationTap = onNotificationTapCallback;

      await _setupLocalNotifications();
      await _setupFirebaseMessaging();
      await _requestPermissions();

      print('✅ تم تهيئة خدمة الإشعارات بنجاح');
    } catch (e) {
      print('❌ خطأ في تهيئة خدمة الإشعارات: $e');
    }
  }

  Future<void> _requestPermissions() async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        await _flutterLocalNotificationsPlugin
            .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
    } catch (e) {
      debugPrint('notification permission: $e');
    }
  }

  Future<void> _setupLocalNotifications() async {
    try {
      print('⚙️ تهيئة الإشعارات المحلية...');

      const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');

      const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
        requestAlertPermission: false, // طلبناها سابقاً
        requestBadgePermission: true,
        requestSoundPermission: true,
        defaultPresentAlert: true,
        defaultPresentBadge: true,
        defaultPresentSound: true,
      );

      const InitializationSettings initializationSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _flutterLocalNotificationsPlugin.initialize(
        settings: initializationSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          final payload = response.payload;
          if (payload != null) {
            _handleNotificationTap(payload);
          }
        },
      );

      // إنشاء قناة الإشعارات للأندرويد
      if (!kIsWeb && Platform.isAndroid) {
        final vibrationPattern = Int64List.fromList([0, 1000, 500, 1000]);

        final AndroidNotificationChannel channel = AndroidNotificationChannel(
          channelId,
          channelName,
          description: channelDesc,
          importance: Importance.max,
          playSound: true,
          sound: const RawResourceAndroidNotificationSound('notification'),
          enableVibration: true,
          vibrationPattern: vibrationPattern,
          enableLights: true,
          ledColor: Ar.accent,
          showBadge: true,
        );

        await _flutterLocalNotificationsPlugin
            .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
            ?.createNotificationChannel(channel);
      }

      print('✅ تم تهيئة الإشعارات المحلية');
    } catch (e) {
      print('❌ خطأ في تهيئة الإشعارات المحلية: $e');
    }
  }

  // Push (FCM) is not used: notifications live in the app and are fetched from the server.
  Future<void> _setupFirebaseMessaging() async {}





  Future<void> _saveDeviceToken(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcm_token', token);
      print('💾 تم حفظ FCM Token محلياً');
    } catch (e) {
      print('❌ خطأ في حفظ التوكن: $e');
    }
  }

  Future<String?> getDeviceToken() async => null; // no push token (no Firebase)


  Future<void> _showLocalNotification({
    required String title,
    required String body,
    required String payload,
    Map<String, dynamic>? data,
  }) async {
    try {
      print('📤 عرض إشعار محلي: $title');

      // استخدام قائمة ثابتة لـ vibrationPattern
      final vibrationPattern = Int64List.fromList([0, 1000, 500, 1000]);


      final androidDetails = AndroidNotificationDetails(
        channelId,
        channelName,
        channelDescription: channelDesc,
        importance: Importance.max,
        priority: Priority.high,
        ticker: 'ticker',
        playSound: true,
        sound: const RawResourceAndroidNotificationSound('notification'),
        enableVibration: true,
        vibrationPattern: vibrationPattern,
        enableLights: true,
        ledColor: Ar.accent,
        color: const Color(0xFFE2501F),
        largeIcon: const DrawableResourceAndroidBitmap('@mipmap/ic_launcher'),
        styleInformation: BigTextStyleInformation(
          body,
          htmlFormatBigText: true,
          contentTitle: title,
          htmlFormatContentTitle: true,
          summaryText: 'إشعار جديد',
          htmlFormatSummaryText: true,
        ),
        autoCancel: true,
        showWhen: true,
        when: DateTime.now().millisecondsSinceEpoch,
        ongoing: false,
        visibility: NotificationVisibility.public,
        timeoutAfter: 5000,
        category: AndroidNotificationCategory.message,
      );

      final iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
        sound: 'default',
        badgeNumber: 1,
        subtitle: title,
        threadIdentifier: 'attendance-notifications',
      );

      final platformDetails = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _flutterLocalNotificationsPlugin.show(
        id: 0,
        title: title,
        body: body,
        notificationDetails: platformDetails,
        payload: payload,
      );


      print('✅ تم عرض الإشعار بنجاح');
    } catch (e) {
      print('❌ خطأ في عرض الإشعار المحلي: $e');
    }
  }

  void _handleNotificationTap(String payload) {
    print('🖱️ تم النقر على إشعار من نوع: $payload');

    if (onNotificationTap != null) {
      onNotificationTap!(payload);
    }
  }

  // 🔥 دالة مساعدة لتحويل أي قيمة إلى bool
  bool _convertToBool(dynamic value) {
    if (value == null) return false;

    if (value is bool) return value;

    if (value is String) {
      final str = value.trim().toLowerCase();

      // القيم التي تعتبر true
      const trueValues = ['true', '1', 'yes', 'y', 't', 'نعم', 'تم'];

      // القيم التي تعتبر false
      const falseValues = ['false', '0', 'no', 'n', 'f', 'لا', 'لم'];

      if (trueValues.contains(str)) return true;
      if (falseValues.contains(str)) return false;

      if (str.isEmpty) return false;

      final numValue = double.tryParse(str);
      if (numValue != null) {
        return numValue != 0;
      }

      return str.isNotEmpty;
    }

    if (value is int) return value != 0;
    if (value is double) return value != 0.0;
    if (value is num) return value.toDouble() != 0.0;

    try {
      return _convertToBool(value.toString());
    } catch (e) {
      return false;
    }
  }

  // باقي الدوال (getUserNotifications, markNotificationAsRead, إلخ)
  // تبقى كما هي بدون تغيير...

  // دالة لإرسال التوكن إلى السيرفر - محسنة مع معالجة الأخطاء
  Future<Map<String, dynamic>> sendTokenToServer(String userId, String token) async {
    try {
      print('📤 إرسال التوكن إلى السيرفر للمستخدم: $userId');

      final response = await ApiService.post({
        'action': 'updateFcmToken',
        'userId': userId,
        'fcmToken': token,
      });

      if (response['success'] == true) {
        print('✅ تم إرسال التوكن بنجاح');

        // حفظ حالة الإرسال في SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('fcm_token_sent_$userId', true);
        await prefs.setString('last_token_sent', DateTime.now().toIso8601String());

        return {
          'success': true,
          'message': 'تم تحديث التوكن بنجاح'
        };
      } else {
        print('❌ فشل إرسال التوكن: ${response['error'] ?? response['message']}');
        return {
          'success': false,
          'message': response['error'] ?? response['message'] ?? 'فشل في إرسال التوكن',
          'errorDetails': response
        };
      }
    } catch (e) {
      print('❌ خطأ في إرسال FCM Token: $e');
      return {
        'success': false,
        'error': 'خطأ في الاتصال بالخادم: $e'
      };
    }
  }

  // دالة جديدة: التحقق مما إذا تم إرسال التوكن مسبقاً
  Future<bool> isTokenSent(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('fcm_token_sent_$userId') ?? false;
    } catch (e) {
      print('❌ خطأ في التحقق من حالة التوكن: $e');
      return false;
    }
  }

  // دالة جديدة: إرسال التوكن إذا لم يكن مرسلاً
  Future<void> sendTokenIfNeeded(String userId) async {
    try {
      final tokenSent = await isTokenSent(userId);

      if (!tokenSent) {
        final token = await getDeviceToken();
        if (token != null) {
          print('🔄 إرسال التوكن للمستخدم $userId لأول مرة...');
          await sendTokenToServer(userId, token);
        } else {
          print('⚠️ لا يوجد توكن متاح للإرسال');
        }
      } else {
        print('✅ التوكن قد تم إرساله مسبقاً للمستخدم: $userId');
      }
    } catch (e) {
      print('❌ خطأ في إرسال التوكن عند الحاجة: $e');
    }
  }

  // دالة جديدة: إعادة تفعيل الإشعارات
  Future<Map<String, dynamic>> reactivateNotifications(String userId) async {
    try {
      print('🔄 محاولة إعادة تفعيل الإشعارات للمستخدم: $userId');

      // 1. الحصول على التوكن الجديد
      final String? newToken = await getDeviceToken();

      if (newToken == null) {
        return {
          'success': false,
          'message': 'لم يتم الحصول على توكن إشعارات. يرجى التأكد من تفعيل الإشعارات في إعدادات الهاتف.'
        };
      }

      // 2. إرسال التوكن الجديد للسيرفر
      final result = await sendTokenToServer(userId, newToken);

      if (result['success']) {
        // 3. الاشتراك في مواضيع المستخدم
        await subscribeToTopics(userId);

        return {
          'success': true,
          'message': 'تم إعادة تفعيل الإشعارات بنجاح!',
          'tokenPreview': newToken.substring(0, 20) + '...'
        };
      } else {
        return result;
      }
    } catch (e) {
      print('❌ خطأ في إعادة تفعيل الإشعارات: $e');
      return {
        'success': false,
        'error': 'خطأ في إعادة التفعيل: $e'
      };
    }
  }

  // دالة جديدة: التحقق من حالة الإشعارات
  Future<Map<String, dynamic>> checkNotificationStatus(String userId) async {
    try {
      final token = await getDeviceToken();
      final tokenSent = await isTokenSent(userId);

      return {
        'success': true,
        'hasToken': token != null,
        'tokenSent': tokenSent,
        'tokenPreview': token != null ? token.substring(0, 20) + '...' : null,
        'message': token == null
            ? 'لم يتم الحصول على توكن إشعارات. يرجى التأكد من تفعيل الإشعارات.'
            : (tokenSent ? 'الإشعارات مفعلة وجاهزة' : 'لم يتم إرسال التوكن للسيرفر بعد')
      };
    } catch (e) {
      return {
        'success': false,
        'error': 'خطأ في التحقق من الحالة: $e'
      };
    }
  }

  // دالة مساعدة: إرسال التوكن عند الحاجة
  Future<void> _sendTokenToServerIfNeeded(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastUserId = prefs.getString('last_logged_in_user');

      if (lastUserId != null && lastUserId.isNotEmpty) {
        final tokenSent = await isTokenSent(lastUserId);

        if (!tokenSent) {
          print('🔄 إرسال التوكن المحدث للمستخدم: $lastUserId');
          await sendTokenToServer(lastUserId, token);
        }
      }
    } catch (e) {
      print('❌ خطأ في إرسال التوكن عند التحديث: $e');
    }
  }

  // دالة لجلب إشعارات المستخدم من السيرفر
  Future<Map<String, dynamic>> getUserNotifications(String userId, {int limit = 50}) async {
    try {
      print('📡 جلب إشعارات للمستخدم: $userId');

      final response = await ApiService.post({
        'action': 'getUserNotifications',
        'userId': userId,
        'limit': limit,
      });

      print('📥 استجابة API للإشعارات: ${response.toString()}');

      if (response['success'] == true) {
        List<Map<String, dynamic>> notifications = [];

        if (response['notifications'] != null && response['notifications'] is List) {
          for (var notif in response['notifications']) {
            try {
              if (notif is Map<String, dynamic>) {
                final bool readStatus = _convertToBool(notif['read']);

                print('🔍 تحويل حقل read: "${notif['read']}" → $readStatus');

                notifications.add({
                  'id': notif['id']?.toString() ?? '',
                  'uid': notif['uid']?.toString() ?? '',
                  'title': notif['title']?.toString() ?? 'بدون عنوان',
                  'body': notif['body']?.toString() ?? 'بدون محتوى',
                  'type': notif['type']?.toString() ?? 'custom',
                  'read': readStatus,
                  'timestamp': notif['timestamp']?.toString() ?? DateTime.now().toIso8601String(),
                });
              }
            } catch (e) {
              print('⚠️ خطأ في تحويل إشعار: $e');
              print('⚠️ بيانات الإشعار المضطرب: $notif');
              continue;
            }
          }
        }

        print('✅ تم جلب ${notifications.length} إشعار للمستخدم $userId');
        return {
          'success': true,
          'notifications': notifications,
          'count': notifications.length,
        };
      } else {
        print('❌ فشل جلب إشعارات المستخدم: ${response['message']}');
        return {
          'success': false,
          'message': response['message'] ?? 'فشل في جلب الإشعارات'
        };
      }
    } catch (e) {
      print('❌ خطأ في جلب إشعارات المستخدم: $e');
      return {
        'success': false,
        'error': e.toString(),
        'notifications': [],
        'count': 0
      };
    }
  }

  // دالة لتعليم إشعار كمقروء
  Future<Map<String, dynamic>> markNotificationAsRead(String notificationId) async {
    try {
      print('📝 تعليم الإشعار كمقروء: $notificationId');

      final response = await ApiService.post({
        'action': 'markNotificationAsRead',
        'notificationId': notificationId,
      });

      if (response['success'] == true) {
        print('✅ تم تعليم الإشعار كمقروء');
        return {'success': true, 'message': 'تم تعليم الإشعار كمقروء'};
      } else {
        print('❌ فشل تعليم الإشعار كمقروء: ${response['message']}');
        return {'success': false, 'message': response['message'] ?? 'فشل في تحديث حالة الإشعار'};
      }
    } catch (e) {
      print('❌ خطأ في تعليم الإشعار كمقروء: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // دالة لتعليم جميع إشعارات المستخدم كمقروءة
  Future<Map<String, dynamic>> markAllNotificationsAsRead(String userId) async {
    try {
      print('📝 تعليم جميع إشعارات المستخدم كمقروءة: $userId');

      final response = await ApiService.post({
        'action': 'markAllNotificationsAsRead',
        'userId': userId,
      });

      if (response['success'] == true) {
        print('✅ تم تعليم جميع الإشعارات كمقروءة');
        return {'success': true, 'message': 'تم تعليم جميع الإشعارات كمقروءة'};
      } else {
        print('❌ فشل تعليم جميع الإشعارات كمقروءة: ${response['message']}');
        return {'success': false, 'message': response['message'] ?? 'فشل في تحديث حالة الإشعارات'};
      }
    } catch (e) {
      print('❌ خطأ في تعليم جميع الإشعارات كمقروءة: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // دالة لحذف إشعار
  Future<Map<String, dynamic>> deleteNotification(String notificationId) async {
    try {
      print('🗑️ حذف الإشعار: $notificationId');

      final response = await ApiService.post({
        'action': 'deleteNotification',
        'notificationId': notificationId,
      });

      if (response['success'] == true) {
        print('✅ تم حذف الإشعار');
        return {'success': true, 'message': 'تم حذف الإشعار'};
      } else {
        print('❌ فشل حذف الإشعار: ${response['message']}');
        return {'success': false, 'message': response['message'] ?? 'فشل في حذف الإشعار'};
      }
    } catch (e) {
      print('❌ خطأ في حذف الإشعار: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // دالة لحذف جميع إشعارات المستخدم
  Future<Map<String, dynamic>> clearAllNotifications(String userId) async {
    try {
      print('🗑️ حذف جميع إشعارات المستخدم: $userId');

      final response = await ApiService.post({
        'action': 'clearAllNotifications',
        'userId': userId,
      });

      if (response['success'] == true) {
        print('✅ تم حذف جميع الإشعارات');
        return {'success': true, 'message': 'تم حذف جميع الإشعارات'};
      } else {
        print('❌ فشل حذف جميع الإشعارات: ${response['message']}');
        return {'success': false, 'message': response['message'] ?? 'فشل في حذف الإشعارات'};
      }
    } catch (e) {
      print('❌ خطأ في حذف جميع الإشعارات: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // اشترك في مواضيع معينة
  Future<void> subscribeToTopics(String userId) async {}

  // ألغ اشتراك من مواضيع
  Future<void> unsubscribeFromTopics(String userId) async {}

  // مسح جميع الإشعارات المحلية
  Future<void> cancelAllLocalNotifications() async {
    try {
      await _flutterLocalNotificationsPlugin.cancelAll();
      print('🗑️ تم مسح جميع الإشعارات المحلية');
    } catch (e) {
      print('❌ خطأ في مسح الإشعارات المحلية: $e');
    }
  }

  // إظهار إشعار محلي مخصص
  Future<void> showCustomNotification({
    required String title,
    required String body,
    String type = 'general',
  }) async {
    await _showLocalNotification(
      title: title,
      body: body,
      payload: type,
    );
  }

  // الحصول على إعدادات الإشعارات
  Future<Map<String, bool>> getNotificationSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return {
        'pushEnabled': prefs.getBool('push_notifications') ?? true,
        'soundEnabled': prefs.getBool('notification_sound') ?? true,
        'vibrationEnabled': prefs.getBool('notification_vibration') ?? true,
      };
    } catch (e) {
      print('❌ خطأ في الحصول على إعدادات الإشعارات: $e');
      return {
        'pushEnabled': true,
        'soundEnabled': true,
        'vibrationEnabled': true,
      };
    }
  }

  // تحديث إعدادات الإشعارات
  Future<void> updateNotificationSettings({
    bool? pushEnabled,
    bool? soundEnabled,
    bool? vibrationEnabled,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (pushEnabled != null) {
        await prefs.setBool('push_notifications', pushEnabled);
      }

      if (soundEnabled != null) {
        await prefs.setBool('notification_sound', soundEnabled);
      }

      if (vibrationEnabled != null) {
        await prefs.setBool('notification_vibration', vibrationEnabled);
      }

      print('⚙️ تم تحديث إعدادات الإشعارات');
    } catch (e) {
      print('❌ خطأ في تحديث إعدادات الإشعارات: $e');
    }
  }

  // تسجيل مستخدم جديد في نظام الإشعارات
  Future<Map<String, dynamic>> registerUserForNotifications(String userId, String name) async {
    try {
      print('👤 تسجيل مستخدم للإشعارات: $userId');

      // الحصول على التوكن
      final String? deviceToken = await getDeviceToken();

      if (deviceToken == null) {
        return {'success': false, 'message': 'لا يوجد توكن FCM'};
      }

      // إرسال التوكن إلى السيرفر
      final tokenResult = await sendTokenToServer(userId, deviceToken);

      if (!tokenResult['success']) {
        return tokenResult;
      }

      // الاشتراك في المواضيع
      await subscribeToTopics(userId);

      return {'success': true, 'message': 'تم تسجيل المستخدم للإشعارات بنجاح'};
    } catch (e) {
      print('❌ خطأ في تسجيل المستخدم للإشعارات: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  // إلغاء تسجيل مستخدم من نظام الإشعارات
  Future<Map<String, dynamic>> unregisterUserFromNotifications(String userId) async {
    try {
      print('👤 إلغاء تسجيل مستخدم من الإشعارات: $userId');

      // إلغاء الاشتراك من المواضيع
      await unsubscribeFromTopics(userId);

      return {'success': true, 'message': 'تم إلغاء تسجيل المستخدم من الإشعارات'};
    } catch (e) {
      print('❌ خطأ في إلغاء تسجيل المستخدم من الإشعارات: $e');
      return {'success': false, 'error': e.toString()};
    }
  }
}