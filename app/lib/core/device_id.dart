import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Stable random id for this install (Value HR device binding). Generated once, kept in local storage.
/// Clearing the app data / browser storage makes it a "new phone" that HR must unlink.
class DeviceId {
  static String? _cached;

  static Future<String> get() async {
    if (_cached != null) return _cached!;
    final p = await SharedPreferences.getInstance();
    var id = p.getString('device_id');
    if (id == null || id.length < 16) {
      final r = Random.secure();
      const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
      id = List.generate(32, (_) => chars[r.nextInt(chars.length)]).join();
      await p.setString('device_id', id);
    }
    return _cached = id;
  }

  static String label() {
    if (kIsWeb) return 'Web browser';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android: return 'Android';
      case TargetPlatform.iOS: return 'iPhone';
      default: return defaultTargetPlatform.name;
    }
  }
}
