import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../services/api_service.dart'; // استيراد ApiService بدلاً من PasswordService
import '../../l10n/app_localizations.dart';
import '../glass_dialog.dart';
import '../glass_ui.dart';

class ChangePasswordForm extends StatefulWidget {
  final String uid;

  const ChangePasswordForm({super.key, required this.uid});

  @override
  State<ChangePasswordForm> createState() => _ChangePasswordFormState();
}

class _ChangePasswordFormState extends State<ChangePasswordForm> {
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;

  String _oldPassword = '';
  String _newPassword = '';
  String _confirmPassword = '';

  final TextEditingController _oldPasswordController = TextEditingController();
  final TextEditingController _newPasswordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();

  bool _showOldPassword = false;
  bool _showNewPassword = false;
  bool _showConfirmPassword = false;

  Future<void> _submitForm() async {
    if (!_formKey.currentState!.validate()) return;

    _formKey.currentState!.save();

    // التحقق من تطابق كلمة المرور الجديدة
    if (_newPassword != _confirmPassword) {
      _showErrorDialog(
        AppLocalizations.of(context, 'passwords_not_match') ?? 'كلمة المرور الجديدة غير متطابقة',
      );
      return;
    }

    // التحقق من عدم تساوي كلمة المرور الجديدة بالقديمة
    if (_oldPassword == _newPassword) {
      _showErrorDialog(
        AppLocalizations.of(context, 'new_password_same_as_old') ?? 'كلمة المرور الجديدة يجب أن تختلف عن القديمة',
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // استخدام ApiService لتغيير كلمة المرور
      final result = await ApiService.changePassword(
        uid: widget.uid,
        oldPass: _oldPassword,
        newPass: _newPassword,
      );

      setState(() {
        _isLoading = false;
      });

      if (result['success'] == true) {
        _showSuccessDialog(
          result['message'] ?? (AppLocalizations.of(context, 'password_changed_successfully') ?? 'تم تغيير كلمة المرور بنجاح'),
        );

        // مسح الحقول بعد التغيير الناجح
        _oldPasswordController.clear();
        _newPasswordController.clear();
        _confirmPasswordController.clear();
      } else {
        _showErrorDialog(
          result['message'] ?? (AppLocalizations.of(context, 'password_change_failed') ?? 'فشل تغيير كلمة المرور'),
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });

      _showErrorDialog(
        '${AppLocalizations.of(context, 'password_change_error') ?? 'حدث خطأ أثناء تغيير كلمة المرور'}: $e',
      );
    }
  }

  void _showSuccessDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: Text(AppLocalizations.of(context, 'success') ?? 'نجاح'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context, 'ok') ?? 'موافق'),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: Text(AppLocalizations.of(context, 'error') ?? 'خطأ'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context, 'ok') ?? 'موافق'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    return Form(
      key: _formKey,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: Glass.tile(isDark, r: 12),
        child: Column(
          children: [
            TextFormField(
              controller: _oldPasswordController,
              obscureText: !_showOldPassword,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context, 'old_password') ?? 'كلمة المرور القديمة',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(
                    _showOldPassword ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () {
                    setState(() {
                      _showOldPassword = !_showOldPassword;
                    });
                  },
                ),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return AppLocalizations.of(context, 'old_password_required') ??
                      'كلمة المرور القديمة مطلوبة';
                }
                if (value.trim().length < 6) {
                  return AppLocalizations.of(context, 'password_min_length') ??
                      'كلمة المرور يجب أن تكون 6 أحرف على الأقل';
                }
                return null;
              },
              onSaved: (value) => _oldPassword = value?.trim() ?? '',
            ),

            const SizedBox(height: 16),

            TextFormField(
              controller: _newPasswordController,
              obscureText: !_showNewPassword,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context, 'new_password') ?? 'كلمة المرور الجديدة',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                prefixIcon: const Icon(Icons.lock_reset),
                suffixIcon: IconButton(
                  icon: Icon(
                    _showNewPassword ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () {
                    setState(() {
                      _showNewPassword = !_showNewPassword;
                    });
                  },
                ),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return AppLocalizations.of(context, 'new_password_required') ??
                      'كلمة المرور الجديدة مطلوبة';
                }
                if (value.trim().length < 6) {
                  return AppLocalizations.of(context, 'password_min_length') ??
                      'كلمة المرور يجب أن تكون 6 أحرف على الأقل';
                }
                return null;
              },
              onSaved: (value) => _newPassword = value?.trim() ?? '',
            ),

            const SizedBox(height: 16),

            TextFormField(
              controller: _confirmPasswordController,
              obscureText: !_showConfirmPassword,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(context, 'confirm_new_password') ?? 'تأكيد كلمة المرور الجديدة',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                prefixIcon: const Icon(Icons.lock_clock),
                suffixIcon: IconButton(
                  icon: Icon(
                    _showConfirmPassword ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () {
                    setState(() {
                      _showConfirmPassword = !_showConfirmPassword;
                    });
                  },
                ),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return AppLocalizations.of(context, 'confirm_password_required') ??
                      'تأكيد كلمة المرور مطلوب';
                }
                return null;
              },
              onSaved: (value) => _confirmPassword = value?.trim() ?? '',
            ),

            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _submitForm,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isLoading
                    ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
                    : Text(
                  AppLocalizations.of(context, 'save_new_password') ?? 'حفظ',
                  style: const TextStyle(fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}