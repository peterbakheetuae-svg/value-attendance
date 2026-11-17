import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/app_nav.dart';
import '../../widgets/glass_bottom_nav.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../leads/lead_page.dart';
import '../leads/leads_api.dart';
import 'partner_profile.dart';

/// A marketing company's app (its own sign-in, not an employee — db/migrations/075_marketing_partners.sql):
///   لوحة التحكم — like the sales dashboard the owner sees, but only its campaigns' leads
///   الليدز      — «لوحة السيلز» itself (LeadsDashboardPage), read-only: the server scopes it to its campaigns' leads
///   الإعدادات   — «تعديل الحساب» … «تسجيل الخروج»
/// what the company's pages share: its campaigns and the stages (loaded once)
class PartnerMeta {
  static Map<String, dynamic>? _m;
  static Future<Map<String, dynamic>> load({bool fresh = false}) async {
    if (_m != null && !fresh) return _m!;
    final r = await lget('/partner/meta');
    if (r['success'] != false) _m = r;
    return r;
  }

  static void clear() => _m = null;
}

GlassBottomNav _bar(BuildContext context, int index) => GlassBottomNav(
      currentIndex: index,
      onTap: (i) => AppNav.go(context, i, current: index, uid: AppNav.uid ?? '', name: AppNav.name ?? '', role: AppNav.role ?? ''),
    );

/// the company's home (AppNav.home): its dashboard, in the app's frame (the same bottom bar / side bar as everyone)
class PartnerDashboardPage extends StatefulWidget {
  const PartnerDashboardPage({super.key});

  @override
  State<PartnerDashboardPage> createState() => _PartnerDashboardPageState();
}

class _PartnerDashboardPageState extends State<PartnerDashboardPage> {
  Map<String, dynamic> _meta = {};

  @override
  void initState() {
    super.initState();
    AppNav.homeAlive++;
    PartnerMeta.load(fresh: true).then((m) {
      if (mounted) setState(() => _meta = m);
    });
  }

  @override
  void dispose() {
    AppNav.homeAlive--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    // the top like the general manager's dashboard: the bell, today / the name, the photo → «الملف الشخصي»
    return AppBackground(
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          extendBody: true,
          bottomNavigationBar: _bar(context, 0),
          body: SafeArea(
            bottom: false,
            // the top scrolls with the page, like the general manager's
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: _PartnerDashboard(isDark: isDark, meta: _meta,
                    header: PartnerTopBar(isDark: isDark, name: '${lm(_meta['company'])['name'] ?? AppNav.name ?? ''}'),
                    onOpenLeads: () => AppNav.go(context, 6, current: 0, uid: AppNav.uid ?? '', name: AppNav.name ?? '', role: AppNav.role ?? '')),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Color _hexColor(Object? v, Color fallback) {
  final s = '${v ?? ''}';
  if (!RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(s)) return fallback;
  return Color(0xFF000000 | int.parse(s.substring(1), radix: 16));
}

Widget _card(bool isDark, {required Widget child, EdgeInsets? padding}) => Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: padding ?? const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: child,
    );

Widget _title(bool isDark, String t, IconData icon) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Icon(icon, color: Ar.accent, size: 20),
        const SizedBox(width: 8),
        Text(t, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      ]),
    );

// ===================================================================== لوحة التحكم
class _PartnerDashboard extends StatefulWidget {
  final bool isDark;
  final Map<String, dynamic> meta;
  final VoidCallback onOpenLeads;
  final Widget header;
  const _PartnerDashboard({required this.isDark, required this.meta, required this.onOpenLeads, required this.header});

  @override
  State<_PartnerDashboard> createState() => _PartnerDashboardState();
}

class _PartnerDashboardState extends State<_PartnerDashboard> {
  Map<String, dynamic> _d = {};
  bool _loading = true;
  String? _campaign;

  bool get isDark => widget.isDark;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await lget('/partner/dashboard', {'campaignId': _campaign});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _d = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final campaigns = ll(widget.meta['campaigns']);
    final counts = lm(_d['counts']);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 120), children: [
        widget.header,
        const SizedBox(height: 18),
        Text(tr('لوحة التحكم'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
        Text(tr('ليدز حملاتك بس'), style: TextStyle(color: JphUi.sub(isDark))),
        const SizedBox(height: 12),
        if (campaigns.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (id, name) in [(null, tr('كل الحملات')), for (final c in campaigns) ('${c['id']}', '${c['name']}')])
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: ChoiceChip(
                    selected: _campaign == id,
                    label: Text(name),
                    onSelected: (_) {
                      setState(() => _campaign = id);
                      _load();
                    },
                  ),
                ),
            ]),
          ),
        const SizedBox(height: 10),
        if (_loading)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
        else if (_d['success'] == false)
          Text('${_d['message']}', style: TextStyle(color: JphUi.sub(isDark)))
        else ...[
          LayoutBuilder(builder: (context, c) {
            final cols = c.maxWidth > 900 ? 5 : (c.maxWidth > 560 ? 3 : 2);
            final w = (c.maxWidth - (cols - 1) * 10) / cols;
            Widget tile(String label, Object? v, IconData icon, Color color) => SizedBox(
                  width: w,
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: JphUi.box(isDark),
                    child: Row(children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(12)),
                        child: Icon(icon, color: color),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${v ?? 0}', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                          Text(label, style: TextStyle(fontSize: 12, color: JphUi.sub(isDark)), overflow: TextOverflow.ellipsis),
                        ]),
                      ),
                    ]),
                  ),
                );
            return Wrap(spacing: 10, runSpacing: 10, children: [
              tile(tr('النهارده'), counts['today'], Icons.today_rounded, Ar.accent),
              tile(tr('آخر 7 أيام'), counts['week'], Icons.date_range_rounded, const Color(0xFF3FC1C9)),
              tile(tr('الشهر ده'), counts['month'], Icons.calendar_month_rounded, const Color(0xFFB28DFF)),
              tile(tr('الإجمالي'), counts['total'], Icons.groups_rounded, const Color(0xFF7FB4E8)),
              tile(tr('اتقفلوا (حجز / صفقة)'), counts['closed'], Icons.verified_rounded, Ar.green),
            ]);
          }),
          const SizedBox(height: 12),
          _card(isDark, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _title(isDark, tr('الليدز آخر 7 أيام'), Icons.bar_chart_rounded),
            _Bars(isDark: isDark, rows: ll(_d['created7'])),
          ])),
          _card(isDark, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _title(isDark, tr('المراحل'), Icons.view_week_rounded),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final s in ll(_d['pipeline']))
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: _hexColor(s['color'], Ar.grey).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: _hexColor(s['color'], Ar.grey).withOpacity(0.5)),
                  ),
                  child: Text('${s['name']}  ${s['count']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                ),
            ]),
          ])),
          _card(isDark, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _title(isDark, tr('مقارنة بين حملاتك'), Icons.compare_arrows_rounded),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(columnSpacing: 22, columns: [
                for (final h in [tr('الحملة'), tr('الليدز'), tr('الشهر ده'), tr('اتقفلوا'), tr('اتلغوا'), tr('نسبة القفل')])
                  DataColumn(label: Text(h, style: const TextStyle(fontWeight: FontWeight.w900))),
              ], rows: [
                for (final c in ll(_d['campaigns']))
                  DataRow(cells: [
                    DataCell(Text('${c['name']}', style: const TextStyle(fontWeight: FontWeight.w800))),
                    DataCell(Text('${c['leads']}')),
                    DataCell(Text('${c['month']}')),
                    DataCell(Text('${c['closed']}')),
                    DataCell(Text('${c['lost']}')),
                    DataCell(Text((c['leads'] as num? ?? 0) == 0 ? '—' : '${((c['closed'] as num) * 100 / (c['leads'] as num)).toStringAsFixed(1)}%')),
                  ]),
              ]),
            ),
          ])),
          _card(isDark, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: _title(isDark, tr('أحدث الليدز'), Icons.fiber_new_rounded)),
              TextButton(onPressed: widget.onOpenLeads, child: Text(tr('الكل'))),
            ]),
            if (ll(_d['latest']).isEmpty) Text(tr('لسه مفيش ليدز'), style: TextStyle(color: JphUi.sub(isDark))),
            for (final l in ll(_d['latest'])) _LeadRow(isDark: isDark, l: l),
          ])),
        ],
      ]),
    );
  }
}

class _Bars extends StatelessWidget {
  final bool isDark;
  final List<Map<String, dynamic>> rows;
  const _Bars({required this.isDark, required this.rows});

  @override
  Widget build(BuildContext context) {
    final max = rows.fold<num>(0, (m, r) => (r['leads'] as num? ?? 0) > m ? (r['leads'] as num) : m);
    return SizedBox(
      height: 150,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final r in rows)
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
              Text('${r['leads']}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              const SizedBox(height: 4),
              Container(
                height: max == 0 ? 4 : 4 + 96 * ((r['leads'] as num? ?? 0) / max),
                margin: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(color: Ar.accent, borderRadius: BorderRadius.circular(6)),
              ),
              const SizedBox(height: 6),
              Text('${r['day']}'.substring(5).replaceAll('-', '/'), style: TextStyle(fontSize: 11, color: JphUi.sub(isDark))),
            ]),
          ),
      ]),
    );
  }
}

class _LeadRow extends StatelessWidget {
  final bool isDark;
  final Map<String, dynamic> l;
  const _LeadRow({required this.isDark, required this.l});

  @override
  Widget build(BuildContext context) {
    final st = lm(l['stage']);
    return InkWell(
      onTap: () => openLead(context, '${l['id']}'),   // the salesmen's lead page itself (read-only for it)
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          leadAvatar('${l['fullName']}'),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${l['fullName']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              Text(
                [
                  '${l['phone']}',
                  if (lm(l['campaign'])['name'] != null) '${lm(l['campaign'])['name']}',
                  if (l['salesman'] != null) '${tr('السيلز')}: ${l['salesman']}',
                  agoAr(l['createdAt']),
                ].join(' · '),
                style: TextStyle(fontSize: 12, color: JphUi.sub(isDark)),
                overflow: TextOverflow.ellipsis,
              ),
            ]),
          ),
          const SizedBox(width: 6),
          if (l['closed'] == true) ...[pill(tr('اتقفل'), Ar.green, icon: Icons.verified_rounded), const SizedBox(width: 4)],
          pill('${st['name'] ?? ''}', _hexColor(st['color'], Ar.grey)),
        ]),
      ),
    );
  }
}
