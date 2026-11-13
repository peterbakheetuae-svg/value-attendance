import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'dart:async';

import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/app_background.dart';
import '../settings/privacy_policy_page.dart';
import '../../widgets/glass_dialog.dart';
import '../../widgets/glass_ui.dart';

class TermsPage extends StatefulWidget {
  const TermsPage({super.key});

  @override
  State<TermsPage> createState() => _TermsPageState();
}

class _TermsPageState extends State<TermsPage> {
  bool _hasAgreed = false;
  final ScrollController _scrollController = ScrollController();
  final String serviceProvider = 'Peter Bakheet';
  final String lastUpdated = 'ديسمبر 2024';

  // متغير للتحقق من قراءة المستخدم
  bool _hasReadToEnd = false;

  @override
  void initState() {
    super.initState();

    // مراقبة تمرير الصفحة للتحقق من قراءة المستخدم للنهاية
    _scrollController.addListener(() {
      final maxScroll = _scrollController.position.maxScrollExtent;
      final currentScroll = _scrollController.position.pixels;

      if (currentScroll >= maxScroll * 0.9) {
        setState(() {
          _hasReadToEnd = true;
        });
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _showAgreementDialog(BuildContext context) {
    final appController = Provider.of<AppController>(context, listen: false);
    final isDark = appController.isDark;

    showDialog(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: Text(
          AppLocalizations.of(context, 'terms_and_conditions') ?? 'الشروط والأحكام',
          style: TextStyle(
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
        content: Text(
          AppLocalizations.of(context, 'must_agree') ?? 'يجب الموافقة على الشروط والأحكام لاستخدام التطبيق',
          style: TextStyle(
            color: isDark ? Ar.grey.shade300 : Ar.grey.shade700,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'OK',
              style: TextStyle(
                color: Theme.of(context).primaryColor,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openPrivacyPolicy(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const PrivacyPolicyPage(),
      ),
    );
  }

  void _copyTermsToClipboard(BuildContext context) {
    final termsText = '''
${AppLocalizations.of(context, 'terms_title') ?? 'الشروط والأحكام'}
${AppLocalizations.of(context, 'service_provider') ?? 'مزود الخدمة'}: $serviceProvider
${AppLocalizations.of(context, 'last_updated') ?? 'آخر تحديث'}: $lastUpdated

${AppLocalizations.of(context, 'acceptance_of_terms_text') ?? 'باستخدامك تطبيق Value...'}
${AppLocalizations.of(context, 'app_usage_text') ?? 'يُمنع النسخ أو التعديل...'}
${AppLocalizations.of(context, 'user_responsibilities_text') ?? 'يجب على المستخدمين الحفاظ على أمان أجهزتهم...'}
''';

    Clipboard.setData(ClipboardData(text: termsText));

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${AppLocalizations.of(context, 'copied_to_clipboard') ?? 'تم النسخ إلى الحافظة'}'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;
    final isRTL = appController.isRTL;

    return Directionality(
      textDirection: isRTL ? TextDirection.rtl : TextDirection.ltr,
      child: AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(
              children: [
                // ✅ Header يدوي بدل AppBar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          Icons.arrow_back,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context, 'terms_and_conditions') ?? 'الشروط والأحكام',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                        ),
                      ),
                      // زر النسخ
                      IconButton(
                        icon: Icon(
                          Icons.content_copy,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                        onPressed: () => _copyTermsToClipboard(context),
                        tooltip: 'Copy Terms',
                      ),
                    ],
                  ),
                ),

                Expanded(
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // بطاقة العنوان الرئيسية
                        _buildHeaderCard(context, isDark),

                        const SizedBox(height: 24),

                        // القبول
                        _buildTermsCard(
                          context: context,
                          isDark: isDark,
                          icon: Icons.check_circle,
                          title: AppLocalizations.of(context, 'acceptance_of_terms') ?? 'القبول',
                          content: AppLocalizations.of(context, 'acceptance_of_terms_text') ?? 'باستخدامك تطبيق Value...',
                          color: Ar.green,
                        ),

                        const SizedBox(height: 16),

                        // استخدام التطبيق
                        _buildTermsCard(
                          context: context,
                          isDark: isDark,
                          icon: Icons.app_settings_alt,
                          title: AppLocalizations.of(context, 'app_usage') ?? 'استخدام التطبيق',
                          content: AppLocalizations.of(context, 'app_usage_text') ?? 'يُمنع النسخ أو التعديل...',
                          color: Ar.info,
                        ),

                        const SizedBox(height: 16),

                        // الملكية الفكرية
                        _buildTermsCard(
                          context: context,
                          isDark: isDark,
                          icon: Icons.copyright,
                          title: AppLocalizations.of(context, 'intellectual_property') ?? 'الملكية الفكرية',
                          content: AppLocalizations.of(context, 'intellectual_property_text') ?? 'جميع حقوق الملكية الفكرية...',
                          color: Ar.accent,
                        ),

                        const SizedBox(height: 16),

                        // مسؤوليات المستخدم
                        _buildTermsCard(
                          context: context,
                          isDark: isDark,
                          icon: Icons.people,
                          title: AppLocalizations.of(context, 'user_responsibilities') ?? 'مسؤوليات المستخدم',
                          content: AppLocalizations.of(context, 'user_responsibilities_text') ?? 'يجب على المستخدمين الحفاظ على أمان أجهزتهم...',
                          color: Ar.amber,
                        ),

                        const SizedBox(height: 16),

                        // الأنشطة المحظورة
                        _buildTermsCard(
                          context: context,
                          isDark: isDark,
                          icon: Icons.block,
                          title: AppLocalizations.of(context, 'prohibited_activities') ?? 'الأنشطة المحظورة',
                          content: AppLocalizations.of(context, 'prohibited_activities_text') ?? 'يحظر استخدام التطبيق لأي غرض غير قانوني...',
                          color: Ar.red,
                        ),

                        const SizedBox(height: 16),

                        // تعديلات التطبيق
                        _buildTermsCard(
                          context: context,
                          isDark: isDark,
                          icon: Icons.update,
                          title: AppLocalizations.of(context, 'app_modifications') ?? 'تعديلات التطبيق',
                          content: AppLocalizations.of(context, 'app_modifications_text') ?? 'قد يقوم مزود الخدمة بتحديث أو تعديل...',
                          color: Ar.amber,
                        ),

                        const SizedBox(height: 16),

                        // تحديد المسؤولية
                        _buildTermsCard(
                          context: context,
                          isDark: isDark,
                          icon: Icons.gavel,
                          title: AppLocalizations.of(context, 'liability_limitation') ?? 'تحديد المسؤولية',
                          content: AppLocalizations.of(context, 'liability_limitation_text') ?? 'لا يتحمل مزود الخدمة المسؤولية...',
                          color: Ar.tan,
                        ),

                        const SizedBox(height: 16),

                        // إنهاء الخدمة
                        _buildTermsCard(
                          context: context,
                          isDark: isDark,
                          icon: Icons.exit_to_app,
                          title: AppLocalizations.of(context, 'termination') ?? 'إنهاء الخدمة',
                          content: AppLocalizations.of(context, 'termination_text') ?? 'يحق لمزود الخدمة إنهاء أو تعليق...',
                          color: Ar.grey,
                        ),

                        const SizedBox(height: 16),

                        // القانون الحاكم
                        _buildTermsCard(
                          context: context,
                          isDark: isDark,
                          icon: Icons.balance,
                          title: AppLocalizations.of(context, 'governing_law') ?? 'القانون الحاكم',
                          content: AppLocalizations.of(context, 'governing_law_text') ?? 'تخضع هذه الشروط والأحكام للقوانين...',
                          color: Ar.accent,
                        ),

                        const SizedBox(height: 24),

                        // معلومات إضافية
                        _buildAdditionalInfo(context, isDark),

                        const SizedBox(height: 24),

                        // إشعار القراءة
                        if (!_hasReadToEnd) ...[
                          _buildReadingNotice(context, isDark),
                          const SizedBox(height: 16),
                        ],
                      ],
                    ),
                  ),
                ),

                // زر الموافقة
                _buildAgreementButton(context, isDark),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // بطاقة العنوان الرئيسية
  Widget _buildHeaderCard(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
            Ar.accent.shade900.withOpacity(0.8),
            Ar.info.shade900.withOpacity(0.8),
          ]
              : [
            Ar.accent.shade50,
            Ar.info.shade50,
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Ar.accent.shade800.withOpacity(0.3)
              : Ar.accent.shade200,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Ar.accent.shade900.withOpacity(0.3)
                : Ar.accent.shade100.withOpacity(0.5),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        children: [
          // أيقونة الشروط
          Icon(
            Icons.description,
            size: 60,
            color: Ar.accent,
          ),
          const SizedBox(height: 16),

          // العنوان
          Text(
            AppLocalizations.of(context, 'terms_title') ?? 'الشروط والأحكام',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),

          // مزود الخدمة
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.person,
                size: 16,
                color: isDark ? Ar.grey.shade300 : Ar.grey.shade600,
              ),
              const SizedBox(width: 8),
              Text(
                '${AppLocalizations.of(context, 'service_provider') ?? 'مزود الخدمة'}: $serviceProvider',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Ar.grey.shade300 : Ar.grey.shade600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // تاريخ التحديث
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.calendar_today,
                size: 16,
                color: isDark ? Ar.grey.shade300 : Ar.grey.shade600,
              ),
              const SizedBox(width: 8),
              Text(
                '${AppLocalizations.of(context, 'last_updated') ?? 'آخر تحديث'}: $lastUpdated',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Ar.grey.shade300 : Ar.grey.shade600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // بطاقة شروط
  Widget _buildTermsCard({
    required BuildContext context,
    required bool isDark,
    required IconData icon,
    required String title,
    required String content,
    required Color color,
  }) {
    return Material(
      borderRadius: BorderRadius.circular(16),
      color: isDark
          ? Ar.grey.shade900.withOpacity(0.5)
          : Colors.white.withOpacity(0.9),
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // العنوان والأيقونة
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: color.withOpacity(0.3)),
                  ),
                  child: Icon(
                    icon,
                    color: color,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // المحتوى
            Text(
              content,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Ar.grey.shade300 : Ar.grey.shade700,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // معلومات إضافية
  Widget _buildAdditionalInfo(BuildContext context, bool isDark) {
    final List<Map<String, dynamic>> additionalSections = [
      {
        'title': AppLocalizations.of(context, 'data_privacy') ?? 'خصوصية البيانات',
        'icon': Icons.privacy_tip,
        'color': Ar.green,
        'content': AppLocalizations.of(context, 'data_privacy_text') ?? 'يتم التعامل مع بيانات المستخدم...',
        'action': _openPrivacyPolicy,
      },
      {
        'title': AppLocalizations.of(context, 'account_security') ?? 'أمان الحساب',
        'icon': Icons.security,
        'color': Ar.info,
        'content': AppLocalizations.of(context, 'account_security_text') ?? 'أنت مسؤول عن الحفاظ على سرية...',
        'action': null,
      },
      {
        'title': AppLocalizations.of(context, 'changes_to_terms') ?? 'تغييرات الشروط',
        'icon': Icons.notifications_active,
        'color': Ar.amber,
        'content': AppLocalizations.of(context, 'changes_to_terms_text') ?? 'تحتفظ الشركة بالحق في تحديث...',
        'action': null,
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'معلومات إضافية',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
        const SizedBox(height: 16),

        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: additionalSections.length,
          separatorBuilder: (context, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final section = additionalSections[index];
            final Color color = section['color'] as Color;

            return Material(
              borderRadius: BorderRadius.circular(16),
              color: isDark
                  ? Ar.grey.shade900.withOpacity(0.5)
                  : Colors.white.withOpacity(0.9),
              elevation: 2,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: section['action'] != null
                    ? () => (section['action'] as Function)(context)
                    : null,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: color.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: color.withOpacity(0.3)),
                        ),
                        child: Icon(
                          section['icon'] as IconData,
                          color: color,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              section['title'] as String,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              section['content'] as String,
                              style: TextStyle(
                                fontSize: 12,
                                color: isDark ? Ar.grey.shade400 : Ar.grey.shade600,
                              ),
                            ),
                            if (section['action'] != null) ...[
                              const SizedBox(height: 8),
                              Row(
                                children: [
                                  Text(
                                    'اقرأ المزيد',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(context).primaryColor,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Icon(
                                    Icons.arrow_forward,
                                    size: 12,
                                    color: Theme.of(context).primaryColor,
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  // إشعار القراءة
  Widget _buildReadingNotice(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: Glass.panel(isDark, r: 16),
      child: Row(
        children: [
          Icon(
            Icons.info,
            color: Ar.amber,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              AppLocalizations.of(context, 'read_accept') ?? 'يرجى قراءة وقبول الشروط والأحكام',
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Ar.grey.shade300 : Ar.grey.shade700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // زر الموافقة
  Widget _buildAgreementButton(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: Glass.tile(isDark, r: 12),
      child: Row(
        children: [
          // مربع الاختيار
          Checkbox(
            value: _hasAgreed,
            onChanged: (value) {
              if (!_hasReadToEnd && value == true) {
                _showAgreementDialog(context);
                return;
              }
              setState(() {
                _hasAgreed = value ?? false;
              });
            },
            activeColor: Theme.of(context).primaryColor,
          ),
          const SizedBox(width: 12),

          // نص الموافقة
          Expanded(
            child: GestureDetector(
              onTap: () {
                if (!_hasReadToEnd && !_hasAgreed) {
                  _showAgreementDialog(context);
                  return;
                }
                setState(() {
                  _hasAgreed = !_hasAgreed;
                });
              },
              child: Text(
                AppLocalizations.of(context, 'i_agree') ?? 'أوافق على الشروط',
                style: TextStyle(
                  fontSize: 16,
                  color: isDark ? Colors.white : Colors.black,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),

          const SizedBox(width: 12),

          // زر الحفظ
          ElevatedButton(
            onPressed: _hasAgreed
                ? () {
              Navigator.pop(context);
            }
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: _hasAgreed
                  ? Theme.of(context).primaryColor
                  : Ar.grey.shade400,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
  }
}