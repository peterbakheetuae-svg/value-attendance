import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Two kinds of alerts:
///  • ring  — permission / visit requests and an overdue return: full-screen, alarm sound, keeps ringing
///            until it is opened, shows even when the phone is locked or the app is closed.
///  • normal — everything else: an ordinary notification (shown by the system from the push).
class RingAlert {
  RingAlert._();
  static const ringChannel = 'ring_channel_v1';
  static const generalChannel = 'general_channel';
  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  static bool _channels = false;

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  /// [background]: called from the push isolate (app closed) — the plugin must be initialised there.
  static Future<void> init({bool background = false}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    if (background) {
      await _plugin.initialize(settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    }
    if (_channels) return;
    await _android?.createNotificationChannel(const AndroidNotificationChannel(
      ringChannel, 'رنين التنبيهات المهمة',
      description: 'طلبات الإذن والمعاينة وميعاد الرجوع',
      importance: Importance.max,
      playSound: true,
      sound: RawResourceAndroidNotificationSound('notification'),
      audioAttributesUsage: AudioAttributesUsage.alarm,
      enableVibration: true,
    ));
    await _android?.createNotificationChannel(const AndroidNotificationChannel(
      generalChannel, 'الإشعارات',
      description: 'إشعارات عادية',
      importance: Importance.defaultImportance,
    ));
    _channels = true;
  }

  /// Android 14+: showing over the lock screen needs the user's OK once.
  static Future<void> requestFullScreen() async {
    try { await _android?.requestFullScreenIntentPermission(); } catch (_) {}
  }

  // ---------------------------------------------------------------- «Valunivo Call»
  /// Alerts shown as an incoming call (the app's own call screen over the lock screen): a check-in made on another phone
  /// of the account («ابدأ عملك الآن» — open the app here so this phone is followed too), and leaving the office with no
  /// approved permission («خرجت بدون إذن»).
  static const callCheckIn = 7100, callExit = 7001;

  /// the call screen a notification type opens: 'checkin' / 'exit', or null (a normal ringing alert)
  static String? callKind(String? type) => switch (type) {
        'checkin_other_phone' || 'tracking_phone_off' => 'checkin',
        'unauthorized_exit_self' => 'exit',
        _ => null,
      };

  /// set by the running app: a call rung while the app is open shows its screen at once (null in the background isolates)
  static void Function(String kind)? onCall;

  /// a call ringing (or that opened the app) and not answered yet: 'checkin' / 'exit' / null
  static Future<String?> pendingCall() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp == true) {
        final k = callKind(launch?.notificationResponse?.payload);
        if (k != null && !_answeredLaunch) {
          _answeredLaunch = true;
          return k;
        }
      }
      final active = await _android?.getActiveNotifications() ?? const [];
      if (active.any((n) => n.id == callExit)) return 'exit';
      if (active.any((n) => n.id == callCheckIn)) return 'checkin';
    } catch (_) {}
    return null;
  }

  static bool _answeredLaunch = false;

  /// the call was answered: its notification (and its ringing) goes
  static Future<void> endCalls() async {
    try {
      await _plugin.cancel(id: callCheckIn);
      await _plugin.cancel(id: callExit);
    } catch (_) {}
  }

  static Future<void> show({required int id, required String title, required String body, String? payload}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final call = callKind(payload);
    if (call != null) {
      // one call at a time per kind; the text of the call screen
      id = call == 'exit' ? callExit : callCheckIn;
      title = 'Valunivo Call';
      body = call == 'exit' ? 'خرجت بدون إذن' : 'ابدأ عملك الآن';
    }
    final details = AndroidNotificationDetails(
      ringChannel, 'رنين التنبيهات المهمة',
      channelDescription: 'طلبات الإذن والمعاينة وميعاد الرجوع',
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true,
      category: call != null ? AndroidNotificationCategory.call : AndroidNotificationCategory.alarm,
      playSound: true,
      sound: const RawResourceAndroidNotificationSound('notification'),
      audioAttributesUsage: AudioAttributesUsage.alarm,
      enableVibration: true,
      vibrationPattern: Int64List.fromList([0, 800, 400, 800, 400, 800]),
      additionalFlags: Int32List.fromList([4]), // FLAG_INSISTENT: keeps ringing until opened
      visibility: NotificationVisibility.public,
      autoCancel: true,
      timeoutAfter: 120000,
      color: const Color(0xFF4F46E5),
      styleInformation: BigTextStyleInformation(body),
    );
    await _plugin.show(id: id, title: title, body: body, notificationDetails: NotificationDetails(android: details), payload: payload);
    // the app is open: its call screen right away
    if (call != null) onCall?.call(call);
  }
}
