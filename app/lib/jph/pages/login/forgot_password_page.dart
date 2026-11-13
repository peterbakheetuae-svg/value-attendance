import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../services/api_service.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/primary_button.dart';
import 'otp_page.dart';
import '../../widgets/glass_ui.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final TextEditingController _emailController = TextEditingController();

  bool _loading = false;
  String? _emailError;

  void _sendCode() async {
    final id = _emailController.text.trim();
    if (id.isEmpty) {
      setState(() => _emailError = 'اكتب كود الموظف أو الموبايل أو الإيميل');
      return;
    }
    setState(() {
      _loading = true;
      _emailError = null;
    });
    final response = await ApiService.post({"action": "forgot_password", "identifier": id});
    if (!mounted) return;
    setState(() => _loading = false);
    if (response["success"] == true) {
      final done = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => OtpPage(identifier: id, sentTo: '${response['sentTo'] ?? ''}')));
      if (done == true && mounted) Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(response["message"] ?? 'فشل الإرسال'), backgroundColor: Ar.red),
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

                    Text(
                      'اكتب كود الموظف أو الموبايل أو الإيميل، وهيوصلك كود تحقق على إيميلك المسجّل',
                      style: const TextStyle(fontSize: 16),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: 'كود الموظف / الموبايل / الإيميل',
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}