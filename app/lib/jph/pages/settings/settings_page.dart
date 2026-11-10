import 'package:flutter/material.dart';
import '../../../core/app_updater.dart';
import '../cash/cashbox_hub_page.dart';
import '../../forms/custody_receipt_page.dart';
import '../sales/sales_page.dart';
import '../cash/cash_page.dart';
import '../commissions/commissions_page.dart';
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
import '../public_holidays_page.dart'; // إضافة
import '../multi_company/company_info_page.dart';
import '../multi_company/positions_page.dart';
import 'late_rules_page.dart';
import '../multi_company/kpi_page.dart';
import '../multi_company/platform_dashboard_page.dart';
import '../../widgets/app_nav.dart';
import '../../widgets/company_selector_sheet.dart';
import '../../widgets/glass_dialog.dart';
import '../custody/custody_assets_page.dart';
import '../../forms/client_intro_page.dart';

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
  bool _companyOpen = false;
  bool _financeOpen = false;
  bool _formsOpen = false;
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

  /// One press: up to date → says so; newer build → downloads it once and offers "تثبيت"
  /// (already downloaded → straight to "تثبيت", never a second download).
  Future<void> _checkForUpdates() async {
    if (_isCheckingUpdate) return;
    setState(() => _isCheckingUpdate = true);
    try {
      await AppUpdater.instance.check(context: context, manual: true);
    } finally {
      if (mounted) setState(() => _isCheckingUpdate = false);
    }
  }

  void onBottomNavTap(int index) => AppNav.go(context, index, current: 3, uid: widget.uid, name: widget.name, role: widget.role);
  void _showNoUpdateDialog() {
    showDialog(
      context: context,
      builder: (context) => GlassAlertDialog(
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
      builder: (context) => GlassAlertDialog(
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
      builder: (context) => GlassAlertDialog(
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
      builder: (context) => GlassDialogPanel(
        child: Directionality(
          textDirection: isRTL ? TextDirection.rtl : TextDirection.ltr,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.transparent,
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
                              // the dialog's own context dies when it closes: keep the app navigator
                              final nav = Navigator.of(this.context, rootNavigator: true);
                              Navigator.pop(context);
                              // sign out on the phone first and show the login page right away;
                              // the server is told in the background (a slow network never keeps the user in)
                              await SessionService.logout();
                              nav.pushAndRemoveUntil(
                                MaterialPageRoute(builder: (_) => const LoginPage()),
                                (route) => false,
                              );
                              ApiService.signOut().timeout(const Duration(seconds: 12)).catchError((_) {});
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
                onTap: (index) => AppNav.go(context, index, current: 3, uid: widget.uid, name: widget.name, role: widget.role),
              ),
              body: SafeArea(
                bottom: false,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
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

                    // ─── المالية: قائمة منسدلة (طلبات ومبيعات / الخزنة …) ───
                    SettingsExpandableTile(
                      title: AppLocalizations.of(context, 'finance') ?? 'المالية',
                      icon: Icons.account_balance_wallet,
                      expanded: _financeOpen,
                      onToggle: () => setState(() => _financeOpen = !_financeOpen),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Column(children: [
                          for (final (i, it) in _financeItems().indexed) ...[
                            if (i > 0) const SizedBox(height: 12),
                            _companyOption(appController, it.$1, it.$2, it.$3),
                          ],
                        ]),
                      ),
                    ),

                    const SizedBox(height: 14),

                    // ─── العهدة: the company's mobiles / laptops (add here, hand over from the employee's page) ───
                    if (CustodyAssetsPage.visible) ...[
                      SettingsTile(
                        title: 'العهدة',
                        icon: Icons.inventory_2_rounded,
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CustodyAssetsPage())),
                      ),
                      const SizedBox(height: 14),
                    ],

                    // ─── استمارات ← استمارة استلام عهدة (موبايل / كمبيوتر محمول) • استمارات عملاء (استمارة تعارف — for everyone) ───
                    ...[
                      SettingsExpandableTile(
                        title: 'استمارات',
                        icon: Icons.description_rounded,
                        expanded: _formsOpen,
                        onToggle: () => setState(() => _formsOpen = !_formsOpen),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            if (CustodyReceiptPage.canUse || ApiService.can('documents.read') || ApiService.can('employee.read_all')) ...[
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8, right: 4),
                                child: Text('استمارة استلام عهدة', style: TextStyle(fontWeight: FontWeight.w800,
                                    color: appController.isDark ? Colors.white70 : Colors.black54)),
                              ),
                              _companyOption(appController, 'موبايل', Icons.phone_android_rounded, () => const CustodyReceiptPage()),
                              const SizedBox(height: 12),
                              _companyOption(appController, 'كمبيوتر محمول', Icons.laptop_rounded, () => const CustodyReceiptPage(device: 'laptop')),
                              const SizedBox(height: 16),
                            ],
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8, right: 4),
                              child: Text('استمارات عملاء', style: TextStyle(fontWeight: FontWeight.w800,
                                  color: appController.isDark ? Colors.white70 : Colors.black54)),
                            ),
                            _companyOption(appController, 'استمارة تعارف', Icons.person_search_rounded, () => const ClientIntroPage()),
                          ]),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],

                    // ─── إعدادات الشركة: expands in place like "change password" / "language"; admins only ───
                    if (_companyItems().isNotEmpty) ...[
                      SettingsExpandableTile(
                        title: 'إعدادات الشركة',
                        icon: Icons.apartment_rounded,
                        expanded: _companyOpen,
                        onToggle: () => setState(() => _companyOpen = !_companyOpen),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          child: Column(children: [
                            for (final (i, it) in _companyItems().indexed) ...[
                              if (i > 0) const SizedBox(height: 12),
                              _companyOption(appController, it.$1, it.$2, it.$3),
                            ],
                          ]),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],

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

                    // KPI
                    if (ApiService.can('kpi.config') || ApiService.can('kpi.read_all') || ApiService.can('kpi.read_team')) ...[
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
                    ],


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
                                  ? Colors.white
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
                            color: Provider.of<AppController>(context, listen: false).isDark ? Colors.white : Theme.of(context).primaryColor,
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
                            'Value Attendance © ${DateTime.now().year}',
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

  /// Company settings shown only to the people who can change them (an employee sees none).
  /// المالية: طلبات ومبيعات + الخزنة (فيها صرف السلف والمرتبات والعمولات)؛ والأقساط لأصحاب الصلاحية، وعمولات المشاريع.
  List<(String, IconData, Widget Function())> _financeItems() => [
        ('طلبات ومبيعات', Icons.request_page_rounded, () => AdvanceRequestPage(uid: widget.uid, name: widget.name, role: widget.role)),
        (CashboxHubPage.canCash ? 'الخزنة' : 'ملخص المالية', Icons.account_balance_wallet_rounded,
            () => CashboxHubPage(uid: widget.uid, name: widget.name, role: widget.role)),
        if (ApiService.can('sales.view')) ('الأقساط والمبيعات', Icons.home_work_rounded, () => const SalesPage()),
        ('عمولات المشاريع', Icons.handshake_rounded, () => const CommissionsPage()),
      ];

  List<(String, IconData, Widget Function())> _companyItems() => [
        if (ApiService.can('settings.manage')) ('معلومات الشركة', Icons.business, () => const CompanyInfoPage()),
        if (ApiService.can('positions.manage') || ApiService.can('roles.manage'))
          ('الوظائف والصلاحيات', Icons.admin_panel_settings_outlined, () => const PositionsPage()),
        if (ApiService.can('settings.manage')) ('خصم التأخير', Icons.timer_off_outlined, () => const LateRulesPage()),
        if (ApiService.can('attendance.config'))
          ('العطلات الرسمية', Icons.event_note, () => PublicHolidaysPage(uid: widget.uid, name: widget.name, role: widget.role)),
      ];

  Widget _companyOption(AppController appController, String title, IconData icon, Widget Function() page) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => page())),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.withOpacity(0.2)),
          ),
          child: Row(children: [
            Icon(icon, size: 22, color: appController.isDark ? Colors.white : Theme.of(context).primaryColor),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: appController.isDark ? Colors.white : Colors.black)),
            ),
            Icon(Icons.chevron_left_rounded, color: appController.isDark ? Colors.white54 : Colors.black45),
          ]),
        ),
      ),
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
                style: const TextStyle(fontSize: 22, fontFamilyFallback: ['NotoFlags']),
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