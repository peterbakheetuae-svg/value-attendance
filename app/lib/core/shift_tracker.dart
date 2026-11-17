import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api.dart';
import 'ring_alert.dart';
import 'shift_service.dart';

/// Value HR "متابعة أثناء الشيفت": while the employee is checked in, the app sends its position
/// every N minutes. On Android it runs as a foreground service (visible notification) so it keeps
/// going with the app in the background; on the web it only runs while the page is open.
/// It stops by itself at check-out (the server refuses pings outside the shift).
class ShiftTracker {
  ShiftTracker._();
  static final ShiftTracker instance = ShiftTracker._();

  ApiClient? _api;
  StreamSubscription<Position>? _sub;
  Timer? _timer;
  DateTime? _lastSent;
  int _intervalMin = 5;
  bool _background = false; // Android: the background service does the work (keeps going with the app closed)
  bool get running => _sub != null || _timer != null || _background;

  // ---- leaving the office is detected on the phone itself (rings even with no internet)
  List<Map<String, dynamic>> _offices = [];
  double _marginM = 0;
  bool _ringedOutside = false;

  static double _dist(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0, rad = math.pi / 180;
    final dLat = (lat2 - lat1) * rad, dLng = (lng2 - lng1) * rad;
    final x = math.pow(math.sin(dLat / 2), 2) + math.cos(lat1 * rad) * math.cos(lat2 * rad) * math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.sqrt(x));
  }

  /// The approved permission / visit right now (kept on the phone so it also works offline).
  Future<bool> _allowedOut() async {
    try {
      final t = await _api?.get('/outings/today');
      final a = (t?['active'] as Map?);
      final until = DateTime.tryParse('${a?['expected_return_at']}');
      final p = await SharedPreferences.getInstance();
      await p.setString('outing_until', until?.toIso8601String() ?? '');
      return until != null && until.isAfter(DateTime.now());
    } catch (_) {
      final p = await SharedPreferences.getInstance();
      final until = DateTime.tryParse(p.getString('outing_until') ?? '');
      return until != null && until.isAfter(DateTime.now());
    }
  }

  /// true when the phone just rang for leaving the office (the server is told at once, not at the next interval).
  Future<bool> _checkOffice(Position pos) async {
    if (_offices.isEmpty || pos.accuracy > 200) return false; // weak GPS never counts as leaving
    final outside = _offices.every((o) =>
        _dist(pos.latitude, pos.longitude, (o['lat'] as num).toDouble(), (o['lng'] as num).toDouble()) >
        (o['radiusM'] as num).toDouble() + _marginM);
    if (!outside) {
      _ringedOutside = false;
      return false;
    }
    if (_ringedOutside || await _allowedOut()) return false;
    // «تتبع أثناء العمل» / «حضور وانصراف» switched off since the shift started: no ring, stop
    // (asked at the moment of leaving; with no internet the phone rings on its last known settings)
    try {
      final c = await _api?.get('/tracking/config');
      if (c != null && c['enabled'] != true) {
        final p = await SharedPreferences.getInstance();
        await p.setBool('tracking_enabled', false);
        await stop();
        return false;
      }
    } catch (_) {}
    _ringedOutside = true;
    await RingAlert.init();
    await RingAlert.show(id: 7001, title: 'إنت برّه نطاق المكتب ⚠️',
        body: 'ارجع المكتب، أو اطلب إذن / معاينة من التطبيق.', payload: 'unauthorized_exit_self');
    return true;
  }

  Future<void> _loadOffices(Map<String, dynamic>? cfg) async {
    final p = await SharedPreferences.getInstance();
    if (cfg != null && cfg['offices'] is List) {
      _offices = (cfg['offices'] as List).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
      _marginM = ((cfg['awayMarginM'] ?? 0) as num).toDouble();
      await p.setString('offices_cache', jsonEncode({'offices': _offices, 'margin': _marginM}));
    } else {
      final c = p.getString('offices_cache');
      if (c != null) {
        final j = jsonDecode(c) as Map<String, dynamic>;
        _offices = ((j['offices'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
        _marginM = ((j['margin'] ?? 0) as num).toDouble();
      }
    }
  }

  /// Starts if the company turned tracking on. Safe to call repeatedly.
  Future<void> start(ApiClient api, {required String notifTitle, required String notifText}) async {
    _api = api;
    // the background service may have stopped by itself (e.g. the phone killed it): start it again
    if (_background && !await ShiftService.running()) _background = false;
    if (running) return;
    try {
      Map<String, dynamic>? cfg;
      try {
        cfg = await api.get('/tracking/config');
      } catch (_) {
        cfg = null; // offline: use the last known settings
      }
      await _loadOffices(cfg);
      final p0 = await SharedPreferences.getInstance();
      if (cfg != null) await p0.setBool('tracking_enabled', cfg['enabled'] == true);
      if ((cfg?['enabled'] ?? p0.getBool('tracking_enabled')) != true) return;
      _intervalMin = ((cfg?['intervalMinutes'] ?? 5) as num).toInt();
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) return;

      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        // from check-in to check-out, even with the app closed / swiped away: its own background service
        if (await ShiftService.start(title: notifTitle, text: notifText, intervalMinutes: _intervalMin)) {
          _background = true;
          return;
        }
        // could not start it: follow while the app is alive (as before)
        final settings = AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          intervalDuration: const Duration(minutes: 1), // office check every minute; server pings stay at the company interval
          foregroundNotificationConfig: ForegroundNotificationConfig(
            notificationTitle: notifTitle,
            notificationText: notifText,
            enableWakeLock: true,
            setOngoing: true,
          ),
        );
        _sub = Geolocator.getPositionStream(locationSettings: settings).listen(_send, onError: (_) {});
      } else {
        await _tick();
        _timer = Timer.periodic(Duration(minutes: _intervalMin), (_) => _tick());
      }
    } catch (_) {
      // tracking is best-effort; attendance itself never depends on it
    }
  }

  Future<void> _tick() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 25)));
      await _send(pos);
    } catch (_) {}
  }

  Future<void> _send(Position pos) async {
    final rang = await _checkOffice(pos);
    if (!running) return; // switched off for this employee: stopped, nothing sent
    final now = DateTime.now();
    // a departure the phone just saw goes to the server right away (it alerts the managers), not at the next interval
    if (!rang && _lastSent != null && now.difference(_lastSent!) < Duration(minutes: _intervalMin) - const Duration(seconds: 20)) return;
    _lastSent = now;
    try {
      // send anything recorded offline first (e.g. the check-in) so the order is kept
      await _api?.flushQueue();
      // no internet: the point is kept with its time and sent later (offline tracking)
      final r = await _api?.postOrQueue('/tracking/ping',
          {'lat': pos.latitude, 'lng': pos.longitude, 'accuracyM': pos.accuracy, if (rang) 'localAlarm': true}, label: 'موقع');
      // following was turned off for this employee (or the company): stop
      if (r != null && r['tracking'] == false) {
        final p = await SharedPreferences.getInstance();
        await p.setBool('tracking_enabled', false);
        await stop();
      }
    } on ApiException catch (e) {
      // 409 = not in a shift any more (checked out) → stop
      if (e.status == 409 && ApiClient.pending.value == 0) await stop();
    } catch (_) {}
  }

  Future<void> stop() async {
    if (_background || ShiftService.supported) await ShiftService.stop();
    _background = false;
    await _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
    _lastSent = null;
    _ringedOutside = false;
  }
}
