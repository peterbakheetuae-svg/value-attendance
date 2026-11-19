import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../../core/save_file.dart';
import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/swipe_tabs.dart';
import '../attendance/attendance_widgets.dart';
import '../cash/cash_page.dart';
import '../leads/leads_extra.dart' show writeXlsx;
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

/// تقفيل السنة — Finance → الأقساط → تقفيل السنة. A review / closing layer over the existing financial records
/// (GET/POST /closing/*): مراجعة وإقفال · التقرير السنوي · سجل السنوات. Every figure comes from the server; a figure the
/// system cannot give is shown as «غير متاح», never as zero. Nothing here creates or changes a financial transaction.
class YearClosingPage extends StatefulWidget {
  const YearClosingPage({super.key});

  /// the same permission the server asks for (cash.office)
  static bool get canOpen => ApiService.can('cash.office');

  @override
  State<YearClosingPage> createState() => _YearClosingPageState();
}

// ------------------------------------------------------------------ small helpers
Map<String, dynamic> _m(Object? v) => ((v as Map?) ?? const {}).cast<String, dynamic>();
List<Map<String, dynamic>> _l(Object? v) => ((v as List?) ?? const []).whereType<Map>().map((x) => x.cast<String, dynamic>()).toList();
num? _n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}');
/// «غير متاح» for a figure the system does not have — never 0
String _money(Object? v) => _n(v) == null ? 'غير متاح' : JphUi.money(v);

const _yearStatus = <String, (String, Color)>{
  'not_started': ('لم تبدأ', Ar.grey),
  'in_review': ('قيد المراجعة', Ar.info),
  'needs_attention': ('تحتاج انتباه', Ar.amber),
  'ready_for_approval': ('جاهزة للاعتماد', Ar.green),
  'approved': ('معتمدة', Ar.green),
  'closed': ('مقفولة', Ar.accent),
  'reopened': ('اتفتحت تاني', Ar.amber),
};
const _itemStatus = <String, (String, Color, IconData)>{
  'not_reviewed': ('لم يُراجع', Ar.grey, Icons.radio_button_unchecked_rounded),
  'reviewed': ('تمت المراجعة', Ar.green, Icons.check_circle_rounded),
  'needs_attention': ('محتاج انتباه', Ar.amber, Icons.error_outline_rounded),
  'blocking': ('مانع للتقفيل', Ar.red, Icons.block_rounded),
  'resolved': ('اتحل', Ar.green, Icons.task_alt_rounded),
  'exception': ('استثناء معتمد', Ar.info, Icons.verified_rounded),
};
const _severity = <String, (String, Color)>{
  'info': ('للعلم', Ar.info),
  'review': ('محتاج مراجعة', Ar.amber),
  'blocking': ('مانع للتقفيل', Ar.red),
};
const _issueStatus = <String, (String, Color)>{
  'open': ('مفتوحة', Ar.red),
  'resolved': ('اتحلت', Ar.green),
  'exception': ('استثناء معتمد', Ar.info),
};
const _recTypes = <String, String>{
  'treasury': 'خزنة', 'bank': 'بنك', 'employee': 'موظف', 'partner': 'شريك', 'project': 'مشروع',
  'receivable': 'مستحق للشركة', 'payable': 'مستحق على الشركة', 'asset': 'أصل / عهدة', 'other': 'أخرى',
};
const _recStatus = <String, (String, Color)>{
  'pending': ('مستنية اعتماد', Ar.amber), 'approved': ('معتمدة', Ar.green), 'rejected': ('مرفوضة', Ar.red),
};

Widget _card(bool isDark, List<Widget> children, {EdgeInsets? margin}) => Container(
      margin: margin ?? const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );

Widget _title(bool isDark, String t, {IconData? icon}) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        if (icon != null) ...[Icon(icon, size: 20, color: JphUi.primary(isDark)), const SizedBox(width: 6)],
        Expanded(child: Text(t, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
      ]),
    );

Widget _row(bool isDark, String label, String value, {Color? color, bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: Text(label, style: TextStyle(color: JphUi.sub(isDark), fontSize: 13.5))),
        const SizedBox(width: 8),
        Flexible(
          child: Text(value, textAlign: TextAlign.end,
              style: TextStyle(fontWeight: strong ? FontWeight.w900 : FontWeight.w700, color: color ?? JphUi.text(isDark), fontSize: 13.5)),
        ),
      ]),
    );

Widget _note(bool isDark, String t, {Color? color}) => Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (color ?? Ar.info).withOpacity(isDark ? 0.18 : 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: (color ?? Ar.info).withOpacity(0.4)),
      ),
      child: Text(t, style: TextStyle(color: JphUi.text(isDark), fontSize: 13)),
    );

Widget _empty(bool isDark, String t) =>
    Padding(padding: const EdgeInsets.all(24), child: Text(t, textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark))));

Widget _btn(bool isDark, String label, IconData icon, VoidCallback? onTap, {Color? color}) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color ?? JphUi.primary(isDark),
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );

Future<void> _push(BuildContext context, Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));

/// a sub page with the app's background and header
class _Sub extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? fab;
  const _Sub({required this.title, required this.child, this.fab});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    return AppBackground(
      child: Directionality(
        textDirection: app.isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: fab,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: app.isDark, isRTL: app.isRTL, title: title),
              Expanded(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1000), child: child))),
            ]),
          ),
        ),
      ),
    );
  }
}

// ==================================================================== the page
class _YearClosingPageState extends State<YearClosingPage> {
  Map<String, dynamic> _years = {};
  int? _year;
  Map<String, dynamic> _d = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final r = await cashGet('/closing/years');
    if (!mounted) return;
    final ys = cashList(r, 'years');
    final now = DateTime.now().year;
    // the last year that ended, else the current one
    final pick = ys.any((y) => _n(y['year']) == now - 1) ? now - 1 : (ys.isNotEmpty ? _n(ys.first['year'])?.toInt() : null);
    setState(() {
      _years = r;
      _year = pick;
    });
    await _load();
  }

  Future<void> _load() async {
    if (_year == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    final r = await cashGet('/closing/$_year');
    if (!mounted) return;
    setState(() {
      _d = r;
      _loading = false;
    });
  }

  Future<void> reload() async {
    final r = await cashGet('/closing/years');
    if (!mounted) return;
    setState(() => _years = r);
    await _load();
  }

  Future<void> _pickYear(bool isDark) async {
    final ys = cashList(_years, 'years');
    final v = await JphUi.sheet<int>(context, isDark, 'اختار السنة المالية', [
      for (final y in ys)
        (_n(y['year'])!.toInt(), '${y['year']} — ${(_yearStatus[y['status']] ?? ('', Ar.grey)).$1}', Icons.calendar_month_rounded),
    ], selected: _year);
    if (v != null && v != _year) {
      setState(() => _year = v);
      await _load();
    }
  }

  /// the tab shown (kept across reloads); [_jump] rebuilds the tabs when another year / tab is opened from the archive
  int _tab = 0, _jump = 0;

  Future<void> _open(int y, int tab) async {
    setState(() {
      _year = y;
      _tab = tab;
      _jump++;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      final ok = _d['success'] == true;
      final status = '${_d['status'] ?? 'not_started'}';
      final st = _yearStatus[status] ?? ('', Ar.grey);
      return AppBackground(
        child: Directionality(
          textDirection: app.isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                Header(onBack: () => Navigator.pop(context), onFilter: () => _pickYear(isDark), isRTL: app.isRTL, isDark: isDark, title: 'تقفيل السنة'),
                if (_year != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: GestureDetector(
                      onTap: () => _pickYear(isDark),
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.calendar_month_rounded, color: JphUi.primary(isDark), size: 20),
                        const SizedBox(width: 6),
                        Text('السنة المالية $_year', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                        const SizedBox(width: 8),
                        JphUi.chip(st.$1, st.$2),
                      ]),
                    ),
                  ),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : !ok
                          ? Center(child: Text('${_d['message'] ?? _years['message'] ?? 'مش متاح'}', style: TextStyle(color: JphUi.sub(isDark))))
                          : Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 1000),
                                child: SwipeTabs(
                                  key: ValueKey('tabs-$_jump'),
                                  isDark: isDark,
                                  initial: _tab,
                                  onChanged: (i) => _tab = i,
                                  tabs: const [
                                    ('مراجعة وإقفال', Icons.fact_check_rounded),
                                    ('التقرير السنوي', Icons.insights_rounded),
                                    ('سجل السنوات', Icons.inventory_2_rounded),
                                  ],
                                  pages: [
                                    _ReviewTab(isDark: isDark, d: _d, onChanged: reload),
                                    _ReportTab(isDark: isDark, d: _d),
                                    _ArchiveTab(isDark: isDark, years: _years, onOpen: _open),
                                  ],
                                ),
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

// ==================================================================== 1) مراجعة وإقفال
class _ReviewTab extends StatelessWidget {
  final bool isDark;
  final Map<String, dynamic> d;
  final Future<void> Function() onChanged;
  const _ReviewTab({required this.isDark, required this.d, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final f = _m(d['figures']);
    final s = _m(d['summary']);
    final can = _m(d['can']);
    final closing = d['closing'] == null ? null : _m(d['closing']);
    final status = '${d['status'] ?? 'not_started'}';
    final year = '${d['year']}';
    final installed = d['installed'] == true;
    final checklist = _l(d['checklist']);
    final issues = _l(d['issues']);
    final preview = _l(d['preview']);
    final recs = _l(d['reconciliations']);
    final closed = status == 'closed';
    return RefreshIndicator(
      onRefresh: onChanged,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 100), children: [
        if (!installed)
          _note(isDark, 'الأرقام والتقارير معروضة للقراءة. بدء المراجعة والتقفيل محتاجين تفعيل الموديول (migration 083) بعد موافقة المالك.', color: Ar.amber),
        // ------------------------------------------------ the year
        _card(isDark, [
          _title(isDark, 'السنة المالية $year', icon: Icons.calendar_month_rounded),
          _row(isDark, 'من', '${f['from'] ?? '$year-01-01'}'),
          _row(isDark, 'إلى', '${f['to'] ?? '$year-12-31'}'),
          _row(isDark, 'الحالة', (_yearStatus[status] ?? (status, Ar.grey)).$1, color: (_yearStatus[status] ?? ('', Ar.grey)).$2, strong: true),
          if (closing != null) ...[
            _row(isDark, 'الإصدار', '${closing['version']}'),
            _row(isDark, 'بدأ المراجعة', '${closing['started_by'] ?? '--'} • ${JphUi.date(closing['started_at'])}'),
            if (d['lastReview'] != null)
              _row(isDark, 'آخر مراجعة', '${_m(d['lastReview'])['by']} • ${JphUi.date(_m(d['lastReview'])['at'])}'),
            if (closing['approved_at'] != null) _row(isDark, 'اعتمدها', '${closing['approved_by'] ?? '--'} • ${JphUi.date(closing['approved_at'])}'),
            if (closing['closed_at'] != null) _row(isDark, 'تاريخ التقفيل', JphUi.date(closing['closed_at'])),
          ],
        ]),
        // ------------------------------------------------ the workflow summary
        if (closing != null) ...[
          JphUi.statGrid([
            JphUi.stat(isDark, 'بنود المراجعة', '${s['total'] ?? 0}', Icons.checklist_rounded, Ar.info),
            JphUi.stat(isDark, 'اتراجعت', '${s['done'] ?? 0}', Icons.check_circle_rounded, Ar.green),
            JphUi.stat(isDark, 'لسه متراجعتش', '${s['notReviewed'] ?? 0}', Icons.radio_button_unchecked_rounded, Ar.grey),
            JphUi.stat(isDark, 'محتاجة انتباه', '${s['attention'] ?? 0}', Icons.error_outline_rounded, Ar.amber),
            JphUi.stat(isDark, 'مشاكل مانعة', '${s['blockingIssues'] ?? 0}', Icons.block_rounded, Ar.red),
            JphUi.stat(isDark, 'تسويات مستنية', '${s['pendingReconciliations'] ?? 0}', Icons.balance_rounded, Ar.amber),
          ], phone: 3),
          const SizedBox(height: 10),
          _card(isDark, [
            Row(children: [
              Expanded(child: Text('نسبة الجاهزية للتقفيل', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
              Text('${s['readinessPct'] ?? 0}%', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.primary(isDark))),
            ]),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: ((_n(s['readinessPct']) ?? 0) / 100).clamp(0, 1).toDouble(), minHeight: 8, borderRadius: BorderRadius.circular(8)),
            const SizedBox(height: 6),
            Text('مؤشر لسير المراجعة بس — مش مقياس لدقة الحسابات.', style: TextStyle(fontSize: 11.5, color: JphUi.sub(isDark))),
          ]),
        ],
        // ------------------------------------------------ the money at a glance
        _OverviewCard(isDark: isDark, f: f),
        // ------------------------------------------------ actions
        if (closing == null && !closed) ...[
          if (preview.isNotEmpty)
            _note(isDark, 'السيستم لقى ${preview.length} ملاحظة على السنة دي (منها ${preview.where((x) => x['blocking'] == true).length} مانعة للتقفيل). هتظهر في «المشاكل» أول ما تبدأ المراجعة.',
                color: Ar.amber),
          if (can['review'] == true && installed)
            _btn(isDark, 'ابدأ مراجعة السنة', Icons.play_arrow_rounded, () async {
              final r = await cashPost('/closing/$year/start', {}, ok: 'بدأت المراجعة ✅');
              if (context.mounted) JphUi.toast(context, r);
              await onChanged();
            }),
        ],
        if (closing != null) ...[
          Row(children: [
            Expanded(
              child: _btn(isDark, 'المشاكل (${issues.where((x) => x['status'] == 'open').length})', Icons.report_problem_rounded,
                  () => _push(context, _IssuesPage(year: year, onChanged: onChanged)), color: Ar.red.shade400),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _btn(isDark, 'التسويات (${recs.length})', Icons.balance_rounded,
                  () => _push(context, _RecsPage(year: year, onChanged: onChanged)), color: Ar.info.shade600),
            ),
          ]),
          _btn(isDark, closed ? 'تفاصيل التقفيل' : 'الاعتماد النهائي والتقفيل', Icons.verified_rounded,
              () => _push(context, _ApprovalPage(year: year, onChanged: onChanged)), color: Ar.green.shade600),
        ],
        // ------------------------------------------------ the checklist
        if (closing != null) ...[
          const SizedBox(height: 6),
          _title(isDark, 'قائمة المراجعة', icon: Icons.fact_check_rounded),
          for (final c in checklist)
            Builder(builder: (context) {
              final items = _l(c['items']);
              final done = items.where((i) => ['reviewed', 'resolved', 'exception'].contains(i['status'])).length;
              final bad = items.any((i) => i['status'] == 'blocking' || i['status'] == 'needs_attention');
              final color = bad ? Ar.red : done == items.length ? Ar.green : Ar.amber;
              return GestureDetector(
                onTap: () => _push(context, _CategoryPage(year: year, category: '${c['key']}', onChanged: onChanged)),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(14),
                  decoration: JphUi.box(isDark),
                  child: Row(children: [
                    JphUi.iconTile(isDark, bad ? Icons.error_outline_rounded : done == items.length ? Icons.check_circle_rounded : Icons.pending_rounded, color),
                    const SizedBox(width: 12),
                    Expanded(child: Text('${c['label']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                    JphUi.chip('$done / ${items.length}', color),
                    const SizedBox(width: 6),
                    Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
                  ]),
                ),
              );
            }),
        ],
      ]),
    );
  }
}

/// the year's money at a glance (a figure the system does not have shows «غير متاح»)
class _OverviewCard extends StatelessWidget {
  final bool isDark;
  final Map<String, dynamic> f;
  const _OverviewCard({required this.isDark, required this.f});

  @override
  Widget build(BuildContext context) {
    final rev = _m(f['revenue']), exp = _m(f['expenses']), res = f['result'] == null ? null : _m(f['result']);
    final t = _m(f['treasury']), office = _m(t['office']), hr = _m(t['hr']);
    final rc = _m(_m(f['receivables'])['installments']);
    final emp = _m(f['employees']);
    final partners = _m(f['partners']);
    final commissions = rev['commissions'] ?? rev['commissionReceived'];
    return _card(isDark, [
      _title(isDark, 'نظرة مالية على السنة', icon: Icons.account_balance_rounded),
      _row(isDark, 'الإيرادات (عمولات المكتب)', _money(commissions), color: Ar.green),
      _row(isDark, 'المصروفات', _money(exp['total']), color: Ar.red),
      _row(isDark, 'نتيجة السنة (صافي المكتب)', res == null ? 'غير متاح' : _money(res['net']), strong: true),
      const Divider(),
      _row(isDark, 'المقبوضات النقدية', _money(_m(f['cashFlow'])['receipts'])),
      _row(isDark, 'المدفوعات النقدية', _money(_m(f['cashFlow'])['payments'])),
      _row(isDark, 'خزنة المكتب في 31/12', _money(office['closing'])),
      _row(isDark, 'خزنة المحاسب في 31/12', _money(hr['closing'])),
      _row(isDark, 'منها بنك (محسوب من الحركات)', _money((_n(office['bankPart']) ?? 0) + (_n(hr['bankPart']) ?? 0))),
      const Divider(),
      _row(isDark, 'مستحق للشركة (أقساط)', _money(rc['total'])),
      _row(isDark, 'مستحق على الشركة (عمولات موظفين)', _money(_m(f['payables'])['employeeCommissions'])),
      _row(isDark, 'سلف لسه هتتخصم', _money(_m(emp['advancesOutstanding'])['total'])),
      _row(isDark, 'أرصدة الشركاء', partners['available'] == true
          ? _money(_l(partners['list']).fold<num>(0, (s, p) => s + (_n(p['closing']) ?? _n(p['opening']) ?? 0)))
          : 'غير متاح'),
      _row(isDark, 'الأصول', 'سجل الأجهزة والعهد (بدون قيم)'),
    ]);
  }
}

// ------------------------------------------------------------------ a checklist category
class _CategoryPage extends StatefulWidget {
  final String year, category;
  final Future<void> Function() onChanged;
  const _CategoryPage({required this.year, required this.category, required this.onChanged});

  @override
  State<_CategoryPage> createState() => _CategoryPageState();
}

class _CategoryPageState extends State<_CategoryPage> {
  Map<String, dynamic> _d = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await cashGet('/closing/${widget.year}');
    if (!mounted) return;
    setState(() {
      _d = r;
      _loading = false;
    });
  }

  Future<void> _changed() async {
    await _load();
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final cat = _l(_d['checklist']).firstWhere((c) => c['key'] == widget.category, orElse: () => const {});
    final items = _l(cat['items']);
    final closed = _d['status'] == 'closed';
    final can = _m(_d['can']);
    final f = _m(_d['figures']);
    return _Sub(
      title: '${cat['label'] ?? 'المراجعة'}',
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 100), children: [
                _CategoryFigures(isDark: isDark, category: widget.category, f: f, year: widget.year),
                if (!closed && can['review'] == true && items.any((i) => i['status'] == 'not_reviewed' && i['verify'] != true))
                  _btn(isDark, 'تمت مراجعة كل البنود اللي لسه متراجعتش', Icons.done_all_rounded, () async {
                    final keys = [for (final i in items) if (i['status'] == 'not_reviewed' && i['verify'] != true) i['key']];
                    final r = await cashPost('/closing/${widget.year}/items', {'keys': keys, 'status': 'reviewed'}, ok: 'اتسجلت المراجعة ✅');
                    if (context.mounted) JphUi.toast(context, r);
                    await _changed();
                  }),
                for (final i in items)
                  GestureDetector(
                    onTap: closed || can['review'] != true ? null : () => _itemSheet(context, isDark, i, f),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(14),
                      decoration: JphUi.box(isDark),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Icon((_itemStatus[i['status']] ?? _itemStatus['not_reviewed']!).$3, color: (_itemStatus[i['status']] ?? _itemStatus['not_reviewed']!).$2),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${i['label']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                            Text((_itemStatus[i['status']] ?? _itemStatus['not_reviewed']!).$1,
                                style: TextStyle(fontSize: 12, color: (_itemStatus[i['status']] ?? _itemStatus['not_reviewed']!).$2)),
                            if (i['verifiedAmount'] != null) Text('الرصيد الفعلي: ${JphUi.money(i['verifiedAmount'])}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                            if ('${i['note'] ?? ''}'.isNotEmpty) Text('${i['note']}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                            if (i['reviewer'] != null)
                              Text('${i['reviewer']} • ${JphUi.date(i['reviewedAt'])}', style: TextStyle(fontSize: 11, color: JphUi.sub(isDark))),
                          ]),
                        ),
                      ]),
                    ),
                  ),
              ]),
            ),
    );
  }

  Future<void> _itemSheet(BuildContext context, bool isDark, Map<String, dynamic> i, Map<String, dynamic> f) async {
    var status = '${i['status']}' == 'not_reviewed' ? 'reviewed' : '${i['status']}';
    final note = TextEditingController(text: '${i['note'] ?? ''}');
    final amount = TextEditingController(text: i['verifiedAmount'] == null ? '' : '${i['verifiedAmount']}');
    final verify = i['verify'] == true;
    final box = '${i['key']}' == 'treasury.office_count' ? 'office' : 'hr';
    final sys = _m(_m(f['treasury'])[box])['closing'];
    final owner = _m(_d['can'])['owner'] == true;
    await cashFormSheet(context, isDark, '${i['label']}', (setS) {
      final va = num.tryParse(amount.text.trim().replaceAll(',', ''));
      final diff = verify && va != null && _n(sys) != null ? va - _n(sys)! : null;
      return [
        cashSegmented(isDark, {
          'reviewed': 'تمت',
          'needs_attention': 'انتباه',
          'blocking': 'مانع',
          'resolved': 'اتحل',
          if (owner) 'exception': 'استثناء',
        }, status, (v) => setS(() => status = v)),
        const SizedBox(height: 10),
        if (verify) ...[
          JphUi.readOnly(isDark: isDark, label: 'رصيد السيستم في 31/12', value: _money(sys), icon: Icons.calculate_rounded, color: Ar.info),
          const SizedBox(height: 8),
          JphUi.input(isDark: isDark, label: 'الرصيد الفعلي بعد الجرد', controller: amount, number: true, onChanged: (_) => setS(() {})),
          if (diff != null && diff.abs() >= 0.01)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('الفرق: ${JphUi.money(diff)} — اكتب السبب، وفسّره بتسوية لو هيتقبل', style: TextStyle(color: Ar.red, fontWeight: FontWeight.w700)),
            ),
          const SizedBox(height: 8),
        ],
        JphUi.input(isDark: isDark, label: 'ملاحظة المراجعة', controller: note, big: false),
        const SizedBox(height: 6),
        Text('الملاحظة مطلوبة لأي بند عليه فرق أو انتباه أو استثناء. القرار بيتسجل باسمك في سجل التقفيل.',
            style: TextStyle(fontSize: 11.5, color: JphUi.sub(isDark))),
      ];
    }, () async {
      final r = await cashPost('/closing/${widget.year}/items', {
        'key': i['key'],
        'status': status,
        'note': note.text.trim(),
        if (verify && amount.text.trim().isNotEmpty) 'verifiedAmount': num.tryParse(amount.text.trim().replaceAll(',', '')),
      }, ok: 'اتسجل ✅');
      if (r['success'] == true) await _changed();
      return r;
    });
  }
}

/// the figures behind a category (from the server) + a way to the source records
class _CategoryFigures extends StatelessWidget {
  final bool isDark;
  final String category, year;
  final Map<String, dynamic> f;
  const _CategoryFigures({required this.isDark, required this.category, required this.f, required this.year});

  @override
  Widget build(BuildContext context) {
    final t = _m(f['treasury']);
    final src = <(String, String)>[];
    final rows = <Widget>[];
    switch (category) {
      case 'treasury':
        for (final b in ['office', 'hr']) {
          final x = _m(t[b]);
          rows.addAll([
            Text(b == 'office' ? 'خزنة المكتب' : 'خزنة المحاسب', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            _row(isDark, 'رصيد أول السنة', _money(x['opening'])),
            _row(isDark, 'المقبوضات', _money(x['receipts']), color: Ar.green),
            _row(isDark, 'المدفوعات', _money(x['payments']), color: Ar.red),
            _row(isDark, 'تحويلات واردة', _money(x['transfersIn'])),
            _row(isDark, 'تحويلات صادرة', _money(x['transfersOut'])),
            _row(isDark, 'تسويات وأرصدة افتتاحية', _money(x['adjustments'])),
            _row(isDark, 'رصيد السيستم في 31/12', _money(x['closing']), strong: true),
            const Divider(),
          ]);
        }
        src.addAll([('ledger', 'كل حركات الخزن'), ('transfers', 'التحويلات')]);
      case 'bank':
        for (final b in ['office', 'hr']) {
          final x = _m(t[b]);
          rows.addAll([
            _row(isDark, b == 'office' ? 'بنك خزنة المكتب في 31/12' : 'بنك خزنة المحاسب في 31/12', _money(x['bankPart']), strong: true),
            _row(isDark, 'إيداع من النقدي للبنك', _money(_m(x['bankMoves'])['toBank'])),
            _row(isDark, 'سحب من البنك للنقدي', _money(_m(x['bankMoves'])['toCash'])),
          ]);
        }
        rows.add(_note(isDark, 'مطابقة البنك بالكشف غير متاحة في السيستم (مفيش كشوف حساب متسجلة) — راجعها يدوي وسجّل أي فرق كتسوية.'));
        src.add(('receipts', 'التحصيلات (فيها طريقة الدفع)'));
      case 'revenue':
        final rev = _m(f['revenue']);
        final sales = _m(rev['sales']);
        rows.addAll([
          _row(isDark, 'عمولات المكتب', _money(rev['commissions'] ?? rev['commissionReceived']), strong: true),
          _row(isDark, 'عمولات مستلمة', _money(rev['commissionReceived'])),
          _row(isDark, 'مبيعات (حجز/مقدم/أقساط) — مش إيراد للمكتب', _money(sales['total'])),
          _row(isDark, 'ضخ من الملاك — مش إيراد', _money(rev['injection'])),
          _row(isDark, 'تحصيلات أخرى', _money(rev['other'])),
        ]);
        src.add(('receipts', 'كل التحصيلات'));
      case 'expenses':
        final exp = _m(f['expenses']);
        rows.addAll([
          _row(isDark, 'إجمالي المصروفات', _money(exp['total']), strong: true),
          _row(isDark, 'المرتبات والصرف للموظفين', _money(exp['payrollTotal'])),
          _row(isDark, 'مصروفات ثابتة', _money(exp['fixed'])),
          _row(isDark, 'مصروفات متغيرة', _money(exp['variable'])),
          _row(isDark, 'مسحوبات الملاك — مش مصروف', _money(exp['ownerDraws'])),
          for (final c in _l(exp['byCategory'])) _row(isDark, '• ${c['name']} (${c['count']})', _money(c['amount'])),
        ]);
        src.addAll([('expenses', 'كل المصروفات'), ('payouts', 'الصرف للموظفين')]);
      case 'employees':
        final e = _m(f['employees']);
        final paid = _m(e['paid']);
        rows.addAll([
          _row(isDark, 'مرتبات مصروفة', _money(paid['salary'])),
          _row(isDark, 'عمولات مصروفة', _money(paid['commission'])),
          _row(isDark, 'سلف مصروفة', _money(paid['advance'])),
          _row(isDark, 'مصاريف عمل', _money(paid['workExpense'])),
          _row(isDark, 'أقساط سلف اتخصمت', _money(_m(e['advanceRepayments'])['total'])),
          _row(isDark, 'جزاءات معتمدة', _money(_m(e['adjustments'])['deductions'])),
          _row(isDark, 'علاوات معتمدة', _money(_m(e['adjustments'])['bonuses'])),
          _row(isDark, 'سلف لسه هتتخصم', _money(_m(e['advancesOutstanding'])['total']), strong: true),
          _row(isDark, 'عمولات مستحقة متصرفتش', _money(_m(e['commissionsUnpaid'])['total']), strong: true),
          _row(isDark, 'مرتبات مستحقة متصرفتش', 'غير متاح كرقم سنوي'),
        ]);
        src.add(('payouts', 'الصرف للموظفين'));
      case 'obligations':
        final rc = _m(_m(f['receivables'])['installments']);
        rows.addAll([
          _row(isDark, 'أقساط مستحقة للشركة', _money(rc['total']), strong: true),
          _row(isDark, 'منها متأخر في 31/12', '${_money(rc['overdue'])} (${rc['overdueCount'] ?? 0})'),
          _row(isDark, 'لسه مجاش ميعاده', _money(rc['notDue'])),
          _row(isDark, 'مسدد جزئياً', '${rc['partial'] ?? 0} قسط'),
          _row(isDark, 'عمولات المطورين المتبقية (النهارده)', _money(_m(_m(f['receivables'])['developerCommissions'])['remaining'])),
          _row(isDark, 'مستحق على الشركة: عمولات', _money(_m(f['payables'])['employeeCommissions'])),
          _row(isDark, 'صرف متأكدش استلامه', _money(_m(f['payables'])['payoutsNotReceived'])),
          _row(isDark, 'أموال الملاك (الأمانات) — النهارده', _money(_m(_m(f['payables'])['ownersTrust'])['total'])),
        ]);
      case 'projects':
        for (final p in _l(_m(_m(f['projects'])['commissions'])['byProject']))
          rows.add(_row(isDark, '${p['name']}', 'مستحق ${_money(p['due'])} • اتحصل ${_money(p['collected'])}'));
        for (final p in _l(_m(_m(f['projects'])['box'])['projects']))
          rows.add(_row(isDark, 'أمانة: ${p['name']}', _money(p['inTrust'])));
        if (rows.isEmpty) rows.add(_empty(isDark, 'مفيش حركات مشاريع في السنة دي'));
      case 'partners':
      case 'profit':
        rows.add(_PartnersView(isDark: isDark, f: f));
      case 'assets':
        final a = _m(f['assets']);
        for (final c in _l(a['custody']))
          rows.add(_row(isDark, 'عهدة: ${c['type']}', 'معاهم ${c['held']} • اتسلّم ${c['assigned']} • رجع ${c['returned']} • مفقود ${c['lost']}'));
        for (final x in _l(a['devices'])) rows.add(_row(isDark, 'جهاز ${x['type']} (${x['status']})', '${x['count']} (اتضاف ${x['added']})'));
        rows.add(_note(isDark, 'مفيش سجل أصول ثابتة بقيم شراء أو إهلاك في السيستم: القيم والإهلاك غير متاحة.'));
      default:
        src.addAll([('ledger', 'كل حركات الخزن'), ('expenses', 'المصروفات'), ('payouts', 'الصرف')]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (rows.isNotEmpty) _card(isDark, rows),
      if (src.isNotEmpty)
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final s in src)
            ActionChip(
              avatar: const Icon(Icons.list_alt_rounded, size: 18),
              label: Text(s.$2),
              onPressed: () => _push(context, _TransactionsPage(year: year, kind: s.$1, title: s.$2)),
            ),
        ]),
      const SizedBox(height: 12),
    ]);
  }
}

class _PartnersView extends StatelessWidget {
  final bool isDark;
  final Map<String, dynamic> f;
  const _PartnersView({required this.isDark, required this.f});

  @override
  Widget build(BuildContext context) {
    final p = _m(f['partners']);
    final pr = _m(f['profit']);
    if (p['available'] != true) return _empty(isDark, 'حسابات الشركاء محتاجة صلاحية «ضخ وسحب أموال الملاك»');
    final reason = '${pr['reason'] ?? ''}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _row(isDark, 'نتيجة السنة (صافي المكتب)', _money(pr['result']), strong: true),
      _row(isDark, 'القابل للتوزيع', pr['available'] == true ? _money(pr['distributable']) : 'غير متاح'),
      _row(isDark, 'محتجز في الشركة', pr['available'] == true ? _money(pr['retained']) : 'غير متاح'),
      if (_n(pr['loss']) != null && _n(pr['loss'])! > 0) _row(isDark, 'خسارة السنة', _money(pr['loss']), color: Ar.red),
      _row(isDark, 'مجموع نسب الملكية', '${p['pctTotal']}%'),
      if (reason == 'no_rules') _note(isDark, 'مفيش نسب ملكية متسجلة — التوزيع مش هيتحسب (السيستم مبيفترضش تقسيم بالتساوي).', color: Ar.amber),
      if (reason == 'pct_over_100') _note(isDark, 'مجموع النسب أكتر من 100% — صحّحها من «نسب الملاك» قبل التقفيل.', color: Ar.red),
      if (reason == 'permission') _note(isDark, 'نتيجة السنة محتاجة صلاحية «دخل وربح المكتب».'),
      _note(isDark, 'أساس التوزيع: ${pr['basis'] ?? 'نسب الملكية الحالية'}. التوزيع المعتمد مش معناه إنه اتصرف — الصرف حركة لوحدها من الخزنة.'),
      for (final x in _l(p['list']))
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: JphUi.box(isDark),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${x['name']} — ${x['pct']}%', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            _row(isDark, 'رصيد أول السنة', '${_money(x['opening'])}${x['openingSource'] == 'closing' ? ' (مرحّل من التقفيل)' : ' (من الحركات — مفيش تقفيل سابق)'}'),
            _row(isDark, 'ضخ خلال السنة', _money(x['contributions'])),
            _row(isDark, 'مسحوبات خلال السنة', _money(x['withdrawals'])),
            if ((_n(x['pendingWithdrawals']) ?? 0) > 0) _row(isDark, 'مسحوبات مستنية اعتماد', _money(x['pendingWithdrawals']), color: Ar.amber),
            _row(isDark, 'نصيبه من ربح السنة', _money(x['allocated'])),
            _row(isDark, 'أرباح لسه متصرفتش', _money(x['outstandingDistribution'])),
            _row(isDark, 'رصيده في 31/12', _money(x['closing']), strong: true),
          ]),
        ),
    ]);
  }
}

// ------------------------------------------------------------------ the source records (paged)
class _TransactionsPage extends StatefulWidget {
  final String year, kind, title;
  const _TransactionsPage({required this.year, required this.kind, required this.title});

  @override
  State<_TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<_TransactionsPage> {
  final _rows = <Map<String, dynamic>>[];
  int? _next = 0;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _more();
  }

  Future<void> _more() async {
    if (_next == null || _loading) return;
    setState(() => _loading = true);
    final r = await cashGet('/closing/${widget.year}/transactions', {'kind': widget.kind, 'offset': '$_next'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _rows.addAll(cashList(r, 'rows'));
      _next = r['success'] == true ? _n(r['next'])?.toInt() : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    return _Sub(
      title: widget.title,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 60), children: [
        if (!_loading && _rows.isEmpty) _empty(isDark, 'مفيش حركات'),
        for (final x in _rows)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.all(12),
            decoration: JphUi.box(isDark),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${x['refNo'] != null ? '#${x['refNo']} • ' : ''}${x['label'] ?? ''}',
                      maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                  Text('${x['type'] ?? ''}${x['cashbox'] != null ? ' • ${x['cashbox'] == 'office' ? 'المكتب' : 'المحاسب'}' : ''}'
                      '${x['status'] != null ? ' • ${x['status']}' : ''} • ${JphUi.date(x['at'])}',
                      style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                ]),
              ),
              Text(JphUi.money(x['amount']),
                  style: TextStyle(fontWeight: FontWeight.w900, color: (_n(x['amount']) ?? 0) < 0 ? Ar.red : JphUi.text(isDark))),
            ]),
          ),
        if (_loading) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _next != null) TextButton(onPressed: _more, child: const Text('اعرض أكتر')),
      ]),
    );
  }
}

// ------------------------------------------------------------------ issues
class _IssuesPage extends StatefulWidget {
  final String year;
  final Future<void> Function() onChanged;
  const _IssuesPage({required this.year, required this.onChanged});

  @override
  State<_IssuesPage> createState() => _IssuesPageState();
}

class _IssuesPageState extends State<_IssuesPage> {
  Map<String, dynamic> _d = {};
  bool _loading = true;
  String _filter = 'open';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await cashGet('/closing/${widget.year}');
    if (!mounted) return;
    setState(() {
      _d = r;
      _loading = false;
    });
  }

  Future<void> _changed() async {
    await _load();
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final all = _l(_d['issues']);
    final list = _filter == 'open' ? all.where((x) => x['status'] == 'open').toList() : all;
    final closed = _d['status'] == 'closed';
    final can = _m(_d['can']);
    return _Sub(
      title: 'المشاكل والفروق',
      fab: closed || can['review'] != true
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _raise(context, isDark),
              icon: const Icon(Icons.add_rounded),
              label: const Text('سجّل مشكلة'),
            ),
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 100), children: [
                cashSegmented(isDark, {'open': 'المفتوحة', 'all': 'الكل (بالتاريخ)'}, _filter, (v) => setState(() => _filter = v)),
                const SizedBox(height: 10),
                if (list.isEmpty) _empty(isDark, _filter == 'open' ? 'مفيش مشاكل مفتوحة' : 'مفيش مشاكل'),
                for (final x in list)
                  GestureDetector(
                    onTap: closed || can['review'] != true ? null : () => _act(context, isDark, x),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(14),
                      decoration: JphUi.box(isDark),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Text('#${x['refNo']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.sub(isDark))),
                          const SizedBox(width: 8),
                          JphUi.chip((_severity[x['severity']] ?? ('', Ar.grey)).$1, (_severity[x['severity']] ?? ('', Ar.grey)).$2),
                          const SizedBox(width: 6),
                          JphUi.chip((_issueStatus[x['status']] ?? ('', Ar.grey)).$1, (_issueStatus[x['status']] ?? ('', Ar.grey)).$2),
                          const Spacer(),
                          if (x['amount'] != null) Text(JphUi.money(x['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                        ]),
                        const SizedBox(height: 6),
                        Text('${x['description']}', style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
                        Text('المصدر: ${x['source']} • اكتشفها ${x['detectedBy']} • ${JphUi.date(x['detectedAt'])}',
                            style: TextStyle(fontSize: 11.5, color: JphUi.sub(isDark))),
                        if ('${x['resolutionNote'] ?? ''}'.isNotEmpty)
                          Text('الحل: ${x['resolutionNote']}${x['resolvedBy'] != null ? ' — ${x['resolvedBy']}' : ''}${x['exceptionBy'] != null ? ' — اعتمدها ${x['exceptionBy']}' : ''}',
                              style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                      ]),
                    ),
                  ),
              ]),
            ),
    );
  }

  Future<void> _act(BuildContext context, bool isDark, Map<String, dynamic> x) async {
    final can = _m(_d['can']);
    final open = x['status'] == 'open';
    final system = x['detectedBy'] == 'السيستم';
    final mayExcept = open && (x['severity'] == 'blocking' ? can['owner'] == true : can['decide'] == true);
    var action = 'note';
    final note = TextEditingController(text: '${x['resolutionNote'] ?? ''}');
    final ref = TextEditingController(text: '${x['resolutionRef'] ?? ''}');
    await cashFormSheet(context, isDark, 'مشكلة #${x['refNo']}', (setS) => [
          Text('${x['description']}', style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
          const SizedBox(height: 10),
          cashSegmented(isDark, {
            'note': 'ملاحظة',
            if (open && !system) 'resolve': 'اتحلت',
            if (mayExcept) 'exception': 'استثناء',
            if (!open) 'reopen': 'افتحها تاني',
          }, action, (v) => setS(() => action = v)),
          const SizedBox(height: 10),
          if (system && open)
            _note(isDark, 'المشكلة دي بيكتشفها السيستم من الحركة نفسها: بتتحل لوحدها أول ما الحركة تتصحح في نظامها (اعتماد / عكس / استلام)، أو تتعتمد كاستثناء بسبب.'),
          JphUi.input(isDark: isDark, label: 'الملاحظة / السبب', controller: note, big: false),
          const SizedBox(height: 8),
          JphUi.input(isDark: isDark, label: 'مرجع الحل (رقم حركة أو مستند) — اختياري', controller: ref, big: false),
        ], () async {
      final r = await cashPost('/closing/issues/${x['id']}', {'action': action, 'note': note.text.trim(), if (ref.text.trim().isNotEmpty) 'ref': ref.text.trim()},
          ok: 'اتسجل ✅');
      if (r['success'] == true) await _changed();
      return r;
    });
  }

  Future<void> _raise(BuildContext context, bool isDark) async {
    var category = 'treasury', severity = 'review';
    final desc = TextEditingController(), amount = TextEditingController(), sourceId = TextEditingController();
    await cashFormSheet(context, isDark, 'تسجيل مشكلة', (setS) => [
          DropdownButtonFormField<String>(
            value: category,
            decoration: const InputDecoration(labelText: 'القسم'),
            items: const [
              DropdownMenuItem(value: 'treasury', child: Text('الخزنة')),
              DropdownMenuItem(value: 'bank', child: Text('البنك')),
              DropdownMenuItem(value: 'revenue', child: Text('الإيرادات')),
              DropdownMenuItem(value: 'expenses', child: Text('المصروفات')),
              DropdownMenuItem(value: 'employees', child: Text('الموظفين')),
              DropdownMenuItem(value: 'obligations', child: Text('المستحقات')),
              DropdownMenuItem(value: 'projects', child: Text('المشاريع')),
              DropdownMenuItem(value: 'partners', child: Text('الشركاء')),
              DropdownMenuItem(value: 'assets', child: Text('الأصول والعهد')),
              DropdownMenuItem(value: 'other', child: Text('أخرى')),
            ],
            onChanged: (v) => setS(() => category = v ?? category),
          ),
          const SizedBox(height: 10),
          cashSegmented(isDark, {'info': 'للعلم', 'review': 'محتاجة مراجعة', 'blocking': 'مانعة'}, severity, (v) => setS(() => severity = v)),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'الوصف', controller: desc, big: false),
          const SizedBox(height: 8),
          JphUi.input(isDark: isDark, label: 'المبلغ (اختياري)', controller: amount, number: true),
          const SizedBox(height: 8),
          JphUi.input(isDark: isDark, label: 'رقم الحركة المرتبطة (اختياري)', controller: sourceId, big: false),
        ], () async {
      final r = await cashPost('/closing/${widget.year}/issues', {
        'category': category,
        'severity': severity,
        'description': desc.text.trim(),
        if (amount.text.trim().isNotEmpty) 'amount': num.tryParse(amount.text.trim().replaceAll(',', '')),
        if (sourceId.text.trim().isNotEmpty) 'sourceId': sourceId.text.trim(),
      }, ok: 'اتسجلت المشكلة ✅');
      if (r['success'] == true) await _changed();
      return r;
    });
  }
}

// ------------------------------------------------------------------ reconciliations
class _RecsPage extends StatefulWidget {
  final String year;
  final Future<void> Function() onChanged;
  const _RecsPage({required this.year, required this.onChanged});

  @override
  State<_RecsPage> createState() => _RecsPageState();
}

class _RecsPageState extends State<_RecsPage> {
  Map<String, dynamic> _d = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await cashGet('/closing/${widget.year}');
    if (!mounted) return;
    setState(() {
      _d = r;
      _loading = false;
    });
  }

  Future<void> _changed() async {
    await _load();
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final list = _l(_d['reconciliations']);
    final closed = _d['status'] == 'closed';
    final can = _m(_d['can']);
    return _Sub(
      title: 'التسويات',
      fab: closed || can['review'] != true
          ? null
          : FloatingActionButton.extended(onPressed: () => _add(context, isDark), icon: const Icon(Icons.add_rounded), label: const Text('تسوية جديدة')),
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 100), children: [
                _note(isDark, 'التسوية بتشرح فرق وبتتربط بمصدره — مبتغيرش أي حركة ولا رصيد. لو محتاج تصحيح فعلي، اعمله من الخزنة بالطريقة العادية.'),
                if (list.isEmpty) _empty(isDark, 'مفيش تسويات'),
                for (final x in list)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(14),
                    decoration: JphUi.box(isDark),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        Text('#${x['refNo']} • ${_recTypes[x['type']] ?? x['type']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                        const SizedBox(width: 8),
                        JphUi.chip((_recStatus[x['status']] ?? ('', Ar.grey)).$1, (_recStatus[x['status']] ?? ('', Ar.grey)).$2),
                        const Spacer(),
                        Text(JphUi.money(x['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                      ]),
                      const SizedBox(height: 4),
                      Text('${x['reason']}', style: TextStyle(color: JphUi.text(isDark))),
                      Text('المصدر: ${x['source']}${x['sourceId'] != null ? ' / ${x['sourceId']}' : ''} • ${x['createdBy']} • ${JphUi.date(x['createdAt'])}',
                          style: TextStyle(fontSize: 11.5, color: JphUi.sub(isDark))),
                      if (x['decidedBy'] != null)
                        Text('القرار: ${x['decidedBy']} • ${JphUi.date(x['decidedAt'])}${'${x['decisionNote'] ?? ''}'.isNotEmpty ? ' — ${x['decisionNote']}' : ''}',
                            style: TextStyle(fontSize: 11.5, color: JphUi.sub(isDark))),
                      if (x['canDecide'] == true)
                        Row(children: [
                          Expanded(child: TextButton(onPressed: () => _decide(context, isDark, x, 'approve'), child: const Text('اعتماد'))),
                          Expanded(child: TextButton(onPressed: () => _decide(context, isDark, x, 'reject'), child: Text('رفض', style: TextStyle(color: Ar.red)))),
                        ]),
                    ]),
                  ),
              ]),
            ),
    );
  }

  Future<void> _decide(BuildContext context, bool isDark, Map<String, dynamic> x, String decision) async {
    final note = TextEditingController();
    await cashFormSheet(context, isDark, decision == 'approve' ? 'اعتماد التسوية' : 'رفض التسوية', (setS) => [
          JphUi.input(isDark: isDark, label: decision == 'approve' ? 'ملاحظة (اختياري)' : 'سبب الرفض', controller: note, big: false),
        ], () async {
      final r = await cashPost('/closing/reconciliations/${x['id']}/decision', {'decision': decision, 'note': note.text.trim()}, ok: 'اتسجل القرار ✅');
      if (r['success'] == true) await _changed();
      return r;
    });
  }

  Future<void> _add(BuildContext context, bool isDark) async {
    var type = 'treasury', box = 'hr', sign = 'minus';
    final amount = TextEditingController(), reason = TextEditingController(), notes = TextEditingController(), source = TextEditingController(), sid = TextEditingController();
    await cashFormSheet(context, isDark, 'تسوية جديدة', (setS) => [
          DropdownButtonFormField<String>(
            value: type,
            decoration: const InputDecoration(labelText: 'نوع التسوية'),
            items: [for (final e in _recTypes.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setS(() => type = v ?? type),
          ),
          const SizedBox(height: 10),
          if (type == 'treasury') ...[
            cashSegmented(isDark, {'office': 'خزنة المكتب', 'hr': 'خزنة المحاسب'}, box, (v) => setS(() => box = v)),
            const SizedBox(height: 10),
          ] else ...[
            JphUi.input(isDark: isDark, label: 'المصدر (مثلاً: cash_expenses)', controller: source, big: false),
            const SizedBox(height: 8),
            JphUi.input(isDark: isDark, label: 'رقم السجل المرتبط (اختياري)', controller: sid, big: false),
            const SizedBox(height: 10),
          ],
          cashSegmented(isDark, {'minus': 'عجز (الفعلي أقل)', 'plus': 'زيادة (الفعلي أكتر)'}, sign, (v) => setS(() => sign = v)),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'المبلغ', controller: amount, number: true),
          const SizedBox(height: 8),
          JphUi.input(isDark: isDark, label: 'السبب', controller: reason, big: false),
          const SizedBox(height: 8),
          JphUi.input(isDark: isDark, label: 'ملاحظات (اختياري)', controller: notes, big: false),
        ], () async {
      final a = num.tryParse(amount.text.trim().replaceAll(',', ''));
      if (a == null || a <= 0) return {'success': false, 'message': 'اكتب المبلغ'};
      final r = await cashPost('/closing/${widget.year}/reconciliations', {
        'type': type,
        'source': type == 'treasury' ? 'cash_ledger' : (source.text.trim().isEmpty ? 'manual' : source.text.trim()),
        if (type == 'treasury') 'sourceId': box else if (sid.text.trim().isNotEmpty) 'sourceId': sid.text.trim(),
        'amount': sign == 'minus' ? -a : a,
        'reason': reason.text.trim(),
        'notes': notes.text.trim(),
      }, ok: 'اتسجلت التسوية — مستنية اعتماد ✅');
      if (r['success'] == true) await _changed();
      return r;
    });
  }
}

// ------------------------------------------------------------------ final approval / closing / reopening
class _ApprovalPage extends StatefulWidget {
  final String year;
  final Future<void> Function() onChanged;
  const _ApprovalPage({required this.year, required this.onChanged});

  @override
  State<_ApprovalPage> createState() => _ApprovalPageState();
}

class _ApprovalPageState extends State<_ApprovalPage> {
  Map<String, dynamic> _d = {};
  Map<String, dynamic> _ob = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await cashGet('/closing/${widget.year}');
    final ob = await cashGet('/closing/${widget.year}/opening-balances');
    if (!mounted) return;
    setState(() {
      _d = r;
      _ob = ob;
      _loading = false;
    });
  }

  Future<void> _changed() async {
    await _load();
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final y = widget.year;
    final status = '${_d['status'] ?? ''}';
    final s = _m(_d['summary']);
    final blockers = _l(_d['blockers']);
    final can = _m(_d['can']);
    final f = _m(_d['figures']);
    final issues = _l(_d['issues']);
    final recs = _l(_d['reconciliations']);
    final closing = _m(_d['closing']);
    return _Sub(
      title: status == 'closed' ? 'تفاصيل التقفيل' : 'الاعتماد النهائي',
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 100), children: [
              _card(isDark, [
                _title(isDark, 'السنة المالية $y', icon: Icons.verified_rounded),
                _row(isDark, 'الحالة', (_yearStatus[status] ?? (status, Ar.grey)).$1, color: (_yearStatus[status] ?? ('', Ar.grey)).$2, strong: true),
                _row(isDark, 'قائمة المراجعة', '${s['done'] ?? 0} من ${s['total'] ?? 0}'),
                _row(isDark, 'مشاكل مانعة مفتوحة', '${s['blockingIssues'] ?? 0}', color: (_n(s['blockingIssues']) ?? 0) > 0 ? Ar.red : null),
                _row(isDark, 'ملاحظات مفتوحة', '${s['reviewIssues'] ?? 0}'),
                _row(isDark, 'استثناءات معتمدة', '${issues.where((x) => x['status'] == 'exception').length}'),
                _row(isDark, 'تسويات معتمدة / مستنية', '${recs.where((x) => x['status'] == 'approved').length} / ${recs.where((x) => x['status'] == 'pending').length}'),
                if (closing['approved_by'] != null) _row(isDark, 'المعتمد', '${closing['approved_by']} • ${JphUi.date(closing['approved_at'])}'),
                if ('${closing['approval_notes'] ?? ''}'.isNotEmpty) _row(isDark, 'ملاحظات الاعتماد', '${closing['approval_notes']}'),
                if (closing['closed_at'] != null) _row(isDark, 'اتقفلت', '${closing['closed_by'] ?? ''} • ${JphUi.date(closing['closed_at'])}'),
                if (_d['snapshot'] != null)
                  _row(isDark, 'بصمة اللقطة (Snapshot)', '${'${_m(_d['snapshot'])['hash']}'.substring(0, 16)}…'),
              ]),
              if (blockers.isNotEmpty)
                _card(isDark, [
                  _title(isDark, 'موانع التقفيل', icon: Icons.block_rounded),
                  for (final b in blockers) _row(isDark, '•', '${b['message']}', color: Ar.red),
                ]),
              _OverviewCard(isDark: isDark, f: f),
              _CarryForward(isDark: isDark, f: f, ob: _ob, closed: status == 'closed'),
              if (status != 'closed' && can['owner'] != true)
                _note(isDark, 'الاعتماد والتقفيل للمالك بس.'),
              if (status != 'closed' && can['owner'] == true && (status == 'ready_for_approval' || status == 'approved' || status == 'in_review'))
                _btn(isDark, status == 'approved' ? 'اعتمد تاني (بالأرقام الحالية)' : 'اعتماد التقفيل', Icons.how_to_reg_rounded,
                    blockers.isNotEmpty ? null : () => _approve(context, isDark), color: Ar.green.shade600),
              if (status == 'approved' && can['owner'] == true)
                _btn(isDark, 'تقفيل السنة $y نهائياً', Icons.lock_rounded, () => _close(context, isDark), color: Ar.accent.shade700),
              if (status == 'closed' && can['owner'] == true)
                _btn(isDark, 'فتح السنة تاني (استثنائي)', Icons.lock_open_rounded, () => _reopen(context, isDark), color: Ar.red.shade400),
            ]),
    );
  }

  Future<void> _approve(BuildContext context, bool isDark) async {
    final notes = TextEditingController();
    await cashFormSheet(context, isDark, 'اعتماد تقفيل ${widget.year}', (setS) => [
          _note(isDark, 'إنت بتعتمد الأرقام المعروضة دلوقتي. لو أي رقم اتغير قبل التقفيل، التقفيل هيرفض ويطلب اعتماد جديد.'),
          JphUi.input(isDark: isDark, label: 'ملاحظات الاعتماد (اختياري)', controller: notes, big: false),
        ], () async {
      final r = await cashPost('/closing/${widget.year}/approve', {'confirm': true, 'notes': notes.text.trim()}, ok: 'اتعتمد التقفيل ✅');
      if (r['success'] == true) await _changed();
      return r;
    });
  }

  Future<void> _close(BuildContext context, bool isDark) async {
    final code = TextEditingController();
    final want = 'CLOSE ${widget.year}';
    await cashFormSheet(context, isDark, 'تقفيل السنة نهائياً', (setS) => [
          _note(isDark, 'بعد التقفيل: السنة للقراءة بس، لقطة الأرقام بتتحفظ ومتتغيرش، الأرصدة بتترحّل للسنة الجديدة، ومفيش أي حركة بتاريخ جوه السنة دي تتسجل. مفيش أي حركة مالية بتتعمل أوتوماتيك.',
              color: Ar.amber),
          JphUi.input(isDark: isDark, label: 'للتأكيد اكتب: $want', controller: code, big: false),
        ], () async {
      if (code.text.trim() != want) return {'success': false, 'message': 'اكتب $want بالظبط'};
      final r = await cashPost('/closing/${widget.year}/close', {'confirm': want}, ok: 'اتقفلت السنة ✅');
      if (r['success'] == true) await _changed();
      return r;
    });
  }

  Future<void> _reopen(BuildContext context, bool isDark) async {
    final code = TextEditingController(), reason = TextEditingController();
    final want = 'REOPEN ${widget.year}';
    await cashFormSheet(context, isDark, 'فتح سنة مقفولة', (setS) => [
          _note(isDark, 'عملية استثنائية: اللقطة القديمة بتفضل محفوظة كإصدار، والأرصدة المرحّلة منها بتتعلّم «ملغاة»، والسنة اللي بعدها لازم تتراجع. مينفعش لو السنة اللي بعدها اتقفلت.',
              color: Ar.red),
          JphUi.input(isDark: isDark, label: 'سبب الفتح (10 حروف على الأقل)', controller: reason, big: false),
          const SizedBox(height: 8),
          JphUi.input(isDark: isDark, label: 'للتأكيد اكتب: $want', controller: code, big: false),
        ], () async {
      if (code.text.trim() != want) return {'success': false, 'message': 'اكتب $want بالظبط'};
      final r = await cashPost('/closing/${widget.year}/reopen', {'confirm': want, 'reason': reason.text.trim()}, ok: 'اتفتحت السنة ✅');
      if (r['success'] == true) await _changed();
      return r;
    });
  }
}

/// what goes to the next year: before closing a preview of the balances, after it the carried records
class _CarryForward extends StatelessWidget {
  final bool isDark, closed;
  final Map<String, dynamic> f, ob;
  const _CarryForward({required this.isDark, required this.f, required this.ob, required this.closed});

  @override
  Widget build(BuildContext context) {
    final out = _l(ob['carriedOut']);
    if (closed) {
      return _card(isDark, [
        _title(isDark, 'الأرصدة المرحّلة للسنة الجديدة', icon: Icons.east_rounded),
        if (out.isEmpty) _empty(isDark, 'مفيش أرصدة مرحّلة'),
        for (final x in out)
          _row(isDark, '${x['label']}${x['status'] == 'superseded' ? ' (ملغي — اتفتحت السنة)' : ''}', JphUi.money(x['carryBalance']),
              color: x['status'] == 'superseded' ? Ar.grey : null),
      ]);
    }
    final t = _m(f['treasury']);
    return _card(isDark, [
      _title(isDark, 'هيترحّل للسنة الجديدة (معاينة)', icon: Icons.east_rounded),
      _row(isDark, 'خزنة المكتب', _money(_m(t['office'])['closing'])),
      _row(isDark, 'خزنة المحاسب', _money(_m(t['hr'])['closing'])),
      _row(isDark, 'أقساط مستحقة', _money(_m(_m(f['receivables'])['installments'])['total'])),
      _row(isDark, 'سلف الموظفين', _money(_m(_m(f['employees'])['advancesOutstanding'])['total'])),
      _row(isDark, 'عمولات مستحقة للموظفين', _money(_m(_m(f['employees'])['commissionsUnpaid'])['total'])),
      Text('الأرصدة المفتوحة بتترحّل زي ما هي — مبتتصفّرش ومبتتسددش أوتوماتيك.', style: TextStyle(fontSize: 11.5, color: JphUi.sub(isDark))),
    ]);
  }
}

// ==================================================================== 2) التقرير السنوي
class _ReportTab extends StatefulWidget {
  final bool isDark;
  final Map<String, dynamic> d;
  const _ReportTab({required this.isDark, required this.d});

  @override
  State<_ReportTab> createState() => _ReportTabState();
}

class _ReportTabState extends State<_ReportTab> {
  int? _cmpYear;
  Map<String, dynamic>? _cmp;

  Future<void> _compare(BuildContext context) async {
    final y = _n(widget.d['year'])?.toInt() ?? DateTime.now().year;
    final v = await JphUi.sheet<int>(context, widget.isDark, 'قارن بسنة', [
      for (var i = 1; i <= 5; i++) (y - i, '${y - i}', Icons.compare_arrows_rounded),
    ], selected: _cmpYear);
    if (v == null) return;
    final r = await cashGet('/closing/$v');
    if (!mounted) return;
    setState(() {
      _cmpYear = v;
      _cmp = r['success'] == true ? _m(r['figures']) : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final d = widget.d;
    final f = _m(d['figures']);
    final rev = _m(f['revenue']);
    final exp = _m(f['expenses']);
    final t = _m(f['treasury']);
    final rc = _m(_m(f['receivables'])['installments']);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 100), children: [
      if (d['status'] != 'closed') _note(isDark, 'التقرير ده من الحركات الحالية (السنة لسه مش مقفولة). بعد التقفيل بيتعرض من اللقطة المحفوظة.'),
      Row(children: [
        Expanded(child: _btn(isDark, 'PDF', Icons.picture_as_pdf_rounded, () => _ReportExport.pdf(d), color: Ar.red.shade400)),
        const SizedBox(width: 8),
        Expanded(child: _btn(isDark, 'Excel', Icons.grid_on_rounded, () async {
          await _ReportExport.xlsx(d);
          if (context.mounted) JphUi.toast(context, {'success': true, 'message': 'اتحفظ ملف الإكسيل ✅'});
        }, color: Ar.green.shade600)),
      ]),
      _OverviewCard(isDark: isDark, f: f),
      ExpansionTile(
        title: const Text('الإيرادات', style: TextStyle(fontWeight: FontWeight.w900)),
        children: [
          _card(isDark, [
            _row(isDark, 'عمولات المكتب', _money(rev['commissions'] ?? rev['commissionReceived']), strong: true),
            _row(isDark, 'عمولات مستلمة', _money(rev['commissionReceived'])),
            _row(isDark, 'تحصيلات أخرى', _money(rev['other'])),
            _row(isDark, 'مبيعات الوحدات (أموال العملاء)', _money(_m(rev['sales'])['total'])),
            _row(isDark, 'ضخ الملاك', _money(rev['injection'])),
            Text('التحصيل النقدي مش بيتحسب إيراد إلا لو تصنيفه عمولة للمكتب.', style: TextStyle(fontSize: 11.5, color: JphUi.sub(isDark))),
          ]),
        ],
      ),
      ExpansionTile(
        title: const Text('المصروفات', style: TextStyle(fontWeight: FontWeight.w900)),
        children: [
          _card(isDark, [
            _row(isDark, 'الإجمالي', _money(exp['total']), strong: true),
            _row(isDark, 'المرتبات والصرف للموظفين', _money(exp['payrollTotal'])),
            for (final c in _l(exp['byCategory'])) _row(isDark, '${c['name']} (${c['count']})', _money(c['amount'])),
          ]),
        ],
      ),
      ExpansionTile(
        title: const Text('الخزن والبنك', style: TextStyle(fontWeight: FontWeight.w900)),
        children: [
          for (final b in ['office', 'hr'])
            _card(isDark, [
              _title(isDark, b == 'office' ? 'خزنة المكتب' : 'خزنة المحاسب'),
              _row(isDark, 'أول السنة', _money(_m(t[b])['opening'])),
              _row(isDark, 'مقبوضات', _money(_m(t[b])['receipts'])),
              _row(isDark, 'مدفوعات', _money(_m(t[b])['payments'])),
              _row(isDark, 'تحويلات واردة / صادرة', '${_money(_m(t[b])['transfersIn'])} / ${_money(_m(t[b])['transfersOut'])}'),
              _row(isDark, 'آخر السنة', _money(_m(t[b])['closing']), strong: true),
              _row(isDark, 'منها نقدي / بنك', '${_money(_m(t[b])['cashPart'])} / ${_money(_m(t[b])['bankPart'])}'),
              Text('التحويلات بين الخزن مش إيراد ولا مصروف.', style: TextStyle(fontSize: 11.5, color: JphUi.sub(isDark))),
            ]),
        ],
      ),
      ExpansionTile(
        title: const Text('الموظفين', style: TextStyle(fontWeight: FontWeight.w900)),
        children: [
          _CategoryFigures(isDark: isDark, category: 'employees', f: f, year: '${d['year']}'),
          _card(isDark, [
            _title(isDark, 'سلف لسه هتتخصم'),
            for (final x in _l(_m(_m(f['employees'])['advancesOutstanding'])['byEmployee'])) _row(isDark, '${x['name']}', JphUi.money(x['amount'])),
            _title(isDark, 'عمولات مستحقة'),
            for (final x in _l(_m(_m(f['employees'])['commissionsUnpaid'])['byEmployee'])) _row(isDark, '${x['name']}', JphUi.money(x['amount'])),
          ]),
        ],
      ),
      ExpansionTile(
        title: const Text('المشاريع', style: TextStyle(fontWeight: FontWeight.w900)),
        children: [_CategoryFigures(isDark: isDark, category: 'projects', f: f, year: '${d['year']}')],
      ),
      ExpansionTile(
        title: const Text('المستحقات والالتزامات', style: TextStyle(fontWeight: FontWeight.w900)),
        children: [
          _CategoryFigures(isDark: isDark, category: 'obligations', f: f, year: '${d['year']}'),
          _card(isDark, [
            _title(isDark, 'أكبر الأقساط المفتوحة'),
            for (final x in _l(rc['lines']).take(30))
              _row(isDark, '${x['party']} • ${x['project']} ${x['unitNo'] ?? ''} • ${x['dueDate']}', '${JphUi.money(x['left'])} من ${JphUi.money(x['amount'])}'),
          ]),
        ],
      ),
      ExpansionTile(
        title: const Text('الشركاء وتوزيع الأرباح', style: TextStyle(fontWeight: FontWeight.w900)),
        children: [_PartnersView(isDark: isDark, f: f)],
      ),
      ExpansionTile(
        title: const Text('الأصول والعهد', style: TextStyle(fontWeight: FontWeight.w900)),
        children: [_CategoryFigures(isDark: isDark, category: 'assets', f: f, year: '${d['year']}')],
      ),
      ExpansionTile(
        title: const Text('مقارنة بسنة تانية', style: TextStyle(fontWeight: FontWeight.w900)),
        children: [
          _btn(isDark, _cmpYear == null ? 'اختار سنة للمقارنة' : 'المقارنة مع $_cmpYear', Icons.compare_arrows_rounded, () => _compare(context)),
          if (_cmp != null) _Compare(isDark: isDark, a: f, b: _cmp!, aYear: '${d['year']}', bYear: '$_cmpYear'),
        ],
      ),
      ExpansionTile(
        title: const Text('حدود النظام', style: TextStyle(fontWeight: FontWeight.w900)),
        children: [for (final x in (d['limitations'] as List? ?? const [])) _note(isDark, '$x')],
      ),
    ]);
  }
}

/// the same metrics of two years side by side (a metric one year lacks shows «غير متاح»)
class _Compare extends StatelessWidget {
  final bool isDark;
  final Map<String, dynamic> a, b;
  final String aYear, bYear;
  const _Compare({required this.isDark, required this.a, required this.b, required this.aYear, required this.bYear});

  static List<(String, Object? Function(Map<String, dynamic>))> metrics = [
    ('الإيرادات', (f) => _m(f['revenue'])['commissions'] ?? _m(f['revenue'])['commissionReceived']),
    ('المصروفات', (f) => _m(f['expenses'])['total']),
    ('نتيجة السنة', (f) => f['result'] == null ? null : _m(f['result'])['net']),
    ('المقبوضات', (f) => _m(f['cashFlow'])['receipts']),
    ('المدفوعات', (f) => _m(f['cashFlow'])['payments']),
    ('خزنة المكتب آخر السنة', (f) => _m(_m(f['treasury'])['office'])['closing']),
    ('خزنة المحاسب آخر السنة', (f) => _m(_m(f['treasury'])['hr'])['closing']),
    ('البنك آخر السنة', (f) => (_n(_m(_m(f['treasury'])['office'])['bankPart']) ?? 0) + (_n(_m(_m(f['treasury'])['hr'])['bankPart']) ?? 0)),
    ('مستحق للشركة', (f) => _m(_m(f['receivables'])['installments'])['total']),
    ('مستحق على الشركة (عمولات)', (f) => _m(f['payables'])['employeeCommissions']),
    ('سلف الموظفين', (f) => _m(_m(f['employees'])['advancesOutstanding'])['total']),
  ];

  @override
  Widget build(BuildContext context) => _card(isDark, [
        Row(children: [
          const Expanded(child: SizedBox()),
          SizedBox(width: 110, child: Text(aYear, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w900))),
          SizedBox(width: 110, child: Text(bYear, textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w900))),
        ]),
        for (final m in metrics)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(child: Text(m.$1, style: TextStyle(color: JphUi.sub(isDark), fontSize: 12.5))),
              SizedBox(width: 110, child: Text(_money(m.$2(a)), textAlign: TextAlign.end, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700))),
              SizedBox(width: 110, child: Text(_money(m.$2(b)), textAlign: TextAlign.end, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700))),
            ]),
          ),
      ]);
}

// ==================================================================== 3) سجل السنوات
class _ArchiveTab extends StatelessWidget {
  final bool isDark;
  final Map<String, dynamic> years;
  final void Function(int year, int tab) onOpen;
  const _ArchiveTab({required this.isDark, required this.years, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final ys = cashList(years, 'years');
    return ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 100), children: [
      if (ys.isEmpty) _empty(isDark, 'مفيش سنين مالية'),
      for (final y in ys)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: JphUi.box(isDark),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Text('${y['year']}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
              const SizedBox(width: 8),
              JphUi.chip((_yearStatus[y['status']] ?? ('', Ar.grey)).$1, (_yearStatus[y['status']] ?? ('', Ar.grey)).$2),
              const Spacer(),
              Text('${y['from']} → ${y['to']}', style: TextStyle(fontSize: 11.5, color: JphUi.sub(isDark))),
            ]),
            if (y['closedAt'] != null) _row(isDark, 'تاريخ التقفيل', JphUi.date(y['closedAt'])),
            if (y['approvedBy'] != null) _row(isDark, 'المعتمد', '${y['approvedBy']}'),
            if (y['startedBy'] != null) _row(isDark, 'المراجع', '${y['startedBy']}'),
            if (y['closingTotals'] != null) ...[
              _row(isDark, 'خزنة المكتب / المحاسب', '${JphUi.money(_m(y['closingTotals'])['office'])} / ${JphUi.money(_m(y['closingTotals'])['hr'])}'),
              _row(isDark, 'البنك', JphUi.money(_m(y['closingTotals'])['bank'])),
              _row(isDark, 'مستحق للشركة / عليها', '${JphUi.money(_m(y['closingTotals'])['receivables'])} / ${JphUi.money(_m(y['closingTotals'])['payables'])}'),
              _row(isDark, 'توزيع الأرباح', _m(y['closingTotals'])['profitAllocated'] == true ? 'اتحسب' : 'غير متاح'),
            ],
            Wrap(spacing: 8, children: [
              TextButton.icon(onPressed: () => onOpen(_n(y['year'])!.toInt(), 1), icon: const Icon(Icons.insights_rounded, size: 18), label: const Text('التقرير')),
              TextButton.icon(onPressed: () => onOpen(_n(y['year'])!.toInt(), 0), icon: const Icon(Icons.fact_check_rounded, size: 18), label: const Text('المراجعة')),
              if (y['status'] != 'not_started')
                TextButton.icon(
                    onPressed: () => _push(context, _YearHistoryPage(year: '${y['year']}')),
                    icon: const Icon(Icons.history_rounded, size: 18),
                    label: const Text('السجل والأرصدة')),
            ]),
          ]),
        ),
      for (final x in (years['limitations'] as List? ?? const [])) _note(isDark, '$x'),
    ]);
  }
}

/// a year's closing history: versions, the audit trail, the carried balances (in and out)
class _YearHistoryPage extends StatefulWidget {
  final String year;
  const _YearHistoryPage({required this.year});

  @override
  State<_YearHistoryPage> createState() => _YearHistoryPageState();
}

class _YearHistoryPageState extends State<_YearHistoryPage> {
  Map<String, dynamic> _d = {}, _audit = {}, _ob = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final d = await cashGet('/closing/${widget.year}');
    final a = await cashGet('/closing/${widget.year}/audit');
    final o = await cashGet('/closing/${widget.year}/opening-balances');
    if (!mounted) return;
    setState(() {
      _d = d;
      _audit = a;
      _ob = o;
      _loading = false;
    });
  }

  static const _actions = {
    'closing.start': 'بدء المراجعة', 'closing.item': 'مراجعة بند', 'closing.issues_detected': 'اكتشاف مشاكل', 'closing.issue_raised': 'تسجيل مشكلة',
    'closing.issue_note': 'ملاحظة على مشكلة', 'closing.issue_resolve': 'حل مشكلة', 'closing.issue_exception': 'اعتماد استثناء', 'closing.issue_reopen': 'فتح مشكلة',
    'closing.reconciliation': 'تسوية جديدة', 'closing.reconciliation_decision': 'قرار تسوية', 'closing.approve': 'اعتماد التقفيل',
    'closing.approval_withdrawn': 'سحب الاعتماد (اتغيرت المراجعة)', 'closing.close': 'تقفيل السنة', 'closing.reopen': 'فتح السنة تاني',
  };

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final versions = _l(_d['versions']);
    final ev = _l(_audit['events']);
    return _Sub(
      title: 'سجل سنة ${widget.year}',
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 100), children: [
              _card(isDark, [
                _title(isDark, 'إصدارات التقفيل', icon: Icons.layers_rounded),
                for (final v in versions)
                  _row(isDark, 'الإصدار ${v['version']} — ${(_yearStatus[v['status']] ?? ('${v['status']}', Ar.grey)).$1}',
                      '${v['closed_at'] != null ? 'اتقفل ${JphUi.date(v['closed_at'])}' : 'بدأ ${JphUi.date(v['started_at'])}'}'
                      '${v['reopen_reason'] != null ? '\nسبب الفتح: ${v['reopen_reason']} (${v['reopened_by']})' : ''}'),
              ]),
              _card(isDark, [
                _title(isDark, 'الأرصدة الافتتاحية (المرحّلة للسنة دي)', icon: Icons.west_rounded),
                if (_l(_ob['carriedIn']).isEmpty) _empty(isDark, 'مفيش أرصدة مرحّلة من تقفيل السنة اللي قبلها'),
                for (final x in _l(_ob['carriedIn']))
                  _row(isDark, '${x['label']} (من ${x['fromYear']} — إصدار ${x['version']})${x['status'] == 'superseded' ? ' — ملغي' : ''}', JphUi.money(x['carryBalance'])),
              ]),
              _card(isDark, [
                _title(isDark, 'المرحّل منها للسنة اللي بعدها', icon: Icons.east_rounded),
                if (_l(_ob['carriedOut']).isEmpty) _empty(isDark, 'لسه متقفلتش'),
                for (final x in _l(_ob['carriedOut']))
                  _row(isDark, '${x['label']}${x['status'] == 'superseded' ? ' — ملغي' : ''}', JphUi.money(x['carryBalance'])),
              ]),
              _card(isDark, [
                _title(isDark, 'سجل عمليات التقفيل', icon: Icons.history_rounded),
                if (ev.isEmpty) _empty(isDark, 'مفيش عمليات'),
                for (final e in ev)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${_actions[e['action']] ?? e['action']} — ${e['by']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                      Text('${JphUi.date(e['at'])}${_m(e['after'])['item'] != null ? ' • ${_m(e['after'])['item']} → ${_m(e['after'])['status']}' : ''}'
                          '${_m(e['after'])['reason'] != null ? ' • ${_m(e['after'])['reason']}' : ''}',
                          style: TextStyle(fontSize: 11.5, color: JphUi.sub(isDark))),
                    ]),
                  ),
              ]),
            ]),
    );
  }
}

// ==================================================================== export (from the same figures the screen shows)
class _ReportExport {
  _ReportExport._();

  static List<List<String>> rows(Map<String, dynamic> d) {
    final f = _m(d['figures']);
    final rev = _m(f['revenue']), exp = _m(f['expenses']), t = _m(f['treasury']);
    final out = <List<String>>[];
    void add(String section, String item, Object? v) => out.add([section, item, _n(v) == null ? 'غير متاح' : '${_n(v)}']);
    add('ملخص', 'الإيرادات (عمولات المكتب)', rev['commissions'] ?? rev['commissionReceived']);
    add('ملخص', 'المصروفات', exp['total']);
    add('ملخص', 'نتيجة السنة', f['result'] == null ? null : _m(f['result'])['net']);
    add('ملخص', 'المقبوضات', _m(f['cashFlow'])['receipts']);
    add('ملخص', 'المدفوعات', _m(f['cashFlow'])['payments']);
    for (final c in _l(exp['byCategory'])) add('المصروفات', '${c['name']}', c['amount']);
    for (final b in ['office', 'hr']) {
      final x = _m(t[b]);
      final n = b == 'office' ? 'خزنة المكتب' : 'خزنة المحاسب';
      for (final k in [('opening', 'أول السنة'), ('receipts', 'مقبوضات'), ('payments', 'مدفوعات'), ('transfersIn', 'تحويلات واردة'), ('transfersOut', 'تحويلات صادرة'),
        ('adjustments', 'تسويات'), ('closing', 'آخر السنة'), ('bankPart', 'منها بنك')]) {
        add(n, k.$2, x[k.$1]);
      }
    }
    add('المستحقات', 'أقساط مستحقة للشركة', _m(_m(f['receivables'])['installments'])['total']);
    add('المستحقات', 'منها متأخر', _m(_m(f['receivables'])['installments'])['overdue']);
    add('الالتزامات', 'عمولات موظفين مستحقة', _m(f['payables'])['employeeCommissions']);
    add('الموظفين', 'سلف لسه هتتخصم', _m(_m(f['employees'])['advancesOutstanding'])['total']);
    for (final x in _l(_m(_m(f['employees'])['advancesOutstanding'])['byEmployee'])) add('سلف', '${x['name']}', x['amount']);
    for (final x in _l(_m(_m(f['employees'])['commissionsUnpaid'])['byEmployee'])) add('عمولات مستحقة', '${x['name']}', x['amount']);
    final p = _m(f['partners']);
    for (final x in _l(p['list'])) {
      add('الشركاء', '${x['name']} — أول السنة', x['opening']);
      add('الشركاء', '${x['name']} — ضخ', x['contributions']);
      add('الشركاء', '${x['name']} — مسحوبات', x['withdrawals']);
      add('الشركاء', '${x['name']} — نصيب الربح', x['allocated']);
      add('الشركاء', '${x['name']} — آخر السنة', x['closing']);
    }
    for (final c in _l(_m(f['assets'])['custody'])) {
      out.add(['العهد', '${c['type']}', 'معاهم ${c['held']} • اتسلّم ${c['assigned']} • رجع ${c['returned']} • مفقود ${c['lost']}']);
    }
    for (final i in _l(d['checklist']).expand((c) => _l(c['items']))) {
      out.add(['قائمة المراجعة', '${i['label']}', '${(_itemStatus[i['status']] ?? ('${i['status']}', Ar.grey, Icons.circle)).$1}${'${i['note'] ?? ''}'.isNotEmpty ? ' — ${i['note']}' : ''}']);
    }
    for (final i in _l(d['issues'])) {
      out.add(['المشاكل', '#${i['refNo']} ${i['description']}', '${(_issueStatus[i['status']] ?? ('${i['status']}', Ar.grey)).$1}${i['amount'] != null ? ' • ${i['amount']}' : ''}']);
    }
    for (final r in _l(d['reconciliations'])) {
      out.add(['التسويات', '#${r['refNo']} ${_recTypes[r['type']] ?? r['type']} — ${r['reason']}', '${r['amount']} • ${(_recStatus[r['status']] ?? ('${r['status']}', Ar.grey)).$1}']);
    }
    for (final o in _l(_m(d['snapshot'])['openingBalances'])) out.add(['الأرصدة المرحّلة', '${o['label']}', '${o['carryBalance']}']);
    if (d['snapshot'] != null) out.add(['التقفيل', 'بصمة اللقطة', '${_m(d['snapshot'])['hash']}']);
    for (final x in (d['limitations'] as List? ?? const [])) out.add(['حدود النظام', '$x', '']);
    return out;
  }

  static Future<void> xlsx(Map<String, dynamic> d) async {
    final rs = rows(d);
    await saveXlsx('year-closing-${d['year']}', writeXlsx('التقرير السنوي', ['القسم', 'البند', 'القيمة (جنيه)'], rs));
  }

  static Future<void> pdf(Map<String, dynamic> d) async {
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
    final rs = rows(d);
    final st = (_yearStatus['${d['status']}'] ?? ('${d['status']}', Ar.grey)).$1;
    final doc = pw.Document();
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      textDirection: pw.TextDirection.rtl,
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
      header: (_) => pw.Text('التقرير السنوي — السنة المالية ${d['year']} ($st)', style: pw.TextStyle(font: bold, fontSize: 15)),
      build: (_) => [
        pw.SizedBox(height: 8),
        pw.TableHelper.fromTextArray(
          headers: const ['القسم', 'البند', 'القيمة (جنيه)'],
          data: rs,
          headerStyle: pw.TextStyle(font: bold, fontSize: 10),
          cellStyle: const pw.TextStyle(fontSize: 9),
          cellAlignment: pw.Alignment.centerRight,
          headerAlignment: pw.Alignment.centerRight,
          columnWidths: {0: const pw.FlexColumnWidth(1.2), 1: const pw.FlexColumnWidth(3), 2: const pw.FlexColumnWidth(1.6)},
        ),
      ],
    ));
    await Printing.layoutPdf(name: 'year-closing-${d['year']}.pdf', onLayout: (_) async => doc.save());
  }
}
