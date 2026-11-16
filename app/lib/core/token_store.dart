import 'package:shared_preferences/shared_preferences.dart';

import 'platform_info.dart';
import 'token_store_stub.dart' if (dart.library.io) 'token_store_windows.dart' as dpapi;

/// Where the sign-in token is kept between runs.
///  - Android / web: unchanged — the same `token` entry as before (existing sessions keep working).
///  - Windows: encrypted with Windows DPAPI (bound to the signed-in Windows user), so the token never sits
///    in plain text in the app's settings file. Copying that file to another PC / user does not carry the session.
class TokenStore {
  TokenStore._();

  static const _plainKey = 'token';
  static const _protectedKey = 'token_dpapi';

  static Future<String?> read() async {
    final p = await SharedPreferences.getInstance();
    if (!PlatformInfo.isWindows) return p.getString(_plainKey);
    final sealed = p.getString(_protectedKey);
    // never keep a plain copy on Windows
    if (p.containsKey(_plainKey)) await p.remove(_plainKey);
    if (sealed == null) return null;
    final tok = dpapi.unprotect(sealed);
    if (tok == null) await p.remove(_protectedKey); // unreadable (other user / damaged): sign in again
    return tok;
  }

  static Future<void> write(String token) async {
    final p = await SharedPreferences.getInstance();
    if (!PlatformInfo.isWindows) {
      await p.setString(_plainKey, token);
      return;
    }
    final sealed = dpapi.protect(token);
    if (sealed == null) throw StateError('Windows could not protect the session token');
    await p.setString(_protectedKey, sealed);
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_plainKey);
    await p.remove(_protectedKey);
  }
}
