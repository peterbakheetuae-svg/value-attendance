import 'side_sheet.dart';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../forms/client_intro_page.dart';
import '../forms/custody_receipt_page.dart';
import '../pages/advance_request_page.dart';
import '../pages/cash/cashbox_hub_page.dart';
import '../pages/commissions/commissions_page.dart';
import '../pages/custody/custody_assets_page.dart';
import '../pages/exclusive/exclusive_projects_page.dart';
import '../pages/leave_summary.dart';
import '../pages/multi_company/company_info_page.dart';
import '../pages/multi_company/company_logo_page.dart';
import '../pages/multi_company/kpi_page.dart';
import '../pages/multi_company/positions_page.dart';
import '../pages/projects/marketing_companies_page.dart';
import '../pages/public_holidays_page.dart';
import '../pages/sales/sales_page.dart';
import '../pages/settings/late_rules_page.dart';
import '../services/api_service.dart';
import '../services/app_controller.dart';
import '../services/jph_bridge.dart';
import 'app_nav.dart';
import '../pages/leads/leads_api.dart' show seesLeads, tr;
import 'glass_ui.dart';

/// One entry of the app's menu: a page, a bottom-bar tab ([nav]) or a group with sub-items.
class MenuEntry {
  final String key;
  final String title;
  final IconData icon;
  final Widget Function()? page;
  final int? nav;
  final List<MenuEntry> children;
  const MenuEntry(this.key, this.title, this.icon, {this.page, this.nav, this.children = const []});

  bool get isGroup => children.isNotEmpty;
  bool has(String? k) => k != null && (key == k || children.any((c) => c.key == k));
}

class MenuSection {
  final String title;
  final List<MenuEntry> entries;
  const MenuSection(this.title, this.entries);
}

/// The app's whole menu in one place: the computer's side bar (like the «Ardena» site) and the phone's «المزيد» sheet
/// both read it, and the settings page takes its lists (المالية / المشاريع / إعدادات الشركة) from here too.
class AppMenu {
  AppMenu._();

  static String get uid => AppNav.uid ?? JphBridge.myCode;
  static String get name => AppNav.name ?? JphBridge.session.name;
  static String get role => AppNav.role ?? JphBridge.session.role;

  /// the website on a computer: a side bar instead of the bottom bar
  static bool wide(BuildContext context) => kIsWeb && MediaQueryData.fromView(View.of(context)).size.width >= 1100;

  // ------------------------------------------------------------------ the lists
  static List<MenuEntry> financeItems() => [
        MenuEntry('requests', 'طلبات مالية', Icons.request_page_rounded, page: () => AdvanceRequestPage(uid: uid, name: name, role: role)),
        MenuEntry('cashbox', CashboxHubPage.canCash ? 'المالية' : 'ملخص المالية', Icons.account_balance_wallet_rounded,
            page: () => CashboxHubPage(uid: uid, name: name, role: role)),
        if (ApiService.can('sales.view')) MenuEntry('installments', 'الأقساط', Icons.event_note_rounded, page: () => const SalesPage()),
      ];

  static List<MenuEntry> projectItems() {
    final office = ApiService.can('cash.office');
    final sales = office || ApiService.can('exclusive.reserve') || ApiService.can('cash.hr_operate');
    return [
      MenuEntry('projects', 'المشاريع', Icons.apartment_rounded, page: () => const ProjectsPage()),
      if (sales) MenuEntry('sales', 'المبيعات', Icons.sell_rounded, page: () => const SalesHubPage()),
      MenuEntry('commissions', 'العمولات', Icons.workspace_premium_rounded, page: () => const CommissionsPage(requestsOnly: true)),
      if (office || ApiService.can('cash.hr_operate')) MenuEntry('developers', 'المطورين', Icons.business_rounded, page: () => const DevelopersPage()),
      if (sales) MenuEntry('clients', 'العملاء', Icons.people_alt_rounded, page: () => const ClientsPage()),
    ];
  }

  static List<MenuEntry> companyItems() => [
        if (ApiService.can('settings.manage')) MenuEntry('company', 'معلومات الشركة', Icons.business, page: () => const CompanyInfoPage()),
        if (ApiService.can('positions.manage') || ApiService.can('roles.manage'))
          MenuEntry('positions', 'الوظائف والصلاحيات', Icons.admin_panel_settings_outlined, page: () => const PositionsPage()),
        if (ApiService.can('settings.manage')) MenuEntry('late', 'خصم التأخير', Icons.timer_off_outlined, page: () => const LateRulesPage()),
        if (ApiService.can('settings.manage') || ApiService.can('attendance.config'))
          MenuEntry('company_logo', 'لوجو الشركة', Icons.verified_rounded, page: () => const CompanyLogoPage()),
        if (ApiService.can('attendance.config'))
          MenuEntry('holidays', 'العطلات الرسمية', Icons.event_note, page: () => PublicHolidaysPage(uid: uid, name: name, role: role)),
      ];

  static List<MenuEntry> formItems() => [
        if (CustodyReceiptPage.canUse || ApiService.can('documents.read') || ApiService.can('employee.read_all')) ...[
          MenuEntry('form_mobile', 'عهدة موبايل', Icons.phone_android_rounded, page: () => const CustodyReceiptPage()),
          MenuEntry('form_laptop', 'عهدة كمبيوتر محمول', Icons.laptop_rounded, page: () => const CustodyReceiptPage(device: 'laptop')),
        ],
        MenuEntry('form_intro', 'استمارة تعارف', Icons.person_search_rounded, page: () => const ClientIntroPage()),
      ];

  /// [sidebar]: the computer's side bar — there المدير العام / المحاسب get «لوحة السيلز» in «الموظفين»'s place
  /// (الموظفين stays in «المزيد» and the bottom bar).
  static List<MenuSection> sections({bool sidebar = false}) {
    final projects = projectItems(), company = companyItems();
    final r = JphBridge.session.role;
    final gmOrAccountant = r == 'manager' || r == 'accountant';
    return [
      MenuSection('الرئيسية', [
        const MenuEntry('nav0', 'لوحة التحكم', Icons.grid_view_rounded, nav: 0),
        const MenuEntry('nav1', 'تقرير الحضور', Icons.assignment_rounded, nav: 1),
        // نظام الليدز: right after تقرير الحضور for everyone who works leads
        if (seesLeads) MenuEntry('leads', tr('لوحة السيلز'), Icons.leaderboard_rounded, nav: 6),
        if (AppNav.seesEmployees && !(sidebar && gmOrAccountant)) const MenuEntry('nav2', 'الموظفين', Icons.group_rounded, nav: 2),
      ]),
      MenuSection('الأعمال', [
        MenuEntry('g_finance', 'المالية', Icons.account_balance_wallet_rounded, children: financeItems()),
        if (projects.isNotEmpty) MenuEntry('g_projects', 'المشاريع', Icons.apartment_rounded, children: projects),
        MenuEntry('leave', 'طلبات الإجازة', Icons.beach_access_rounded, page: () => LeaveSummaryPage(uid: uid, name: name, role: role)),
        if (ApiService.can('cash.office'))
          MenuEntry('marketing', 'شركات التسويق', Icons.campaign_rounded, page: () => const MarketingCompaniesPage()),
        if (CustodyAssetsPage.visible) MenuEntry('custody', 'العهدة', Icons.inventory_2_rounded, page: () => const CustodyAssetsPage()),
        MenuEntry('g_forms', 'استمارات', Icons.description_rounded, children: formItems()),
      ]),
      MenuSection('الحساب', [
        if (company.isNotEmpty) MenuEntry('g_company', 'إعدادات الشركة', Icons.domain_rounded, children: company),
        if (ApiService.can('kpi.config') || ApiService.can('kpi.read_all') || ApiService.can('kpi.read_team'))
          MenuEntry('kpi', 'مؤشرات الأداء', Icons.insights_rounded, page: () => const KpiPage()),
        const MenuEntry('nav4', 'الملف الشخصي', Icons.person_rounded, nav: 4),
        const MenuEntry('nav3', 'الإعدادات', Icons.settings_rounded, nav: 3),
      ]),
    ];
  }

  /// the 3 quick squares on top of «المزيد»
  static List<MenuEntry> quick() {
    final sales = ApiService.can('cash.office') || ApiService.can('exclusive.reserve') || ApiService.can('cash.hr_operate');
    return [
      MenuEntry('leave', 'طلب إجازة', Icons.beach_access_rounded, page: () => LeaveSummaryPage(uid: uid, name: name, role: role)),
      MenuEntry('requests', 'طلب مالي', Icons.request_page_rounded, page: () => AdvanceRequestPage(uid: uid, name: name, role: role)),
      if (sales)
        MenuEntry('sales', 'حجز / تعاقد', Icons.sell_rounded, page: () => const SalesHubPage())
      else
        const MenuEntry('nav1', 'تقرير الحضور', Icons.assignment_rounded, nav: 1),
    ];
  }

  /// which entry the page in [context] is (the route's name; the home is the bottom of the stack)
  static String? activeKey(BuildContext context) {
    final r = ModalRoute.of(context);
    if (r == null) return null;
    final n = r.settings.name;
    if (n == null || n == '/') return r.isFirst ? 'nav0' : null;
    return n;
  }

  /// Opens an entry. [replace] (the side bar): the new page sits right on the home instead of piling up.
  static void open(BuildContext context, MenuEntry e, {bool replace = false}) {
    final nav = Navigator.of(context);
    if (e.nav == 0) {
      AppNav.go(context, 0, current: -1, uid: uid, name: name, role: role);
      return;
    }
    final page = e.nav != null ? AppNav.page(e.nav!, uid: uid, name: name, role: role) : e.page?.call();
    if (page == null) return;
    final route = MaterialPageRoute(settings: RouteSettings(name: e.key), builder: (_) => page);
    if (replace) {
      nav.pushAndRemoveUntil(route, (r) => r.isFirst);
    } else {
      nav.push(route);
    }
  }

  // ------------------------------------------------------------------ «المزيد» (the phone)
  static Future<void> showMore(BuildContext context) {
    final active = activeKey(context);
    return showAppSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.45),
      builder: (sheet) => _MoreSheet(active: active, onOpen: (e) {
        Navigator.pop(sheet);
        open(context, e);
      }),
    );
  }
}

String _initials(String n) {
  final p = n.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList();
  if (p.isEmpty) return '؟';
  return p.length == 1 ? p.first.characters.first : '${p.first.characters.first}${p[1].characters.first}';
}

// ==================================================================== «المزيد»
class _MoreSheet extends StatelessWidget {
  final String? active;
  final ValueChanged<MenuEntry> onOpen;
  const _MoreSheet({required this.active, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final d = app.isDark;
    final h = MediaQuery.of(context).size.height;
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Container(
        height: h * 0.9,
        margin: const EdgeInsets.only(top: 40),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: DecoratedBox(
              decoration: Glass.panel(d, r: 28).copyWith(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: d
                    ? [const Color(0xF2302F2C), const Color(0xF2262624)]
                    : [const Color(0xF7FFFFFF), const Color(0xF2F4F4F6)]),
              ),
              child: Column(children: [
                const SizedBox(height: 10),
                Container(width: 44, height: 5, decoration: BoxDecoration(color: Glass.muted(d).withOpacity(0.5), borderRadius: BorderRadius.circular(9))),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 24, 14),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(app.companyName?.isNotEmpty == true ? app.companyName! : 'Value',
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Glass.ink(d))),
                        const SizedBox(height: 2),
                        Text('${AppMenu.name} · كل الصفحات', style: TextStyle(fontSize: 12.5, color: Glass.muted(d))),
                      ]),
                    ),
                    IconButton(onPressed: () => Navigator.pop(context), icon: Icon(Icons.close_rounded, color: Glass.ink(d), size: 26)),
                  ]),
                ),
                Divider(height: 1, color: Glass.line(d)),
                Expanded(
                  child: ListView(padding: const EdgeInsets.fromLTRB(18, 18, 18, 28), children: [
                    // the three quick squares
                    Row(children: [
                      for (final (i, q) in AppMenu.quick().indexed) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => onOpen(q),
                            child: Container(
                              height: 64, // the site's quick squares
                              decoration: BoxDecoration(
                                color: Glass.blue.withOpacity(d ? 0.22 : 0.12),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: Glass.blue.withOpacity(0.18)),
                              ),
                              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                Icon(q.icon, color: d ? Glass.blueHi : Glass.blue, size: 20),
                                const SizedBox(height: 4),
                                Text(q.title, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 11, color: d ? const Color(0xFFFF8A63) : Glass.blue)),
                              ]),
                            ),
                          ),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 14),
                    for (final s in AppMenu.sections())
                      for (final e in s.entries) _row(context, d, e),
                    const SizedBox(height: 8),
                    Divider(color: Glass.line(d)),
                    _darkRow(context, d, app),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, bool d, MenuEntry e) {
    final on = e.has(active);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), // the site: 48px rows
      decoration: on && e.isGroup ? Glass.tile(d, r: 16).copyWith(border: Border.all(color: Colors.transparent)) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: e.isGroup ? null : () => onOpen(e),
          child: Row(children: [
            Container(
              width: 32,
              height: 32,
              decoration: on && !e.isGroup ? BoxDecoration(color: Glass.blue, borderRadius: BorderRadius.circular(10)) : Glass.tile(d, r: 10),
              child: Icon(e.icon, size: 16, color: on && !e.isGroup ? Colors.white : (d ? Glass.blueHi : Glass.blue)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(e.title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Glass.ink(d)))),
            if (e.isGroup)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(color: Glass.ink(d).withOpacity(0.12), borderRadius: BorderRadius.circular(99)),
                child: Text('${e.children.length}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Glass.ink(d))),
              ),
          ]),
        ),
        if (e.isGroup)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 44, top: 8),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in e.children)
                GestureDetector(
                  onTap: () => onOpen(c),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11), // 40px
                    decoration: c.key == active
                        ? BoxDecoration(color: Glass.blue, borderRadius: BorderRadius.circular(10))
                        : Glass.tile(d, r: 10),
                    child: Text(c.title,
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: c.key == active ? Colors.white : Glass.ink(d))),
                  ),
                ),
            ]),
          ),
      ]),
    );
  }
}

Widget _darkRow(BuildContext context, bool d, AppController app, {bool small = false}) => Padding(
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 14, vertical: 6),
      child: Row(children: [
        Icon(d ? Icons.dark_mode_rounded : Icons.light_mode_rounded, size: small ? 18 : 22, color: Glass.muted(d)),
        SizedBox(width: small ? 10 : 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('الوضع الداكن', style: TextStyle(fontSize: small ? 13 : 14, fontWeight: FontWeight.w600, color: Glass.ink(d))),
            if (!small) Text('للتطبيق كله', style: TextStyle(fontSize: 12.5, color: Glass.muted(d))),
          ]),
        ),
        Transform.scale(
          scale: small ? 0.8 : 1,
          child: Switch(
            value: d,
            activeColor: Colors.white,
            activeTrackColor: Glass.blue,
            onChanged: (v) => app.setThemeMode(v ? ThemeMode.dark : ThemeMode.light),
          ),
        ),
      ]),
    );

// ==================================================================== the computer's side bar
class AppSidebar extends StatefulWidget {
  final String? active;
  const AppSidebar({super.key, required this.active});

  static const double width = 244;

  @override
  State<AppSidebar> createState() => _AppSidebarState();
}

class _AppSidebarState extends State<AppSidebar> {
  /// open groups survive moving between pages (each page builds its own side bar)
  static final Set<String> _open = {};

  @override
  void initState() {
    super.initState();
    for (final s in AppMenu.sections(sidebar: true)) {
      for (final e in s.entries) {
        if (e.isGroup && e.has(widget.active)) _open.add(e.key);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final d = app.isDark;
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: SizedBox(
        width: AppSidebar.width,
        child: GlassBox(
          isDark: d,
          radius: 24,
          padding: const EdgeInsets.fromLTRB(12, 18, 12, 12),
          child: Material(
            type: MaterialType.transparency,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              // brand
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Row(children: [
                  // the app's logo
                  Image.asset('assets/images/logo.png', width: 40, height: 40, filterQuality: FilterQuality.medium),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(Localizations.localeOf(context).languageCode == 'ar' ? 'فاليو نيفو' : 'VALUNIVO',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Glass.ink(d))),
                      Text(app.companyName?.isNotEmpty == true ? app.companyName! : 'الحضور والمالية',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: Glass.muted(d))),
                    ]),
                  ),
                ]),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: ListView(padding: EdgeInsets.zero, children: [
                  for (final s in AppMenu.sections(sidebar: true)) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
                      child: Text(s.title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: Glass.muted(d))),
                    ),
                    for (final e in s.entries) ..._item(context, d, e),
                  ],
                ]),
              ),
              const SizedBox(height: 8),
              // who is signed in + the dark switch
              Container(
                padding: const EdgeInsets.all(10),
                decoration: Glass.tile(d, r: 16),
                child: Column(children: [
                  Row(children: [
                    CircleAvatar(
                      radius: 17,
                      backgroundColor: Glass.blue.withOpacity(0.2),
                      child: Text(_initials(AppMenu.name), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: d ? Glass.blueHi : Glass.blue)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(AppMenu.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Glass.ink(d))),
                    ),
                  ]),
                  _darkRow(context, d, app, small: true),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  List<Widget> _item(BuildContext context, bool d, MenuEntry e, {bool child = false}) {
    final on = !e.isGroup && e.key == widget.active;
    final open = _open.contains(e.key);
    return [
      Padding(
        padding: EdgeInsetsDirectional.only(bottom: 3, start: child ? 22 : 0),
        child: Material(
          color: on ? Glass.blue : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            hoverColor: Glass.ink(d).withOpacity(0.06),
            onTap: () {
              if (e.isGroup) {
                setState(() => open ? _open.remove(e.key) : _open.add(e.key));
              } else {
                AppMenu.open(context, e, replace: true);
              }
            },
            child: SizedBox(
              height: child ? 36 : 40,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(children: [
                  Icon(e.icon, size: child ? 16 : 18, color: on ? Colors.white : (e.has(widget.active) ? (d ? Glass.blueHi : Glass.blue) : Glass.muted(d))),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(e.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: child ? 13 : 13.5, fontWeight: FontWeight.w600, color: on ? Colors.white : Glass.ink(d))),
                  ),
                  if (e.isGroup)
                    AnimatedRotation(
                      turns: open ? 0.25 : 0,
                      duration: const Duration(milliseconds: 180),
                      child: Icon(Icons.chevron_left_rounded, size: 18, color: Glass.muted(d)),
                    ),
                ]),
              ),
            ),
          ),
        ),
      ),
      if (e.isGroup && open)
        for (final c in e.children) ..._item(context, d, c, child: true),
    ];
  }
}
