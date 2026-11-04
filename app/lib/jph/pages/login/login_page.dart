//login_page.dart
import 'package:flutter/material.dart';
import '../../../pages/change_password_page.dart';
import '../../services/jph_bridge.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../services/api_service.dart';
import '../../services/session_service.dart';
import '../../services/notification_service.dart';
import '../dashboard_employers/dashboard_page.dart';     // لوحة أصحاب العمل
import '../dashboard_employees/dashboard_page_team.dart'; // لوحة الموظفين
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/app_background.dart';
import '../../widgets/primary_button.dart';
import 'forgot_password_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with WidgetsBindingObserver {
  final TextEditingController _uidCtrl = TextEditingController();
  final TextEditingController _passCtrl = TextEditingController();

  final ScrollController _scrollController = ScrollController();
  final GlobalKey _uidKey = GlobalKey();
  final GlobalKey _passKey = GlobalKey();

  bool _loading = false;
  bool _hidePass = true;
  String? _uidError;
  String? _passError;
  bool _showLanguageDialog = false;

  final FocusNode _uidFocusNode = FocusNode();
  final FocusNode _passFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeMetrics() {
    final bottomInset = WidgetsBinding.instance.window.viewInsets.bottom;
    if (bottomInset > 0) {
      _scrollToFocusedField();
    }
  }

  void _scrollToFocusedField() {
    BuildContext? context;

    if (_uidFocusNode.hasFocus) {
      context = _uidKey.currentContext;
    } else if (_passFocusNode.hasFocus) {
      context = _passKey.currentContext;
    }

    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        alignment: 0.3,
      );
    }
  }

  Future<void> _login() async {
    setState(() {
      _uidError = null;
      _passError = null;
    });

    bool hasError = false;

    if (_uidCtrl.text.trim().isEmpty) {
      setState(() {
        _uidError = 'اكتب كود الموظف أو الموبايل أو الإيميل';
      });
      hasError = true;
    }

    if (_passCtrl.text.trim().isEmpty) {
      setState(() {
        _passError = '${AppLocalizations.of(context, 'password')} ${AppLocalizations.of(context, 'required')}';
      });
      hasError = true;
    }

    if (hasError) return;
    if (_loading) return;

    setState(() => _loading = true);

    try {
      final response = await ApiService.post({
        "action": "login",
        "identifier": _uidCtrl.text.trim(),
        "pass": _passCtrl.text.trim(),
      });

      if (!mounted) return;

      if (response["success"] != true) {
        _showError(response["message"] ?? AppLocalizations.of(context, 'login_failed'));
        return;
      }

      // كلمة مرور مؤقتة: لازم تتغير قبل الدخول
      if (response["mustChangePassword"] == true) {
        await Navigator.push(context, MaterialPageRoute(
          builder: (ctx) => ChangePasswordPage(forced: true, onDone: () => Navigator.pop(ctx)),
        ));
        if (!mounted || JphBridge.session.mustChangePassword) return;
      }

      // حفظ بيانات الجلسة
      await SessionService.save(response);

      // حفظ بيانات المستخدم في AppController
      final appController = Provider.of<AppController>(context, listen: false);
      await appController.saveUserData(
        uid: response["uid"]?.toString() ?? '',
        name: response["name"]?.toString() ?? '',
        role: response["role"]?.toString() ?? '',
        photo: response["photo"]?.toString(),
        validity: response["validity"]?.toString(),   // 🔥 استلام Validity
        companyId: response["companyId"]?.toString(), // 🔥 استلام CompanyID
      );

      // إرسال FCM Token
      try {
        final notificationService = NotificationService();
        final token = await notificationService.getDeviceToken();
        if (token != null) {
          await notificationService.sendTokenToServer(
            response["uid"]?.toString() ?? '',
            token,
          );
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('last_logged_in_user', response["uid"]?.toString() ?? '');
        }
      } catch (tokenError) {
        print('⚠️ فشل إرسال التوكن: $tokenError');
      }

      if (!mounted) return;

      // ✅ تحديد لوحة التحكم بناءً على Validity
      final validity = response["validity"]?.toString().toLowerCase() ?? '';
      final isAdmin = validity == 'super admin' || validity == 'admin';

      if (isAdmin) {
        // انتقل إلى لوحة أصحاب العمل
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => DashboardPage(
              uid: response["uid"]?.toString() ?? '',
              name: response["name"]?.toString() ?? '',
              role: response["role"]?.toString() ?? '',
            ),
          ),
        );
      } else {
        // انتقل إلى لوحة الموظفين
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => DashboardPageTeam(
              uid: response["uid"]?.toString() ?? '',
              name: response["name"]?.toString() ?? '',
              role: response["role"]?.toString() ?? '',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      _showError('${AppLocalizations.of(context, 'network_error')}: ${error.toString()}');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _changeLanguage(BuildContext context) {
    final appController = Provider.of<AppController>(context, listen: false);
    final currentLanguage = appController.languageCode;
    final isDark = appController.isDark;

    setState(() => _showLanguageDialog = true);

    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.5),
      builder: (context) {
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(40),
          child: GlassCard(
            radius: 20,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  AppLocalizations.of(context, 'language') ?? 'اللغة',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                ),
                const SizedBox(height: 24),
                _buildLanguageOption(
                  context: context,
                  appController: appController,
                  languageCode: 'ar',
                  flag: '🇸🇦',
                  languageName: AppLocalizations.of(context, 'arabic') ?? 'العربية',
                  isCurrent: currentLanguage == 'ar',
                  isDark: isDark,
                ),
                const SizedBox(height: 16),
                _buildLanguageOption(
                  context: context,
                  appController: appController,
                  languageCode: 'en',
                  flag: '🇺🇸',
                  languageName: AppLocalizations.of(context, 'english') ?? 'English',
                  isCurrent: currentLanguage == 'en',
                  isDark: isDark,
                ),
                const SizedBox(height: 16),
                _buildLanguageOption(
                  context: context,
                  appController: appController,
                  languageCode: 'ur',
                  flag: '🇵🇰',
                  languageName: 'اردو',
                  isCurrent: currentLanguage == 'ur',
                  isDark: isDark,
                ),
                const SizedBox(height: 16),
                _buildLanguageOption(
                  context: context,
                  appController: appController,
                  languageCode: 'hi',
                  flag: '🇮🇳',
                  languageName: 'हिन्दी',
                  isCurrent: currentLanguage == 'hi',
                  isDark: isDark,
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: PrimaryButton(
                    label: AppLocalizations.of(context, 'close') ?? 'إغلاق',
                    color: AppColors.primary,
                    onTap: () {
                      Navigator.pop(context);
                      if (mounted) setState(() => _showLanguageDialog = false);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ).then((_) {
      if (mounted) setState(() => _showLanguageDialog = false);
    });
  }

  Widget _buildLanguageOption({
    required BuildContext context,
    required AppController appController,
    required String languageCode,
    required String flag,
    required String languageName,
    required bool isCurrent,
    required bool isDark,
  }) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          appController.setLanguage(languageCode);
          Navigator.pop(context);
          if (mounted) setState(() => _showLanguageDialog = false);
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: isCurrent ? AppColors.primary.withOpacity(0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: isCurrent ? AppColors.primary : Colors.transparent, width: 1.5),
          ),
          child: Row(
            children: [
              Text(flag, style: const TextStyle(fontSize: 28)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  languageName,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black),
                ),
              ),
              if (isCurrent) Icon(Icons.check_circle, color: AppColors.primary, size: 24),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollController.dispose();
    _uidCtrl.dispose();
    _passCtrl.dispose();
    _uidFocusNode.dispose();
    _passFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;
        final isRTL = appController.isRTL;
        final currentLanguage = appController.languageCode;

        final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
        final subduedTextColor = isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight;

        return Material(
          child: AppBackground(
            safeArea: false,
            child: Directionality(
              textDirection: isRTL ? TextDirection.rtl : TextDirection.ltr,
              child: Scaffold(
                resizeToAvoidBottomInset: true,
                backgroundColor: Colors.transparent,
                body: SafeArea(
                  minimum: const EdgeInsets.all(20),
                  child: Stack(
                    children: [
                      SingleChildScrollView(
                        controller: _scrollController,
                        physics: const BouncingScrollPhysics(),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 6),
                            _buildHeader(textColor),
                            const SizedBox(height: 0),
                            _buildLoginForm(textColor, subduedTextColor),
                            const SizedBox(height: 16),
                            _buildForgotPasswordAndRegister(subduedTextColor),
                            const SizedBox(height: 0),
                            _buildFooter(subduedTextColor),
                          ],
                        ),
                      ),
                      Positioned(top: 0, right: 2, child: _buildLanguageButton(currentLanguage, isDark)),
                      Positioned(top: 0, left: 2, child: _buildDarkModeToggle(appController, isDark)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLanguageButton(String currentLanguage, bool isDark) {
    return GestureDetector(
      onTap: () => _changeLanguage(context),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.1) : Colors.black.withOpacity(0.05),
          borderRadius: BorderRadius.circular(50),
          border: Border.all(color: isDark ? Colors.white.withOpacity(0.2) : Colors.black.withOpacity(0.1), width: 1.7),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.2 : 0.1), blurRadius: 10, spreadRadius: 2)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.language, size: 24, color: isDark ? Colors.white : Colors.black),
            const SizedBox(width: 8),
            Text(_getLanguageFlag(currentLanguage), style: const TextStyle(fontSize: 16)),
          ],
        ),
      ),
    );
  }

  String _getLanguageFlag(String languageCode) {
    switch (languageCode) {
      case 'ar': return '🇸🇦';
      case 'en': return '🇺🇸';
      case 'ur': return '🇵🇰';
      case 'hi': return '🇮🇳';
      default: return '🌐';
    }
  }

  Widget _buildDarkModeToggle(AppController appController, bool isDark) {
    return GestureDetector(
      onTap: () => appController.setThemeMode(isDark ? ThemeMode.light : ThemeMode.dark),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.1) : Colors.black.withOpacity(0.05),
          borderRadius: BorderRadius.circular(50),
          border: Border.all(color: isDark ? Colors.white.withOpacity(0.2) : Colors.black.withOpacity(0.1), width: 1.5),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.2 : 0.1), blurRadius: 10, spreadRadius: 2)],
        ),
        child: Icon(isDark ? Icons.light_mode : Icons.dark_mode, size: 24, color: isDark ? Colors.white : Colors.orange[700]),
      ),
    );
  }

  Widget _buildHeader(Color textColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Center(
          child: Container(
            width: 192,
            height: 192,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(0)),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(0),
              child: Image.asset('assets/images/logo.png', width: 0, height: 0, fit: BoxFit.cover),
            ),
          ),
        ),
        const SizedBox(height: 0),
        Text(
          AppLocalizations.of(context, 'employer_login') ?? 'تسجيل دخول',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: textColor, height: 1.2),
        ),
        const SizedBox(height: 8),
        Text(
          AppLocalizations.of(context, 'employers_only') ?? 'الدخول مخصص للمستخدمين المسجلين',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.orange[700]),
        ),
      ],
    );
  }

  Widget _buildLoginForm(Color textColor, Color subduedTextColor) {
    return GlassCard(
      radius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Column(
        children: [
          Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: _uidKey,
                  controller: _uidCtrl,
                  focusNode: _uidFocusNode,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: 'كود الموظف أو الموبايل أو الإيميل',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: subduedTextColor.withOpacity(0.3))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.primary, width: 2)),
                    labelStyle: TextStyle(color: subduedTextColor),
                    contentPadding: const EdgeInsets.all(16),
                  ),
                  style: TextStyle(color: textColor),
                ),
                if (_uidError != null) Padding(padding: const EdgeInsets.only(top: 4, left: 12), child: Text(_uidError!, style: const TextStyle(color: Colors.red, fontSize: 12))),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  key: _passKey,
                  controller: _passCtrl,
                  focusNode: _passFocusNode,
                  obscureText: _hidePass,
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context, 'password') ?? 'كلمة المرور',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: subduedTextColor.withOpacity(0.3))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: AppColors.primary, width: 2)),
                    labelStyle: TextStyle(color: subduedTextColor),
                    contentPadding: const EdgeInsets.all(16),
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => _hidePass = !_hidePass),
                      icon: Icon(_hidePass ? Icons.visibility_off : Icons.visibility, color: subduedTextColor),
                      splashRadius: 20,
                    ),
                  ),
                  style: TextStyle(color: textColor),
                ),
                if (_passError != null) Padding(padding: const EdgeInsets.only(top: 4, left: 12), child: Text(_passError!, style: const TextStyle(color: Colors.red, fontSize: 12))),
              ],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: PrimaryButton(
              label: _loading ? (AppLocalizations.of(context, 'logging_in') ?? 'جاري تسجيل الدخول...') : (AppLocalizations.of(context, 'login') ?? 'تسجيل الدخول'),
              color: AppColors.primary,
              loading: _loading,
              onTap: _login,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForgotPasswordAndRegister(Color subduedTextColor) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        TextButton(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => ForgotPasswordPage()),
            );
          },
          child: Text(
            AppLocalizations.of(context, 'forgot_password') ?? 'نسيت كلمة المرور؟',
            style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _buildFooter(Color subduedTextColor) {
    return Center(
      child: Column(
        children: [
          Text(AppLocalizations.of(context, 'app_name') ?? 'Value Attendance', style: TextStyle(color: subduedTextColor, fontWeight: FontWeight.w500, fontSize: 14)),
          const SizedBox(height: 8),
          Text('© ${DateTime.now().year}', style: TextStyle(color: subduedTextColor.withOpacity(0.6), fontSize: 12)),
        ],
      ),
    );
  }
}