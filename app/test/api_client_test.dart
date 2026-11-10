import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:jph_real_estate_hr/core/api.dart';

void main() {
  test('sends bearer token and decodes JSON', () async {
    late http.Request seen;
    final api = ApiClient(baseUrl: 'http://x/', client: MockClient((r) async { seen = r; return http.Response(jsonEncode({'ok': true}), 200, headers: {'content-type': 'application/json'}); }))..token = 'abc';
    final r = await api.get('/me', {'month': '2026-03', 'empty': null});
    expect(r['ok'], true);
    expect(seen.headers['Authorization'], 'Bearer abc');
    expect(seen.url.toString(), 'http://x/me?month=2026-03');
  });

  test('maps the error envelope and flags forced password change', () async {
    final api = ApiClient(baseUrl: 'http://x', client: MockClient((_) async => http.Response(
        jsonEncode({'error': {'code': 'forbidden', 'message': 'change', 'details': {'reason': 'must_change_password'}}}), 403)));
    try { await api.get('/dashboard'); fail('should throw'); } on ApiException catch (e) {
      expect(e.status, 403);
      expect(e.mustChangePassword, true);
    }
  });

  test('401 triggers onUnauthorized; network failure becomes isNetwork', () async {
    var signedOut = false;
    final api = ApiClient(baseUrl: 'http://x', client: MockClient((_) async => http.Response('{"error":{"code":"unauthenticated","message":"x"}}', 401)))
      ..token = 't'..onUnauthorized = () => signedOut = true;
    await expectLater(api.get('/me'), throwsA(isA<ApiException>()));
    expect(signedOut, true);
    final down = ApiClient(baseUrl: 'http://x', client: MockClient((_) async => throw http.ClientException('down')));
    try { await down.get('/me'); fail('should throw'); } on ApiException catch (e) { expect(e.isNetwork, true); }
  });

  test('a read seen again is served at once; any change forgets it; live paths are never remembered', () async {
    var n = 0;
    final api = ApiClient(baseUrl: 'http://x', client: MockClient((r) async {
      n++;
      return http.Response(jsonEncode({'n': n}), 200);
    }))..token = 't';
    expect((await api.get('/employees'))['n'], 1);
    expect((await api.get('/employees'))['n'], 1, reason: 'remembered');
    await api.post('/employees', {});
    expect((await api.get('/employees'))['n'], 3, reason: 'a change forgets it');
    final a = await api.get('/attendance/today');
    final b = await api.get('/attendance/today');
    expect(b['n'], greaterThan(a['n'] as int), reason: 'live screens always ask the server');
  });
}
