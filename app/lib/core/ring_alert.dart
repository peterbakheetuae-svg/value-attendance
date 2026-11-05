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
      description: 'طلبات الإذن والزيارة وميعاد الرجوع',
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

  static Future<void> show({required int id, required String title, required String body, String? payload}) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final details = AndroidNotificationDetails(
      ringChannel, 'رنين التنبيهات المهمة',
      channelDescription: 'طلبات الإذن والزيارة وميعاد الرجوع',
      importance: Importance.max,
      priority: Priority.max,
      fullScreenIntent: true,
      category: AndroidNotificationCategory.alarm,
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
  }
}
