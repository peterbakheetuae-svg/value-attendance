import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'api.dart';
import 'ring_alert.dart';

/// Phone push (Firebase Cloud Messaging, free): makes alerts ring even when the app is closed.
/// The Firebase client config is public and injected at build time; without it push stays off
/// and the in-app polling alerts keep working.
const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
const _appId = String.fromEnvironment('FIREBASE_APP_ID');
const _senderId = String.fromEnvironment('FIREBASE_SENDER_ID');
const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

/// App closed / in the background: a "ring" push becomes a full-screen ringing alert.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage m) async {
  if (m.data['ring'] != '1') return;
  try {
    await RingAlert.init(background: true);
    await RingAlert.show(
      id: '${m.data['id'] ?? m.messageId}'.hashCode & 0x7fffffff,
      title: '${m.data['title'] ?? 'تنبيه'}',
      body: '${m.data['body'] ?? ''}',
      payload: '${m.data['type'] ?? ''}',
    );
  } catch (_) {}
}

class Push {
  Push._();
  static bool _ready = false;
  static String? _token;
  static String? _sentFor; // "<token>|<session token>" already registered
  static void Function()? onMessage;

  /// Pushes are reaching this device (the system shows them; no extra local notification needed).
  static bool get active => _ready && _sentFor != null;

  static bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android && _apiKey.isNotEmpty && _appId.isNotEmpty;

  static Future<void> init() async {
    if (!supported || _ready) return;
    try {
      await Firebase.initializeApp(
          options: const FirebaseOptions(apiKey: _apiKey, appId: _appId, messagingSenderId: _senderId, projectId: _projectId));
      FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
      await RingAlert.init();
      await RingAlert.requestFullScreen();
      final m = FirebaseMessaging.instance;
      await m.requestPermission(alert: true, sound: true, badge: true);
      _token = await m.getToken();
      m.onTokenRefresh.listen((t) { _token = t; _sentFor = null; });
      // app open: let the in-app alert center ring + show the dialog right away
      FirebaseMessaging.onMessage.listen((_) => onMessage?.call());
      FirebaseMessaging.onMessageOpenedApp.listen((_) => onMessage?.call());
      _ready = true;
    } catch (_) {
      // no Google Play services / offline: polling alerts still work
    }
  }

  /// Register this device for the signed-in session (cheap no-op when already done).
  static Future<void> sync(ApiClient api) async {
    final t = _token, s = api.token;
    if (!_ready || t == null || s == null || _sentFor == '$t|$s') return;
    try {
      await api.post('/me/push-token', {'token': t, 'platform': 'android'});
      _sentFor = '$t|$s';
    } catch (_) {}
  }
}
