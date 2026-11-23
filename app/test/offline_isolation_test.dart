// R1 / R2 regression tests (remediation of docs/SPEED_ENGINEER_AUDIT.md §7).
// Uses the real ApiClient, Session and JPH router against a fake two-user server.
// Before the fix, the scenarios marked LEAK reproduced: after A's session ended without a sign-out, B (same phone,
// offline) was shown A's cached cash data, A's queued check-out was sent as B, and A's offline punch made B's
// check-in turn into a check-out.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jph_real_estate_hr/core/api.dart';
import 'package:jph_real_estate_hr/core/session.dart';
import 'package:jph_real_estate_hr/core/shift_service.dart' show pingsOfSession;
import 'package:jph_real_estate_hr/jph/services/api_service.dart';
import 'package:jph_real_estate_hr/jph/services/jph_bridge.dart';

/// Fake server: users A and B, per-user private data, can go offline, can revoke tokens.
class FakeServer {
  bool offline = false;
  final revoked = <String>{};
  final writes = <String>[]; // "who|path"
  final logins = <String, int>{};
  double balance = 1000;
  String? _who(http.Request r) {
    final t = (r.headers['Authorization'] ?? '').replaceFirst('Bearer ', '');
    if (revoked.contains(t)) return null;
    return t.startsWith('tokA') ? 'A' : t.startsWith('tokB') ? 'B' : null;
  }

  http.Response _json(Object b, [int s = 200]) =>
      http.Response.bytes(utf8.encode(jsonEncode(b)), s, headers: {'content-type': 'application/json'});
  late final client = MockClient((r) async {
    if (offline) throw http.ClientException('SocketException: Network is unreachable');
    if (r.url.path == '/auth/login') {
      final id = (jsonDecode(r.body) as Map)['identifier'] as String;
      final n = logins[id] = (logins[id] ?? 0) + 1; // every sign-in gets a new token
      return _json({'token': 'tok$id$n'});
    }
    final who = _who(r);
    if (who == null) return _json({'error': {'code': 'unauthenticated', 'message': 'session expired'}}, 401);
    if (r.method != 'GET') {
      writes.add('$who|${r.url.path}');
      if (r.url.path == '/cash/expenses') balance -= 500;
      if (r.url.path.startsWith('/attendance/check-in')) return _json({'attendance': {'checkIn': '2026-11-22T07:00:00Z', 'lateMinutes': 0}});
      return _json({'ok': true});
    }
    switch (r.url.path) {
      case '/me':
        return _json({'employee': {'id': who, 'full_name': 'user $who', 'role_key': who == 'A' ? 'accountant' : 'sales_employee'},
          'permissions': who == 'A' ? ['cash.read'] : []});
      case '/cash/summary':
        return who == 'A' ? _json({'balance': balance, 'owner': 'A-PRIVATE'}) : _json({'error': {'code': 'forbidden', 'message': 'no'}}, 403);
      case '/payouts':
        return _json({'payouts': [{'employee': who, 'amount': who == 'A' ? 9999 : 1}]});
      case '/attendance/today':
        return _json({'date': _today(), 'attendance': null});
    }
    return _json({});
  });
}

String _today() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

Future<Map<String, dynamic>> _try(Future<Map<String, dynamic>> f) => f.then((r) => r, onError: (Object e) => {'error': '$e'});

Future<SharedPreferences> _prefs() => SharedPreferences.getInstance();
Future<List<String>> _cacheKeys() async => (await _prefs()).getKeys().where((k) => k.startsWith('apicache:')).toList();
Future<List<Map<String, dynamic>>> _queue() async =>
    ((jsonDecode((await _prefs()).getString('offline_queue') ?? '[]') as List).cast<Map>().map((m) => m.cast<String, dynamic>())).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux; // plain token storage, no background service
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<(FakeServer, Session)> start([FakeServer? server]) async {
    final s = server ?? FakeServer();
    final session = Session(ApiClient(baseUrl: 'http://x', client: s.client));
    JphBridge.session = session;
    return (s, session);
  }

  Future<void> expire(FakeServer srv, Session session) async {
    srv.revoked.add(session.api.token!);
    await expectLater(session.api.get('/me'), throwsA(isA<ApiException>())); // 401 → Session._clear()
    await pumpEventQueue();
    expect(session.api.token, isNull);
  }

  group('R1 offline data isolation', () {
    test('EXPIRED session (401), then B offline: A\'s cached data is not shown (was: LEAK)', () async {
      final (srv, session) = await start();
      await session.login('A', 'pw');
      expect((await session.api.get('/cash/summary'))['owner'], 'A-PRIVATE');
      await session.api.get('/payouts');
      expect(await _cacheKeys(), isNotEmpty, reason: 'A has offline copies while signed in');
      await expire(srv, session);
      expect(await _cacheKeys(), isEmpty, reason: 'the 401 removed every offline read');
      await session.login('B', 'pw');
      srv.offline = true;
      final cash = await _try(session.api.get('/cash/summary'));
      final pay = await _try(session.api.get('/payouts'));
      expect(cash['owner'], isNull, reason: 'B must not see A\'s cash summary');
      expect(cash['error'], contains('Network'));
      expect(jsonEncode(pay), isNot(contains('9999')), reason: 'B must not see A\'s payouts');
    });

    test('REVOKED during a write (401 on POST): offline reads cleared the same way', () async {
      final (srv, session) = await start();
      await session.login('A', 'pw');
      await session.api.get('/cash/summary');
      srv.revoked.add(session.api.token!);
      await expectLater(session.api.post('/cash/expenses', {}), throwsA(isA<ApiException>()));
      await pumpEventQueue();
      expect(session.api.token, isNull);
      expect(await _cacheKeys(), isEmpty);
      await session.login('B', 'pw');
      srv.offline = true;
      expect((await _try(session.api.get('/cash/summary')))['owner'], isNull);
    });

    test('ACCOUNT SWITCH without sign-out or 401: B never reads A\'s offline copies', () async {
      final (srv, session) = await start();
      await session.login('A', 'pw');
      await session.api.get('/cash/summary');
      await session.api.get('/payouts');
      await session.login('B', 'pw'); // straight over A's session
      expect(session.api.owner, 'B');
      srv.offline = true;
      expect((await _try(session.api.get('/cash/summary')))['owner'], isNull);
      expect(jsonEncode(await _try(session.api.get('/payouts'))), isNot(contains('9999')));
      expect((await _cacheKeys()).every((k) => k.startsWith('apicache:A:')), isTrue, reason: 'A\'s copies stay filed under A');
    });

    test('OFFLINE RESTORE: the owner still works offline after an app restart (no regression)', () async {
      final srv = FakeServer();
      final (_, s1) = await start(srv);
      await s1.login('A', 'pw');
      await s1.api.get('/cash/summary');
      srv.offline = true;
      final (_, s2) = await start(srv); // app restarted, no connection
      await s2.restore();
      expect(s2.id, 'A');
      final r = await s2.api.get('/cash/summary');
      expect(r['owner'], 'A-PRIVATE');
      expect(r['_offline'], true);
    });

    test('OFFLINE RESTORE after expiry + B sign-in: B\'s restored session has none of A\'s data', () async {
      final srv = FakeServer();
      final (_, s1) = await start(srv);
      await s1.login('A', 'pw');
      await s1.api.get('/cash/summary');
      await expire(srv, s1);
      await s1.login('B', 'pw');
      await s1.api.get('/payouts');
      srv.offline = true;
      final (_, s2) = await start(srv);
      await s2.restore();
      expect(s2.id, 'B');
      expect((await _try(s2.api.get('/cash/summary')))['owner'], isNull);
      expect(jsonEncode(await s2.api.get('/payouts')), isNot(contains('9999')));
    });

    test('QUEUE: A\'s queued check-out is never sent as B; it is sent when A signs in again (was: LEAK)', () async {
      final (srv, session) = await start();
      await session.login('A', 'pw');
      srv.offline = true;
      expect((await session.api.postOrQueue('/attendance/check-out', {'lat': 30.0, 'lng': 31.0}, label: 'x'))['queued'], true);
      expect(ApiClient.pending.value, 1);
      srv.offline = false;
      await expire(srv, session);
      await session.login('B', 'pw');
      final r = await session.api.flushQueue();
      expect(r.sent, 0);
      expect(srv.writes.where((w) => w.startsWith('B|/attendance/check-out')), isEmpty, reason: 'not recorded as B');
      expect(ApiClient.pending.value, 0, reason: 'B is not shown A\'s pending count');
      expect((await _queue()).single['owner'], 'A', reason: 'kept for A');
      await session.logout(); // B signs out: A's action is not B's to drop
      expect((await _queue()).single['owner'], 'A');
      await session.login('A', 'pw'); // new token for A
      final r2 = await session.api.flushQueue();
      expect(r2.sent, 1);
      expect(srv.writes.last, 'A|/attendance/check-out');
      expect(await _queue(), isEmpty);
    });

    test('QUEUE: action queued before the person is known is tied to its session token', () async {
      final (srv, session) = await start();
      session.api.token = 'tokA1';
      srv.offline = true;
      await session.api.postOrQueue('/requests', {}, label: 'x'); // owner unknown (no /me yet)
      srv.offline = false;
      session.api.token = 'tokB1';
      session.api.owner = 'B';
      expect((await session.api.flushQueue()).sent, 0, reason: 'a different session never sends it');
      session.api.token = 'tokA1';
      session.api.owner = null;
      expect((await session.api.flushQueue()).sent, 1);
      expect(srv.writes.single, 'A|/requests');
    });

    test('QUEUE: an old untagged action (previous app version) is never sent as anyone and is dropped at sign-out', () async {
      SharedPreferences.setMockInitialValues({'offline_queue': jsonEncode([{'path': '/attendance/check-out', 'body': {}, 'label': 'x'}])});
      final (srv, session) = await start();
      await session.login('B', 'pw');
      expect((await session.api.flushQueue()).sent, 0);
      expect(srv.writes, isEmpty);
      await session.logout();
      expect(await _queue(), isEmpty);
    });

    test('OFFLINE PUNCH: A\'s offline check-in does not turn B\'s check-in into a check-out (was: LEAK)', () async {
      final (srv, session) = await start();
      await session.login('A', 'pw');
      await session.api.get('/attendance/today');
      srv.offline = true;
      final a = await ApiService.post({'action': 'checkin', 'location': '30,31,10'});
      expect('${a['message']}', contains('📴'));
      srv.offline = false;
      await expire(srv, session);
      await session.login('B', 'pw');
      await session.api.get('/attendance/today'); // B's own (empty) day, kept for offline
      srv.offline = true;
      await ApiService.post({'action': 'checkin', 'location': '30,31,10'});
      final bItems = (await _queue()).where((i) => i['owner'] == 'B').map((i) => i['path']).toList();
      expect(bItems, ['/attendance/check-in'], reason: 'B checks in (before the fix this became a check-out)');
      final keys = (await _prefs()).getKeys();
      expect(keys, containsAll(['offline_punch:A', 'offline_punch:B']));
      expect(keys, isNot(contains('offline_punch')));
    });

    test('OFFLINE PUNCH: an old untagged punch is not shown to whoever signs in', () async {
      SharedPreferences.setMockInitialValues({'offline_punch': jsonEncode({'date': _today(), 'in': '2026-11-22T06:00:00Z'})});
      final (srv, session) = await start();
      await session.login('B', 'pw');
      await session.api.get('/attendance/today');
      srv.offline = true;
      await ApiService.post({'action': 'checkin', 'location': '30,31,10'});
      expect((await _queue()).map((i) => i['path']), ['/attendance/check-in']);
      expect((await _prefs()).containsKey('offline_punch'), isFalse);
    });

    test('BACKGROUND PINGS: points kept offline are sent only with the session that recorded them', () {
      final a = ApiClient.tokenTag('tokA1'), b = ApiClient.tokenTag('tokB1');
      final q = [
        {'lat': 1, 'tt': a},
        {'lat': 2, 'tt': b},
        {'lat': 3}, // untagged (previous version)
      ];
      expect(pingsOfSession(q, 'tokA1').map((x) => x['lat']), [1]);
      expect(pingsOfSession(q, 'tokB1').map((x) => x['lat']), [2]);
      expect(pingsOfSession(q, null), isEmpty);
      expect(a, isNot(contains('tokA1')), reason: 'only a fingerprint is stored, never the token');
      expect(a!.length, 16);
    });

    test('CONTROL: normal sign-out still clears everything of the person', () async {
      final (srv, session) = await start();
      await session.login('A', 'pw');
      await session.api.get('/cash/summary');
      await session.logout();
      expect(await _cacheKeys(), isEmpty);
      await session.login('B', 'pw');
      srv.offline = true;
      await expectLater(session.api.get('/cash/summary'), throwsA(isA<ApiException>()));
    });

    test('CONTROL: in-memory cache is per person (no cross-user hit online)', () async {
      final (srv, session) = await start();
      await session.login('A', 'pw');
      await session.api.get('/payouts');
      await expire(srv, session);
      await session.login('B', 'pw');
      expect(((await session.api.get('/payouts'))['payouts'] as List).first['employee'], 'B');
    });
  });

  group('R2 balance freshness', () {
    Future<ApiClient> api(double Function() balance, List<String> seen) async => ApiClient(baseUrl: 'http://x',
        client: MockClient((r) async {
          seen.add(r.url.path);
          return http.Response(jsonEncode({'balance': balance(), 'n': seen.length}), 200, headers: {'content-type': 'application/json'});
        }))..token = 'tokA1';

    test('freshness: another person changes the cashbox; reopening the screen shows the server balance (was: 1000)', () async {
      var balance = 1000.0;
      final seen = <String>[];
      final a = await api(() => balance, seen);
      expect((await a.get('/cash/summary'))['balance'], 1000.0);
      balance = 500.0; // an expense recorded by someone else
      expect((await a.get('/cash/summary'))['balance'], 500.0);
    });

    test('freshness: every audited money prefix is read from the server each time', () async {
      var balance = 1.0;
      final seen = <String>[];
      final a = await api(() => balance, seen);
      const paths = ['/cash/summary', '/cash/overview', '/cash/ledger', '/cash/receipts', '/cash/expenses', '/cash/transfers',
        '/cash/bank-moves', '/cash/fixed-expenses', '/payouts', '/payouts/cashiers', '/finance/dashboard', '/finance/dashboard/details',
        '/finance/employee-account/x', '/finance/adjustments', '/payroll/employee/x', '/payroll-batches', '/advances', '/advances/open',
        '/sales', '/sales/installments/due', '/commissions/entitlements', '/commissions/requests', '/commissions/projects',
        '/insights/employees', '/custody', '/brokerage/deals', '/brokerage/status'];
      for (final p in paths) {
        await a.get(p);
        balance++;
        expect((await a.get(p))['balance'], balance, reason: '$p must not be served from memory');
      }
      expect(seen.length, paths.length * 2);
    });

    test('freshness: identical money reads in flight still share one request', () async {
      final seen = <String>[];
      final a = await api(() => 7, seen);
      final r = await Future.wait([a.get('/cash/summary'), a.get('/cash/summary')]);
      expect(r[0]['balance'], 7);
      expect(seen.length, 1);
    });

    test('freshness: non-money screens keep the 5-minute memory copy (unchanged)', () async {
      final seen = <String>[];
      final a = await api(() => 1, seen);
      await a.get('/employees');
      await a.get('/employees');
      expect(seen.length, 1);
    });

    test('freshness: offline, the money screen still answers from the owner\'s own copy, marked offline', () async {
      var down = false;
      final a = ApiClient(baseUrl: 'http://x', client: MockClient((r) async {
        if (down) throw http.ClientException('SocketException');
        return http.Response(jsonEncode({'balance': 1000}), 200);
      }))
        ..token = 'tokA1'
        ..owner = 'A';
      await a.get('/cash/summary');
      await pumpEventQueue();
      down = true;
      final r = await a.get('/cash/summary');
      expect(r['balance'], 1000);
      expect(r['_offline'], true);
      a.owner = 'B';
      await expectLater(a.get('/cash/summary'), throwsA(isA<ApiException>()), reason: 'never another person\'s copy');
    });
  });
}
