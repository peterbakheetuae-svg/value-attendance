// lib/pages/profile/edit_profile_page.dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../services/profile_api.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';

class EditProfilePage extends StatefulWidget {
  final String uid;
  final Map<String, dynamic> currentData;
  final String source; // 'employee' or 'employer'

  const EditProfilePage({
    super.key,
    required this.uid,
    required this.currentData,
    required this.source,
  });

  @override
  State<EditProfilePage> createState() => _EditProfilePageState();
}

class _EditProfilePageState extends State<EditProfilePage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _emailController;
  late TextEditingController _phoneController;
  late TextEditingController _bankNameController;
  late TextEditingController _accountHolderController;
  late TextEditingController _ibanController;
  late TextEditingController _accountNumberController;

  String? _newPhotoBase64;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _emailController = TextEditingController(text: widget.currentData["email"] ?? '');
    _phoneController = TextEditingController(text: widget.currentData["phone"] ?? '');
    _bankNameController = TextEditingController(text: widget.currentData["bankName"] ?? '');
    _accountHolderController = TextEditingController(text: widget.currentData["accountHolder"] ?? '');
    _ibanController = TextEditingController(text: widget.currentData["iban"] ?? '');
    _accountNumberController = TextEditingController(text: widget.currentData["accountNumber"] ?? '');
  }

  @override
  void dispose() {
    _emailController.dispose();
    _phoneController.dispose();
    _bankNameController.dispose();
    _accountHolderController.dispose();
    _ibanController.dispose();
    _accountNumberController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final XFile? picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (picked != null) {
      final bytes = await picked.readAsBytes();
      final base64 = base64Encode(bytes);
      setState(() {
        _newPhotoBase64 = "data:image/jpeg;base64,$base64";
      });
    }
  }

  Future<void> _saveChanges() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _loading = true);

    final appController = Provider.of<AppController>(context, listen: false);
    final currentUserUid = appController.userUid; // UID of logged-in user

    if (currentUserUid == null || currentUserUid.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cannot update: user not logged in')),
        );
      }
      setState(() => _loading = false);
      return;
    }

    final result = await ProfileApi.updateProfile(
      uid: widget.uid,
      email: _emailController.text.trim(),
      phone: _phoneController.text.trim(),
      bankName: _bankNameController.text.trim(),
      accountHolder: _accountHolderController.text.trim(),
      iban: _ibanController.text.trim(),
      accountNumber: _accountNumberController.text.trim(),
      photoBase64: _newPhotoBase64,
      currentUserUid: currentUserUid,
    );

    setState(() => _loading = false);

    if (!mounted) return;

    if (result["success"] == true) {
      if (result["photo"] != null) {
        await appController.saveUserPhoto(result["photo"]);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result["message"] ?? "Update successful")),
      );
      Navigator.pop(context, true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result["message"] ?? "Update failed")),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;
    final subduedTextColor = isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight;

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(AppLocalizations.of(context, 'edit_account')),
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                // Photo picker
                GestureDetector(
                  onTap: _pickImage,
                  child: Stack(
                    children: [
                      Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: primaryColor, width: 2),
                          image: _newPhotoBase64 != null
                              ? DecorationImage(
                            image: MemoryImage(base64Decode(_newPhotoBase64!.split(',').last)),
                            fit: BoxFit.cover,
                          )
                              : (widget.currentData["photo"] != null && widget.currentData["photo"].toString().isNotEmpty)
                              ? DecorationImage(
                            image: NetworkImage(widget.currentData["photo"]),
                            fit: BoxFit.cover,
                          )
                              : null,
                          color: isDark ? AppColors.surfaceVariantDark : Colors.grey[200],
                        ),
                        child: (_newPhotoBase64 == null && (widget.currentData["photo"] == null || widget.currentData["photo"].isEmpty))
                            ? Icon(Icons.person, size: 40, color: subduedTextColor)
                            : null,
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(color: primaryColor, shape: BoxShape.circle),
                          child: const Icon(Icons.camera_alt, color: Colors.white, size: 20),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Editable fields card
                GlassCard(
                  radius: 24,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      TextFormField(
                        controller: _emailController,
                        decoration: InputDecoration(
                          labelText: AppLocalizations.of(context, 'email'),
                          prefixIcon: Icon(Icons.email, color: primaryColor),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        keyboardType: TextInputType.emailAddress,
                        validator: (value) {
                          if (value != null && value.isNotEmpty && !value.contains('@')) {
                            return 'Enter a valid email';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _phoneController,
                        decoration: InputDecoration(
                          labelText: AppLocalizations.of(context, 'phone'),
                          prefixIcon: Icon(Icons.phone, color: primaryColor),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        keyboardType: TextInputType.phone,
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: ElevatedButton(
                          onPressed: _loading ? null : _saveChanges,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primaryColor,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: _loading
                              ? const CircularProgressIndicator(color: Colors.white)
                              : Text(
                            AppLocalizations.of(context, 'save_changes'),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}