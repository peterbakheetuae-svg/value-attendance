import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../../pages/change_password_page.dart';
import '../../l10n/app_localizations.dart';
import '../../services/app_controller.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/app_nav.dart';
import '../../widgets/glass_bottom_nav.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/jph_form_ui.dart';
import '../leads/leads_api.dart';

/// the company's logo (its «صورة الملف الشخصي»), loaded once
class PartnerLogo {
  static Uint8List? bytes;
  static bool _tried = false;
  static Future<Uint8List?> load({bool fresh = false}) async {
    if (_tried && !fresh) return bytes;
    _tried = true;
    final r = await lget('/partner/files/logo');
    bytes = r['data'] == null ? null : base64Decode('${r['data']}');
    return bytes;
  }
}

/// The top of the company's dashboard — the same as the general manager's: the bell on the right, today / the name /
/// «شركة تسويق» in the middle, the photo (its logo) on the left → «الملف الشخصي».
class PartnerTopBar extends StatefulWidget {
  final bool isDark;
  final String name;
  const PartnerTopBar({super.key, required this.isDark, required this.name});

  @override
  State<PartnerTopBar> createState() => _PartnerTopBarState();
}

class _PartnerTopBarState extends State<PartnerTopBar> {
  Uint8List? _logo;
  int _unread = 0;

  @override
  void initState() {
    super.initState();
    PartnerLogo.load().then((b) {
      if (mounted) setState(() => _logo = b);
    });
    _count();
  }

  Future<void> _count() async {
    final r = await lget('/partner/notifications');
    if (mounted && r['success'] != false) setState(() => _unread = (r['unread'] as num?)?.toInt() ?? 0);
  }

  String _today(BuildContext context) {
    final now = DateTime.now();
    final dayName = AppLocalizations.of(context, 'day_${now.weekday}');
    return "${AppLocalizations.of(context, 'today')} $dayName ${now.day.toString().padLeft(2, '0')} / ${now.month.toString().padLeft(2, '0')} / ${now.year}";
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        GestureDetector(
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const PartnerNotificationsPage()));
            _count();
          },
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDark ? Colors.white.withOpacity(0.15) : AppColors.primary.withOpacity(0.1),
                border: Border.all(color: isDark ? Colors.white.withOpacity(0.2) : AppColors.primary.withOpacity(0.2), width: 1),
              ),
              child: const Icon(Icons.notifications, size: 24, color: Ar.info),
            ),
            if (_unread > 0)
              PositionedDirectional(
                top: -4,
                end: -4,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  constraints: const BoxConstraints(minWidth: 18),
                  decoration: BoxDecoration(color: Ar.red, borderRadius: BorderRadius.circular(10)),
                  child: Text(_unread > 99 ? '99+' : '$_unread', textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                ),
              ),
          ]),
        ),
        Column(children: [
          Text(_today(context), style: TextStyle(fontSize: 12, color: isDark ? Colors.white70 : Ar.grey.shade700)),
          Text(widget.name, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
          Text('شركة تسويق', style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Ar.grey.shade600)),
        ]),
        GestureDetector(
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => const PartnerProfilePage()));
            final b = await PartnerLogo.load(fresh: true);
            if (mounted) setState(() => _logo = b);
          },
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? Colors.white.withOpacity(0.15) : Colors.white.withOpacity(0.25),
              border: Border.all(color: isDark ? Colors.white.withOpacity(0.2) : AppColors.primary.withOpacity(0.2), width: 1.5),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 6, spreadRadius: 1, offset: const Offset(0, 2))],
            ),
            child: ClipOval(child: _logo != null ? Image.memory(_logo!, fit: BoxFit.cover) : const DefaultPhoto()),
          ),
        ),
      ]),
    );
  }
}

/// «الإشعارات»: what happened on its campaigns' leads (new leads, the salesmen's follow-ups)
class PartnerNotificationsPage extends StatefulWidget {
  const PartnerNotificationsPage({super.key});

  @override
  State<PartnerNotificationsPage> createState() => _PartnerNotificationsPageState();
}

class _PartnerNotificationsPageState extends State<PartnerNotificationsPage> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await lget('/partner/notifications');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = ll(r['items']);
    });
    lpost('/partner/notifications/seen', {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    return LeadsShell(
      isDark: isDark,
      title: 'الإشعارات',
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 40), children: [
                if (_items.isEmpty)
                  Padding(padding: const EdgeInsets.all(40), child: Center(child: Text('مفيش إشعارات', style: TextStyle(color: JphUi.sub(isDark))))),
                for (final n in _items)
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.all(14),
                    decoration: JphUi.box(isDark),
                    child: Row(children: [
                      Icon(n['kind'] == 'lead' ? Icons.person_add_alt_1_rounded : Icons.forum_rounded,
                          color: n['unread'] == true ? Ar.accent : JphUi.sub(isDark)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${n['title']}', style: TextStyle(fontWeight: n['unread'] == true ? FontWeight.w900 : FontWeight.w700, color: JphUi.text(isDark))),
                          if ('${n['body'] ?? ''}'.isNotEmpty) Text('${n['body']}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                          Text(agoAr(n['at']), style: TextStyle(fontSize: 11.5, color: JphUi.sub(isDark))),
                        ]),
                      ),
                      if (n['unread'] == true) Container(width: 9, height: 9, decoration: const BoxDecoration(color: Ar.red, shape: BoxShape.circle)),
                    ]),
                  ),
              ]),
            ),
    );
  }
}

/// «الملف الشخصي» of the company — the employee's profile page (profile_page.dart) for a company: the same header card,
/// sections and look, with its own data (no salary / attendance / KPIs).
class PartnerProfilePage extends StatefulWidget {
  const PartnerProfilePage({super.key});

  @override
  State<PartnerProfilePage> createState() => _PartnerProfilePageState();
}

class _PartnerProfilePageState extends State<PartnerProfilePage> {
  bool loading = true;
  Map<String, dynamic> data = {};
  Uint8List? _logo;

  static const _docs = {
    'contract': 'عقد التعاقد',
    'financial_plan': 'بلان الاتفاقات المالية',
    'execution_vision': 'رؤية الشركة للتنفيذ',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await lget('/partner/profile');
    final logo = await PartnerLogo.load(fresh: true);
    if (!mounted) return;
    setState(() {
      loading = false;
      data = lm(r['profile']);
      _logo = logo;
    });
  }

  Future<void> _openDoc(String kind) async {
    final r = await lget('/partner/files/$kind');
    if (!mounted || r['data'] == null) return;
    final bytes = base64Decode('${r['data']}');
    await Navigator.push(context, MaterialPageRoute(builder: (_) => AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: Text('${r['fileName']}')),
        body: PdfPreview(build: (_) async => bytes, pdfFileName: '${r['fileName']}', canChangePageFormat: false, canChangeOrientation: false, canDebug: false),
      ),
    )));
  }

  Widget _section(String title, List<Widget> rows, Color textColor) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textColor)),
        const SizedBox(height: 12),
        GlassCard(radius: 24, padding: const EdgeInsets.all(16), child: Column(children: rows)),
        const SizedBox(height: 24),
      ]);

  Widget _row(IconData icon, String label, String value, Color color) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text('$label : $value', style: TextStyle(fontSize: 14, color: color))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, appController, _) {
      final isDark = appController.isDark;
      final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;
      final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
      final sub = isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight;
      final files = lm(data['files']);
      final fixed = data['kind'] == 'fixed';
      return AppBackground(
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            extendBody: true,
            backgroundColor: Colors.transparent,
            bottomNavigationBar: GlassBottomNav(
              currentIndex: 4,
              onTap: (i) => AppNav.go(context, i, current: 4, uid: AppNav.uid ?? '', name: AppNav.name ?? '', role: AppNav.role ?? ''),
            ),
            body: loading
                ? Center(child: CircularProgressIndicator(color: primaryColor))
                : SafeArea(
                    bottom: false,
                    child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 120), children: [
                      Row(children: [
                        IconButton(icon: Icon(Icons.arrow_back, color: textColor), onPressed: () => Navigator.pop(context)),
                        Text(AppLocalizations.of(context, 'profile'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: textColor)),
                      ]),
                      const SizedBox(height: 16),
                      GlassCard(
                        radius: 24,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${data['name'] ?? ''}', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: textColor)),
                              const SizedBox(height: 6),
                              Text('شركة تسويق', style: TextStyle(color: sub, fontSize: 14)),
                              const SizedBox(height: 14),
                              SizedBox(
                                height: 46,
                                child: ElevatedButton.icon(
                                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChangePasswordPage())),
                                  icon: const Icon(Icons.lock_reset_rounded, size: 18, color: Colors.white),
                                  label: const Text('تغيير كلمة المرور', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: primaryColor,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                                    padding: const EdgeInsets.symmetric(horizontal: 18),
                                  ),
                                ),
                              ),
                            ]),
                          ),
                          const SizedBox(width: 14),
                          Container(
                            width: 108,
                            height: 108,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: data['status'] == 'active' ? Ar.green : Ar.red, width: 6),
                            ),
                            child: ClipOval(child: _logo != null ? Image.memory(_logo!, fit: BoxFit.cover) : const DefaultPhoto()),
                          ),
                        ]),
                      ),
                      const SizedBox(height: 24),
                      _section('معلومات الشركة', [
                        _row(Icons.email, AppLocalizations.of(context, 'email'), '${data['email'] ?? '--'}', sub),
                        _row(Icons.phone, AppLocalizations.of(context, 'phone'), '${data['phone'] ?? '--'}', sub),
                        _row(Icons.event, 'تاريخ التعاقد', '${data['contractDate'] ?? '--'}', sub),
                        _row(Icons.supervisor_account, 'المدير المباشر', '${data['manager'] ?? '--'}', sub),
                        _row(Icons.account_tree, 'المدير العام', '${data['generalManager'] ?? '--'}', sub),
                        _row(Icons.info, 'الوضع', data['status'] == 'active' ? 'متعاقد' : 'تم فسخ التعاقد', sub),
                      ], textColor),
                      _section('المحاسبة', [
                        _row(Icons.account_balance, 'المحاسبه', fixed ? 'مبلغ ثابت' : 'بالعمولة', sub),
                        fixed
                            ? _row(Icons.money, 'المبلغ الشهري', JphUi.money(data['monthlyFee']), sub)
                            : _row(Icons.percent_rounded, 'نسبة العمولة', JphUi.pct(data['defaultPct']), sub),
                      ], textColor),
                      _section('الحملات', [
                        if (ll(data['campaigns']).isEmpty) _row(Icons.ads_click_rounded, 'الحملات', 'مفيش حملات مربوطة', sub),
                        for (final c in ll(data['campaigns']))
                          _row(Icons.ads_click_rounded, '${c['name']}', c['active'] == true ? 'شغالة' : 'موقوفة', sub),
                      ], textColor),
                      _section('المستندات', [
                        for (final e in _docs.entries)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(files[e.key] != null ? Icons.check_circle_rounded : Icons.description_outlined,
                                color: files[e.key] != null ? Ar.green : sub),
                            title: Text(e.value, style: TextStyle(color: textColor, fontWeight: FontWeight.w700)),
                            subtitle: Text(files[e.key] != null ? '${lm(files[e.key])['fileName']}' : 'لسه مترفعش', style: TextStyle(color: sub)),
                            trailing: files[e.key] != null
                                ? IconButton(tooltip: 'عرض', icon: const Icon(Icons.visibility_rounded), onPressed: () => _openDoc(e.key))
                                : null,
                          ),
                      ], textColor),
                    ]),
                  ),
          ),
        ),
      );
    });
  }
}
