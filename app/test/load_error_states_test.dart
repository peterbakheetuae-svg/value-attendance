// R7 regression tests: the five screens that showed "no data" (or nothing) when a read failed now show the failure
// with «حاول تاني»; a permission refusal keeps the old behaviour; an empty answer still shows the empty state.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jph_real_estate_hr/core/api.dart';
import 'package:jph_real_estate_hr/core/session.dart';
import 'package:jph_real_estate_hr/jph/services/app_controller.dart';
import 'package:jph_real_estate_hr/jph/services/jph_bridge.dart';
import 'package:jph_real_estate_hr/jph/pages/cash/cash_overview.dart';
import 'package:jph_real_estate_hr/jph/pages/commissions/commissions_page.dart';
import 'package:jph_real_estate_hr/jph/pages/leads/leads_calendar_page.dart';
import 'package:jph_real_estate_hr/jph/pages/leads/leads_list_page.dart';
import 'package:jph_real_estate_hr/jph/pages/projects/marketing_companies_page.dart';

/// mode: 'down' (no connection), '500', '403', 'empty'
String mode = 'down';
var calls = 0;

http.Response _json(Object b, [int s = 200]) => http.Response.bytes(utf8.encode(jsonEncode(b)), s, headers: {'content-type': 'application/json'});

final client = MockClient((r) async {
  calls++;
  if (r.url.path == '/me') return _json({'employee': {'id': 'u1', 'full_name': 'x', 'role_key': 'owner'}, 'permissions': <String>[]});
  switch (mode) {
    case 'down':
      throw http.ClientException('SocketException: Network is unreachable');
    case '500':
      return _json({'error': {'code': 'internal', 'message': 'السيرفر وقع'}}, 500);
    case '403':
      return _json({'error': {'code': 'forbidden', 'message': 'no'}}, 403);
  }
  return _json({'projects': [], 'items': [], 'leads': [], 'total': 0, 'companies': [], 'success': true});
});

Widget host(Widget child) => ChangeNotifierProvider(
      create: (_) => AppController(),
      child: MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: child))),
    );

Future<void> open(WidgetTester tester, Widget w) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(host(w));
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

final retry = find.text('حاول تاني');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final api = ApiClient(baseUrl: 'http://x', client: client)..token = 'tok';
    JphBridge.session = Session(api)..permissions = {'commission.read_all'}; // the projects tab is shown
    calls = 0;
  });

  final screens = <String, Widget Function()>{
    'commissions (projects)': () => const CommissionsPage(initialTab: 'projects'),
    'leads calendar': () => const LeadsCalendarPage(),
    'leads list': () => const LeadsListPage(),
    'marketing companies': () => const MarketingCompaniesPage(),
    'cash overview': () => const SingleChildScrollView(child: CashOverview(isDark: false)),
  };

  for (final e in screens.entries) {
    testWidgets('${e.key}: no connection → message + «حاول تاني» (was: empty / nothing)', (tester) async {
      mode = 'down';
      await open(tester, e.value());
      expect(retry, findsOneWidget);
      final before = calls;
      mode = 'empty';
      await tester.tap(retry);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(calls, greaterThan(before), reason: 'retry reads again');
      expect(retry, findsNothing, reason: 'the answer came: the failure block is gone');
    });

    testWidgets('${e.key}: server error → its message + «حاول تاني»', (tester) async {
      mode = '500';
      await open(tester, e.value());
      expect(retry, findsOneWidget);
      expect(find.textContaining('السيرفر وقع'), findsWidgets);
    });

    testWidgets('${e.key}: permission refusal keeps the old behaviour (no retry block)', (tester) async {
      mode = '403';
      await open(tester, e.value());
      expect(retry, findsNothing);
    });
  }

  testWidgets('empty answers still show the empty state (unchanged)', (tester) async {
    mode = 'empty';
    await open(tester, const MarketingCompaniesPage());
    expect(retry, findsNothing);
    await open(tester, const CommissionsPage(initialTab: 'projects'));
    expect(find.text('مفيش مشاريع'), findsOneWidget);
  });
}
