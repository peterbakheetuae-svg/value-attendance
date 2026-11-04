import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/notification_service.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/glass_ui_widgets.dart';

// صفحة واحدة موحدة تجمع خصائص الصفحتين: NotificationSettingsPageteam و NotificationSettingsPage
class NotificationSettingsPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role; // من الصفحة الأولى

  const NotificationSettingsPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
  });

  @override
  State<NotificationSettingsPage> createState() => _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  final NotificationService _notificationService = NotificationService();

  // حالات التحميل
  bool _loading = true;
  bool _reactivating = false;
  bool _checkingStatus = false; // من الصفحة الثانية
  bool _sendingToken = false;   // من الصفحة الثانية

  // بيانات الحالة (موحدة)
  Map<String, dynamic> _status = {};

  // إعدادات الإشعارات (من الأولى)
  Map<String, bool> _settings = {
    'pushEnabled': true,
    'soundEnabled': true,
    'vibrationEnabled': true,
  };

  // رسالة مؤقتة (من الثانية)
  String _message = '';

  @override
  void initState() {
    super.initState();
    _loadStatus();
    _loadSettings();
  }

  // تحميل الحالة الشاملة (مدمجة من الأولى والثانية)
  Future<void> _loadStatus() async {
    setState(() => _loading = true);
    try {
      final status = await _notificationService.checkNotificationStatus(widget.uid);
      if (status['success'] == true) {
        setState(() {
          _status = status;
        });
      } else {
        _showMessage(status['error'] ?? 'فشل تحميل الحالة', isError: true);
      }
    } catch (e) {
      _showMessage('خطأ في تحميل الحالة: $e', isError: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  // تحميل الإعدادات المحلية
  Future<void> _loadSettings() async {
    final settings = await _notificationService.getNotificationSettings();
    setState(() {
      _settings = settings;
    });
  }

  // إعادة تفعيل الإشعارات (من الأولى)
  Future<void> _reactivateNotifications() async {
    setState(() => _reactivating = true);
    try {
      final result = await _notificationService.reactivateNotifications(widget.uid);
      if (result['success'] == true) {
        _showMessage('✅ تم إعادة تفعيل الإشعارات بنجاح');
        await _loadStatus(); // تحديث الحالة
      } else {
        _showMessage('❌ فشل إعادة التفعيل: ${result['message']}', isError: true);
      }
    } catch (e) {
      _showMessage('❌ خطأ: $e', isError: true);
    } finally {
      setState(() => _reactivating = false);
    }
  }

  // إعادة فحص الحالة يدوياً (من الثانية)
  Future<void> _checkNotificationStatus() async {
    setState(() {
      _checkingStatus = true;
      _message = '';
    });
    try {
      await _loadStatus(); // نستخدم نفس دالة التحميل
      _showMessage('✅ تم تحديث الحالة');
    } catch (e) {
      _showMessage('❌ فشل التحديث: $e', isError: true);
    } finally {
      setState(() => _checkingStatus = false);
    }
  }

  // إرسال التوكن يدوياً (من الثانية)
  Future<void> _sendTokenManually() async {
    setState(() {
      _sendingToken = true;
      _message = '';
    });
    try {
      final token = await _notificationService.getDeviceToken();
      if (token == null) {
        _showMessage('لم يتم الحصول على توكن. تأكد من تفعيل الإشعارات في إعدادات الهاتف.', isError: true);
        return;
      }
      final result = await _notificationService.sendTokenToServer(widget.uid, token);
      if (result['success'] == true) {
        _showMessage(result['message'] ?? 'تم إرسال التوكن بنجاح');
        await _loadStatus(); // تحديث الحالة
      } else {
        _showMessage(result['message'] ?? 'فشل الإرسال', isError: true);
      }
    } catch (e) {
      _showMessage('خطأ في الإرسال: $e', isError: true);
    } finally {
      setState(() => _sendingToken = false);
    }
  }

  // مسح الإشعارات المحلية (من الأولى)
  Future<void> _clearLocalNotifications() async {
    await _notificationService.cancelAllLocalNotifications();
    _showMessage('🗑️ تم مسح جميع الإشعارات المحلية');
  }

  // تحديث إعداد معين
  Future<void> _updateSetting(String key, bool value) async {
    setState(() {
      _settings[key] = value;
    });
    await _notificationService.updateNotificationSettings(
      pushEnabled: _settings['pushEnabled'],
      soundEnabled: _settings['soundEnabled'],
      vibrationEnabled: _settings['vibrationEnabled'],
    );
  }

  // عرض رسالة مؤقتة
  void _showMessage(String msg, {bool isError = false}) {
    setState(() {
      _message = msg;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;
    final isRTL = appController.isRTL;

    return AppBackground(
      child: Directionality(
        textDirection: isRTL ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: Text(
              AppLocalizations.of(context, 'notification_settings') ?? 'إعدادات الإشعارات',
              style: TextStyle(color: isDark ? Colors.white : Colors.black),
            ),
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: Icon(
                isRTL ? Icons.arrow_forward : Icons.arrow_back,
                color: isDark ? Colors.white : Colors.black,
              ),
              onPressed: () => Navigator.pop(context),
            ),
          ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ---------- بطاقة الحالة (مطورة من الأولى مع تفاصيل إضافية) ----------
                GlassCard(
                  radius: 16,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocalizations.of(context, 'notification_status') ?? 'حالة الإشعارات',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                      const SizedBox(height: 16),
                      _buildStatusRow(
                        '🔑',
                        AppLocalizations.of(context, 'fcm_token') ?? 'FCM Token',
                        _status['hasToken'] == true ? '✅ موجود' : '❌ غير موجود',
                        _status['hasToken'] == true ? Colors.green : Colors.red,
                      ),
                      _buildStatusRow(
                        '📤',
                        AppLocalizations.of(context, 'token_sent_to_server') ?? 'تم إرسال التوكن للخادم',
                        _status['tokenSentToServer'] == true ? '✅ نعم' : '❌ لا',
                        _status['tokenSentToServer'] == true ? Colors.green : Colors.red,
                      ),
                      _buildStatusRow(
                        '👤',
                        AppLocalizations.of(context, 'sent_for_current_user') ?? 'مرسل للمستخدم الحالي',
                        _status['tokenSentForCurrentUser'] == true ? '✅ نعم' : '❌ لا',
                        _status['tokenSentForCurrentUser'] == true ? Colors.green : Colors.red,
                      ),
                      _buildStatusRow(
                        '🔔',
                        AppLocalizations.of(context, 'notifications_enabled') ?? 'الإشعارات مفعلة',
                        _status['notificationsEnabled'] == true ? '✅ نعم' : '❌ لا',
                        _status['notificationsEnabled'] == true ? Colors.green : Colors.red,
                      ),
                      if (_status['tokenPreview'] != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          '${AppLocalizations.of(context, 'token_preview') ?? 'التوكن'}: ${_status['tokenPreview']}',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white70 : Colors.grey[700],
                          ),
                        ),
                      ],
                      // رسالة الحالة من الثانية (إذا وجدت)
                      if (_status['message'] != null && _status['message'].toString().isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            _status['message'],
                            style: TextStyle(
                              fontSize: 13,
                              color: _status['message']!.contains('✅') ? Colors.green : Colors.orange,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // ---------- التوصيات (من الأولى) ----------
                if (_status['recommendations'] != null && (_status['recommendations'] as List).isNotEmpty)
                  GlassCard(
                    radius: 16,
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocalizations.of(context, 'recommendations') ?? 'التوصيات',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                        ),
                        const SizedBox(height: 12),
                        ...(_status['recommendations'] as List).map((rec) {
                          final isSuccess = rec.startsWith('✅');
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(isSuccess ? '✅' : '💡', style: const TextStyle(fontSize: 16)),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    rec,
                                    style: TextStyle(
                                      color: isSuccess
                                          ? Colors.green
                                          : (isDark ? Colors.white70 : Colors.black87),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      ],
                    ),
                  ),

                const SizedBox(height: 20),

                // ---------- إعدادات الإشعارات (من الأولى) ----------
                GlassCard(
                  radius: 16,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocalizations.of(context, 'settings') ?? 'الإعدادات',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile(
                        title: Text(
                          AppLocalizations.of(context, 'push_notifications') ?? 'الإشعارات الفورية',
                          style: TextStyle(color: isDark ? Colors.white : Colors.black),
                        ),
                        value: _settings['pushEnabled'] ?? true,
                        onChanged: (val) => _updateSetting('pushEnabled', val),
                        activeColor: AppColors.primary,
                      ),
                      SwitchListTile(
                        title: Text(
                          AppLocalizations.of(context, 'notification_sound') ?? 'الصوت',
                          style: TextStyle(color: isDark ? Colors.white : Colors.black),
                        ),
                        value: _settings['soundEnabled'] ?? true,
                        onChanged: (val) => _updateSetting('soundEnabled', val),
                        activeColor: AppColors.primary,
                      ),
                      SwitchListTile(
                        title: Text(
                          AppLocalizations.of(context, 'notification_vibration') ?? 'الاهتزاز',
                          style: TextStyle(color: isDark ? Colors.white : Colors.black),
                        ),
                        value: _settings['vibrationEnabled'] ?? true,
                        onChanged: (val) => _updateSetting('vibrationEnabled', val),
                        activeColor: AppColors.primary,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // ---------- أزرار الإجراءات (مدمجة من الصفحتين) ----------
                GlassCard(
                  radius: 16,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocalizations.of(context, 'actions') ?? 'الإجراءات',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                      const SizedBox(height: 16),
                      // إعادة تفعيل الإشعارات (من الأولى)
                      PrimaryButton(
                        label: _reactivating
                            ? (AppLocalizations.of(context, 'reactivating') ?? 'جاري إعادة التفعيل...')
                            : (AppLocalizations.of(context, 'reactivate_notifications') ?? 'إعادة تفعيل الإشعارات'),
                        color: AppColors.primary,
                        loading: _reactivating,
                        onTap: _reactivateNotifications,
                      ),
                      const SizedBox(height: 12),
                      // إعادة فحص الحالة (من الثانية)
                      PrimaryButton(
                        label: _checkingStatus
                            ? (AppLocalizations.of(context, 'checking') ?? 'جاري الفحص...')
                            : (AppLocalizations.of(context, 'recheck_status') ?? 'إعادة فحص الحالة'),
                        color: Colors.blue,
                        loading: _checkingStatus,
                        onTap: _checkNotificationStatus,
                      ),
                      const SizedBox(height: 12),
                      // إرسال التوكن يدوياً (من الثانية)
                      PrimaryButton(
                        label: _sendingToken
                            ? (AppLocalizations.of(context, 'sending') ?? 'جاري الإرسال...')
                            : (AppLocalizations.of(context, 'send_token_manually') ?? 'إرسال التوكن يدوياً'),
                        color: Colors.orange,
                        loading: _sendingToken,
                        onTap: _sendTokenManually,
                      ),
                      const SizedBox(height: 12),
                      // مسح الإشعارات المحلية (من الأولى)
                      Center(
                        child: TextButton(
                          onPressed: _clearLocalNotifications,
                          child: Text(
                            AppLocalizations.of(context, 'clear_local_notifications') ?? 'مسح الإشعارات المحلية',
                            style: TextStyle(color: isDark ? Colors.white70 : Colors.grey[700]),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // ---------- نصائح ومعلومات المستخدم (من الثانية) ----------
                GlassCard(
                  radius: 16,
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocalizations.of(context, 'tips_and_info') ?? 'نصائح ومعلومات',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                      const SizedBox(height: 16),
                      // معلومات المستخدم
                      Row(
                        children: [
                          Icon(Icons.person, color: AppColors.primary, size: 24),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  widget.name,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: isDark ? Colors.white : Colors.black,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'ID: ${widget.uid}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark ? Colors.white70 : Colors.grey[600],
                                  ),
                                ),
                                if (widget.role.isNotEmpty)
                                  Text(
                                    '${AppLocalizations.of(context, 'role') ?? 'الدور'}: ${widget.role}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark ? Colors.white70 : Colors.grey[600],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // نصائح
                      _buildTipItem(
                        icon: Icons.settings,
                        title: AppLocalizations.of(context, 'tip_enable_in_settings') ?? 'تفعيل الإشعارات في إعدادات الهاتف',
                        description: AppLocalizations.of(context, 'tip_enable_in_settings_desc') ?? 'تأكد من تفعيل الإشعارات للتطبيق في إعدادات الهاتف',
                        isDark: isDark,
                      ),
                      const SizedBox(height: 8),
                      _buildTipItem(
                        icon: Icons.wifi,
                        title: AppLocalizations.of(context, 'tip_internet') ?? 'الاتصال بالإنترنت',
                        description: AppLocalizations.of(context, 'tip_internet_desc') ?? 'تأكد من اتصال الهاتف بالإنترنت عند إرسال التوكن',
                        isDark: isDark,
                      ),
                      const SizedBox(height: 8),
                      _buildTipItem(
                        icon: Icons.update,
                        title: AppLocalizations.of(context, 'tip_update') ?? 'تحديث التطبيق',
                        description: AppLocalizations.of(context, 'tip_update_desc') ?? 'تأكد من أنك تستخدم آخر نسخة من التطبيق',
                        isDark: isDark,
                      ),
                      const SizedBox(height: 8),
                      _buildTipItem(
                        icon: Icons.restart_alt,
                        title: AppLocalizations.of(context, 'tip_restart') ?? 'إعادة تشغيل التطبيق',
                        description: AppLocalizations.of(context, 'tip_restart_desc') ?? 'حاول إعادة تشغيل التطبيق إذا استمرت المشكلة',
                        isDark: isDark,
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

  // دالة مساعدة لعرض صف الحالة
  Widget _buildStatusRow(String icon, String label, String value, Color valueColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 18)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).brightness == Brightness.dark ? Colors.white70 : Colors.black87,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }

  // دالة مساعدة لعرض نصيحة
  Widget _buildTipItem({
    required IconData icon,
    required String title,
    required String description,
    required bool isDark,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: AppColors.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontWeight: FontWeight.w500,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? Colors.white70 : Colors.grey[700],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}