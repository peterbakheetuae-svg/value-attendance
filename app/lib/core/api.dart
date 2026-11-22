import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// API base URL is injected at build time:
///   flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8095
const String kApiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:8095');

/// Optional extra addresses of the same API (comma separated), tried in order when one cannot be
/// reached — some mobile networks block a hosting domain; a mirror on another domain keeps the app working.
const String kApiMirrorUrls = String.fromEnvironment('API_MIRROR_URLS', defaultValue: '');

class ApiException implements Exception {
  final int status;
  final String code;
  final String message;
  final Map<String, dynamic>? details;
  ApiException(this.status, this.code, this.message, [this.details]);
  bool get isNetwork => status == 0;
  bool get mustChangePassword => status == 403 && details?['reason'] == 'must_change_password';
  @override
  String toString() => message;
}

class ApiClient {
  final List<String> _bases;
  int _active = 0;
  final http.Client _http;
  String? token;

  /// The signed-in employee (set by the session once it knows who signed in). Everything kept on the phone for
  /// offline use — remembered reads and queued actions — belongs to one person and is only ever shown to / sent
  /// as that person. Null while nobody is known: nothing is kept for offline reading then.
  String? get owner => _owner;
  set owner(String? v) {
    final o = (v == null || v.isEmpty) ? null : v;
    if (o == _owner) return;
    _owner = o;
    clearCache(); // a different person never sees the previous one's remembered reads
  }
  String? _owner;

  /// A short, one-way fingerprint of a session token (never the token itself) — ties an action queued before the
  /// person was known to the session that recorded it.
  static String? tokenTag(String? t) =>
      (t == null || t.isEmpty) ? null : crypto.sha256.convert(utf8.encode(t)).toString().substring(0, 16);

  void Function()? onUnauthorized;
  /// a 403: the permissions this app holds may be out of date (changed by an administrator) — re-read them
  void Function()? onForbidden;

  /// The address currently in use (switches to a mirror when the first one is unreachable).
  String get baseUrl => _bases[_active];

  ApiClient({String? baseUrl, http.Client? client})
      : _bases = [
          for (final b in [
            if (baseUrl == null) ...kApiMirrorUrls.split(','),
            baseUrl ?? kApiBaseUrl,
          ])
            if (b.trim().isNotEmpty) b.trim().replaceAll(RegExp(r'/+$'), ''),
        ],
        _http = client ?? http.Client();

  Map<String, String> _headers({bool json = false}) => {
        if (token != null) 'Authorization': 'Bearer $token',
        if (json) 'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

  Uri _uri(String path, [Map<String, String?>? query]) {
    final q = <String, String>{};
    query?.forEach((k, v) { if (v != null && v.isNotEmpty) q[k] = v; });
    return Uri.parse('$baseUrl$path').replace(queryParameters: q.isEmpty ? null : q);
  }

  // ---- speed: a screen opened again shows its last data at once and refreshes it in the background --------------
  // Kept in memory for 5 minutes, per signed-in user. Any change the person makes (post / put / patch / delete)
  // clears it, so their own actions always show fresh. Live things (attendance, outings, notifications, the
  // signed-in account) are never served from it. Identical reads in flight are shared instead of sent twice.
  static const _memTtl = Duration(minutes: 5);
  static const _memFresh = Duration(seconds: 15);
  static const _live = ['/attendance', '/outings', '/notifications', '/me', '/auth', '/tracking', '/alerts', '/healthz', '/media'];
  final Map<String, (Map<String, dynamic>, DateTime)> _mem = {};
  final Map<String, Future<Map<String, dynamic>>> _inflight = {};

  /// Forget every remembered read (sign-out, or after a change).
  void clearCache() {
    _mem.clear();
    _gen++;
  }

  int _gen = 0; // bumps on every change: a read that started before it is not remembered

  Future<Map<String, dynamic>> get(String path, [Map<String, String?>? query]) {
    final memKey = '${token.hashCode}|${_uri(path, query).replace(scheme: 'x', host: 'x')}';
    final live = _live.any(path.startsWith);
    final hit = live ? null : _mem[memKey];
    final age = hit == null ? null : DateTime.now().difference(hit.$2);
    final gen = _gen;
    Future<Map<String, dynamic>> fetch() => _inflight[memKey] ??= _getNetwork(path, query).then((r) {
          if (!live && r['_offline'] != true && gen == _gen) _mem[memKey] = (r, DateTime.now());
          return r;
        }).whenComplete(() {
          _inflight.remove(memKey); // (a block: returning the removed future would make it wait for itself)
        });
    if (hit != null && age! < _memTtl) {
      if (age > _memFresh) fetch().catchError((_) => <String, dynamic>{}); // refresh quietly for the next time
      return Future.value({...hit.$1});
    }
    return fetch();
  }

  /// Reads work offline: every successful read is kept on the phone and returned (marked
  /// `_offline: true`) when there is no connection.
  Future<Map<String, dynamic>> _getNetwork(String path, [Map<String, String?>? query]) async {
    // the offline copy is filed under the person who read it: another person signed in on the same phone never gets it
    final who = owner;
    final key = who == null ? null : 'apicache:$who:${_uri(path, query).replace(scheme: 'x', host: 'x').toString()}';
    try {
      final r = await _send(() => _http.get(_uri(path, query), headers: _headers()), retry: true);
      if (key != null && who == owner) _cachePut(key, r);
      return r;
    } on ApiException catch (e) {
      if (!e.isNetwork || key == null) rethrow;
      final cached = await _cacheGet(key);
      if (cached == null) rethrow;
      return {...cached, '_offline': true};
    }
  }

  Future<void> _cachePut(String key, Map<String, dynamic> body) async {
    try {
      final s = jsonEncode(body);
      if (s.length > 300000) return; // big lists/files are not kept
      final p = await SharedPreferences.getInstance();
      await p.setString(key, s);
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _cacheGet(String key) async {
    try {
      final s = (await SharedPreferences.getInstance()).getString(key);
      return s == null ? null : jsonDecode(s) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Forget every read kept for offline use, whoever it belonged to (the session ended: expired, revoked or signed
  /// out). Queued actions are not touched here — each one is sent only as the person who recorded it.
  static Future<void> clearOfflineReads() async {
    try {
      final p = await SharedPreferences.getInstance();
      for (final k in p.getKeys().where((k) => k.startsWith('apicache:')).toList()) {
        await p.remove(k);
      }
    } catch (_) {}
  }

  /// Sign-out: forget the offline reads and this person's own queued / refused actions. Actions another person
  /// recorded on this phone stay until that person signs in again; old untagged ones (recorded before actions were
  /// tagged with their owner) cannot be told apart, so they are dropped rather than sent as anyone.
  Future<void> clearOfflineOnSignOut() async {
    await clearOfflineReads();
    try {
      final p = await SharedPreferences.getInstance();
      for (final key in [_queueKey, _failedKey]) {
        final keep = _readList(p, key).where((i) => _taggedOwner(i) && !_mine(i)).toList();
        keep.isEmpty ? await p.remove(key) : await p.setString(key, jsonEncode(keep));
      }
      pending.value = 0;
    } catch (_) {}
  }

  static bool _taggedOwner(Map<String, dynamic> i) => i['owner'] != null || i['tt'] != null;

  /// An action recorded by the person signed in now (by employee, or by the session when the person was not known yet).
  bool _mine(Map<String, dynamic> i) {
    final o = i['owner'];
    if (o != null) return owner != null && o == owner;
    final tt = i['tt'];
    return tt != null && tt == tokenTag(token);
  }

  // ------------------------------------------------------------------ offline queue
  static const _queueKey = 'offline_queue';
  static const _failedKey = 'offline_failed';
  bool _flushing = false;

  /// Number of actions waiting on the phone for the internet.
  static final ValueNotifierLite<int> pending = ValueNotifierLite<int>(0);

  /// A write that must not be lost: sent now when online; with no connection it is saved on the
  /// phone with the time it happened (`offlineAt`) and sent automatically when the internet is back.
  /// Returns the server reply, or `{'queued': true}`.
  Future<Map<String, dynamic>> postOrQueue(String path, Map<String, dynamic> body, {required String label}) async {
    try {
      return await post(path, body);
    } on ApiException catch (e) {
      if (!e.isNetwork) rethrow;
      final p = await SharedPreferences.getInstance();
      final q = _readList(p, _queueKey);
      q.add({'path': path, 'body': {...body, 'offlineAt': DateTime.now().toUtc().toIso8601String()}, 'label': label,
        'at': DateTime.now().toIso8601String(), 'owner': owner, 'tt': tokenTag(token)});
      await p.setString(_queueKey, jsonEncode(q));
      pending.value = q.where(_mine).length;
      return {'queued': true};
    }
  }

  static List<Map<String, dynamic>> _readList(SharedPreferences p, String key) {
    try {
      return ((jsonDecode(p.getString(key) ?? '[]') as List).whereType<Map>().map((m) => m.cast<String, dynamic>())).toList();
    } catch (_) {
      return [];
    }
  }

  /// Send what was saved offline, oldest first. Stops at the first connection failure.
  /// Items the server refuses (e.g. already done, too old) move to a "failed" list with the reason.
  Future<({int sent, int important, List<Map<String, dynamic>> failed})> flushQueue() async {
    if (_flushing || token == null) return (sent: 0, important: 0, failed: const <Map<String, dynamic>>[]);
    _flushing = true;
    var sent = 0, important = 0;
    final failed = <Map<String, dynamic>>[];
    try {
      final p = await SharedPreferences.getInstance();
      var q = _readList(p, _queueKey);
      pending.value = q.where(_mine).length;
      // only this person's actions are sent (with this person's session); anyone else's wait for their owner
      var i = 0;
      while (i < q.length) {
        final item = q[i];
        if (!_mine(item)) { i++; continue; }
        try {
          await post(item['path'] as String, (item['body'] as Map).cast<String, dynamic>());
          sent++;
          if (item['path'] != '/tracking/ping') important++;
        } on ApiException catch (e) {
          if (e.isNetwork) break;
          // a refused location point (e.g. shift already closed) is just dropped
          if (item['path'] != '/tracking/ping') failed.add({...item, 'error': e.message});
        }
        q = _readList(p, _queueKey); // (an action may have been queued meanwhile)
        final at = q.indexWhere((x) => jsonEncode(x) == jsonEncode(item));
        if (at >= 0) q.removeAt(at);
        await p.setString(_queueKey, jsonEncode(q));
        pending.value = q.where(_mine).length;
        i = at >= 0 ? at : i;
      }
      if (failed.isNotEmpty) {
        final f = _readList(p, _failedKey)..addAll(failed);
        await p.setString(_failedKey, jsonEncode(f.length > 50 ? f.sublist(f.length - 50) : f));
      }
    } catch (_) {
      // try again next time
    } finally {
      _flushing = false;
    }
    return (sent: sent, important: important, failed: failed);
  }

  /// a change makes the remembered reads stale (location pings are not a change anyone sees)
  void _changed(String path) {
    if (!path.startsWith('/tracking')) clearCache();
  }

  Future<Map<String, dynamic>> post(String path, [Object? body]) {
    _changed(path);
    return _send(() => _http.post(_uri(path), headers: _headers(json: true), body: jsonEncode(body ?? {})))
        .whenComplete(() => _changed(path));
  }

  Future<Map<String, dynamic>> put(String path, [Object? body]) {
    _changed(path);
    return _send(() => _http.put(_uri(path), headers: _headers(json: true), body: jsonEncode(body ?? {})))
        .whenComplete(() => _changed(path));
  }

  Future<Map<String, dynamic>> patch(String path, [Object? body]) {
    _changed(path);
    return _send(() => _http.patch(_uri(path), headers: _headers(json: true), body: jsonEncode(body ?? {})))
        .whenComplete(() => _changed(path));
  }

  Future<Map<String, dynamic>> delete(String path) {
    _changed(path);
    return _send(() => _http.delete(_uri(path), headers: _headers())).whenComplete(() => _changed(path));
  }

  /// Binary download (xlsx / photos / documents).
  Future<Uint8List> bytes(String path, [Map<String, String?>? query]) async {
    final res = await _raw(() => _http.get(_uri(path, query), headers: _headers()), retry: true);
    if (res.statusCode >= 400) throw _error(res);
    return res.bodyBytes;
  }

  Future<http.Response> _raw(Future<http.Response> Function() f, {bool retry = false}) async {
    // reads get one quiet retry (the free API / database may be waking up); writes never repeat
    final tries = retry ? 2 : 1;
    for (var attempt = 1; ; attempt++) {
      try {
        return await f().timeout(Duration(seconds: _bases.length > 1 ? 20 : 40));
      } on TimeoutException {
        // a blocked domain often just hangs: move to the next mirror
        if (_bases.length > 1 && attempt <= _bases.length) {
          _active = (_active + 1) % _bases.length;
          continue;
        }
        if (attempt < tries) continue;
        throw ApiException(0, 'timeout', 'timeout — $baseUrl');
      } catch (e) {
        if (e is ApiException) rethrow;
        // unreachable address (blocked / DNS / refused): switch to the next mirror and try there
        if (_bases.length > 1 && attempt <= _bases.length) {
          _active = (_active + 1) % _bases.length;
          continue;
        }
        if (attempt < tries) { await Future<void>.delayed(const Duration(seconds: 2)); continue; }
        // SocketException / HandshakeException / ClientException / XMLHttpRequest error on web.
        // Keep the real reason so the screen can show it (helps diagnose phone-only failures).
        final why = e.toString().split('\n').first;
        throw ApiException(0, 'network', '${why.length > 160 ? why.substring(0, 160) : why} — $baseUrl');
      }
    }
  }

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() f, {bool retry = false}) async {
    final res = await _raw(f, retry: retry);
    if (res.statusCode >= 400) {
      final e = _error(res);
      if (res.statusCode == 401) onUnauthorized?.call();
      if (res.statusCode == 403 && !e.mustChangePassword) onForbidden?.call();
      throw e;
    }
    if (res.body.isEmpty) return {};
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  ApiException _error(http.Response res) {
    try {
      final b = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final e = b['error'] as Map<String, dynamic>;
      return ApiException(res.statusCode, e['code']?.toString() ?? 'error', e['message']?.toString() ?? 'error',
          e['details'] is Map<String, dynamic> ? e['details'] as Map<String, dynamic> : null);
    } catch (_) {
      return ApiException(res.statusCode, 'error', 'HTTP ${res.statusCode}');
    }
  }
}

/// Tiny listenable counter (no Flutter import in the API layer).
class ValueNotifierLite<T> {
  ValueNotifierLite(this._value);
  T _value;
  final _listeners = <void Function(T)>[];
  T get value => _value;
  set value(T v) {
    if (v == _value) return;
    _value = v;
    for (final l in List.of(_listeners)) l(v);
  }
  void listen(void Function(T) l) => _listeners.add(l);
}
