import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';

import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/app_background.dart';

class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  static const String lastUpdated = 'ديسمبر 2024';
  static const String privacyEmail = 'info@valueaqar.com';

  Future<void> _sendEmail() async {
    final uri = Uri.parse('mailto:$privacyEmail');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      throw 'Could not launch $uri';
    }
  }

  void _copyEmailToClipboard(BuildContext context) {
    Clipboard.setData(ClipboardData(text: privacyEmail));

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
                      Text(
                        AppLocalizations.of(context, 'privacy_policy') ?? 'سياسة الخصوصية',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),

                // ✅ المحتوى القابل للتمرير
                Expanded(
                  child: ScrollConfiguration(
                    behavior: const ScrollBehavior().copyWith(
                      overscroll: false,
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // بطاقة العنوان الرئيسية
                          _buildHeaderCard(context, isDark),

                          const SizedBox(height: 24),

                          // المعلومات التي نجمعها
                          _buildSectionCard(
                            context: context,
                            isDark: isDark,
                            icon: Icons.collections_bookmark,
                            title: AppLocalizations.of(context, 'information_we_collect') ?? 'المعلومات التي نجمعها',
                            content: AppLocalizations.of(context, 'information_we_collect_text') ?? 'يجمع تطبيق Value Attendance معلومات الجهاز والاستخدام...',
                            color: Colors.blue,
                          ),

                          const SizedBox(height: 16),

                          // كيف نستخدم المعلومات
                          _buildSectionCard(
                            context: context,
                            isDark: isDark,
                            icon: Icons.how_to_reg,
                            title: AppLocalizations.of(context, 'how_we_use_information') ?? 'كيف نستخدم المعلومات',
                            content: AppLocalizations.of(context, 'how_we_use_information_text') ?? 'نستخدم المعلومات التي نجمعها لتقديم خدماتنا...',
                            color: Colors.green,
                          ),

                          const SizedBox(height: 16),

                          // مشاركة البيانات
                          _buildSectionCard(
                            context: context,
                            isDark: isDark,
                            icon: Icons.share,
                            title: AppLocalizations.of(context, 'data_sharing') ?? 'مشاركة البيانات',
                            content: AppLocalizations.of(context, 'data_sharing_text') ?? 'قد تتم مشاركة البيانات المجمعة والمجهولة...',
                            color: Colors.orange,
                          ),

                          const SizedBox(height: 16),

                          // احتفاظ البيانات
                          _buildSectionCard(
                            context: context,
                            isDark: isDark,
                            icon: Icons.save,
                            title: AppLocalizations.of(context, 'data_retention') ?? 'احتفاظ البيانات',
                            content: AppLocalizations.of(context, 'data_retention_text') ?? 'يتم الاحتفاظ بالبيانات الشخصية فقط...',
                            color: Colors.purple,
                          ),

                          const SizedBox(height: 16),

                          // خصوصية الأطفال
                          _buildSectionCard(
                            context: context,
                            isDark: isDark,
                            icon: Icons.child_care,
                            title: AppLocalizations.of(context, 'children_privacy') ?? 'خصوصية الأطفال',
                            content: AppLocalizations.of(context, 'children_privacy_text') ?? 'التطبيق لا يجمع معلومات عن قصد...',
                            color: Colors.pink,
                          ),

                          const SizedBox(height: 16),

                          // حقوق المستخدم
                          _buildSectionCard(
                            context: context,
                            isDark: isDark,
                            icon: Icons.verified_user,
                            title: AppLocalizations.of(context, 'user_rights') ?? 'حقوق المستخدم',
                            content: AppLocalizations.of(context, 'user_rights_text') ?? 'يمكنك إلغاء الاشتراك في أي وقت...',
                            color: Colors.teal,
                          ),

                          const SizedBox(height: 16),

                          // حماية البيانات
                          _buildSectionCard(
                            context: context,
                            isDark: isDark,
                            icon: Icons.security,
                            title: AppLocalizations.of(context, 'data_protection') ?? 'حماية البيانات',
                            content: AppLocalizations.of(context, 'data_protection_text') ?? 'تم تنفيذ ضمانات لحماية بياناتك...',
                            color: Colors.red,
                          ),

                          const SizedBox(height: 16),

                          // الموافقة
                          _buildSectionCard(
                            context: context,
                            isDark: isDark,
                            icon: Icons.gpp_good,
                            title: AppLocalizations.of(context, 'consent') ?? 'الموافقة',
                            content: AppLocalizations.of(context, 'consent_text') ?? 'يوافق المستخدم على سياسة الخصوصية...',
                            color: Colors.indigo,
                          ),

                          const SizedBox(height: 24),

                          // ميزات الخصوصية
                          _buildPrivacyFeatures(context, isDark),

                          const SizedBox(height: 24),

                          // اتصل بنا
                          _buildContactCard(context, isDark),

                          const SizedBox(height: 24),

                          // تحديث السياسة
                          _buildUpdateSection(context, isDark),
                        ],
                      ),
                    ),
                  ),
                ),
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
            Colors.indigo.shade900.withOpacity(0.8),
            Colors.purple.shade900.withOpacity(0.8),
          ]
              : [
            Colors.indigo.shade50,
            Colors.purple.shade50,
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.indigo.shade800.withOpacity(0.3)
              : Colors.indigo.shade200,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.indigo.shade900.withOpacity(0.3)
                : Colors.indigo.shade100.withOpacity(0.5),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        children: [
          // أيقونة الخصوصية
          Icon(
            Icons.privacy_tip,
            size: 60,
            color: Colors.indigoAccent,
          ),
          const SizedBox(height: 16),

          // العنوان
          Text(
            AppLocalizations.of(context, 'privacy_policy_title') ?? 'سياسة الخصوصية',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),

          // تاريخ التحديث
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.update,
                size: 16,
                color: isDark ? Colors.grey.shade300 : Colors.grey.shade600,
              ),
              const SizedBox(width: 8),
              Text(
                '${AppLocalizations.of(context, 'last_updated') ?? 'آخر تحديث'}: $lastUpdated',
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.grey.shade300 : Colors.grey.shade600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // نص المقدمة
          Text(
            AppLocalizations.of(context, 'introduction_text') ?? 'نحن في تطبيق Value Attendance ندرك أهمية خصوصية معلوماتك...',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.grey.shade300 : Colors.grey.shade600,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  // بطاقة قسم
  Widget _buildSectionCard({
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
          ? Colors.grey.shade900.withOpacity(0.5)
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
                color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ميزات الخصوصية
  Widget _buildPrivacyFeatures(BuildContext context, bool isDark) {
    final List<Map<String, dynamic>> features = [
      {
        'title': AppLocalizations.of(context, 'encryption') ?? 'التشفير',
        'icon': Icons.lock,
        'color': Colors.green,
        'description': AppLocalizations.of(context, 'encryption_text') ?? 'جميع البيانات المرسلة بين جهازك وخوادمنا مشفرة...',
      },
      {
        'title': AppLocalizations.of(context, 'local_storage') ?? 'التخزين المحلي',
        'icon': Icons.storage,
        'color': Colors.blue,
        'description': AppLocalizations.of(context, 'local_storage_text') ?? 'يتم تخزين بعض البيانات محلياً على جهازك...',
      },
      {
        'title': AppLocalizations.of(context, 'permissions') ?? 'الأذونات',
        'icon': Icons.perm_device_information,
        'color': Colors.orange,
        'description': AppLocalizations.of(context, 'permissions_text') ?? 'التطبيق يطلب فقط الأذونات الضرورية...',
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppLocalizations.of(context, 'privacy_features') ?? 'ميزات الخصوصية',
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
          itemCount: features.length,
          separatorBuilder: (context, index) => const SizedBox(height: 12),
          itemBuilder: (context, index) {
            final feature = features[index];
            final Color color = feature['color'] as Color;

            return Material(
              borderRadius: BorderRadius.circular(16),
              color: isDark
                  ? Colors.grey.shade900.withOpacity(0.5)
                  : Colors.white.withOpacity(0.9),
              elevation: 2,
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
                        feature['icon'] as IconData,
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
                            feature['title'] as String,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            feature['description'] as String,
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  // بطاقة الاتصال
  Widget _buildContactCard(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.teal.shade900.withOpacity(0.3)
            : Colors.teal.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.teal.shade800
              : Colors.teal.shade200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.of(context, 'contact_us') ?? 'اتصل بنا',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black,
            ),
          ),
          const SizedBox(height: 12),

          Text(
            AppLocalizations.of(context, 'contact_us_privacy_text') ?? 'إذا كانت لديك أي أسئلة أو استفسارات حول سياسة الخصوصية، يمكنك التواصل معنا عبر البريد الإلكتروني.',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),

          // بطاقة البريد الإلكتروني
          Material(
            borderRadius: BorderRadius.circular(12),
            color: isDark
                ? Colors.teal.shade800.withOpacity(0.5)
                : Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // عنوان البريد الإلكتروني
                  Row(
                    children: [
                      Icon(
                        Icons.email,
                        color: Colors.teal,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        AppLocalizations.of(context, 'email_privacy') ?? 'البريد الإلكتروني',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // عنوان البريد الإلكتروني
                  Text(
                    privacyEmail,
                    style: TextStyle(
                      fontSize: 15,
                      color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
                    ),
                  ),

                  const SizedBox(height: 16),

                  // أزرار الإجراءات في صف واحد
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      // زر النسخ
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => _copyEmailToClipboard(context),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.teal.withOpacity(0.2),
                            foregroundColor: Colors.teal,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                              side: BorderSide(color: Colors.teal.withOpacity(0.3)),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                          ),
                          icon: const Icon(Icons.content_copy, size: 18),
                          label: Text(
                            AppLocalizations.of(context, 'copy_email') ?? 'نسخ',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),

                      const SizedBox(width: 8),

                      // زر الإرسال
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _sendEmail,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.teal,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                          ),
                          icon: const Icon(Icons.email_outlined, size: 18),
                          label: Text(
                            'إرسال',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // قسم تحديث السياسة
  Widget _buildUpdateSection(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.grey.shade900.withOpacity(0.5)
            : Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark
              ? Colors.grey.shade800
              : Colors.grey.shade200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.notifications_active,
                color: Colors.amber,
              ),
              const SizedBox(width: 12),
              Text(
                AppLocalizations.of(context, 'update_policy') ?? 'تحديث السياسة',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          Text(
            AppLocalizations.of(context, 'update_policy_text') ?? 'قد نقوم بتحديث سياسة الخصوصية هذه من وقت لآخر. سنقوم بإعلامك بأي تغييرات جوهرية.',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.amber.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.amber.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info,
                      size: 10,
                      color: Colors.amber,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Important',
                      style: TextStyle(
                        color: Colors.amber,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Check this page regularly for updates',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}