import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../services/app_controller.dart';
import '../../services/notification_service.dart';
import '../../widgets/app_background.dart';
import '../../theme/app_colors.dart';
import 'Send_Notifications_Page.dart'; // 🔥 استيراد صفحة إرسال الإشعارات

class NotificationsPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;

  const NotificationsPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
  });

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class NotificationItem {
  final String id;
  final String title;
  final String body;
  final DateTime timestamp;
  final String type;
  final bool read;

  NotificationItem({
    required this.id,
    required this.title,
    required this.body,
    required this.timestamp,
    required this.type,
    this.read = false,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> json) {
    // 🔥 التحويل الآمن لحقل read باستخدام دالة المساعدة
    bool readStatus = false;
    final readValue = json['read'];

    if (readValue == null) {
      readStatus = false;
    } else if (readValue is bool) {
      readStatus = readValue;
    } else if (readValue is String) {
      final readStr = readValue.trim().toLowerCase();

      // معالجة جميع الحالات الممكنة
      const trueValues = ['true', '1', 'yes', 'y', 't', 'نعم', 'تم'];
      const falseValues = ['false', '0', 'no', 'n', 'f', 'لا', 'لم'];

      if (trueValues.contains(readStr)) {
        readStatus = true;
      } else if (falseValues.contains(readStr)) {
        readStatus = false;
      } else if (readStr.isEmpty) {
        readStatus = false;
      } else {
        // إذا كانت السلسلة غير فارغة وغير معروفة، نعتبرها false
        readStatus = false;
      }
    } else if (readValue is int) {
      readStatus = readValue != 0;
    } else if (readValue is num) {
      readStatus = readValue.toDouble() != 0.0;
    }

    // تحويل timestamp إلى DateTime
    DateTime parsedTimestamp;
    final ts = json['timestamp'];

    try {
      if (ts is String) {
        parsedTimestamp = DateTime.parse(ts);
      } else if (ts is Map && ts.containsKey('_seconds')) {
        parsedTimestamp = DateTime.fromMillisecondsSinceEpoch(ts['_seconds'] * 1000);
      } else if (json['createdAt'] != null) {
        final createdAt = json['createdAt'];
        if (createdAt is String) {
          parsedTimestamp = DateTime.parse(createdAt);
        } else if (createdAt is Map && createdAt.containsKey('_seconds')) {
          parsedTimestamp = DateTime.fromMillisecondsSinceEpoch(createdAt['_seconds'] * 1000);
        } else {
          parsedTimestamp = DateTime.now();
        }
      } else {
        parsedTimestamp = DateTime.now();
      }
    } catch (e) {
      print('⚠️ خطأ في تحويل التاريخ: $ts');
      parsedTimestamp = DateTime.now();
    }

    return NotificationItem(
      id: json['id']?.toString() ?? json['notificationId'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
      title: json['title']?.toString() ?? 'إشعار',
      body: json['body']?.toString() ?? json['message']?.toString() ?? '',
      timestamp: parsedTimestamp,
      type: json['type']?.toString() ?? 'general',
      read: readStatus,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'body': body,
      'timestamp': timestamp.toIso8601String(),
      'type': type,
      'read': read,
    };
  }

  String get timeAgo {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inMinutes < 1) {
      return 'الآن';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes} دقيقة';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} ساعة';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} يوم';
    } else if (difference.inDays < 30) {
      final weeks = (difference.inDays / 7).floor();
      return '$weeks أسبوع';
    } else {
      return DateFormat('dd/MM/yyyy').format(timestamp);
    }
  }

  Color get iconColor {
    switch (type) {
      case 'checkin':
        return Colors.green;
      case 'checkout':
        return Colors.blue;
      case 'break_start':
        return Colors.orange;
      case 'break_end':
        return Colors.purple;
      case 'leave_approved':
        return Colors.green;
      case 'leave_rejected':
        return Colors.red;
      case 'advance_approved':
        return Colors.green;
      case 'advance_rejected':
        return Colors.red;
      case 'checkin_reminder':
        return Colors.amber;
      case 'system':
        return Colors.deepPurple;
      case 'daily_reminder':
        return Colors.cyan;
      case 'broadcast':
        return Colors.indigo;
      default:
        return Colors.grey;
    }
  }

  IconData get icon {
    switch (type) {
      case 'checkin':
        return Icons.login;
      case 'checkout':
        return Icons.logout;
      case 'break_start':
        return Icons.coffee;
      case 'break_end':
        return Icons.work;
      case 'leave_approved':
      case 'advance_approved':
        return Icons.check_circle;
      case 'leave_rejected':
      case 'advance_rejected':
        return Icons.cancel;
      case 'checkin_reminder':
      case 'daily_reminder':
        return Icons.alarm;
      case 'system':
      case 'broadcast':
        return Icons.info;
      default:
        return Icons.notifications;
    }
  }
}

class _NotificationsPageState extends State<NotificationsPage> {
  List<NotificationItem> notifications = [];
  bool loading = true;
  bool hasError = false;
  String errorMessage = '';
  int totalCount = 0;
  int unreadCount = 0;
  int readCount = 0;

  final NotificationService _notificationService = NotificationService();

  @override
  void initState() {
    super.initState();
    _loadNotifications();
  }

  Future<void> _loadNotifications() async {
    if (!mounted) return;

    setState(() {
      loading = true;
      hasError = false;
      errorMessage = '';
    });

    try {
      print('📡 جلب الإشعارات للمستخدم: ${widget.uid}');

      // استخدام NotificationService لجلب الإشعارات
      final response = await _notificationService.getUserNotifications(widget.uid, limit: 50);

      if (!mounted) return;

      if (response['success'] == true) {
        final List<dynamic> notificationsData = response['notifications'] ?? [];

        setState(() {
          notifications = notificationsData.map((item) {
            return NotificationItem.fromJson(item);
          }).toList();

          totalCount = notifications.length;
          unreadCount = notifications.where((n) => !n.read).length;
          readCount = notifications.where((n) => n.read).length;
          loading = false;
        });

        // 🔥 تحديث حالة الإشعارات في AppController
        final appController = Provider.of<AppController>(context, listen: false);
        appController.updateNotificationStatus(unreadCount > 0, notifications.isNotEmpty);
        print('✅ تم تحديث AppController: unread=${unreadCount > 0}, any=${notifications.isNotEmpty}');

        print('✅ تم تحميل ${notifications.length} إشعار');
      } else {
        setState(() {
          hasError = true;
          errorMessage = response['message'] ?? 'فشل في جلب الإشعارات';
          loading = false;
        });

        print('❌ خطأ في جلب الإشعارات: $errorMessage');

      }
    } catch (e) {
      print('❌ خطأ غير متوقع: $e');

      if (!mounted) return;

      setState(() {
        hasError = true;
        errorMessage = 'حدث خطأ في الاتصال بالخادم: $e';
        loading = false;
      });
    }
  }

  Future<void> _markAsRead(String id) async {
    try {
      // استخدام NotificationService لتحديث حالة الإشعار
      final result = await _notificationService.markNotificationAsRead(id);

      if (result['success'] == true) {
        setState(() {
          notifications = notifications.map((notification) {
            if (notification.id == id) {
              return NotificationItem(
                id: notification.id,
                title: notification.title,
                body: notification.body,
                timestamp: notification.timestamp,
                type: notification.type,
                read: true,
              );
            }
            return notification;
          }).toList();

          unreadCount = notifications.where((n) => !n.read).length;
          readCount = notifications.where((n) => n.read).length;
        });

        _showSuccessSnackbar('تم تعليم الإشعار كمقروء');
      } else {
        _showErrorSnackbar(result['message'] ?? 'فشل في تحديث حالة الإشعار');
      }
    } catch (e) {
      print('❌ خطأ في تحديث حالة الإشعار: $e');
      _showErrorSnackbar('فشل في تحديث حالة الإشعار');
    }
  }

  Future<void> _markAllAsRead() async {
    try {
      // استخدام NotificationService لتعليم جميع الإشعارات كمقروءة
      final result = await _notificationService.markAllNotificationsAsRead(widget.uid);

      if (result['success'] == true) {
        setState(() {
          notifications = notifications.map((notification) {
            return NotificationItem(
              id: notification.id,
              title: notification.title,
              body: notification.body,
              timestamp: notification.timestamp,
              type: notification.type,
              read: true,
            );
          }).toList();

          unreadCount = 0;
          readCount = notifications.length;
        });

        _showSuccessSnackbar('تم تعليم جميع الإشعارات كمقروءة');
      } else {
        _showErrorSnackbar(result['message'] ?? 'فشل في تعليم جميع الإشعارات كمقروءة');
      }
    } catch (e) {
      print('❌ خطأ في تعليم جميع الإشعارات كمقروءة: $e');
      _showErrorSnackbar('فشل في تعليم جميع الإشعارات كمقروءة');
    }
  }

  Future<void> _deleteNotification(String id) async {
    try {
      // استخدام NotificationService لحذف الإشعار
      final result = await _notificationService.deleteNotification(id);

      if (result['success'] == true) {
        setState(() {
          notifications.removeWhere((notification) => notification.id == id);
          totalCount = notifications.length;
          unreadCount = notifications.where((n) => !n.read).length;
          readCount = notifications.where((n) => n.read).length;
        });

        _showSuccessSnackbar('تم حذف الإشعار');
      } else {
        _showErrorSnackbar(result['message'] ?? 'فشل في حذف الإشعار');
      }
    } catch (e) {
      print('❌ خطأ في حذف الإشعار: $e');
      _showErrorSnackbar('فشل في حذف الإشعار');
    }
  }

  Future<void> _clearAllNotifications() async {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: const Text('هل أنت متأكد من حذف جميع الإشعارات؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);

              try {
                // استخدام NotificationService لحذف جميع الإشعارات
                final result = await _notificationService.clearAllNotifications(widget.uid);

                if (result['success'] == true) {
                  setState(() {
                    notifications.clear();
                    totalCount = 0;
                    unreadCount = 0;
                    readCount = 0;
                  });

                  _showSuccessSnackbar('تم حذف جميع الإشعارات');
                } else {
                  _showErrorSnackbar(result['message'] ?? 'فشل في حذف جميع الإشعارات');
                }
              } catch (e) {
                print('❌ خطأ في حذف جميع الإشعارات: $e');
                _showErrorSnackbar('فشل في حذف جميع الإشعارات');
              }
            },
            child: const Text('حذف الكل', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showErrorSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  void _showSuccessSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  // 🔥 دالة للانتقال إلى صفحة إرسال الإشعارات
  void _navigateToSendNotifications() {
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

        return AppBackground(
          child: Directionality(
            textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                child: Column(
                  children: [
                    // Header بنفس تصميم leave_summary_page
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
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color: isDark
                                    ? Colors.white.withOpacity(0.15)
                                    : Colors.white.withOpacity(0.70),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.08),
                                    blurRadius: 14,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
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
                            'الإشعارات',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const Spacer(),
                          // أزرار الإجراءات
                          Row(
                            children: [
                              // 🔥 زر إرسال إشعار جديد
                              GestureDetector(
                                onTap: _navigateToSendNotifications,
                                child: Container(
                                  width: 46,
                                  height: 46,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    color: isDark
                                        ? Colors.white.withOpacity(0.15)
                                        : Colors.white.withOpacity(0.70),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.08),
                                        blurRadius: 14,
                                        offset: const Offset(0, 8),
                                      ),
                                    ],
                                  ),
                                  child: Icon(
                                    Icons.notification_add,
                                    color: isDark ? Colors.purple[300] : Colors.purple,
                                    size: 22,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),

                              if (notifications.isNotEmpty && unreadCount > 0)
                                GestureDetector(
                                  onTap: _markAllAsRead,
                                  child: Container(
                                    width: 46,
                                    height: 46,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(14),
                                      color: isDark
                                          ? Colors.white.withOpacity(0.15)
                                          : Colors.white.withOpacity(0.70),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.08),
                                          blurRadius: 14,
                                          offset: const Offset(0, 8),
                                        ),
                                      ],
                                    ),
                                    child: Icon(
                                      Icons.mark_email_read,
                                      color: isDark ? Colors.blue[300] : Colors.blue,
                                      size: 22,
                                    ),
                                  ),
                                ),
                              if (notifications.isNotEmpty && unreadCount > 0)
                                const SizedBox(width: 8),
                              if (notifications.isNotEmpty)
                                GestureDetector(
                                  onTap: _clearAllNotifications,
                                  child: Container(
                                    width: 46,
                                    height: 46,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(14),
                                      color: isDark
                                          ? Colors.white.withOpacity(0.15)
                                          : Colors.white.withOpacity(0.70),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.08),
                                          blurRadius: 14,
                                          offset: const Offset(0, 8),
                                        ),
                                      ],
                                    ),
                                    child: Icon(
                                      Icons.delete_sweep,
                                      color: isDark ? Colors.red[300] : Colors.red,
                                      size: 22,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 8),

                    // 4 مربعات إحصائية بنفس تصميم leave_summary_page
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          // إجمالي
                          Expanded(
                            child: _buildStatCard(
                              title: 'إجمالي',
                              count: totalCount,
                              icon: Icons.notifications,
                              iconColor: Colors.blue,
                              bgColor: isDark
                                  ? Colors.blue.withOpacity(0.3)
                                  : Colors.blue.shade50,
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(width: 8),

                          // غير مقروء
                          Expanded(
                            child: _buildStatCard(
                              title: 'غير مقروء',
                              count: unreadCount,
                              icon: Icons.mark_email_unread,
                              iconColor: Colors.red,
                              bgColor: isDark
                                  ? Colors.red.withOpacity(0.3)
                                  : Colors.red.shade50,
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(width: 8),

                          // مقروء
                          Expanded(
                            child: _buildStatCard(
                              title: 'مقروء',
                              count: readCount,
                              icon: Icons.mark_email_read,
                              iconColor: Colors.green,
                              bgColor: isDark
                                  ? Colors.green.withOpacity(0.3)
                                  : Colors.green.shade50,
                              isDark: isDark,
                            ),
                          ),
                          const SizedBox(width: 8),

                          // جديد (للإشعارات غير المقروءة)
                          Expanded(
                            child: _buildStatCard(
                              title: 'جديد',
                              count: unreadCount,
                              icon: Icons.new_releases,
                              iconColor: Colors.orange,
                              bgColor: isDark
                                  ? Colors.orange.withOpacity(0.3)
                                  : Colors.orange.shade50,
                              isDark: isDark,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // قائمة الإشعارات
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
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: isDark
                  ? Colors.white.withOpacity(0.1)
                  : Colors.white.withOpacity(0.7),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.grey.shade700,
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
    final subduedTextColor = isDark ? Colors.white70 : Colors.grey.shade600;
    final cardColor = isDark ? Colors.white.withOpacity(0.15) : Colors.white;
    final dividerColor =
    isDark ? Colors.white.withOpacity(0.2) : Colors.grey.shade300;

    if (loading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              color: isDark ? Colors.white : Colors.blue,
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

    if (hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 64,
              color: Colors.red,
            ),
            const SizedBox(height: 16),
            Text(
              errorMessage,
              style: TextStyle(
                fontSize: 16,
                color: Colors.red,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadNotifications,
              style: ElevatedButton.styleFrom(
                backgroundColor: isDark ? Colors.blue[800] : Colors.blue,
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

    if (notifications.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.notifications_off_rounded,
              size: 64,
              color: subduedTextColor,
            ),
            const SizedBox(height: 16),
            Text(
              'لا توجد إشعارات',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: subduedTextColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'سيظهر هنا الإشعارات الجديدة',
              style: TextStyle(
                fontSize: 14,
                color: subduedTextColor,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadNotifications,
      color: isDark ? Colors.white : Colors.blue,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: notifications.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final notification = notifications[index];
          return _buildNotificationCard(
            notification: notification,
            index: index,
            isDark: isDark,
            isRTL: isRTL,
            textColor: textColor,
            subduedTextColor: subduedTextColor,
            cardColor: cardColor,
            dividerColor: dividerColor,
          );
        },
      ),
    );
  }

  Widget _buildNotificationCard({
    required NotificationItem notification,
    required int index,
    required bool isDark,
    required bool isRTL,
    required Color textColor,
    required Color subduedTextColor,
    required Color cardColor,
    required Color dividerColor,
  }) {
    return Dismissible(
      key: Key(notification.id),
      direction: DismissDirection.horizontal,
      background: isRTL
          ? Container(
        color: Colors.transparent,
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(right: 20),
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withOpacity(0.5),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: const Icon(
              Icons.delete_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
      )
          : Container(
        color: Colors.transparent,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(left: 20),
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withOpacity(0.5),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: const Icon(
              Icons.delete_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
      ),
      secondaryBackground: isRTL
          ? Container(
        color: Colors.transparent,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.only(left: 20),
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withOpacity(0.5),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: const Icon(
              Icons.delete_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
      )
          : Container(
        color: Colors.transparent,
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(right: 20),
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.red,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withOpacity(0.5),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: const Icon(
              Icons.delete_rounded,
              color: Colors.white,
              size: 24,
            ),
          ),
        ),
      ),
      onDismissed: (direction) {
        _deleteNotification(notification.id);
      },
      child: GestureDetector(
        onTap: () {
          if (!notification.read) {
            _markAsRead(notification.id);
          }
        },
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
            border: Border.all(
              color:
              isDark ? Colors.white.withOpacity(0.1) : Colors.grey.shade200,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: notification.read
                          ? Colors.grey.withOpacity(0.1)
                          : Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: notification.read
                            ? Colors.grey.withOpacity(0.3)
                            : Colors.blue.withOpacity(0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          notification.read
                              ? Icons.mark_email_read
                              : Icons.mark_email_unread,
                          size: 16,
                          color: notification.read ? Colors.grey : Colors.blue,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          notification.read ? 'مقروء' : 'جديد',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: notification.read ? Colors.grey : Colors.blue,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    notification.timeAgo,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: textColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: notification.iconColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: notification.iconColor.withOpacity(0.3),
                        width: 1,
                      ),
                    ),
                    child: Icon(
                      notification.icon,
                      color: notification.iconColor,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      notification.title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Divider(
                color: dividerColor,
                height: 1,
              ),
              const SizedBox(height: 12),
              Text(
                notification.body,
                style: TextStyle(
                  fontSize: 14,
                  color: textColor,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    Icons.access_time_rounded,
                    size: 18,
                    color: subduedTextColor,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${notification.timeAgo} مضت',
                    style: TextStyle(
                      fontSize: 12,
                      color: subduedTextColor,
                    ),
                  ),
                  const Spacer(),
                  if (!notification.read)
                    ElevatedButton(
                      onPressed: () => _markAsRead(notification.id),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.withOpacity(0.1),
                        foregroundColor: Colors.green,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: Colors.green.withOpacity(0.3)),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.check, size: 16),
                          SizedBox(width: 4),
                          Text('تعليم كمقروء'),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}