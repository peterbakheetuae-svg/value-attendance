import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:jph_real_estate_hr/core/api.dart';
import 'package:jph_real_estate_hr/core/app_settings.dart';
import 'package:jph_real_estate_hr/core/i18n.dart';
import 'package:jph_real_estate_hr/core/session.dart';
import 'package:jph_real_estate_hr/design/app_colors.dart';
import 'package:jph_real_estate_hr/design/glass.dart';
import 'package:jph_real_estate_hr/design/glass_bottom_nav.dart';
import 'package:jph_real_estate_hr/design/light_theme.dart';
import 'package:jph_real_estate_hr/design/primary_button.dart';
import 'package:jph_real_estate_hr/pages/login_page.dart';

Map<String, String> _load(String l) => (json.decode(File('assets/l10n/$l.json').readAsStringSync()) as Map).map((k, v) => MapEntry('$k', '$v'));

Widget _host(Widget child, {TextDirection dir = TextDirection.rtl}) => MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSettings()),
        ChangeNotifierProvider(create: (_) => Session(ApiClient(baseUrl: 'http://test'))),
      ],
      child: MaterialApp(theme: LightTheme.theme, home: Directionality(textDirection: dir, child: child)),
    );

void main() {
  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    I18n.setTables({'ar': _load('ar'), 'en': _load('en')});
  });

  test('design tokens are the original JPH Attendance values', () {
    expect(AppColors.primary, const Color(0xFF4F46E5));
    expect(AppColors.secondary, const Color(0xFF14B8A6));
    expect(LightTheme.theme.textTheme.bodyMedium!.fontFamily, 'Cairo');
  });

  testWidgets('login page renders in Arabic RTL with the glass form', (tester) async {
    I18n.lang = 'ar';
    tester.view.physicalSize = const Size(1080, 2200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(const LoginPage()));
    await tester.pump();
    expect(find.text(I18n.t('login_title')), findsWidgets);
    expect(find.byType(GlassCard), findsOneWidget);
    expect(find.byType(PrimaryButton), findsOneWidget);
    expect(Directionality.of(tester.element(find.byType(LoginPage))), TextDirection.rtl);
  });

  testWidgets('empty login shows required-field errors without calling the API', (tester) async {
    I18n.lang = 'ar';
    await tester.pumpWidget(_host(const LoginPage()));
    await tester.tap(find.byType(PrimaryButton));
    await tester.pump();
    expect(find.text(I18n.t('field_required')), findsNWidgets(2));
  });

  testWidgets('glass bottom nav shows the label only for the active tab', (tester) async {
    var tapped = -1;
    await tester.pumpWidget(_host(Scaffold(bottomNavigationBar: GlassBottomNav(
      currentIndex: 0, onTap: (i) => tapped = i,
      items: const [NavItem(Icons.home_rounded, 'الرئيسية'), NavItem(Icons.fingerprint_rounded, 'الحضور')],
    ))));
    expect(find.text('الرئيسية'), findsOneWidget);
    expect(find.text('الحضور'), findsNothing);
    await tester.tap(find.byIcon(Icons.fingerprint_rounded));
    expect(tapped, 1);
  });

  testWidgets('English renders LTR strings', (tester) async {
    I18n.lang = 'en';
    await tester.pumpWidget(_host(const LoginPage(), dir: TextDirection.ltr));
    await tester.pump();
    expect(find.text('Sign in'), findsWidgets);
    I18n.lang = 'ar';
  });
}
