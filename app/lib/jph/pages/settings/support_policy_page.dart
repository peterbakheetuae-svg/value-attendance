import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart'; // لإضافة Clipboard
import 'package:share_plus/share_plus.dart'; // لمشاركة معلومات الاتصال

import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/app_background.dart';

class SupportPolicyPage extends StatelessWidget {
  const SupportPolicyPage({super.key});

  // روابط التواصل
  // official Value contact (the only support phone / email shown in the app)
  static const String supportEmail = 'info@valueaqar.com';
  static const String websiteUrl = 'https://valueaqar.com';
  static const String supportPhone = '01080660100';
  static const String whatsappNumber = '01080660100';

  // وظائف لفتح الروابط
  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      throw 'Could not launch $url';
    }
  }

  Future<void> _sendEmail() async {
    final uri = Uri.parse('mailto:$supportEmail');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      throw 'Could not launch $uri';
    }
  }

  Future<void> _makePhoneCall() async {
    final uri = Uri.parse('tel:$supportPhone');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      throw 'Could not launch $uri';
    }
  }

  Future<void> _openWhatsApp() async {
    // Egyptian mobile → international form for WhatsApp (01080660100 → 201080660100)
    final url = 'https://wa.me/2$whatsappNumber';
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      throw 'Could not launch $url';
    }
  }

  void _copyToClipboard(BuildContext context, String text, String label) {
    Clipboard.setData(ClipboardData(text: text));

    // عرض snackbar للإشعار
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label ${AppLocalizations.of(context, 'copied_to_clipboard') ?? 'تم النسخ إلى الحافظة'}'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _shareContactInfo(BuildContext context) {
    final shareText = '''
Value Attendance Support:
📧 Email: $supportEmail
🌐 Website: $websiteUrl
📞 Support: $supportPhone
💬 WhatsApp: $whatsappNumber
''';

    Share.share(shareText, subject: 'Value Attendance Support Information');
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
                          AppLocalizations.of(context, 'support_policy') ?? 'سياسة الدعم',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                        ),
                      ),
                      // زر المشاركة
                      IconButton(
                        icon: Icon(
                          Icons.share,
                          color: isDark ? Colors.white70 : Colors.black54,
                        ),
                        onPressed: () => _shareContactInfo(context),
                        tooltip: 'Share',
                      ),
                    ],
                  ),
                ),

                // ✅ المحتوى القابل للتمرير
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // بطاقة الدعم الرئيسية
                        _buildSupportCard(context, isDark),

                        const SizedBox(height: 24),

                        // عنوان قنوات الاتصال
                        Text(
                          AppLocalizations.of(context, 'contact_us') ?? 'تواصل معنا',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          AppLocalizations.of(context, 'support_description') ?? 'نحن هنا لمساعدتك على مدار الساعة. إذا كان لديك أي أسئلة أو مخاوف أو تحتاج إلى مساعدة بخصوص منتجاتنا أو خدماتنا، فلا تتردد في التواصل مع فريق الدعم لدينا.',
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
                          ),
                        ),

                        const SizedBox(height: 24),

                        // قنوات الاتصال
                        _buildContactChannels(context, isDark),

                        const SizedBox(height: 24),

                        // روابط سريعة
                        _buildQuickLinks(context, isDark),

                        const SizedBox(height: 24),

                        // معلومات فريق الدعم
                        _buildSupportTeamInfo(context, isDark),
                      ],
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

  // بطاقة الدعم الرئيسية
  Widget _buildSupportCard(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
            Colors.blue.shade900.withOpacity(0.8),
            Colors.purple.shade900.withOpacity(0.8),
          ]
              : [
            Colors.blue.shade50,
            Colors.purple.shade50,
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDark
              ? Colors.blue.shade800.withOpacity(0.3)
              : Colors.blue.shade200,
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: isDark
                ? Colors.blue.shade900.withOpacity(0.3)
                : Colors.blue.shade100.withOpacity(0.5),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        children: [
          // أيقونة الدعم
          Icon(
            Icons.support_agent,
            size: 60,
            color: Colors.blueAccent,
          ),
          const SizedBox(height: 16),

          // العنوان
          Text(
            AppLocalizations.of(context, 'support_24_7') ?? 'دعم على مدار الساعة',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),

          // وصف مختصر
          Text(
            AppLocalizations.of(context, 'support_description') ?? 'نحن هنا لمساعدتك على مدار الساعة',
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.grey.shade300 : Colors.grey.shade600,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),

          // شارة 24/7
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.greenAccent.withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.greenAccent),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.access_time,
                  size: 16,
                  color: Colors.greenAccent,
                ),
                const SizedBox(width: 8),
                Text(
                  '24/7 ${AppLocalizations.of(context, 'available_24_7') ?? 'متاح'}',
                  style: const TextStyle(
                    color: Colors.greenAccent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // قنوات الاتصال
  Widget _buildContactChannels(BuildContext context, bool isDark) {
    return Column(
      children: [
        // البريد الإلكتروني
        _buildContactCard(
          context: context,
          isDark: isDark,
          icon: Icons.email,
          title: AppLocalizations.of(context, 'email') ?? 'البريد الإلكتروني',
          subtitle: supportEmail,
          color: Colors.blue,
          onTap: _sendEmail,
          onCopy: () => _copyToClipboard(context, supportEmail, 'Email'),
        ),

        const SizedBox(height: 16),

        // الموقع الإلكتروني
        _buildContactCard(
          context: context,
          isDark: isDark,
          icon: Icons.language,
          title: AppLocalizations.of(context, 'website') ?? 'الموقع الإلكتروني',
          subtitle: 'VALUE ATTENDANCE',
          color: Colors.green,
          onTap: () => _launchUrl(websiteUrl),
          onCopy: () => _copyToClipboard(context, websiteUrl, 'Website'),
        ),

        const SizedBox(height: 16),

        // دعم الهاتف
        _buildContactCard(
          context: context,
          isDark: isDark,
          icon: Icons.phone,
          title: AppLocalizations.of(context, 'phone_support') ?? 'دعم الهاتف',
          subtitle: supportPhone,
          color: Colors.orange,
          onTap: _makePhoneCall,
          onCopy: () => _copyToClipboard(context, supportPhone, 'Phone'),
        ),

        const SizedBox(height: 16),

        // واتساب
        _buildContactCard(
          context: context,
          isDark: isDark,
          icon: Icons.chat,
          title: AppLocalizations.of(context, 'whatsapp') ?? 'واتساب',
          subtitle: whatsappNumber,
          color: Colors.green,
          onTap: _openWhatsApp,
          onCopy: () => _copyToClipboard(context, whatsappNumber, 'WhatsApp'),
        ),
      ],
    );
  }

  // بطاقة اتصال واحدة
  Widget _buildContactCard({
    required BuildContext context,
    required bool isDark,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
    required VoidCallback onCopy,
  }) {
    return Material(
      borderRadius: BorderRadius.circular(16),
      color: isDark
          ? Colors.grey.shade900.withOpacity(0.5)
          : Colors.white.withOpacity(0.9),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // الأيقونة
              Container(
                width: 50,
                height: 50,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: color.withOpacity(0.3)),
                ),
                child: Icon(
                  icon,
                  color: color,
                  size: 24,
                ),
              ),

              const SizedBox(width: 16),

              // النص
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),

              // زر النسخ
              IconButton(
                icon: Icon(
                  Icons.content_copy,
                  size: 20,
                  color: color,
                ),
                onPressed: onCopy,
                tooltip: AppLocalizations.of(context, 'copy_email') ?? 'نسخ',
              ),
            ],
          ),
        ),
      ),
    );
  }

  // روابط سريعة
  Widget _buildQuickLinks(BuildContext context, bool isDark) {
    final quickLinks = [
      {
        'title': AppLocalizations.of(context, 'frequently_asked_questions') ?? 'الأسئلة الشائعة',
        'icon': Icons.question_answer,
        'color': Colors.blue,
      },
      {
        'title': AppLocalizations.of(context, 'user_guide') ?? 'دليل المستخدم',
        'icon': Icons.book,
        'color': Colors.green,
      },
      {
        'title': AppLocalizations.of(context, 'troubleshooting') ?? 'استكشاف الأخطاء',
        'icon': Icons.build,
        'color': Colors.orange,
      },
      {
        'title': AppLocalizations.of(context, 'report_issue') ?? 'الإبلاغ عن مشكلة',
        'icon': Icons.bug_report,
        'color': Colors.red,
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppLocalizations.of(context, 'quick_links') ?? 'روابط سريعة',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : Colors.black,
          ),
        ),
        const SizedBox(height: 16),

        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            childAspectRatio: 1.5,
          ),
          itemCount: quickLinks.length,
          itemBuilder: (context, index) {
            final link = quickLinks[index];
            return Material(
              borderRadius: BorderRadius.circular(16),
              color: isDark
                  ? Colors.grey.shade900.withOpacity(0.5)
                  : Colors.white.withOpacity(0.9),
              elevation: 2,
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  // يمكنك إضافة التنقل للصفحات المناسبة هنا
                  _showComingSoonDialog(context);
                },
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        link['icon'] as IconData,
                        color: link['color'] as Color,
                        size: 32,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        link['title'] as String,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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

  // معلومات فريق الدعم
  Widget _buildSupportTeamInfo(BuildContext context, bool isDark) {
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
          Text(
            AppLocalizations.of(context, 'support_team') ?? 'فريق الدعم',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black,
            ),
          ),
          const SizedBox(height: 16),

          // معلومات الاستجابة
          _buildInfoRow(
            icon: Icons.access_time,
            title: AppLocalizations.of(context, 'response_time') ?? 'وقت الاستجابة',
            value: AppLocalizations.of(context, 'within_24_hours') ?? 'خلال 24 ساعة',
            color: Colors.green,
            isDark: isDark,
          ),

          const SizedBox(height: 12),

          // الدعم الفني
          _buildInfoRow(
            icon: Icons.computer,
            title: AppLocalizations.of(context, 'technical_support') ?? 'الدعم الفني',
            value: 'Available',
            color: Colors.blue,
            isDark: isDark,
          ),

          const SizedBox(height: 12),

          // دعم الحساب
          _buildInfoRow(
            icon: Icons.person,
            title: AppLocalizations.of(context, 'account_support') ?? 'دعم الحساب',
            value: 'Available',
            color: Colors.purple,
            isDark: isDark,
          ),

          const SizedBox(height: 12),

          // دعم الفواتير
          _buildInfoRow(
            icon: Icons.receipt,
            title: AppLocalizations.of(context, 'billing_support') ?? 'دعم الفواتير',
            value: 'Available',
            color: Colors.orange,
            isDark: isDark,
          ),

          const SizedBox(height: 16),

          // ساعات العمل
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.blue.shade900.withOpacity(0.2)
                  : Colors.blue.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark
                    ? Colors.blue.shade800
                    : Colors.blue.shade200,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.schedule,
                  color: Colors.blueAccent,
                  size: 20,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocalizations.of(context, 'working_hours') ?? 'ساعات العمل',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppLocalizations.of(context, 'available_24_7') ?? 'متاح 24/7',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.grey.shade300 : Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow({
    required IconData icon,
    required String title,
    required String value,
    required Color color,
    required bool isDark,
  }) {
    return Row(
      children: [
        Icon(
          icon,
          color: color,
          size: 20,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Text(
            value,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }

  void _showComingSoonDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('قريباً'),
        content: const Text('هذه الميزة قيد التطوير وسوف تكون متاحة قريباً.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('حسناً'),
          ),
        ],
      ),
    );
  }
}