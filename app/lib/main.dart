import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'core/api.dart';
import 'core/app_settings.dart';
import 'core/i18n.dart';
import 'core/session.dart';
import 'design/dark_theme.dart';
import 'design/glass.dart';
import 'design/light_theme.dart';
import 'pages/change_password_page.dart';
import 'pages/home_shell.dart';
import 'pages/login_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await I18n.load();
  final settings = AppSettings();
  await settings.restore();
  final session = Session(ApiClient());
  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider.value(value: session),
    ],
    child: const ValueAttendanceApp(),
  ));
  session.restore();
}

class ValueAttendanceApp extends StatelessWidget {
  const ValueAttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return MaterialApp(
      title: 'Value Attendance',
      debugShowCheckedModeBanner: false,
      theme: LightTheme.theme,
      darkTheme: DarkTheme.theme,
      themeMode: settings.themeMode,
      locale: settings.locale,
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (ctx, child) => Directionality(textDirection: I18n.direction, child: child ?? const SizedBox()),
      home: const _Root(),
    );
  }
}

class _Root extends StatelessWidget {
  const _Root();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    if (s.restoring) {
      return const Material(child: AppBackground(child: LoadingState()));
    }
    if (!s.signedIn) return const LoginPage();
    if (s.mustChangePassword) return const ChangePasswordPage(forced: true);
    return const HomeShell();
  }
}
