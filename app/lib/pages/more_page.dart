import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/app_settings.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../design/app_colors.dart';
import '../design/glass.dart';
import '../design/glass_page.dart';
import '../design/primary_button.dart';
import 'admin_pages.dart';
import 'change_password_page.dart';
import 'common.dart';
import 'employees_page.dart';
import 'evaluations_page.dart';
import 'finance_page.dart';
import 'kpi_page.dart';
import 'notifications_page.dart';
import 'reports_page.dart';

/// Settings-style hub (original SettingTile list inside GlassCards), filtered by permission.
class MorePage extends StatelessWidget {
  const MorePage({super.key});

  void _go(BuildContext c, Widget p) => Navigator.push(c, MaterialPageRoute(builder: (_) => p));

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    final settings = context.watch<AppSettings>();
    final isDark = isDarkOf(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(title: t('more')),
        GlassCard(child: Row(children: [
          EmployeeAvatar(employeeId: s.id, hasPhoto: s.me?['has_photo'] == true, size: 56),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            Text('${s.me?['code'] ?? ''} · ${I18n.lang == 'ar' ? (s.me?['role_name_ar'] ?? '') : (s.me?['role_name_en'] ?? '')}'),
          ])),
        ])),
        SectionTitle(t('me')),
        _group([
          SettingTile(icon: Icons.person_rounded, title: t('my_profile'), onTap: () => _go(context, EmployeeProfilePage(id: s.id))),
          SettingTile(icon: Icons.insights_rounded, title: t('my_kpi'), onTap: () => _go(context, _Wrap(title: t('my_kpi'), child: EmployeeKpiView(employeeId: s.id)))),
          SettingTile(icon: Icons.star_rate_rounded, title: t('my_evaluations'), onTap: () => _go(context, _Wrap(title: t('my_evaluations'), child: EvaluationsView(employeeId: s.id, employeeName: s.name)))),
          SettingTile(icon: Icons.summarize_rounded, title: t('my_monthly_report'), onTap: () => _go(context, EmployeeReportPage(employeeId: s.id, month: DateTime(DateTime.now().year, DateTime.now().month)))),
          SettingTile(icon: Icons.notifications_rounded, title: t('notifications'), onTap: () => _go(context, const NotificationsPage())),
        ]),
        if (s.seesReports || s.seesPayroll || s.configuresKpi) ...[
          SectionTitle(t('management')),
          _group([
            if (s.seesReports) SettingTile(icon: Icons.assessment_rounded, title: t('monthly_reports'), onTap: () => _go(context, const ReportsPage())),
            if (s.has('kpi.read_all') || s.has('kpi.read_team')) SettingTile(icon: Icons.leaderboard_rounded, title: t('kpi_overview'), onTap: () => _go(context, const KpiOverviewPage())),
            if (s.configuresKpi) SettingTile(icon: Icons.tune_rounded, title: t('kpi_settings'), onTap: () => _go(context, const KpiConfigPage())),
            if (s.has('report.payroll') || s.has('report.read_all')) SettingTile(icon: Icons.payments_rounded, title: t('payroll_summary'), onTap: () => _go(context, const PayrollPage())),
            if (s.has('finance.read')) SettingTile(icon: Icons.account_balance_wallet_rounded, title: t('financial_adjustments'), onTap: () => _go(context, const FinancePage())),
          ]),
        ],
        if (s.isAdmin || s.has('audit.read')) ...[
          SectionTitle(t('administration')),
          _group([
            if (s.has('org.manage')) SettingTile(icon: Icons.apartment_rounded, title: t('departments_and_teams'), onTap: () => _go(context, const OrgAdminPage())),
            if (s.has('attendance.config')) SettingTile(icon: Icons.schedule_rounded, title: t('schedules_holidays_locations'), onTap: () => _go(context, const AttendanceConfigPage())),
            if (s.has('settings.manage')) SettingTile(icon: Icons.settings_rounded, title: t('company_settings'), onTap: () => _go(context, const CompanySettingsPage())),
            if (s.has('settings.manage')) SettingTile(icon: Icons.rule_rounded, title: t('payroll_rules'), onTap: () => _go(context, const PayrollRulesPage())),
            if (s.has('roles.manage')) SettingTile(icon: Icons.admin_panel_settings_rounded, title: t('roles_permissions'), onTap: () => _go(context, const RolesPage())),
            if (s.has('audit.read')) SettingTile(icon: Icons.manage_search_rounded, title: t('audit_log'), onTap: () => _go(context, const AuditPage())),
          ]),
        ],
        SectionTitle(t('app_settings')),
        _group([
          SwitchListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode, color: isDark ? AppColors.primaryLight : AppColors.primary),
            title: Text(t('dark_mode')),
            value: settings.themeMode == ThemeMode.dark,
            onChanged: (v) => settings.setTheme(v ? ThemeMode.dark : ThemeMode.light),
          ),
          SettingTile(icon: Icons.language_rounded, title: t('language'), subtitle: settings.lang == 'ar' ? 'العربية' : 'English',
              onTap: () => settings.setLang(settings.lang == 'ar' ? 'en' : 'ar')),
          SettingTile(icon: Icons.lock_rounded, title: t('change_password'), onTap: () => _go(context, const ChangePasswordPage())),
        ]),
        const SizedBox(height: 16),
        PrimaryButton(label: t('logout'), icon: Icons.logout_rounded, color: AppColors.error, onTap: () async {
          final ok = await confirmDialog(context, title: t('logout'), message: t('logout_confirm'), ok: t('logout'), cancel: t('cancel'));
          if (ok && context.mounted) await context.read<Session>().logout();
        }),
        const SizedBox(height: 110),
      ]),
    );
  }

  Widget _group(List<Widget> children) => GlassCard(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: Column(children: children));
}

class _Wrap extends StatelessWidget {
  final String title;
  final Widget child;
  const _Wrap({required this.title, required this.child});
  @override
  Widget build(BuildContext context) => GlassPage(title: title, body: child);
}
