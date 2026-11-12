import 'package:flutter/material.dart';
import 'core/app_updater.dart';
import 'core/push.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'core/api.dart';
import 'core/i18n.dart';
import 'core/session.dart';
import 'jph/l10n/app_localizations.dart';
import 'jph/pages/dashboard_employees/dashboard_page_team.dart';
import 'jph/pages/dashboard_employers/dashboard_page.dart';
import 'jph/pages/login/login_page.dart';
import 'jph/services/app_controller.dart';
import 'jph/services/alert_center.dart';
import 'jph/services/jph_bridge.dart';
import 'jph/services/notification_service.dart';
import 'jph/services/session_service.dart';
import 'jph/theme/dark_theme.dart';
import 'jph/theme/light_theme.dart';
import 'jph/widgets/web_frame.dart';
import 'pages/change_password_page.dart';

/// Value Attendance — the original JPH Attendance app (screens, design, assets unchanged),
/// running on the Value Attendance API through `jph/services/api_service.dart`.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final session = Session(ApiClient());
  JphBridge.session = session;
  final appController = AppController();
  // startup steps don't depend on each other: load them together instead of one after another
  // (strings for the added screens, the saved session, theme / language)
  await Future.wait([I18n.load(), session.restore(), appController.initialize()]);


  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));


  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: appController),
      ChangeNotifierProvider.value(value: session),
    ],
    child: const JPHBootstrap(),
  ));

  // notifications / push start after the first screen is up (never delay opening the app)
  Future(() async {
    try {
      await NotificationService().initialize();
      await Push.init();
    } catch (_) {}
  });
}

class JPHBootstrap extends StatefulWidget {
  const JPHBootstrap({super.key});
  @override
  State<JPHBootstrap> createState() => _JPHBootstrapState();
}

class _JPHBootstrapState extends State<JPHBootstrap> {
  Map<String, dynamic>? _session;
  bool loading = true;
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var s = await SessionService.get();
    // a saved screen session without a valid API session means: sign in again
    if (s != null && !JphBridge.session.signedIn) {
      await SessionService.logout();
      s = null;
    }
    if (!mounted) return;
    setState(() {
      _session = s;
      loading = false;
    });
    // keep the screen session in step with the API session (sign-out anywhere → login page)
    JphBridge.session.addListener(_onSession);
    // in-app alerts with sound (polls while signed in)
    AlertCenter.instance.start(navigatorKey);
    // automatic update of the Android app (newest GitHub release)
    AppUpdater.instance.start(navigatorKey);
  }

  Future<void> _onSession() async {
    final s = JphBridge.session.signedIn ? await SessionService.get() : null;
    if (mounted && (s == null) != (_session == null)) setState(() => _session = s);
  }

  @override
  void dispose() {
    JphBridge.session.removeListener(_onSession);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(backgroundColor: Color(0xFF0B1020)),
      );
    }
    return Consumer<AppController>(
      builder: (context, appController, _) {
        I18n.lang = appController.languageCode == 'ar' ? 'ar' : 'en';
        return MaterialApp(
          title: 'Value Attendance',
          debugShowCheckedModeBanner: false,
          locale: appController.locale,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('ar'), Locale('en'), Locale('ur'), Locale('hi')],
          theme: LightTheme.theme,
          darkTheme: DarkTheme.theme,
          themeMode: appController.themeMode,
          navigatorKey: navigatorKey,
          // the website on a computer keeps a comfortable width (phones and the APK unchanged)
          builder: (context, child) => WebFrame(child: child ?? const SizedBox.shrink()),
          home: _home(),
        );
      },
    );
  }

  Widget _home() => Consumer<Session>(builder: (_, session, __) => _route(session));

  Widget _route(Session session) {
    final s = _session;
    if (s == null || !session.signedIn) return const LoginPage();
    final uid = (s['uid'] ?? '').toString();
    final name = (s['name'] ?? '').toString();
    final role = (s['role'] ?? '').toString();
    final photo = (s['photo'] ?? '').toString();
    if (uid.isEmpty) return const LoginPage();
    if (session.mustChangePassword) return const ChangePasswordPage(forced: true);
    final validity = (s['validity'] ?? '').toString().toLowerCase();
    if (validity == 'admin' || validity == 'super admin') {
      return DashboardPage(uid: uid, name: name, role: role, photo: photo);
    }
    return DashboardPageTeam(uid: uid, name: name, role: role, photo: photo);
  }
}
