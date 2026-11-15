// Windows CI smoke test — runs inside the real Windows app build (flutter test integration_test -d windows).
// Read-only against the live API: no sign-in, no accounts, no data written.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:jph_real_estate_hr/core/api.dart';
import 'package:jph_real_estate_hr/core/platform_info.dart';
import 'package:jph_real_estate_hr/core/token_store.dart';
import 'package:jph_real_estate_hr/jph/pages/login/login_page.dart';
import 'package:jph_real_estate_hr/main.dart' as app;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('running as the native Windows app', () {
    expect(PlatformInfo.isWindows, isTrue);
    expect(PlatformInfo.isComputer, isTrue);
  });

  test('session token is DPAPI-encrypted at rest and reads back', () async {
    const sample = 'ci-sample-token-not-a-real-session-0123456789';
    await TokenStore.write(sample);
    final p = await SharedPreferences.getInstance();
    await p.reload();
    expect(p.getString('token'), isNull, reason: 'no plain-text token on Windows');
    final sealed = p.getString('token_dpapi');
    expect(sealed, isNotNull);
    expect(sealed!.contains(sample), isFalse);
    expect(sealed.length, greaterThan(sample.length));
    expect(await TokenStore.read(), sample);
    // a tampered value is refused (and cleared), never returned
    await p.setString('token_dpapi', '${sealed.substring(0, sealed.length - 8)}AAAAAAA=');
    expect(await TokenStore.read(), isNull);
    await TokenStore.clear();
    expect(await TokenStore.read(), isNull);
  });

  test('backend reachable from the Windows app', () async {
    final r = await ApiClient().get('/healthz');
    expect(r['ok'], isTrue);
  });

  test('server enforces sign-in and rejects a forged token (permissions are not only in the app)', () async {
    Future<int> status(String path, {String? token}) async {
      final c = ApiClient()..token = token;
      try {
        await c.get(path);
        return 200;
      } on ApiException catch (e) {
        return e.status;
      }
    }

    expect(await status('/me'), 401);
    expect(await status('/me', token: 'forged.ci.token'), 401);
    expect(await status('/employees'), 401);
  });

  testWidgets('the app starts and shows the original login screen', (tester) async {
    await TokenStore.clear();
    app.main();
    for (var i = 0; i < 60 && find.byType(LoginPage).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(find.byType(LoginPage), findsOneWidget);
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
