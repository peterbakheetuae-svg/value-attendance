import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'ring_alert.dart';
import 'token_store.dart';

/// «متابعة أثناء الشيفت» in the background (Android): a foreground service with its own engine, so it keeps
/// following the employee from check-in to check-out even when the app is closed or swiped away from the recent
/// apps. It reads the location every minute, rings by itself when the phone leaves the office (no internet
/// needed), and sends the position to the server at the company's interval. It stops at check-out (the server
/// refuses pings outside the shift), at sign-out, or when the company turns tracking off.
class ShiftService {
  ShiftService._();
  static const channelId = 'shift_tracking';
  static const notificationId = 7100;
  static bool _configured = false;

  static bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<void> _configure(String title, String text) async {
    if (_configured) return;
    // the service's own (quiet) notification channel must exist before it starts
    await FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(channelId, 'متابعة الشيفت',
            description: 'بيظهر طول ما الحضور شغال، وبيقف لوحده بعد الانصراف', importance: Importance.low));
    await FlutterBackgroundService().configure(
      androidConfiguration: AndroidConfiguration(
        onStart: shiftServiceMain,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        notificationChannelId: channelId,
        initialNotificationTitle: title,
        initialNotificationContent: text,
        foregroundServiceNotificationId: notificationId,
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(autoStart: false),
    );
    _configured = true;
  }

  /// Starts the background follow-up (safe to call again). Returns false when it could not start, so the
  /// caller falls back to following in the app only.
  static Future<bool> start({required String title, required String text, required int intervalMinutes}) async {
    if (!supported) return false;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('bg_tracking_on', true);
      await p.setInt('bg_tracking_interval', intervalMinutes);
      await p.setString('bg_tracking_title', title);
      await _configure(title, text);
      final s = FlutterBackgroundService();
      if (await s.isRunning()) return true;
      return await s.startService();
    } catch (e) {
      debugPrint('shift service: $e');
      return false;
    }
  }

  static Future<void> stop() async {
    if (!supported) return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('bg_tracking_on', false);
      await p.remove('bg_ringed_outside');
      final s = FlutterBackgroundService();
      if (await s.isRunning()) s.invoke('stop');
    } catch (_) {}
  }

  static Future<bool> running() async {
    if (!supported) return false;
    try {
      return await FlutterBackgroundService().isRunning();
    } catch (_) {
      return false;
    }
  }
}

/// Entry point of the background engine.
@pragma('vm:entry-point')
Future<void> shiftServiceMain(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  final w = _Worker(service);
  service.on('stop').listen((_) => w.finish());
  await w.begin();
}

class _Worker {
  _Worker(this.service);
  final ServiceInstance service;
  final ApiClient api = ApiClient();
  StreamSubscription<Position>? _sub;
  Timer? _watch;
  DateTime? _lastSent;
  DateTime? _lastFix;
  bool _done = false;

  static const _queueKey = 'bg_ping_queue';

  Future<SharedPreferences> _prefs() async {
    final p = await SharedPreferences.getInstance();
    await p.reload(); // the app (another isolate) may have changed the token / settings
    return p;
  }

  Future<void> begin() async {
    try {
      await RingAlert.init(background: true);
    } catch (_) {}
    final settings = AndroidSettings(accuracy: LocationAccuracy.high, distanceFilter: 0, intervalDuration: const Duration(minutes: 1));
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(_onFix, onError: (_) {});
    // a fix is asked for directly when the stream goes quiet (some phones pause it)
    _watch = Timer.periodic(const Duration(minutes: 2), (_) async {
      final p = await _prefs();
      if (p.getBool('bg_tracking_on') != true || ((await TokenStore.read()) ?? '').isEmpty) return finish();
      if (_lastFix == null || DateTime.now().difference(_lastFix!) > const Duration(minutes: 3)) {
        try {
          final pos = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 40)));
          await _onFix(pos);
        } catch (_) {}
      }
    });
  }

  Future<void> finish() async {
    if (_done) return;
    _done = true;
    await _sub?.cancel();
    _watch?.cancel();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('bg_tracking_on', false);
    } catch (_) {}
    await service.stopSelf();
  }

  static double _dist(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0, rad = math.pi / 180;
    final dLat = (lat2 - lat1) * rad, dLng = (lng2 - lng1) * rad;
    final x = math.pow(math.sin(dLat / 2), 2) + math.cos(lat1 * rad) * math.cos(lat2 * rad) * math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.sqrt(x));
  }

  Future<void> _onFix(Position pos) async {
    if (_done) return;
    _lastFix = DateTime.now();
    final p = await _prefs();
    final token = await TokenStore.read(); // the secure storage on Android (VA-04), the legacy copy while it migrates
    if (p.getBool('bg_tracking_on') != true || token == null || token.isEmpty) return finish();
    api.token = token;
    final rangBefore = p.getBool('bg_ringed_outside') == true;
    final outside = await _checkOffice(p, pos);
    if (_done) return; // switched off for this employee: stopped, nothing sent
    // the phone rang just now: tell the server at once (it alerts the managers), not at the next interval
    final rang = outside == true && !rangBefore && p.getBool('bg_ringed_outside') == true;
    _status(outside);
    final every = Duration(minutes: p.getInt('bg_tracking_interval') ?? 5) - const Duration(seconds: 20);
    if (!rang && _lastSent != null && DateTime.now().difference(_lastSent!) < every) return;
    _lastSent = DateTime.now();
    await _flush(p);
    final body = {'lat': pos.latitude, 'lng': pos.longitude, 'accuracyM': pos.accuracy, if (rang) 'localAlarm': true};
    try {
      final r = await api.post('/tracking/ping', body);
      // following was turned off for this employee (or the company): the service stops
      if (r['tracking'] == false) {
        await p.setBool('tracking_enabled', false);
        await finish();
      }
    } on ApiException catch (e) {
      if (e.isNetwork) {
        // no internet: kept with its time and sent later (offline tracking)
        final q = _read(p)..add({...body, 'offlineAt': DateTime.now().toUtc().toIso8601String()});
        await p.setString(_queueKey, jsonEncode(q.length > 300 ? q.sublist(q.length - 300) : q));
      } else if (e.status == 409 || e.status == 401) {
        // 409 = not in a shift any more (checked out); 401 = signed out → stop
        await finish();
      }
    } catch (_) {}
  }

  List<Map<String, dynamic>> _read(SharedPreferences p) {
    try {
      return (jsonDecode(p.getString(_queueKey) ?? '[]') as List).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _flush(SharedPreferences p) async {
    var q = _read(p);
    while (q.isNotEmpty) {
      try {
        await api.post('/tracking/ping', q.first);
      } on ApiException catch (e) {
        if (e.isNetwork) return;
      } catch (_) {
        return;
      }
      q = q.sublist(1);
      await p.setString(_queueKey, jsonEncode(q));
    }
  }

  /// Leaving the office is detected on the phone itself: rings even with no internet. Returns null when there is
  /// no office / the fix is too weak to say.
  Future<bool?> _checkOffice(SharedPreferences p, Position pos) async {
    List<Map<String, dynamic>> offices = [];
    double margin = 0;
    try {
      final j = jsonDecode(p.getString('offices_cache') ?? '{}') as Map<String, dynamic>;
      offices = ((j['offices'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
      margin = ((j['margin'] ?? 0) as num).toDouble();
    } catch (_) {}
    if (offices.isEmpty || pos.accuracy > 200) return null; // weak GPS never counts as leaving
    final outside = offices.every((o) =>
        _dist(pos.latitude, pos.longitude, (o['lat'] as num).toDouble(), (o['lng'] as num).toDouble()) >
        (o['radiusM'] as num).toDouble() + margin);
    if (!outside) {
      await p.remove('bg_ringed_outside');
      return false;
    }
    if (p.getBool('bg_ringed_outside') == true || await _allowedOut(p)) return true;
    // «تتبع أثناء العمل» / «حضور وانصراف» switched off since the shift started: no ring, the service stops
    // (asked at the moment of leaving; with no internet the phone rings on its last known settings)
    if (!await _stillFollowed(p)) {
      await finish();
      return null;
    }
    await p.setBool('bg_ringed_outside', true);
    try {
      await RingAlert.show(id: 7001, title: 'إنت برّه نطاق المكتب ⚠️',
          body: 'ارجع المكتب، أو اطلب إذن / معاينة من التطبيق.', payload: 'unauthorized_exit_self');
    } catch (_) {}
    return true;
  }

  Future<bool> _stillFollowed(SharedPreferences p) async {
    try {
      final c = await api.get('/tracking/config');
      await p.setBool('tracking_enabled', c['enabled'] == true);
      return c['enabled'] == true;
    } catch (_) {
      return true;
    }
  }

  /// An approved permission / visit right now (asked from the server, else the last answer kept on the phone).
  Future<bool> _allowedOut(SharedPreferences p) async {
    DateTime? until;
    try {
      final t = await api.get('/outings/today');
      until = DateTime.tryParse('${(t['active'] as Map?)?['expected_return_at']}');
      await p.setString('outing_until', until?.toIso8601String() ?? '');
    } catch (_) {
      until = DateTime.tryParse(p.getString('outing_until') ?? '');
    }
    return until != null && until.isAfter(DateTime.now());
  }

  void _status(bool? outside) {
    final s = service;
    if (s is! AndroidServiceInstance) return;
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final where = outside == null ? '' : outside ? ' — برّه نطاق المكتب' : ' — جوه المكتب';
    s.setForegroundNotificationInfo(
      title: 'فاليو نيفو — الحضور شغال',
      content: 'آخر موقع ${two(now.hour)}:${two(now.minute)}$where. التتبع بيقف لوحده بعد الانصراف',
    );
  }
}
