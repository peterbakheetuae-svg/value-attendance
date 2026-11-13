import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../services/app_controller.dart';
import '../../services/send_notification_api.dart';
import '../../widgets/app_background.dart';
import '../../theme/app_colors.dart';
import 'Send_Notifications_Page.dart';
import '../../widgets/glass_ui.dart';

class SentNotificationsPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;

  const SentNotificationsPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
  });

  @override
  State<SentNotificationsPage> createState() => _SentNotificationsPageState();
}

class _SentNotificationsPageState extends State<SentNotificationsPage> {
  List<Map<String, dynamic>> _sentNotifications = [];
  bool _isLoading = true;
  bool _hasError = false;
  String _errorMessage = '';
  int _totalCount = 0;

  @override
  void initState() {
    super.initState();
    _loadSentNotifications();
  }

  Future<void> _loadSentNotifications() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      final result = await NotificationApi.getSentNotifications(widget.uid);

      if (!mounted) return;

      if (result["success"] == true) {
        setState(() {
          _sentNotifications = List<Map<String, dynamic>>.from(result["notifications"] ?? []);
          _totalCount = result["count"] ?? _sentNotifications.length;
          _isLoading = false;
        });
      } else {
        setState(() {
          _hasError = true;
          _errorMessage = result["message"] ?? 'فشل في جلب الإشعارات المرسلة';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _hasError = true;
        _errorMessage = 'حدث خطأ في الاتصال: $e';
        _isLoading = false;
      });
    }
  }

  String _formatRecipient(String recipient) {
    final labels = {
      'CEO': 'أصحاب العمل',
      'Managers': 'المديرين',
      'Accountants': 'المحاسبين',
      'Employees': 'الموظفين',
      'الجميع': 'الجميع',
    };
    return labels[recipient] ?? recipient;
  }

  Color _getStatusColor(String status) {
    if (status.contains('تم الإرسال') || status.contains('ناجح')) {
      return Ar.green;
    } else if (status.contains('فشل')) {
      return Ar.red;
    } else {
      return Ar.amber;
    }
  }

  IconData _getStatusIcon(String status) {
    if (status.contains('تم الإرسال') || status.contains('ناجح')) {
      return Icons.check_circle_rounded;
    } else if (status.contains('فشل')) {
      return Icons.error_rounded;
    } else {
      return Icons.pending_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;
        final isRTL = appController.isRTL;

        final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
        final subduedTextColor = isDark
            ? AppColors.onSurfaceVariantDark
            : AppColors.onSurfaceVariantLight;
        final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;

        return AppBackground(
          child: Directionality(
            textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                child: Column(
                  children: [
                    // Header
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Row(
                        children: [
                          // زر الرجوع
                          GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: Glass.panel(isDark, r: 14),
                              child: Icon(
                                isRTL
                                    ? Icons.arrow_forward_ios_rounded
                                    : Icons.arrow_back_ios_rounded,
                                color: textColor,
                                size: 22,
                              ),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'الإشعارات المرسلة',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const Spacer(),
                          // زر إرسال جديد
                          GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => SendNotificationsPage(
                                    uid: widget.uid,
                                    name: widget.name,
                                    role: widget.role,
                                  ),
                                ),
                              );
                            },
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: Glass.panel(isDark, r: 14),
                              child: Icon(
                                Icons.add_rounded,
                                color: textColor,
                                size: 22,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 8),

                    // إحصائيات
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildStatCard(
                              title: 'إجمالي المرسلة',
                              count: _totalCount,
                              icon: Icons.send_rounded,
                              iconColor: Ar.info,
                              bgColor: isDark
                                  ? Ar.info.withOpacity(0.3)
                                  : Ar.info.shade50,
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildStatCard(
                              title: 'ناجحة',
                              count: _sentNotifications
                                  .where((n) =>
                              n['status']?.toString().contains('تم الإرسال') ?? false)
                                  .length,
                              icon: Icons.check_circle_rounded,
                              iconColor: Ar.green,
                              bgColor: isDark
                                  ? Ar.green.withOpacity(0.3)
                                  : Ar.green.shade50,
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _buildStatCard(
                              title: 'فاشلة',
                              count: _sentNotifications
                                  .where((n) =>
                              n['status']?.toString().contains('فشل') ?? false)
                                  .length,
                              icon: Icons.error_rounded,
                              iconColor: Ar.red,
                              bgColor: isDark
                                  ? Ar.red.withOpacity(0.3)
                                  : Ar.red.shade50,
                              isDark: isDark,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    Expanded(
                      child: _buildNotificationsList(isDark, isRTL),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildStatCard({
    required String title,
    required int count,
    required IconData icon,
    required Color iconColor,
    required Color bgColor,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: Glass.tile(isDark, r: 10),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Ar.grey.shade700,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            count.toString(),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: iconColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNotificationsList(bool isDark, bool isRTL) {
    final textColor = isDark ? Colors.white : Colors.black;
    final subduedTextColor = isDark ? Colors.white70 : Ar.grey.shade600;
    final cardColor = isDark ? Colors.white.withOpacity(0.15) : Colors.white;

    if (_isLoading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: isDark ? Colors.white : Ar.info,
            ),
            const SizedBox(height: 16),
            Text(
              'جاري تحميل الإشعارات...',
              style: TextStyle(
                color: subduedTextColor,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }

    if (_hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 64,
              color: Ar.red,
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage,
              style: TextStyle(
                fontSize: 16,
                color: Ar.red,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadSentNotifications,
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark ? Ar.info[800] : Ar.info,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      );
    }

    if (_sentNotifications.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.history_rounded,
              size: 64,
              color: subduedTextColor,
            ),
            const SizedBox(height: 16),
            Text(
              'لا توجد إشعارات مرسلة',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: subduedTextColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'سيظهر هنا الإشعارات التي قمت بإرسالها',
              style: TextStyle(
                fontSize: 14,
                color: subduedTextColor,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => SendNotificationsPage(
                      uid: widget.uid,
                      name: widget.name,
                      role: widget.role,
                    ),
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark ? Ar.info[800] : Ar.info,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add_rounded, size: 20),
                  SizedBox(width: 8),
                  Text('إرسال إشعار جديد'),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadSentNotifications,
      color: isDark ? Colors.white : Ar.info,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _sentNotifications.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final notification = _sentNotifications[index];
          return _buildNotificationCard(
            notification: notification,
            isDark: isDark,
            textColor: textColor,
            subduedTextColor: subduedTextColor,
            cardColor: cardColor,
          );
        },
      ),
    );
  }

  Widget _buildNotificationCard({
    required Map<String, dynamic> notification,
    required bool isDark,
    required Color textColor,
    required Color subduedTextColor,
    required Color cardColor,
  }) {
    final recipient = notification['recipient']?.toString() ?? 'غير معروف';
    final title = notification['title']?.toString() ?? 'بدون عنوان';
    final content = notification['content']?.toString() ?? 'بدون محتوى';
    final sender = notification['sender']?.toString() ?? 'غير معروف';
    final dateStr = notification['date']?.toString() ?? '';
    final status = notification['status']?.toString() ?? 'غير معروف';
    final details = notification['details']?.toString() ?? '';

    DateTime? date;
    try {
      if (dateStr.isNotEmpty) {
        date = DateFormat('dd/MM/yyyy').parse(dateStr);
      }
    } catch (_) {
      date = null;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: Glass.panel(isDark, r: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header مع الحالة
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: _getStatusColor(status).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: _getStatusColor(status).withOpacity(0.3),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      _getStatusIcon(status),
                      size: 16,
                      color: _getStatusColor(status),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      status,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _getStatusColor(status),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (date != null)
                Text(
                  DateFormat('yyyy-MM-dd').format(date),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: subduedTextColor,
                  ),
                ),
            ],
          ),

          const SizedBox(height: 12),

          // العنوان
          Text(
            title,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: textColor,
            ),
          ),

          const SizedBox(height: 12),

          Divider(
            color: isDark ? Colors.white.withOpacity(0.2) : Ar.grey.shade300,
            height: 1,
          ),

          const SizedBox(height: 12),

          // المحتوى
          Text(
            content,
            style: TextStyle(
              fontSize: 14,
              color: textColor,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),

          const SizedBox(height: 12),

          // تفاصيل الإرسال
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isDark
                  ? Ar.info.shade900.withOpacity(0.2)
                  : Ar.info.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isDark
                    ? Ar.info.shade700.withOpacity(0.3)
                    : Ar.info.shade200,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.person_rounded,
                      size: 16,
                      color: isDark ? Ar.info.shade300 : Ar.info.shade700,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'المستلم: ',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        _formatRecipient(recipient),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: isDark ? Ar.info.shade300 : Ar.info.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.person_outline_rounded,
                      size: 16,
                      color: isDark ? Ar.green.shade300 : Ar.green.shade700,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'المرسل: ',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        sender,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: isDark ? Ar.green.shade300 : Ar.green.shade800,
                        ),
                      ),
                    ),
                  ],
                ),
                if (details.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Icon(
                        Icons.info_rounded,
                        size: 16,
                        color: isDark ? Ar.amber.shade300 : Ar.amber.shade700,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          details,
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Ar.amber.shade200 : Ar.amber.shade800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}