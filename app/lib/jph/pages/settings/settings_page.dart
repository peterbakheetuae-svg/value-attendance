import 'package:flutter/material.dart';
import '../../services/session_service.dart';
import '../../services/api_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../pages/employees/employees_page.dart';
import '../../services/app_controller.dart';
import '../../services/update_service.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/app_background.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/glass_bottom_nav.dart';
import '../../widgets/settings/settings_tile.dart';
import '../../widgets/settings/settings_expandable_tile.dart';
import '../../widgets/settings/change_password_form.dart';
import '../../widgets/settings/language_picker.dart';

import '../dashboard_employers/dashboard_page.dart';
import '../profile/profile_page.dart';
import '../id_card_page.dart';
import '../login/login_page.dart';
import '../attendance/attendance_report_page.dart';
import 'privacy_policy_page.dart';
import 'support_policy_page.dart';
import 'terms_page.dart';
import '../leave_summary.dart';
import '../advance_request_page.dart';
import '../notifications/notification_settings.dart'; // إضافة
import '../public_holidays_page.dart'; // إضافة
import '../multi_company/company_info_page.dart';
import '../multi_company/branches_page.dart';
import '../multi_company/kpi_page.dart';
import '../multi_company/work_locations_page.dart';
import '../multi_company/advances_page.dart';
import '../multi_company/reports_page.dart';
import '../multi_company/platform_dashboard_page.dart';
import '../../widgets/company_selector_sheet.dart';

class SettingsPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;

  const SettingsPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool expandPassword = false;
  bool expandLanguage = false;
  bool _isCheckingUpdate = false;
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    _initPackageInfo();
  }

  Future<void> _initPackageInfo() async {
    final packageInfo = await PackageInfo.fromPlatform();
    setState(() {
      _packageInfo = packageInfo;
    });
  }

  Future<void> _checkForUpdates() async {
    if (_isCheckingUpdate) return;

    setState(() {
      _isCheckingUpdate = true;
    });

    try {
      final result = await UpdateService.checkForUpdate();

      if (!mounted) return;

      if (result['success'] == true) {
        if (result['update_available'] == true) {
          UpdateDialog.show(
            context: context,
            updateInfo: result,
            onUpdate: () {
              UpdateService.downloadAndInstallWithProgress(
                result['latest_version']['update_url'] ?? '',
                context,
                result,
              );
            },
            onLater: () {
              Navigator.of(context).pop();
            },
            forceUpdate: result['force_update'] == true,
          );
        } else {
          _showNoUpdateDialog();
        }
      } else {
        _showUpdateCheckFailedDialog();
      }
    } catch (e) {
      if (mounted) {
        _showUpdateCheckErrorDialog(e.toString());
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCheckingUpdate = false;
        });
      }
    }
  }

  void onBottomNavTap(int index) {
    if (index == 3) return; // نحن بالفعل في صفحة الملف الشخصي

    final page = switch (index) {
      0 => DashboardPage(uid: widget.uid, name: widget.name, role: widget.role),
      1 => AttendanceReportPage(uid: widget.uid, name: widget.name, role: widget.role),
      2 => EmployeesPage(currentUserId: widget.uid, currentUserName: widget.name, currentUserRole: widget.role,),
      4 => ProfilePage(uid: widget.uid, name: widget.name, role: widget.role),
      _ => null,
    };

    if (page != null) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => page),
      );
    }
  }
  void _showNoUpdateDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context, 'check_for_updates') ?? 'التحقق من التحديثات'),
        content: Text(AppLocalizations.of(context, 'app_up_to_date') ?? 'أنت تستخدم أحدث إصدار من التطبيق'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context, 'ok') ?? 'موافق'),
          ),
        ],
      ),
    );
  }

  void _showUpdateCheckFailedDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context, 'check_for_updates') ?? 'التحقق من التحديثات'),
        content: Text(AppLocalizations.of(context, 'update_check_failed') ?? 'فشل التحقق من التحديثات'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context, 'ok') ?? 'موافق'),
          ),
        ],
      ),
    );
  }

  void _showUpdateCheckErrorDialog(String error) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(AppLocalizations.of(context, 'check_for_updates') ?? 'التحقق من التحديثات'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(AppLocalizations.of(context, 'update_check_error') ?? 'حدث خطأ أثناء التحقق من التحديثات'),
            const SizedBox(height: 8),
            Text(
              error,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppLocalizations.of(context, 'ok') ?? 'موافق'),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    final appController = Provider.of<AppController>(context, listen: false);
    final isDark = appController.isDark;
    final isRTL = appController.isRTL;

    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Directionality(
          textDirection: isRTL ? TextDirection.rtl : TextDirection.ltr,
          child: Container(
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.black.withOpacity(0.2)
                  : Colors.white.withOpacity(0.8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark
                    ? Colors.white.withOpacity(0.1)
                    : Colors.black.withOpacity(0.1),
              ),
              boxShadow: [
                BoxShadow(
                  color: isDark
                      ? Colors.black.withOpacity(0.3)
                      : Colors.grey.withOpacity(0.2),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.logout,
                      color: isDark ? Colors.orangeAccent : Colors.orange,
                      size: 60,
                    ),
                    const SizedBox(height: 20),

                    Text(
                      AppLocalizations.of(context, 'confirm_logout') ?? 'تأكيد الخروج',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                    ),

                    const SizedBox(height: 16),

                    Text(
                      AppLocalizations.of(context, 'logout_confirmation_message') ??
                          'هل أنت متأكد من تسجيل الخروج؟',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
                      ),
                    ),

                    const SizedBox(height: 24),

                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () => Navigator.pop(context),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: isDark ? Colors.grey.shade600 : Colors.grey.shade300,
                                ),
                              ),
                            ),
                            child: Text(
                              AppLocalizations.of(context, 'cancel') ?? 'إلغاء',
                              style: TextStyle(
                                fontSize: 16,
                                color: isDark ? Colors.grey.shade300 : Colors.grey.shade700,
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(width: 12),

                        Expanded(
                          child: ElevatedButton(
                            onPressed: () async {
                              Navigator.pop(context);

                              await ApiService.signOut();
                              await SessionService.logout();

                              if (!mounted) return;

                              Navigator.of(context).pushAndRemoveUntil(
                                MaterialPageRoute(builder: (_) => const LoginPage()),
                                    (route) => false,
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              elevation: 0,
                            ),
                            child: Text(
                              AppLocalizations.of(context, 'logout') ?? 'تسجيل خروج',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        return AppBackground(
          child: Directionality(
            textDirection: appController.isRTL ? TextDirection.rtl : TextDirection.ltr,
            child: Scaffold(
              extendBody: true,
              backgroundColor: Colors.transparent,
              bottomNavigationBar: GlassBottomNav(
                currentIndex: 3, // ✅ هذا الفهرس يعتمد على موقع الإعدادات في القائمة
                onTap: (index) {
                  switch (index) {
                    case 0:
                    // ✅ الرئيسية
                      Navigator.pushReplacement(
                        context,
                        MaterialPageRoute(
                          builder: (_) => DashboardPage(
                            uid: widget.uid,
                            name: widget.name,
                            role: widget.role,
                          ),
                        ),
                      );
                      break;
                    case 1:
                    // ✅ تقارير الحضور
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => AttendanceReportPage(
                            uid: widget.uid,
                            name: widget.name,
                            role: widget.role,
                          ),
                        ),
                      );
                      break;
                    case 2:
                    // ✅ الموظفين (الجديد)
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => EmployeesPage(
                            currentUserId: widget.uid,
                            currentUserName: widget.name,
                            currentUserRole: widget.role,
                          ),
                        ),
                      );
                      break;
                    case 3:
                    // ✅ الإعدادات (الصفحة الحالية)
                    // نحن بالفعل في هذه الصفحة
                      break;
                    case 4:
                    // ✅ الملف الشخصي
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ProfilePage(
                            uid: widget.uid,
                            name: widget.name,
                            role: widget.role,
                          ),
                        ),
                      );
                      break;
                  }
                },
              ),
              body: SafeArea(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 110),
                  children: [
                    Text(
                      AppLocalizations.of(context, 'settings') ?? 'الإعدادات',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 20),

                    SettingsTile(
                      title: AppLocalizations.of(context, 'attendance') ?? 'تقرير الحضور',
                      icon: Icons.receipt_long,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AttendanceReportPage(
                              uid: widget.uid,
                              name: widget.name,
                              role: widget.role,
                            ),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 14),

                    SettingsTile(
                      title: AppLocalizations.of(context, 'leave_requests') ?? 'طلبات الإجازة',
                      icon: Icons.beach_access,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => LeaveSummaryPage(
                              uid: widget.uid,
                              name: widget.name,
                              role: widget.role,
                            ),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 14),

                    SettingsTile(
                      title: AppLocalizations.of(context, 'finance') ?? 'المالية',
                      icon: Icons.account_balance_wallet,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AdvanceRequestPage(
                              uid: widget.uid,
                              name: widget.name,
                              role: widget.role,
                            ),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 14),

                    // إضافة العطلات الرسمية هنا - قبل تغيير كلمة المرور
                    SettingsTile(
                      title: AppLocalizations.of(context, 'public_holidays') ?? 'العطلات الرسمية',
                      icon: Icons.event_note,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PublicHolidaysPage(
                              uid: widget.uid,
                              name: widget.name,
                              role: widget.role,
                            ),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 14),

                    // ─── Multi-Company Management section ───
                    // Company selector (only visible when user has >1 membership)
                    if (appController.availableCompanies.length > 1) ...[
                      SettingsTile(
                        title: AppLocalizations.of(context, 'switch_company'),
                        icon: Icons.swap_horiz,
                        onTap: () => CompanySelectorSheet.show(context),
                      ),
                      const SizedBox(height: 14),
                    ],

                    // Company Info
                    SettingsTile(
                      title: AppLocalizations.of(context, 'company_info'),
                      icon: Icons.business,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const CompanyInfoPage(),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 14),

                    // Branches
                    SettingsTile(
                      title: AppLocalizations.of(context, 'branches'),
                      icon: Icons.account_tree,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const BranchesPage(),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 14),

                    // KPI
                    SettingsTile(
                      title: AppLocalizations.of(context, 'kpi_definitions'),
                      icon: Icons.insights,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const KpiPage(),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 14),

                    // Work Locations (Geofence)
                    SettingsTile(
                      title: AppLocalizations.of(context, 'work_locations'),
                      icon: Icons.location_on,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const WorkLocationsPage(),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 14),

                    // Advances
                    SettingsTile(
                      title: AppLocalizations.of(context, 'advances'),
                      icon: Icons.savings,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const AdvancesPage(),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 14),

                    // Reports
                    SettingsTile(
                      title: AppLocalizations.of(context, 'reports'),
                      icon: Icons.assessment,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const ReportsPage(),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 14),

                    // Platform Dashboard (only for Platform Owners)
                    if (appController.isPlatformOwner) ...[
                      SettingsTile(
                        title: AppLocalizations.of(context, 'platform_dashboard'),
                        icon: Icons.admin_panel_settings,
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const PlatformDashboardPage(),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 14),
                    ],

                    // ─── End Multi-Company Management section ───

                    // تغيير كلمة المرور - بدون مربع خلفي
                    SettingsExpandableTile(
                      title: AppLocalizations.of(context, 'change_password') ?? 'تغيير كلمة المرور',
                      icon: Icons.key,
                      expanded: expandPassword,
                      onToggle: () => setState(() => expandPassword = !expandPassword),
                      child: Container(
                        // إزالة أي خلفية أو حدود
                        color: Colors.transparent,
                        child: ChangePasswordForm(uid: widget.uid),
                      ),
                    ),

                    const SizedBox(height: 14),

                    // تغيير اللغة - بدون إعادة التوجيه
                    SettingsExpandableTile(
                      title: AppLocalizations.of(context, 'language') ?? 'اللغة',
                      icon: Icons.translate,
                      expanded: expandLanguage,
                      onToggle: () => setState(() => expandLanguage = !expandLanguage),
                      child: _buildLanguagePicker(appController),
                    ),

                    const SizedBox(height: 14),

                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.grey.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              appController.isDark
                                  ? Icons.nightlight_round
                                  : Icons.wb_sunny,
                              color: appController.isDark
                                  ? Colors.yellow[700]
                                  : Colors.orange[700],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  AppLocalizations.of(context, 'dark_mode') ?? 'الوضع الداكن',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                    color: appController.isDark
                                        ? Colors.white
                                        : Colors.black,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  appController.isDark
                                      ? AppLocalizations.of(context, 'dark_mode_active') ?? 'الوضع المظلم مفعل'
                                      : AppLocalizations.of(context, 'light_mode_active') ?? 'الوضع الفاتح مفعل',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: appController.isDark,
                            onChanged: (value) {
                              appController.setThemeMode(
                                  value
                                      ? ThemeMode.dark
                                      : ThemeMode.light
                              );
                            },
                            activeColor: Theme.of(context).primaryColor,
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    // إضافة إعدادات الإشعارات هنا - قبل الخصوصية
                    SettingsTile(
                      title: AppLocalizations.of(context, 'notification_settings') ?? 'إعدادات الإشعارات',
                      icon: Icons.notifications_active,
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => NotificationSettingsPage(
                              uid: widget.uid,
                              name: widget.name,
                              role: widget.role,

                            ),
                          ),
                        );
                      },
                    ),

                    const SizedBox(height: 14),

                    SettingsTile(
                      title: AppLocalizations.of(context, 'privacy') ?? 'سياسة الخصوصية',
                      icon: Icons.policy,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const PrivacyPolicyPage()),
                      ),
                    ),

                    const SizedBox(height: 14),

                    SettingsTile(
                      title: AppLocalizations.of(context, 'support') ?? 'الدعم',
                      icon: Icons.headset_mic,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SupportPolicyPage()),
                      ),
                    ),

                    const SizedBox(height: 14),

                    SettingsTile(
                      title: AppLocalizations.of(context, 'terms') ?? 'الشروط والأحكام',
                      icon: Icons.article,
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const TermsPage()),
                      ),
                    ),

                    const SizedBox(height: 14),

                    Container(
                      margin: const EdgeInsets.symmetric(vertical: 7),
                      child: ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.grey.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            Icons.system_update,
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                        title: Text(
                          AppLocalizations.of(context, 'check_for_updates') ?? 'التحقق من التحديثات',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        trailing: _isCheckingUpdate
                            ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                            : Icon(
                          Icons.arrow_forward_ios,
                          size: 16,
                          color: Colors.grey[600],
                        ),
                        onTap: _isCheckingUpdate ? null : _checkForUpdates,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        tileColor: Colors.white.withOpacity(0.1),
                      ),
                    ),

                    const SizedBox(height: 20),

                    PrimaryButton(
                      label: AppLocalizations.of(context, 'logout') ?? 'تسجيل خروج',
                      color: Colors.redAccent,
                      onTap: _logout,
                    ),

                    const SizedBox(height: 20),

                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.grey.withOpacity(0.2),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (_packageInfo != null) ...[
                            Text(
                              _packageInfo!.appName,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '${AppLocalizations.of(context, 'version') ?? 'الإصدار'}: ${_packageInfo!.version}',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                          ] else ...[
                            Container(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: const Center(
                                child: SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(height: 8),
                          Text(
                            'JPH © ${DateTime.now().year}',
                            style: TextStyle(
                              fontSize: 10,
                              color: Colors.grey[500],
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
      },
    );
  }

  Widget _buildLanguagePicker(AppController appController) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          // اللغة العربية
          _buildLanguageOption(
            context: context,
            appController: appController,
            languageCode: 'ar',
            flag: '🇸🇦',
            languageName: AppLocalizations.of(context, 'arabic') ?? 'العربية',
            isCurrent: appController.languageCode == 'ar',
          ),
          const SizedBox(height: 12),

          // اللغة الإنجليزية
          _buildLanguageOption(
            context: context,
            appController: appController,
            languageCode: 'en',
            flag: '🇺🇸',
            languageName: AppLocalizations.of(context, 'english') ?? 'English',
            isCurrent: appController.languageCode == 'en',
          ),
          const SizedBox(height: 12),

          // اللغة الأردية
          _buildLanguageOption(
            context: context,
            appController: appController,
            languageCode: 'ur',
            flag: '🇵🇰',
            languageName: 'اردو',
            isCurrent: appController.languageCode == 'ur',
          ),
          const SizedBox(height: 12),

          // اللغة الهندية
          _buildLanguageOption(
            context: context,
            appController: appController,
            languageCode: 'hi',
            flag: '🇮🇳',
            languageName: 'हिन्दी',
            isCurrent: appController.languageCode == 'hi',
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageOption({
    required BuildContext context,
    required AppController appController,
    required String languageCode,
    required String flag,
    required String languageName,
    required bool isCurrent,
  }) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          appController.setLanguage(languageCode);
          setState(() {
            expandLanguage = false;
          });
        },
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isCurrent
                ? Theme.of(context).primaryColor.withOpacity(0.1)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isCurrent
                  ? Theme.of(context).primaryColor
                  : Colors.grey.withOpacity(0.2),
              width: isCurrent ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              // العلم
              Text(
                flag,
                style: const TextStyle(fontSize: 22),
              ),
              const SizedBox(width: 12),

              // اسم اللغة
              Expanded(
                child: Text(
                  languageName,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
                    color: appController.isDark ? Colors.white : Colors.black,
                  ),
                ),
              ),

              // علامة التحديد
              if (isCurrent)
                Icon(
                  Icons.check_circle,
                  color: Color(0xFF4CAF50), // كود اللون الأخضر HEX
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }
}