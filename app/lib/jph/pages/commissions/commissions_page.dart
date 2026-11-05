import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/jph_form_ui.dart';
import 'commission_project_page.dart';
import 'project_form_page.dart';

/// إدارة عمولات المشاريع — one place, tabs by permission:
///  المشاريع (owner / المدير / HR / sales manager) • للاعتماد (المدير / owner) • الاستحقاقات (HR / payroll) • عمولاتي (everyone).
/// What each tab shows comes from the API already filtered by role; nothing is only hidden here.
class CommissionsPage extends StatefulWidget {
  final String? initialTab;
  const CommissionsPage({super.key, this.initialTab});

  @override
  State<CommissionsPage> createState() => _CommissionsPageState();
}

class _CommissionsPageState extends State<CommissionsPage> {
  late String _tab;
  Map<String, dynamic> _can = {};

  bool get _seeProjects => ApiService.can('commission.project_manage') || ApiService.can('commission.read_all') || ApiService.can('commission.read_team');
  bool get _approve => ApiService.can('commission.approve');
  bool get _payroll => ApiService.can('commission.read_all');

  List<(String, String, IconData)> get _tabs => [
        if (_seeProjects) ('projects', 'المشاريع', Icons.apartment_rounded),
        if (_approve) ('approve', 'للاعتماد', Icons.fact_check_rounded),
        if (_payroll) ('payroll', 'الاستحقاقات', Icons.receipt_long_rounded),
        ('mine', 'عمولاتي', Icons.person_rounded),
      ];

  @override
  void initState() {
    super.initState();
    final keys = _tabs.map((t) => t.$1).toList();
    _tab = widget.initialTab != null && keys.contains(widget.initialTab) ? widget.initialTab! : keys.first;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      final isRTL = app.isRTL;
      return AppBackground(
        child: Directionality(
          textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                JphUi.header(context, isDark: isDark, isRTL: isRTL, title: 'عمولات المشاريع'),
                const SizedBox(height: 6),
                if (_tabs.length > 1)
                  SizedBox(
                    height: 46,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      children: [
                        for (final t in _tabs)
                          Padding(
                            padding: const EdgeInsetsDirectional.only(end: 8),
                            child: ChoiceChip(
                              selected: _tab == t.$1,
                              onSelected: (_) => setState(() => _tab = t.$1),
                              avatar: Icon(t.$3, size: 18, color: _tab == t.$1 ? Colors.white : JphUi.primary(isDark)),
                              label: Text(t.$2, style: TextStyle(fontWeight: FontWeight.w800,
                                  color: _tab == t.$1 ? Colors.white : JphUi.text(isDark))),
                              selectedColor: JphUi.primary(isDark),
                              backgroundColor: isDark ? Colors.white.withOpacity(0.12) : Colors.white,
                              showCheckmark: false,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      child: switch (_tab) {
                        'projects' => _ProjectsTab(isDark: isDark, onCan: (c) => _can = c, can: _can),
                        'approve' => _ApproveTab(isDark: isDark),
                        'payroll' => _PayrollTab(isDark: isDark),
                        _ => _MineTab(isDark: isDark),
                      },
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

// ==================================================================== المشاريع
class _ProjectsTab extends StatefulWidget {
  final bool isDark;
  final Map<String, dynamic> can;
  final ValueChanged<Map<String, dynamic>> onCan;
  const _ProjectsTab({required this.isDark, required this.can, required this.onCan});

  @override
  State<_ProjectsTab> createState() => _ProjectsTabState();
}

class _ProjectsTabState extends State<_ProjectsTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];
  Map<String, dynamic> _can = {};
  String _status = '';
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'commission_projects', 'q': _q.text.trim(), 'status': _status});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = ((r['projects'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
      _can = ((r['can'] as Map?) ?? const {}).cast<String, dynamic>();
    });
    widget.onCan(_can);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final companyView = _can['companyView'] == true;
    num sum(String k) => _items.fold<num>(0, (s, p) => s + ((p[k] as num?) ?? 0));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        // summary
        LayoutBuilder(builder: (context, c) {
          final cols = c.maxWidth > 700 ? 4 : 2;
          final cards = [
            JphUi.stat(isDark, 'وحدات مباعة', '${sum('units')}', Icons.home_work_rounded, Colors.indigo),
            JphUi.stat(isDark, 'قيمة المبيعات', JphUi.money(sum('salesValue')), Icons.trending_up_rounded, Colors.blue),
            JphUi.stat(isDark, 'عمولات البائعين', JphUi.money(sum('salesCommission')), Icons.person_rounded, Colors.teal),
            if (companyView)
              JphUi.stat(isDark, 'أرباح الشركة', JphUi.money(sum('companyCommission')), Icons.account_balance_rounded, Colors.green)
            else
              JphUi.stat(isDark, 'عمولات المديرين', JphUi.money(sum('managerCommission')), Icons.groups_rounded, Colors.purple),
          ];
          return GridView.count(
            crossAxisCount: cols, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: cols == 4 ? 2.1 : 1.75,
            children: cards,
          );
        }),
        const SizedBox(height: 14),
        // search + filter
        Row(children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: JphUi.box(isDark),
              child: TextField(
                controller: _q,
                onSubmitted: (_) => _load(),
                decoration: InputDecoration(
                  hintText: 'ابحث باسم المشروع', border: InputBorder.none,
                  prefixIcon: Icon(Icons.search_rounded, color: JphUi.primary(isDark)),
                  suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward_rounded), onPressed: _load),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: () async {
              final v = await JphUi.sheet<String>(context, isDark, 'حالة المشروع', [
                ('', 'الكل', Icons.all_inclusive_rounded),
                ('active', 'شغال', Icons.play_circle_rounded),
                ('paused', 'متوقف مؤقتاً', Icons.pause_circle_rounded),
                ('closed', 'مقفول', Icons.lock_rounded),
              ]);
              if (v != null) {
                setState(() => _status = v);
                _load();
              }
            },
            child: Container(
              height: 52, padding: const EdgeInsets.symmetric(horizontal: 14), decoration: JphUi.box(isDark),
              child: Row(children: [
                Icon(Icons.filter_list_rounded, color: JphUi.primary(isDark)),
                const SizedBox(width: 6),
                Text(_statusAr(_status.isEmpty ? null : _status) ?? 'الكل', style: const TextStyle(fontWeight: FontWeight.w800)),
              ]),
            ),
          ),
        ]),
        const SizedBox(height: 14),
        if (_can['manage'] == true)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: ElevatedButton.icon(
              onPressed: () async {
                final saved = await Navigator.push(context, MaterialPageRoute(builder: (_) => const ProjectFormPage()));
                if (saved == true) _load();
              },
              icon: const Icon(Icons.add_business_rounded),
              label: const Text('إضافة مشروع جديد', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              style: ElevatedButton.styleFrom(
                backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 54),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
            ),
          ),
        if (_loading)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
        else if (_items.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش مشاريع', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark))))
        else
          for (final p in _items) _projectCard(p, companyView),
      ]),
    );
  }

  Widget _projectCard(Map<String, dynamic> p, bool companyView) {
    final isDark = widget.isDark;
    final (stAr, stColor) = _statusChip(p['status']);
    return GestureDetector(
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => CommissionProjectPage(projectId: '${p['id']}')));
        _load();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: JphUi.box(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            JphUi.iconTile(isDark, Icons.apartment_rounded, Colors.indigo),
            const SizedBox(width: 12),
            Expanded(child: Text('${p['name']}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
            JphUi.chip(stAr, stColor),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (p['totalPct'] != null) _pill('الإجمالي ${JphUi.pct(p['totalPct'])}', Colors.blueGrey),
            _pill('البائع ${JphUi.pct(p['salesPct'])}', Colors.teal),
            if (p['managerPct'] != null) _pill('مدير المبيعات ${JphUi.pct(p['managerPct'])}', Colors.purple),
            if (p['companyPct'] != null) _pill('الشركة ${JphUi.pct(p['companyPct'])}', Colors.green),
          ]),
          if (p['units'] != null) ...[
            const SizedBox(height: 12),
            Divider(height: 1, color: isDark ? Colors.white24 : Colors.grey.shade200),
            const SizedBox(height: 10),
            Wrap(spacing: 18, runSpacing: 6, children: [
              _kv('وحدات', '${p['units']}'),
              _kv('المبيعات', JphUi.money(p['salesValue'])),
              if (companyView) _kv('إجمالي العمولة', JphUi.money(p['totalCommission'])),
              if (companyView) _kv('أرباح الشركة', JphUi.money(p['companyCommission'])),
              if (!companyView) _kv('عمولات البائعين', JphUi.money(p['salesCommission'])),
            ]),
          ],
        ]),
      ),
    );
  }

  Widget _pill(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(color: c.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
        child: Text(t, style: TextStyle(color: c, fontWeight: FontWeight.w800, fontSize: 12)),
      );

  Widget _kv(String k, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(k, style: TextStyle(fontSize: 11, color: JphUi.sub(widget.isDark), fontWeight: FontWeight.w600)),
        Text(v, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: JphUi.text(widget.isDark))),
      ]);
}

String? _statusAr(Object? s) => switch (s) { 'active' => 'شغال', 'paused' => 'متوقف مؤقتاً', 'closed' => 'مقفول', _ => null };
(String, Color) _statusChip(Object? s) => switch (s) {
      'paused' => ('متوقف مؤقتاً', Colors.orange),
      'closed' => ('مقفول', Colors.grey),
      _ => ('شغال', Colors.green),
    };

// ==================================================================== للاعتماد (المدير العام)
class _ApproveTab extends StatefulWidget {
  final bool isDark;
  const _ApproveTab({required this.isDark});

  @override
  State<_ApproveTab> createState() => _ApproveTabState();
}

class _ApproveTabState extends State<_ApproveTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'commission_requests', 'scope': 'pending'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = ((r['requests'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    });
  }

  Future<void> _approve(Map<String, dynamic> x) async {
    final isDark = widget.isDark;
    final now = DateTime.now();
    final months = [for (var i = -1; i <= 6; i++) DateTime(now.year, now.month + i)];
    final m = await JphUi.sheet<DateTime>(context, isDark, 'شهر نزول العمولة في المرتب',
        [for (final d in months) (d, '${JphUi.monthsAr[d.month - 1]} ${d.year}', Icons.event_rounded)]);
    if (m == null || !mounted) return;
    final month = '${m.year}-${m.month.toString().padLeft(2, '0')}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          title: const Text('تأكيد اعتماد العمولة', style: TextStyle(fontWeight: FontWeight.w900)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${x['projectName']} — وحدة ${x['unitNo']}'),
            const SizedBox(height: 6),
            Text('عمولة البائع: ${JphUi.money(x['salesAmount'])}'),
            if (x['managerAmount'] != null) Text('عمولة مدير المبيعات: ${JphUi.money(x['managerAmount'])}'),
            const SizedBox(height: 6),
            Text('تنزل في مرتب: ${JphUi.monthAr(month)}', style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('رجوع')),
            ElevatedButton(
              onPressed: () => Navigator.pop(c, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
              child: const Text('اعتماد'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _decide(x, {'decision': 'approve', 'month': month});
  }

  Future<void> _reject(Map<String, dynamic> x) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          title: const Text('سبب الرفض', style: TextStyle(fontWeight: FontWeight.w900)),
          content: TextField(controller: reason, maxLines: 3, decoration: const InputDecoration(hintText: 'اكتب السبب (إجباري)')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('رجوع')),
            ElevatedButton(
              onPressed: () => Navigator.pop(c, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
              child: const Text('رفض'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    if (reason.text.trim().length < 3) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لازم تكتب سبب الرفض'), backgroundColor: Colors.red));
      return;
    }
    await _decide(x, {'decision': 'reject', 'reason': reason.text.trim()});
  }

  Future<void> _decide(Map<String, dynamic> x, Map<String, dynamic> body) async {
    setState(() => _busy.add('${x['id']}'));
    final r = await ApiService.post({'action': 'commission_decide', 'id': x['id'], ...body});
    if (!mounted) return;
    _busy.remove('${x['id']}');
    JphUi.toast(context, r);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    if (_loading) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        if (_items.isEmpty)
          Padding(padding: const EdgeInsets.all(40), child: Text('مفيش طلبات عمولة مستنية الاعتماد', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final x in _items)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: JphUi.box(isDark),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                JphUi.iconTile(isDark, Icons.handshake_rounded, Colors.teal),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${x['employeeName']}', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text('طلب #${x['ref']} • ${JphUi.date(x['createdAt'])}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                  ]),
                ),
                JphUi.chip('مستني', Colors.orange),
              ]),
              const SizedBox(height: 12),
              _detailsGrid(isDark, x),
              if ('${x['note'] ?? ''}'.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('ملاحظة: ${x['note']}', style: TextStyle(color: JphUi.sub(isDark))),
              ],
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy.contains('${x['id']}') ? null : () => _reject(x),
                    icon: const Icon(Icons.close_rounded, color: Colors.red),
                    label: const Text('رفض', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w800)),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48),
                        side: const BorderSide(color: Colors.red), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: _busy.contains('${x['id']}') ? null : () => _approve(x),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('اعتماد', style: TextStyle(fontWeight: FontWeight.w800)),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white,
                        minimumSize: const Size(0, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  ),
                ),
              ]),
            ]),
          ),
      ]),
    );
  }
}

/// The figures of one deal as label / value pairs (company ones only arrive for those allowed).
Widget _detailsGrid(bool isDark, Map<String, dynamic> x) {
  final items = <(String, String)>[
    ('المشروع', '${x['projectName']}'),
    ('رقم الوحدة', '${x['unitNo']}'),
    ('سعر المتر', JphUi.money(x['pricePerM2'])),
    ('المساحة', '${x['areaM2']} م²'),
    ('قيمة الوحدة', JphUi.money(x['unitValue'])),
    ('البائع ${JphUi.pct(x['salesPct'])}', JphUi.money(x['salesAmount'])),
    if (x['managerAmount'] != null) ('مدير المبيعات ${JphUi.pct(x['managerPct'])}', JphUi.money(x['managerAmount'])),
    if (x['companyAmount'] != null) ('الشركة ${JphUi.pct(x['companyPct'])}', JphUi.money(x['companyAmount'])),
    if (x['totalAmount'] != null) ('إجمالي العمولة ${JphUi.pct(x['totalPct'])}', JphUi.money(x['totalAmount'])),
  ];
  return LayoutBuilder(builder: (context, c) {
    final w = c.maxWidth > 600 ? (c.maxWidth - 20) / 3 : (c.maxWidth - 10) / 2;
    return Wrap(spacing: 10, runSpacing: 10, children: [
      for (final it in items)
        Container(
          width: w,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withOpacity(0.06) : Colors.grey.shade50,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(it.$1, style: TextStyle(fontSize: 11, color: JphUi.sub(isDark), fontWeight: FontWeight.w600)),
            Text(it.$2, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
          ]),
        ),
    ]);
  });
}

// ==================================================================== الاستحقاقات (HR)
class _PayrollTab extends StatefulWidget {
  final bool isDark;
  const _PayrollTab({required this.isDark});

  @override
  State<_PayrollTab> createState() => _PayrollTabState();
}

class _PayrollTabState extends State<_PayrollTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];
  Map<String, dynamic> _totals = {};
  String _month = '';
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'commission_entitlements', 'scope': 'all', 'month': _month});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = ((r['entitlements'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
      _totals = ((r['totals'] as Map?) ?? const {}).cast<String, dynamic>();
    });
  }

  Future<void> _pay(Map<String, dynamic> e) async {
    setState(() => _busy.add('${e['id']}'));
    final r = await ApiService.post({
      'action': 'payout_create', 'employeeId': e['employeeId'], 'kind': 'commission', 'amount': e['amount'],
      'month': e['period'], 'entitlementId': e['id'], 'note': '${e['projectName']} — وحدة ${e['unitNo']}',
    });
    if (!mounted) return;
    _busy.remove('${e['id']}');
    JphUi.toast(context, r);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final canPay = ApiService.can('finance.disburse');
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        JphUi.picker(
          isDark: isDark, icon: Icons.calendar_month_rounded, iconColor: JphUi.primary(isDark), label: 'شهر المرتب',
          value: _month.isEmpty ? 'كل الشهور' : JphUi.monthAr(_month),
          onTap: () async {
            final now = DateTime.now();
            final v = await JphUi.sheet<String>(context, isDark, 'شهر المرتب', [
              ('', 'كل الشهور', Icons.all_inclusive_rounded),
              for (var i = -6; i <= 6; i++)
                (() {
                  final d = DateTime(now.year, now.month + i);
                  final k = '${d.year}-${d.month.toString().padLeft(2, '0')}';
                  return (k, JphUi.monthAr(k), Icons.event_rounded);
                })(),
            ]);
            if (v != null) {
              setState(() => _month = v);
              _load();
            }
          },
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: JphUi.stat(isDark, 'إجمالي العمولات في المرتبات', JphUi.money(_totals['amount']), Icons.payments_rounded, Colors.teal)),
          const SizedBox(width: 10),
          Expanded(child: JphUi.stat(isDark, 'لسه ماتصرفتش', JphUi.money(_totals['unpaid']), Icons.hourglass_bottom_rounded, Colors.orange)),
        ]),
        const SizedBox(height: 14),
        if (_loading)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
        else if (_items.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش عمولات معتمدة', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark))))
        else
          for (final e in _items)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: JphUi.box(isDark),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  JphUi.iconTile(isDark, e['role'] == 'manager' ? Icons.groups_rounded : Icons.person_rounded,
                      e['role'] == 'manager' ? Colors.purple : Colors.teal),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${e['employeeName']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                      Text('${e['role'] == 'manager' ? 'عمولة مدير مبيعات' : 'عمولة بائع'} • ${e['projectName']} • وحدة ${e['unitNo']}',
                          style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                    ]),
                  ),
                  Text(JphUi.money(e['amount']), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                ]),
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  JphUi.chip('مرتب ${JphUi.monthAr('${e['period']}')}', Colors.blue),
                  JphUi.chip(e['payrollIncluded'] == true ? 'داخلة في المرتب' : 'خارج المرتب', e['payrollIncluded'] == true ? Colors.indigo : Colors.grey),
                  JphUi.chip(paymentStatus('${e['payment']}').$1, paymentStatus('${e['payment']}').$2),
                  Text('اعتماد ${JphUi.date(e['approvedAt'])}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                ]),
                if (canPay && e['payment'] == 'unpaid' && e['status'] == 'active')
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: ElevatedButton.icon(
                        onPressed: _busy.contains('${e['id']}') ? null : () => _pay(e),
                        icon: const Icon(Icons.payments_rounded),
                        label: const Text('صرف العمولة'),
                        style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                      ),
                    ),
                  ),
              ]),
            ),
      ]),
    );
  }
}

// ==================================================================== عمولاتي
class _MineTab extends StatefulWidget {
  final bool isDark;
  const _MineTab({required this.isDark});

  @override
  State<_MineTab> createState() => _MineTabState();
}

class _MineTabState extends State<_MineTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _reqs = [];
  List<Map<String, dynamic>> _ents = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'commission_requests', 'scope': 'mine'});
    final e = await ApiService.post({'action': 'commission_entitlements', 'scope': 'mine'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _reqs = ((r['requests'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
      // entitlements from other people's deals (sales manager share) are listed too
      _ents = ((e['entitlements'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>())
          .where((x) => x['role'] == 'manager').toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    if (_loading) return const Center(child: CircularProgressIndicator());
    final approved = _reqs.where((x) => x['status'] == 'approved').fold<num>(0, (s, x) => s + ((x['salesAmount'] as num?) ?? 0));
    final mgr = _ents.where((x) => x['status'] == 'active').fold<num>(0, (s, x) => s + ((x['amount'] as num?) ?? 0));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        Row(children: [
          Expanded(child: JphUi.stat(isDark, 'عمولاتي المعتمدة', JphUi.money(approved), Icons.verified_rounded, Colors.green)),
          const SizedBox(width: 10),
          Expanded(child: JphUi.stat(isDark, 'طلبات مستنية', '${_reqs.where((x) => x['status'] == 'pending').length}', Icons.hourglass_top_rounded, Colors.orange)),
        ]),
        if (_ents.isNotEmpty) ...[
          const SizedBox(height: 10),
          JphUi.stat(isDark, 'عمولاتي كمدير مبيعات', JphUi.money(mgr), Icons.groups_rounded, Colors.purple),
        ],
        const SizedBox(height: 14),
        if (_reqs.isEmpty && _ents.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش طلبات عمولة لسه — اطلبها من صفحة المالية ← عمولة صفقة',
              textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final x in _reqs)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: JphUi.box(isDark),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                JphUi.iconTile(isDark, Icons.handshake_rounded, Colors.teal),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${x['projectName']} — وحدة ${x['unitNo']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text('طلب #${x['ref']} • ${JphUi.date(x['createdAt'])}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                  ]),
                ),
                JphUi.chip(commissionStatus('${x['status']}').$1, commissionStatus('${x['status']}').$2),
              ]),
              const SizedBox(height: 10),
              Wrap(spacing: 14, runSpacing: 6, children: [
                Text('قيمة الوحدة: ${JphUi.money(x['unitValue'])}', style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('عمولتك (${JphUi.pct(x['salesPct'])}): ${JphUi.money(x['salesAmount'])}', style: const TextStyle(fontWeight: FontWeight.w900)),
                if (x['period'] != null) Text('تنزل في مرتب ${JphUi.monthAr('${x['period']}')}', style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.blue)),
                for (final p in ((x['payroll'] as List?) ?? const []).whereType<Map>())
                  JphUi.chip(paymentStatus('${p['payment']}').$1, paymentStatus('${p['payment']}').$2),
              ]),
              if (x['status'] == 'rejected' && '${x['rejectReason'] ?? ''}'.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text('سبب الرفض: ${x['rejectReason']}', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w700))),
              if (x['status'] == 'voided' && '${x['voidReason'] ?? ''}'.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 8), child: Text('اتلغت: ${x['voidReason']}', style: TextStyle(color: JphUi.sub(isDark)))),
            ]),
          ),
        for (final e in _ents)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: JphUi.box(isDark),
            child: Row(children: [
              JphUi.iconTile(isDark, Icons.groups_rounded, Colors.purple),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('عمولة مدير مبيعات — ${e['projectName']} • وحدة ${e['unitNo']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                  Text('مرتب ${JphUi.monthAr('${e['period']}')} • ${paymentStatus('${e['payment']}').$1}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                ]),
              ),
              Text(JphUi.money(e['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            ]),
          ),
      ]),
    );
  }
}
