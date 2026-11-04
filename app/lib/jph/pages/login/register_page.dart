import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../services/api_service.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/primary_button.dart';

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final TextEditingController _uidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _companyIdController = TextEditingController();

  bool _loading = false;
  String? _uidError;
  String? _passwordError;
  String? _nameError;
  String? _emailError;
  String? _companyIdError;

  void _register() async {
    // التحقق من الحقول
    if (_uidController.text.trim().isEmpty) {
      setState(() => _uidError = 'رقم المستخدم مطلوب');
      return;
    }
    if (_passwordController.text.trim().length < 4) {
      setState(() => _passwordError = 'كلمة المرور يجب أن تكون 4 أحرف على الأقل');
      return;
    }
    if (_nameController.text.trim().isEmpty) {
      setState(() => _nameError = 'الاسم مطلوب');
      return;
    }
    if (_emailController.text.trim().isEmpty || !_emailController.text.contains('@')) {
      setState(() => _emailError = 'بريد إلكتروني صحيح مطلوب');
      return;
    }
    if (_companyIdController.text.trim().isEmpty) {
      setState(() => _companyIdError = 'معرف الشركة مطلوب');
      return;
    }

    setState(() {
      _loading = true;
      _uidError = null;
      _passwordError = null;
      _nameError = null;
      _emailError = null;
      _companyIdError = null;
    });

    final response = await ApiService.post({
      "action": "register",
      "uid": _uidController.text.trim(),
      "password": _passwordController.text.trim(),
      "name": _nameController.text.trim(),
      "email": _emailController.text.trim(),
      "phone": _phoneController.text.trim(),
      "companyId": _companyIdController.text.trim().toUpperCase(),
    });

    setState(() => _loading = false);

    if (!mounted) return;

    if (response["success"] == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(response["message"] ?? 'تم التسجيل بنجاح')),
      );
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(response["message"] ?? 'فشل التسجيل')),
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
          title: Text(AppLocalizations.of(context, 'register') ?? 'تسجيل جديد'),
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
                    AppLocalizations.of(context, 'register_as_employee') ?? 'سجل كموظف',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _uidController,
                    decoration: InputDecoration(
                      labelText: AppLocalizations.of(context, 'employee_id') ?? 'رقم الموظف',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      errorText: _uidError,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: AppLocalizations.of(context, 'password') ?? 'كلمة المرور',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      errorText: _passwordError,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _nameController,
                    decoration: InputDecoration(
                      labelText: AppLocalizations.of(context, 'full_name') ?? 'الاسم الكامل',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      errorText: _nameError,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: InputDecoration(
                      labelText: AppLocalizations.of(context, 'email') ?? 'البريد الإلكتروني',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      errorText: _emailError,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: InputDecoration(
                      labelText: AppLocalizations.of(context, 'phone') ?? 'رقم الهاتف',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _companyIdController,
                    decoration: InputDecoration(
                      labelText: AppLocalizations.of(context, 'company_id') ?? 'معرف الشركة',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                      errorText: _companyIdError,
                    ),
                  ),
                  const SizedBox(height: 24),
                  PrimaryButton(
                    label: _loading ? 'جاري التسجيل...' : (AppLocalizations.of(context, 'register') ?? 'تسجيل'),
                    color: primaryColor,
                    loading: _loading,
                    onTap: _register,
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