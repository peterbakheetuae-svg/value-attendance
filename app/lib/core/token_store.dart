import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'platform_info.dart';
import 'token_store_stub.dart' if (dart.library.io) 'token_store_windows.dart' as dpapi;

/// Where the sign-in token is kept between runs.
///  - Android: in the Android Keystore-backed secure storage (VA-04) — never in the plain settings file, never in
///    backups (the manifest also disables backup). A session saved by an older version (plain `token` entry) is moved
///    there on first read: copied, read back to verify, and the plain copy is removed in every case — if the secure
///    storage fails, the session is kept in memory for this run only (never left on disk in plain text; release gate
///    2026-11-26: no insecure fallback).
///  - Windows: encrypted with Windows DPAPI (bound to the signed-in Windows user), unchanged.
///    A NEW session is never written in plain text: if the secure storage cannot keep it, it lives in memory only for this
///    run (the employee signs in again after the app restarts) — security review L-2026-11-24, fail closed.
///  - Web: the same `token` entry as before (browser storage).
/// The token itself is never printed or logged.
class TokenStore {
  TokenStore._();

  static const _plainKey = 'token';
  static const _protectedKey = 'token_dpapi';
  static const _secureKey = 'session_token';
  // set when signing out could not delete the secure copy: that copy is never used again (cleared by the next sign-in)
  static const _signedOutKey = 'session_signed_out';
  static const _secure = FlutterSecureStorage();
  // Android only: a session the secure storage refused to keep (never written to disk in plain text)
  static String? _memory;
  /// tests only: behave as a phone whose Keystore-backed storage refuses to read / write
  @visibleForTesting
  static bool debugSecureStorageFails = false;

  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static Future<String?> read() async {
    final p = await SharedPreferences.getInstance();
    if (_android) return _readAndroid(p);
    if (!PlatformInfo.isWindows) return p.getString(_plainKey);
    final sealed = p.getString(_protectedKey);
    // never keep a plain copy on Windows
    if (p.containsKey(_plainKey)) await p.remove(_plainKey);
    if (sealed == null) return null;
    final tok = dpapi.unprotect(sealed);
    if (tok == null) await p.remove(_protectedKey); // unreadable (other user / damaged): sign in again
    return tok;
  }

  static Future<String?> _readAndroid(SharedPreferences p) async {
    if (p.getBool(_signedOutKey) == true) {
      if (_memory != null) return _memory; // signed in again during this run, the secure storage refusing
      await p.remove(_plainKey);
      try { await _secure.delete(key: _secureKey); await p.remove(_signedOutKey); } catch (_) {}
      return null;
    }
    String? secure;
    try {
      if (debugSecureStorageFails) throw StateError('secure storage unavailable (test)');
      secure = await _secure.read(key: _secureKey);
    } catch (_) {
      secure = null; // the secure storage is unavailable: the legacy copy below is moved to memory, never kept on disk
    }
    final legacy = p.getString(_plainKey);
    if (secure != null && secure.isNotEmpty) {
      if (legacy != null) await p.remove(_plainKey); // already migrated: the plain copy goes
      return secure;
    }
    if (_memory != null) {
      if (legacy != null) await p.remove(_plainKey);
      return _memory;
    }
    if (legacy == null || legacy.isEmpty) {
      if (legacy != null) await p.remove(_plainKey);
      return null;
    }
    // migrate an older session: copy → verify. The plain copy is removed either way: when the secure storage cannot keep
    // it, the session lives in memory for this run only (the employee signs in again after a restart) — fail closed
    final kept = await _storeSecure(legacy);
    _memory = kept ? null : legacy;
    await p.remove(_plainKey);
    return legacy;
  }

  /// true only when the token was written AND read back identical
  static Future<bool> _storeSecure(String token) async {
    try {
      if (debugSecureStorageFails) return false;
      await _secure.write(key: _secureKey, value: token);
      return await _secure.read(key: _secureKey) == token;
    } catch (_) {
      return false;
    }
  }

  static Future<void> write(String token) async {
    final p = await SharedPreferences.getInstance();
    if (_android) {
      // the phone's secure storage failed: the session works for this run only, never as a plain file
      _memory = await _storeSecure(token) ? null : token;
      await p.remove(_plainKey);
      if (_memory == null) await p.remove(_signedOutKey); // a fresh secure session replaces the signed-out one
      return;
    }
    if (!PlatformInfo.isWindows) {
      await p.setString(_plainKey, token);
      return;
    }
    final sealed = dpapi.protect(token);
    if (sealed == null) throw StateError('Windows could not protect the session token');
    await p.setString(_protectedKey, sealed);
  }

  static Future<void> clear() async {
    _memory = null;
    final p = await SharedPreferences.getInstance();
    await p.remove(_plainKey);
    await p.remove(_protectedKey);
    if (_android) {
      try {
        if (debugSecureStorageFails) throw StateError('secure storage unavailable (test)');
        await _secure.delete(key: _secureKey);
        await p.remove(_signedOutKey);
      } catch (_) {
        // the secure copy could not be deleted: mark it signed out so it is never restored (fail closed)
        await p.setBool(_signedOutKey, true);
      }
    }
  }
}
