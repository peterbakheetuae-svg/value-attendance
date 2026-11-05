import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'api.dart';

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
  bool get running => _sub != null || _timer != null;

  /// Starts if the company turned tracking on. Safe to call repeatedly.
  Future<void> start(ApiClient api, {required String notifTitle, required String notifText}) async {
    _api = api;
    if (running) return;
    try {
      final cfg = await api.get('/tracking/config');
      if (cfg['enabled'] != true) return;
      _intervalMin = (cfg['intervalMinutes'] ?? 5) as int;
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) return;

      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final settings = AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          intervalDuration: Duration(minutes: _intervalMin),
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
    final now = DateTime.now();
    if (_lastSent != null && now.difference(_lastSent!) < Duration(minutes: _intervalMin) - const Duration(seconds: 20)) return;
    _lastSent = now;
    try {
      // send anything recorded offline first (e.g. the check-in) so the order is kept
      await _api?.flushQueue();
      // no internet: the point is kept with its time and sent later (offline tracking)
      await _api?.postOrQueue('/tracking/ping', {'lat': pos.latitude, 'lng': pos.longitude, 'accuracyM': pos.accuracy}, label: 'موقع');
    } on ApiException catch (e) {
      // 409 = not in a shift any more (checked out) → stop
      if (e.status == 409 && ApiClient.pending.value == 0) await stop();
    } catch (_) {}
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _timer?.cancel();
    _timer = null;
    _lastSent = null;
  }
}
