import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// API base URL is injected at build time:
///   flutter run -d chrome --dart-define=API_BASE_URL=http://localhost:8095
const String kApiBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:8095');

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
  final String baseUrl;
  final http.Client _http;
  String? token;
  void Function()? onUnauthorized;

  ApiClient({String? baseUrl, http.Client? client})
      : baseUrl = (baseUrl ?? kApiBaseUrl).replaceAll(RegExp(r'/+$'), ''),
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
      _send(() => _http.get(_uri(path, query), headers: _headers()));
  Future<Map<String, dynamic>> post(String path, [Object? body]) =>
      _send(() => _http.post(_uri(path), headers: _headers(json: true), body: jsonEncode(body ?? {})));
  Future<Map<String, dynamic>> put(String path, [Object? body]) =>
      _send(() => _http.put(_uri(path), headers: _headers(json: true), body: jsonEncode(body ?? {})));
  Future<Map<String, dynamic>> patch(String path, [Object? body]) =>
      _send(() => _http.patch(_uri(path), headers: _headers(json: true), body: jsonEncode(body ?? {})));
  Future<Map<String, dynamic>> delete(String path) => _send(() => _http.delete(_uri(path), headers: _headers()));

  /// Binary download (xlsx / photos / documents).
  Future<Uint8List> bytes(String path, [Map<String, String?>? query]) async {
    final res = await _raw(() => _http.get(_uri(path, query), headers: _headers()));
    if (res.statusCode >= 400) throw _error(res);
    return res.bodyBytes;
  }

  Future<http.Response> _raw(Future<http.Response> Function() f) async {
    try {
      return await f().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw ApiException(0, 'timeout', 'timeout');
    } catch (e) {
      if (e is ApiException) rethrow;
      // SocketException / ClientException / XMLHttpRequest error on web
      throw ApiException(0, 'network', 'network');
    }
  }

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() f) async {
    final res = await _raw(f);
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
