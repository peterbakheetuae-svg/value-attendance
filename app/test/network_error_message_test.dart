// 2026-11-26: every connectivity failure shows exactly «تأكد من الإنترنت وحاول مرة أخرى» — never an exception name, a host
// or a URL; HTTP answers (401 / 403 / 422 / 500) keep their own messages.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jph_real_estate_hr/core/api.dart';
import 'package:jph_real_estate_hr/core/async_view.dart';
import 'package:jph_real_estate_hr/core/session.dart';
import 'package:jph_real_estate_hr/jph/services/api_service.dart';
import 'package:jph_real_estate_hr/jph/services/app_controller.dart';
import 'package:jph_real_estate_hr/jph/services/jph_bridge.dart';
import 'package:jph_real_estate_hr/jph/pages/leads/leads_list_page.dart';
import 'package:jph_real_estate_hr/jph/pages/projects/marketing_companies_page.dart';

const exact = 'تأكد من الإنترنت وحاول مرة أخرى';
const host = 'valunivo.vercel.app';

http.Response _json(Object b, [int s = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(b)), s, headers: {'content-type': 'application/json'});

ApiClient throwing(Object error) => ApiClient(baseUrl: 'https://$host', client: MockClient((_) async => throw error));

void expectClean(String shown) {
  expect(shown, exact);
  for (final bad in ['Exception', 'Socket', 'lookup', host, 'https://', 'http://', 'Errno', 'timeout']) {
    expect(shown.contains(bad), false, reason: '«$shown» must not contain $bad');
  }
}

void main() {
  final failures = <String, Object>{
    'device offline': http.ClientException('SocketException: Network is unreachable (OS Error: Network is unreachable, errno = 101)'),
    'DNS lookup failure': http.ClientException("Failed host lookup: '$host' (OS Error: No address associated with hostname, errno = 7)"),
    'SocketException': const SocketException('Connection reset by peer', port: 443),
    'connection timeout': TimeoutException('no answer'),
    'connection refused': http.ClientException('Connection refused, address = $host, port = 443'),
  };

  for (final f in failures.entries) {
    test('${f.key}: exactly the network message, nothing technical, the reason kept (redacted) for developers', () async {
      try {
        await throwing(f.value).post('/attendance/check-in', {});
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.isNetwork, true);
        expectClean(e.message);
        expectClean(e.toString());
        expectClean(JphRouter.messageFor(e));
        expect(isNetworkFailure(e), true);
        expect(e.diagnostic, isNotNull);
        expect(e.diagnostic!.contains(host), false, reason: 'no host in the diagnostic');
        expect(e.diagnostic!.contains('https://'), false, reason: 'no URL in the diagnostic');
      }
    });
  }

  test('a read with no connection: the same message after its quiet retry', () async {
    try {
      await throwing(http.ClientException("Failed host lookup: '$host'")).get('/leads');
      fail('should throw');
    } on ApiException catch (e) {
      expectClean(e.message);
    }
  });

  final answers = <int, Map<String, Object>>{
    401: {'code': 'unauthenticated', 'message': 'Sign in'},
    403: {'code': 'forbidden', 'message': 'مش مسموح'},
    422: {'code': 'unprocessable', 'message': 'لازم تكمل البيانات', 'details': {'field': 'reason'}},
    500: {'code': 'internal', 'message': 'حصلت مشكلة في السيرفر'},
  };
  for (final a in answers.entries) {
    test('HTTP ${a.key} keeps its own handling (never the network message)', () async {
      final api = ApiClient(baseUrl: 'https://$host', client: MockClient((_) async => _json({'error': a.value}, a.key)));
      try {
        await api.post('/x', {});
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.status, a.key);
        expect(e.isNetwork, false);
        expect(isNetworkFailure(e), false);
        expect(e.diagnostic, isNull);
        final shown = JphRouter.messageFor(e);
        expect(shown == exact, false);
        if (a.key == 401) {
          expect(shown, 'انتهت الجلسة، سجّل الدخول مرة أخرى');
        } else if (a.key == 403) {
          expect(shown, 'ليس لديك صلاحية لهذا الإجراء', reason: 'the existing permission message');
        } else {
          expect(shown, a.value['message']);
        }
        expect(errorText(e) == exact, false);
      }
    });
  }

  test('plain errors that are not connectivity failures are not called network errors', () {
    expect(isNetworkFailure(const FormatException('bad json')), false);
    expect(isNetworkFailure(StateError('x')), false);
    expect(isNetworkFailure(http.ClientException('down')), true);
    expect(isNetworkFailure(TimeoutException('t')), true);
  });

  group('through the app layer (ApiService) and on screens', () {
    var down = true;
    final client = MockClient((r) async {
      if (r.url.path == '/me') return _json({'employee': {'id': 'u1', 'full_name': 'x', 'role_key': 'owner'}, 'permissions': <String>[]});
      if (down) throw http.ClientException("Failed host lookup: '$host' (OS Error: No address associated with hostname, errno = 7)");
      return _json({'leads': [], 'total': 0, 'companies': [], 'items': [], 'success': true});
    });
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      final api = ApiClient(baseUrl: 'https://$host', client: client)..token = 'tok';
      JphBridge.session = Session(api);
      down = true;
    });

    test('ApiService answers the exact message, once', () async {
      final r = await ApiService.post({'action': 'cash_get', 'path': '/leads'});
      expect(r['success'], false);
      expectClean('${r['message']}');
    });

    for (final s in <String, Widget Function()>{
      'leads list': () => const LeadsListPage(),
      'marketing companies': () => const MarketingCompaniesPage(),
    }.entries) {
      testWidgets('${s.key}: no connection shows the message and nothing technical', (tester) async {
        tester.view.physicalSize = const Size(1200, 2400);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(ChangeNotifierProvider(
          create: (_) => AppController(),
          child: MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: s.value()))),
        ));
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(find.textContaining(exact), findsWidgets);
        for (final bad in ['Exception', 'lookup', host, 'https://', 'تعذّر الاتصال']) {
          expect(find.textContaining(bad), findsNothing, reason: bad);
        }
      });
    }
  });
}
