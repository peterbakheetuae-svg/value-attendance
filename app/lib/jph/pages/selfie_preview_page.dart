import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart'; // 🔥 أضف هذا

import '../services/app_controller.dart'; // 🔥 أضف هذا
import '../l10n/app_localizations.dart'; // 🔥 أضف هذا
import '../theme/app_colors.dart'; // 🔥 أضف هذا

class SelfiePreviewPage extends StatelessWidget {
  final File imageFile;

  const SelfiePreviewPage({super.key, required this.imageFile});

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;
    final isRTL = appController.isRTL;

    // 🔥 ألوان ديناميكية
    final backgroundColor = isDark ? AppColors.backgroundDark : Colors.black;
    final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;
    final textColor = Colors.white; // النصوص تبقى بيضاء على الخلفية الداكنة
    final borderColor = isDark ? AppColors.outlineDark : Colors.white;

    return Directionality(
      textDirection: isRTL ? TextDirection.rtl : TextDirection.ltr, // 🔥 ديناميكي
      child: Scaffold(
        backgroundColor: backgroundColor,
        body: SafeArea(
          child: Column(
            children: [
              // 🔥 Header مع ترجمة
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      AppLocalizations.of(context, 'selfie_preview'), // 🔥 ترجمة
                      style: TextStyle(
                        color: textColor,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close, color: textColor),
                      onPressed: () => Navigator.pop(context, null),
                    )
                  ],
                ),
              ),

              // 🔥 عرض الصورة
              Expanded(
                child: Center(
                  child: Container(
                    margin: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 10,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.file(
                        imageFile,
                        fit: BoxFit.cover,
                        width: double.infinity,
                      ),
                    ),
                  ),
                ),
              ),

              // 🔥 الأزرار مع ترجمة
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    // 🔥 زر إعادة التصوير
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: textColor,
                          side: BorderSide(color: borderColor),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(Icons.refresh),
                        label: Text(AppLocalizations.of(context, 'retake_photo')), // 🔥 ترجمة
                        onPressed: () => Navigator.pop(context, false),
                      ),
                    ),
                    const SizedBox(width: 12),

                    // 🔥 زر استخدام الصورة
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 2,
                        ),
                        icon: const Icon(Icons.check),
                        label: Text(AppLocalizations.of(context, 'use_photo')), // 🔥 ترجمة
                        onPressed: () => Navigator.pop(context, true),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}