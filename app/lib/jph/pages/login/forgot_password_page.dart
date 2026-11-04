import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../services/api_service.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/primary_button.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();

  bool _loading = false;
  bool _codeSent = false;
  String? _emailError;
  String? _codeError;
  String? _passwordError;

  void _sendCode() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _emailError = 'البريد الإلكتروني مطلوب');
      return;
    }

    setState(() {
      _loading = true;
      _emailError = null;
    });

    final response = await ApiService.post({
      "action": "forgot_password",
      "email": email,
    });

    setState(() => _loading = false);

    if (!mounted) return;

    if (response["success"] == true) {
      setState(() => _codeSent = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(response["message"] ?? 'تم إرسال الرمز')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(response["message"] ?? 'فشل الإرسال')),
      );
    }
  }

  void _resetPassword() async {
    final email = _emailController.text.trim();
    final code = _codeController.text.trim();
    final newPass = _newPasswordController.text.trim();
    final confirm = _confirmPasswordController.text.trim();

    if (code.isEmpty) {
      setState(() => _codeError = 'الرمز مطلوب');
      return;
    }
    if (newPass.isEmpty || newPass.length < 4) {
      setState(() => _passwordError = 'كلمة المرور يجب أن تكون 4 أحرف على الأقل');
      return;
    }
    if (newPass != confirm) {
      setState(() => _passwordError = 'كلمة المرور غير متطابقة');
      return;
    }

    setState(() {
      _loading = true;
      _codeError = null;
      _passwordError = null;
    });

    final response = await ApiService.post({
      "action": "reset_password",
      "email": email,
      "code": code,
      "newPassword": newPass,
    });

    setState(() => _loading = false);

    if (!mounted) return;

    if (response["success"] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(response["message"] ?? 'تم تغيير كلمة المرور')),
      );
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(response["message"] ?? 'فشل التحقق')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(AppLocalizations.of(context, 'forgot_password') ?? 'نسيت كلمة المرور'),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: GlassCard(
              radius: 24,
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_codeSent) ...[
                    Text(
                      AppLocalizations.of(context, 'enter_email_to_reset') ?? 'أدخل بريدك الإلكتروني لإعادة تعيين كلمة المرور',
                      style: const TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: AppLocalizations.of(context, 'email') ?? 'البريد الإلكتروني',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        errorText: _emailError,
                      ),
                    ),
                    const SizedBox(height: 24),
                    PrimaryButton(
                      label: _loading ? 'جاري الإرسال...' : (AppLocalizations.of(context, 'send_reset_code') ?? 'إرسال الرمز'),
                      color: primaryColor,
                      loading: _loading,
                      onTap: _sendCode,
                    ),
                  ] else ...[
                    Text(
                      AppLocalizations.of(context, 'enter_reset_code') ?? 'أدخل الرمز الذي أرسل إلى بريدك',
                      style: const TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _codeController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: AppLocalizations.of(context, 'reset_code') ?? 'رمز إعادة التعيين',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        errorText: _codeError,
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _newPasswordController,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: AppLocalizations.of(context, 'new_password') ?? 'كلمة المرور الجديدة',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _confirmPasswordController,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: AppLocalizations.of(context, 'confirm_password') ?? 'تأكيد كلمة المرور',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        errorText: _passwordError,
                      ),
                    ),
                    const SizedBox(height: 24),
                    PrimaryButton(
                      label: _loading ? 'جاري التغيير...' : (AppLocalizations.of(context, 'change_password') ?? 'تغيير كلمة المرور'),
                      color: primaryColor,
                      loading: _loading,
                      onTap: _resetPassword,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}