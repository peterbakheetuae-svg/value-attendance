import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/api.dart';
import '../core/app_settings.dart';
import '../core/async_view.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../design/app_colors.dart';
import '../design/glass.dart';
import '../design/primary_button.dart';

/// Same composition as the original JPH login: language pill + theme toggle on top,
/// centred logo, 28/w900 title, orange subtitle, glass form card, footer.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _id = TextEditingController();
  final _pw = TextEditingController();
  bool _hide = true, _loading = false;
  String? _idErr, _pwErr;

  @override
  void dispose() { _id.dispose(); _pw.dispose(); super.dispose(); }

  Future<void> _submit() async {
    setState(() {
      _idErr = _id.text.trim().isEmpty ? t('field_required') : null;
      _pwErr = _pw.text.isEmpty ? t('field_required') : null;
    });
    if (_idErr != null || _pwErr != null || _loading) return;
    setState(() => _loading = true);
    try {
      await context.read<Session>().login(_id.text.trim(), _pw.text);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_loginError(e)), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _loginError(Object e) {
    if (e is ApiException) {
      if (e.status == 401) return t('login_failed');
      if (e.status == 423) return t('login_locked');
      if (e.status == 403) return t('account_inactive');
    }
    return errorText(e);
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final isDark = isDarkOf(context);
    final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final sub = isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight;
    return Material(
      child: AppBackground(
        safeArea: false,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          resizeToAvoidBottomInset: true,
          body: SafeArea(
            minimum: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SingleChildScrollView(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      _pill(isDark, child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.language, size: 24, color: isDark ? Colors.white : Colors.black),
                        const SizedBox(width: 8),
                        Text(settings.lang == 'ar' ? 'العربية' : 'English', style: const TextStyle(fontWeight: FontWeight.w700)),
                      ]), onTap: () => settings.setLang(settings.lang == 'ar' ? 'en' : 'ar')),
                      _pill(isDark,
                          child: Icon(isDark ? Icons.light_mode : Icons.dark_mode, size: 24, color: isDark ? Colors.white : Colors.orange[700]),
                          onTap: () => settings.setTheme(isDark ? ThemeMode.light : ThemeMode.dark)),
                    ]),
                    const SizedBox(height: 8),
                    Center(child: Image.asset('assets/images/logo.png', width: 120, height: 120, fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const SizedBox(height: 120))),
                    const SizedBox(height: 8),
                    Text(t('login_title'), style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: textColor, height: 1.2)),
                    const SizedBox(height: 8),
                    Text(t('login_subtitle'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Colors.orange[700])),
                    const SizedBox(height: 20),
                    GlassCard(
                      radius: 20,
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
                      child: Material(
                        type: MaterialType.transparency,
                        child: AutofillGroup(
                          child: Column(children: [
                            TextField(
                              controller: _id,
                              autofillHints: const [AutofillHints.username],
                              textInputAction: TextInputAction.next,
                              decoration: glassInput(context, t('employee_code_or_email')).copyWith(errorText: _idErr),
                              style: TextStyle(color: textColor),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              controller: _pw,
                              obscureText: _hide,
                              autofillHints: const [AutofillHints.password],
                              onSubmitted: (_) => _submit(),
                              decoration: glassInput(context, t('password'),
                                  suffix: IconButton(icon: Icon(_hide ? Icons.visibility_off : Icons.visibility, color: sub),
                                      onPressed: () => setState(() => _hide = !_hide))).copyWith(errorText: _pwErr),
                              style: TextStyle(color: textColor),
                            ),
                            const SizedBox(height: 24),
                            PrimaryButton(label: _loading ? t('logging_in') : t('login'), loading: _loading, onTap: _submit),
                          ]),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Center(child: Text(t('forgot_password_hint'), textAlign: TextAlign.center, style: TextStyle(color: sub, fontSize: 13))),
                    const SizedBox(height: 24),
                    Center(child: Column(children: [
                      Text(t('app_name'), style: TextStyle(color: sub, fontWeight: FontWeight.w500, fontSize: 14)),
                      const SizedBox(height: 8),
                      Text('© ${DateTime.now().year}', style: TextStyle(color: sub.withValues(alpha: 0.6), fontSize: 12)),
                    ])),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pill(bool isDark, {required Widget child, required VoidCallback onTap}) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(50),
            border: Border.all(color: isDark ? Colors.white.withValues(alpha: 0.2) : Colors.black.withValues(alpha: 0.1), width: 1.5),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.1), blurRadius: 10, spreadRadius: 2)],
          ),
          child: child,
        ),
      );
}
