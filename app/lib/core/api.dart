import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

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
  void Function()? onUnauthorized;

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

  Future<Map<String, dynamic>> get(String path, [Map<String, String?>? query]) =>
      _send(() => _http.get(_uri(path, query), headers: _headers()), retry: true);
  Future<Map<String, dynamic>> post(String path, [Object? body]) =>
      _send(() => _http.post(_uri(path), headers: _headers(json: true), body: jsonEncode(body ?? {})));
  Future<Map<String, dynamic>> put(String path, [Object? body]) =>
      _send(() => _http.put(_uri(path), headers: _headers(json: true), body: jsonEncode(body ?? {})));
  Future<Map<String, dynamic>> patch(String path, [Object? body]) =>
      _send(() => _http.patch(_uri(path), headers: _headers(json: true), body: jsonEncode(body ?? {})));
  Future<Map<String, dynamic>> delete(String path) => _send(() => _http.delete(_uri(path), headers: _headers()));

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
