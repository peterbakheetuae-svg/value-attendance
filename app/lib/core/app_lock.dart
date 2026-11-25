import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Asks the phone's own lock: the fingerprint / face, or — when the person prefers or has none — the device PIN,
/// pattern or password. Swappable in tests.
abstract class DeviceAuthenticator {
  /// whether this device can confirm its owner at all (a biometric OR a screen lock is set up)
  Future<bool> available();

  /// shows the system prompt; true only when the owner confirmed it. Never throws.
  Future<bool> confirm(String reason);
}

class LocalDeviceAuthenticator implements DeviceAuthenticator {
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  Future<bool> available() async {
    if (kIsWeb) return false; // the browser has no device-lock API for this app
    try {
      return await _auth.isDeviceSupported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> confirm(String reason) async {
    try {
      // biometricOnly: false → the system prompt also offers the device PIN / pattern / password
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true, useErrorDialogs: true),
      );
    } catch (_) {
      return false;
    }
  }
}

/// Optional lock over the SAVED session (the person chooses it in الإعدادات).
///
/// It never signs anyone out and never touches the server session: the session stays exactly as the server keeps it
/// (180 days, renewed on every use, revoked by sign-out / password change / deactivation). The lock only hides the
/// app until the phone's owner confirms with a fingerprint / face or the device PIN, pattern or password:
///   - when the app starts with a saved session (also after a reboot),
///   - when it comes back after more than [relockAfter] in the background.
/// The choice is a per-device preference, not a secret; signing out clears it with the rest of the app's settings.
class AppLock extends ChangeNotifier with WidgetsBindingObserver {
  AppLock({DeviceAuthenticator? authenticator, this.relockAfter = const Duration(minutes: 5), DateTime Function()? clock})
      : _auth = authenticator ?? LocalDeviceAuthenticator(),
        _now = clock ?? DateTime.now;

  static AppLock instance = AppLock();
  static const prefKey = 'app_lock_enabled';
  static const reason = 'أكّد إنك صاحب الموبايل علشان تفتح فاليو نيفو';

  final DeviceAuthenticator _auth;
  final Duration relockAfter;
  final DateTime Function() _now;

  bool _enabled = false;
  bool _locked = false;
  bool _unlocking = false;
  DateTime? _backgroundAt;
  bool Function() _hasSession = () => false;

  bool get enabled => _enabled;
  bool get locked => _enabled && _locked && _hasSession();

  /// at start-up: reads the choice and, with a saved session, starts locked
  Future<void> init({required bool Function() hasSession}) async {
    _hasSession = hasSession;
    try {
      final p = await SharedPreferences.getInstance();
      _enabled = p.getBool(prefKey) == true && await _auth.available();
    } catch (_) {
      _enabled = false;
    }
    _locked = _enabled && hasSession();
    notifyListeners();
  }

  Future<bool> available() => _auth.available();

  /// turning it on asks the device first (so nobody can lock the app with a lock they cannot open);
  /// turning it off also asks, so a borrowed, unlocked phone cannot remove it
  Future<bool> setEnabled(bool on) async {
    if (on == _enabled) return true;
    if (on && !await _auth.available()) return false;
    if (!await _auth.confirm(reason)) return false;
    _enabled = on;
    _locked = false;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(prefKey, on);
    } catch (_) {}
    notifyListeners();
    return true;
  }

  /// the lock screen's button (and its first frame): one system prompt at a time
  Future<bool> unlock() async {
    if (!locked) return true;
    if (_unlocking) return false;
    _unlocking = true;
    try {
      final ok = await _auth.confirm(reason);
      if (ok) {
        _locked = false;
        notifyListeners();
      }
      return ok;
    } finally {
      _unlocking = false;
    }
  }

  /// signed out (or the session ended): nothing to protect any more
  void reset() {
    _locked = false;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_enabled) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundAt ??= _now();
    } else if (state == AppLifecycleState.resumed) {
      final since = _backgroundAt;
      _backgroundAt = null;
      // the system prompt itself pauses the app: only a real absence longer than relockAfter locks again
      if (since != null && !_unlocking && _now().difference(since) >= relockAfter && _hasSession()) {
        _locked = true;
        notifyListeners();
      }
    }
  }
}
