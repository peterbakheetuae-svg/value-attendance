import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/app_menu.dart';
import '../../widgets/app_nav.dart';
import '../../widgets/glass_bottom_nav.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../leads/leads_api.dart';

/// A marketing company's app (its own sign-in, not an employee — db/migrations/075_marketing_partners.sql):
///   لوحة التحكم — like the sales dashboard the owner sees, but only its campaigns' leads
///   الليدز      — the leads of its campaigns (read-only: stage, salesman, comments, closed or not) + adding a lead
///   الإعدادات   — «تغيير كلمة المرور» … «تسجيل الخروج»
/// The server answers only /partner/… for it; every other page refuses its account.
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
    return LeadsShell(
      isDark: isDark,
      title: tr('لوحة التحكم'),
      bottomBar: _bar(context, 0),
      child: _PartnerDashboard(isDark: isDark, meta: _meta, onOpenLeads: () => AppNav.go(context, 6, current: 0,
          uid: AppNav.uid ?? '', name: AppNav.name ?? '', role: AppNav.role ?? '')),
    );
  }
}

/// «الليدز»: its campaigns' leads (tab 6 of the bottom bar, like «لوحة السيلز» for the sales)
class PartnerLeadsPage extends StatefulWidget {
  const PartnerLeadsPage({super.key});

  @override
  State<PartnerLeadsPage> createState() => _PartnerLeadsPageState();
}

class _PartnerLeadsPageState extends State<PartnerLeadsPage> {
  Map<String, dynamic>? _meta;

  @override
  void initState() {
    super.initState();
    PartnerMeta.load().then((m) {
      if (mounted) setState(() => _meta = m);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    return LeadsShell(
      isDark: isDark,
      title: tr('الليدز'),
      bottomBar: _bar(context, 6),
      child: _meta == null ? const Center(child: CircularProgressIndicator()) : _PartnerLeads(isDark: isDark, meta: _meta!),
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
  const _PartnerDashboard({required this.isDark, required this.meta, required this.onOpenLeads});

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
    final company = lm(widget.meta['company']);
    final campaigns = ll(widget.meta['campaigns']);
    final counts = lm(_d['counts']);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 30), children: [
        Text('${company['name'] ?? ''}', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
        Text(tr('لوحة التحكم — ليدز حملاتك بس'), style: TextStyle(color: JphUi.sub(isDark))),
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
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _PartnerLeadPage(isDark: isDark, id: '${l['id']}'))),
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

// ===================================================================== الليدز
class _PartnerLeads extends StatefulWidget {
  final bool isDark;
  final Map<String, dynamic> meta;
  const _PartnerLeads({required this.isDark, required this.meta});

  @override
  State<_PartnerLeads> createState() => _PartnerLeadsState();
}

class _PartnerLeadsState extends State<_PartnerLeads> {
  final _q = TextEditingController();
  List<Map<String, dynamic>> _rows = [];
  int _page = 1, _pages = 1, _total = 0;
  String? _campaign, _stage;
  bool _loading = true;

  bool get isDark => widget.isDark;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    final page = more ? _page + 1 : 1;
    final r = await lget('/partner/leads', {'q': _q.text.trim(), 'campaignId': _campaign, 'stage': _stage, 'page': '$page'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r['success'] == false) return;
      _rows = more ? [..._rows, ...ll(r['leads'])] : ll(r['leads']);
      _page = (r['page'] as num?)?.toInt() ?? 1;
      _pages = (r['pages'] as num?)?.toInt() ?? 1;
      _total = (r['total'] as num?)?.toInt() ?? 0;
    });
  }

  Future<void> _add() async {
    final campaigns = ll(widget.meta['campaigns']).where((c) => c['active'] != false).toList();
    if (campaigns.isEmpty) {
      JphUi.toast(context, {'success': false, 'message': tr('مفيش حملة مربوطة بيك — كلم الإدارة')});
      return;
    }
    var campaign = campaigns.length == 1 ? '${campaigns.first['id']}' : null;
    final name = TextEditingController(), phone = TextEditingController(), email = TextEditingController(), notes = TextEditingController();
    final ok = await leadForm(context, isDark, tr('ليد جديد'), (set) => [
          JphUi.picker(
            isDark: isDark,
            icon: Icons.campaign_rounded,
            iconColor: Ar.accent,
            label: tr('الحملة'),
            value: campaign == null ? tr('اختار') : '${campaigns.firstWhere((c) => '${c['id']}' == campaign)['name']}',
            onTap: () async {
              final v = await JphUi.sheet<String>(context, isDark, tr('الحملة'),
                  [for (final c in campaigns) ('${c['id']}', '${c['name']}', Icons.campaign_rounded)], selected: campaign);
              if (v != null) set(() => campaign = v);
            },
          ),
          JphUi.input(isDark: isDark, label: tr('اسم العميل'), controller: name, icon: Icons.person_rounded, big: false),
          JphUi.input(isDark: isDark, label: tr('الموبايل'), controller: phone, number: true, icon: Icons.phone_rounded, big: false),
          JphUi.input(isDark: isDark, label: tr('الإيميل (اختياري)'), controller: email, icon: Icons.alternate_email_rounded, big: false),
          JphUi.input(isDark: isDark, label: tr('ملاحظات (اختياري)'), controller: notes, icon: Icons.notes_rounded, big: false),
        ], () async {
      if (campaign == null) {
        JphUi.toast(context, {'success': false, 'message': tr('اختار الحملة')});
        return false;
      }
      final r = await lpost('/partner/leads', {
        'campaignId': campaign,
        'fullName': name.text.trim(),
        'phone': phone.text.trim(),
        'email': email.text.trim(),
        'notes': notes.text.trim(),
      }, ok: tr('اتضاف الليد ✅'));
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final campaigns = ll(widget.meta['campaigns']);
    final stages = ll(widget.meta['stages']).where((s) => s['active'] == true).toList();
    return Stack(children: [
      RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 100), children: [
          Text(tr('الليدز'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
          Text('${tr('ليدز حملاتك')} · $_total', style: TextStyle(color: JphUi.sub(isDark))),
          const SizedBox(height: 10),
          TextField(
            controller: _q,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              hintText: tr('دوّر بالاسم أو الموبايل'),
              prefixIcon: const Icon(Icons.search_rounded),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              if (campaigns.length > 1)
                for (final (id, n) in [(null, tr('كل الحملات')), for (final c in campaigns) ('${c['id']}', '${c['name']}')])
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: ChoiceChip(selected: _campaign == id, label: Text(n), onSelected: (_) {
                      setState(() => _campaign = id);
                      _load();
                    }),
                  ),
            ]),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (k, n) in [(null, tr('كل المراحل')), for (final s in stages) ('${s['key']}', '${s['name']}')])
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: ChoiceChip(selected: _stage == k, label: Text(n), onSelected: (_) {
                    setState(() => _stage = k);
                    _load();
                  }),
                ),
            ]),
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (_rows.isEmpty)
            Padding(padding: const EdgeInsets.all(30), child: Center(child: Text(tr('مفيش ليدز'), style: TextStyle(color: JphUi.sub(isDark)))))
          else
            _card(isDark, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6), child: Column(children: [
              for (final l in _rows) _LeadRow(isDark: isDark, l: l),
            ])),
          if (_page < _pages) Center(child: TextButton(onPressed: () => _load(more: true), child: Text(tr('المزيد')))),
        ]),
      ),
      PositionedDirectional(
        end: 16,
        bottom: AppMenu.wide(context) ? 16 : 96,   // above the bottom bar on the phone
        child: FloatingActionButton.extended(
          heroTag: 'partner-add',
          onPressed: _add,
          backgroundColor: Ar.accent,
          icon: const Icon(Icons.person_add_alt_1_rounded, color: Colors.white),
          label: Text(tr('ليد جديد'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        ),
      ),
    ]);
  }
}

// ===================================================================== صفحة الليد (قراءة بس)
class _PartnerLeadPage extends StatefulWidget {
  final bool isDark;
  final String id;
  const _PartnerLeadPage({required this.isDark, required this.id});

  @override
  State<_PartnerLeadPage> createState() => _PartnerLeadPageState();
}

class _PartnerLeadPageState extends State<_PartnerLeadPage> {
  Map<String, dynamic> _d = {};
  bool _loading = true;

  bool get isDark => widget.isDark;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await lget('/partner/leads/${widget.id}');
    if (mounted) setState(() {
      _loading = false;
      _d = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = lm(_d['lead']);
    final st = lm(l['stage']);
    return LeadsShell(
      isDark: isDark,
      title: '${l['fullName'] ?? tr('الليد')}',
      child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _d['success'] == false
                  ? Center(child: Text('${_d['message']}'))
                  : ListView(padding: const EdgeInsets.all(16), children: [
                      _card(isDark, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          leadAvatar('${l['fullName']}', size: 48),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${l['fullName']}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                              Text('#${l['refNo']} · ${l['phone']}', style: TextStyle(color: JphUi.sub(isDark))),
                            ]),
                          ),
                        ]),
                        const SizedBox(height: 12),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          pill('${st['name'] ?? ''}', _hexColor(st['color'], Ar.grey)),
                          if (l['closed'] == true) pill(tr('اتقفل (حجز / صفقة)'), Ar.green, icon: Icons.verified_rounded),
                          if (lm(l['campaign'])['name'] != null) pill('${lm(l['campaign'])['name']}', Ar.accent, icon: Icons.campaign_rounded),
                          if (l['addedByUs'] == true) pill(tr('انت اللي ضفته'), const Color(0xFFB28DFF)),
                        ]),
                        const SizedBox(height: 10),
                        Text('${tr('السيلز المسؤول')}: ${l['salesman'] ?? tr('لسه متوزعش')}', style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
                        Text('${tr('اتضاف')}: ${agoAr(l['createdAt'])}', style: TextStyle(color: JphUi.sub(isDark))),
                        if ('${l['email'] ?? ''}'.isNotEmpty) Text('${l['email']}', style: TextStyle(color: JphUi.sub(isDark))),
                        if ('${l['notes'] ?? ''}'.isNotEmpty) ...[const SizedBox(height: 6), Text('${l['notes']}', style: TextStyle(color: JphUi.text(isDark)))],
                      ])),
                      _card(isDark, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        _title(isDark, tr('التعليقات والمتابعات'), Icons.forum_rounded),
                        if (ll(_d['actions']).isEmpty) Text(tr('لسه مفيش متابعات'), style: TextStyle(color: JphUi.sub(isDark))),
                        for (final a in ll(_d['actions']))
                          Container(
                            margin: const EdgeInsets.only(bottom: 10),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: (isDark ? Colors.white : Colors.black).withOpacity(0.04),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Row(children: [
                                Expanded(
                                  child: Text('${a['by']} · ${agoAr(a['at'])}',
                                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: JphUi.sub(isDark))),
                                ),
                                if (lm(a['stage'])['name'] != null) pill('${lm(a['stage'])['name']}', _hexColor(lm(a['stage'])['color'], Ar.grey)),
                              ]),
                              const SizedBox(height: 4),
                              Text('${a['comment']}', style: TextStyle(color: JphUi.text(isDark))),
                            ]),
                          ),
                      ])),
                    ]),
    );
  }
}
