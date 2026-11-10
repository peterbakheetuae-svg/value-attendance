import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../jph/services/api_service.dart';
import 'web_push_stub.dart' if (dart.library.js_interop) 'web_push_web.dart' as impl;

/// Notifications for the web app (iPhone Home Screen app / desktop browsers) — Web Push.
/// Android keeps its own push (Firebase). Safe to call often: it asks at most once a day, and on iPhone in Safari
/// it first explains how to add the app to the Home Screen (Apple allows web notifications only there).
class WebPush {
  static bool _busy = false;

  static Future<void> ensure() async {
    if (!kIsWeb || _busy || !impl.supported()) return;
    _busy = true;
    try {
      final k = await ApiService.post({'action': 'web_push_key'});
      final key = '${k['publicKey'] ?? ''}';
      if (key.isEmpty) return;
      final perm = impl.permission();
      String sub = '';
      if (perm == 'granted') {
        sub = await impl.current(key);
      } else if (perm == 'default') {
        if (impl.ios() && !impl.standalone()) {
          await impl.installHint();
          return;
        }
        sub = await impl.prompt(key);
      }
      if (sub.isEmpty) return;
      final j = jsonDecode(sub) as Map<String, dynamic>;
      await ApiService.post({'action': 'web_push_save', 'endpoint': j['endpoint'], 'keys': j['keys']});
    } catch (_) {
      // best-effort: in-app alerts still work while the app is open
    } finally {
      _busy = false;
    }
  }
}
