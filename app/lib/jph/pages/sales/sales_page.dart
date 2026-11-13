import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/swipe_tabs.dart';
import '../attendance/attendance_widgets.dart';
import '../cash/cash_page.dart';
import '../../widgets/glass_ui.dart';

/// المبيعات والأقساط — the operational page for HR and the manager (the Projects page stays as it is):
///  • الأقساط المستحقة: كل المفتوح | المتأخر | النهارده (swipe), period filter icon top-left, search by buyer.
///  • العملاء: every buyer (from the sales); tapping one shows his installments; a new sale is registered here.
class SalesPage extends StatefulWidget {
  const SalesPage({super.key});

  @override
  State<SalesPage> createState() => _SalesPageState();
}

const _lineStatus = {
  'not_due': ('لسه مجاش ميعاده', Ar.grey), 'due': ('مستحق النهارده', Ar.info), 'partial': ('مدفوع جزئياً', Ar.amber),
  'paid': ('مدفوع', Ar.green), 'overdue': ('متأخر', Ar.red), 'cancelled': ('ملغي', Ar.grey),
};
const _freqAr = {'monthly': 'شهري', 'quarterly': 'كل 3 شهور', 'semiannual': 'كل 6 شهور', 'annual': 'سنوي'};
const _stageAr = {
  'reserved': ('حجز — المقدم لسه مكملش', Ar.amber), 'installments': ('أقساط', Ar.info),
  'completed': ('اتسدد بالكامل', Ar.green), 'cancelled': ('ملغي', Ar.grey),
  'pending': ('مستنية اعتماد الإدارة', Ar.amber), 'rejected': ('مرفوضة', Ar.red),
};

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _SalesPageState extends State<SalesPage> {
  /// the period filter (icon top-left, like the attendance report) — applies to the installments lists
  final _range = ValueNotifier<DateTimeRange?>(null);

  @override
  void dispose() {
    _range.dispose();
    super.dispose();
  }

  Future<void> _filter(bool isDark) async {
    final now = DateTime.now();
    final picked = await JphUi.pickRange(context, isDark, _range.value?.start ?? now, _range.value?.end ?? now.add(const Duration(days: 30)));
    if (picked != null) _range.value = picked;
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
                Header(
                  onBack: () => Navigator.pop(context),
                  onFilter: () => _filter(isDark),
                  isRTL: isRTL,
                  isDark: isDark,
                  title: 'المبيعات والأقساط',
                ),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      // the page bar is tapped; the installments bar under it is the one you swipe
                      child: SwipeTabs(
                        isDark: isDark,
                        swipe: false,
                        tabs: const [('الأقساط المستحقة', Icons.event_note_rounded), ('العملاء', Icons.people_alt_rounded)],
                        pages: [_DueTab(isDark: isDark, range: _range), _ClientsTab(isDark: isDark)],
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

// ==================================================================== الأقساط المستحقة
/// كل المفتوح | المتأخر | النهارده — same bar as the attendance pages, swipe right / left between them.
class _DueTab extends StatelessWidget {
  final bool isDark;
  final ValueNotifier<DateTimeRange?> range;
  const _DueTab({required this.isDark, required this.range});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      ValueListenableBuilder<DateTimeRange?>(
        valueListenable: range,
        builder: (_, r, __) => r == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: InputChip(
                  avatar: const Icon(Icons.date_range_rounded, size: 18),
                  label: Text('من ${_iso(r.start)} لـ ${_iso(r.end)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  onDeleted: () => range.value = null,
                ),
              ),
      ),
      Expanded(
        child: SwipeTabs(
          isDark: isDark,
          tabs: const [
            ('كل المفتوح', Icons.list_alt_rounded),
            ('المتأخر', Icons.warning_amber_rounded),
            ('النهارده', Icons.today_rounded),
          ],
          pages: [
            _DueList(isDark: isDark, filter: 'open', range: range),
            _DueList(isDark: isDark, filter: 'overdue', range: range),
            _DueList(isDark: isDark, filter: 'today', range: range),
          ],
        ),
      ),
    ]);
  }
}

class _DueList extends StatefulWidget {
  final bool isDark;
  final String filter; // open | overdue | today
  final ValueNotifier<DateTimeRange?> range;
  const _DueList({required this.isDark, required this.filter, required this.range});

  @override
  State<_DueList> createState() => _DueListState();
}

class _DueListState extends State<_DueList> {
  final _q = TextEditingController();
  Map<String, dynamic> _r = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.range.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.range.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    final q = _q.text.trim();
    final range = widget.range.value;
    final r = await cashGet('/sales/installments/due', {
      if (widget.filter == 'overdue') 'overdue': '1',
      if (widget.filter == 'today') 'today': '1',
      if (range != null) 'from': _iso(range.start),
      if (range != null) 'to': _iso(range.end),
      if (q.isNotEmpty) 'buyer': q,
    });
    if (!mounted) return;
    setState(() {
      _loading = false;
      _r = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final list = cashList(_r, 'installments');
    final totals = ((_r['totals'] as Map?) ?? const {});
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: JphUi.box(isDark),
          child: TextField(
            controller: _q,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(hintText: 'ابحث باسم المشتري', border: InputBorder.none,
                prefixIcon: Icon(Icons.search_rounded, color: JphUi.primary(isDark))),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: JphUi.stat(isDark, 'الباقي', JphUi.money(totals['remaining']), Icons.hourglass_bottom_rounded, Ar.amber)),
          const SizedBox(width: 10),
          Expanded(child: JphUi.stat(isDark, 'منه متأخر', JphUi.money(totals['overdue']), Icons.warning_rounded, Ar.red)),
        ]),
        const SizedBox(height: 12),
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && list.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش أقساط', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final x in list)
          GestureDetector(
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => SaleDetailsPage(saleId: '${x['saleId']}')));
              _load();
            },
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: JphUi.box(isDark),
              child: Row(children: [
                JphUi.iconTile(isDark, Icons.event_note_rounded, (_lineStatus[x['status']] ?? ('', Ar.grey)).$2),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${x['buyerName']} • ${x['projectName']} — ${x['unitNo']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text('${x['seq'] == 0 ? 'المقدم' : 'قسط ${x['seq']}'} • ${x['dueDate']} • مدفوع ${JphUi.money(x['paid'])} من ${JphUi.money(x['amount'])}',
                        style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                    Text('الباقي على الوحدة: ${JphUi.money(x['saleRemaining'])}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  CountUpText(JphUi.money(x['remaining']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  const SizedBox(height: 4),
                  JphUi.chip((_lineStatus[x['status']] ?? ('${x['status']}', Ar.grey)).$1, (_lineStatus[x['status']] ?? ('', Ar.grey)).$2),
                ]),
              ]),
            ),
          ),
      ]),
    );
  }
}

// ==================================================================== العملاء
/// Every buyer (from the registered sales — one client per mobile number). Tapping one opens his installments.
class _ClientsTab extends StatefulWidget {
  final bool isDark;
  const _ClientsTab({required this.isDark});

  @override
  State<_ClientsTab> createState() => _ClientsTabState();
}

class _ClientsTabState extends State<_ClientsTab> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await cashGet('/sales/clients', {'q': _q.text.trim()});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = r['success'] == true ? null : '${r['message'] ?? 'مش قادر أحمّل العملاء'}';
      _items = cashList(r, 'clients');
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        // البيع والحجز من «المشاريع ← المبيعات» بس
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: JphUi.box(isDark),
          child: TextField(
            controller: _q,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(hintText: 'ابحث باسم العميل أو الموبايل أو الوحدة', border: InputBorder.none,
                prefixIcon: Icon(Icons.search_rounded, color: JphUi.primary(isDark))),
          ),
        ),
        const SizedBox(height: 10),
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _error != null)
          Padding(padding: const EdgeInsets.all(30), child: Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        if (!_loading && _error == null && _items.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش عملاء', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final c in _items)
          GestureDetector(
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => ClientDetailsPage(clientKey: '${c['key']}', name: '${c['name']}')));
              _load();
            },
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: JphUi.box(isDark),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  JphUi.iconTile(isDark, Icons.person_rounded, c['paymentMethod'] == 'installments' ? Ar.accent : Ar.green),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${c['name']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                      Text([if ('${c['phone'] ?? ''}'.isNotEmpty) '${c['phone']}', ...((c['units'] as List?) ?? const []).map((u) => '$u')].join(' • '),
                          style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                    ]),
                  ),
                  JphUi.chip(c['paymentMethod'] == 'installments' ? 'تقسيط' : 'كاش', c['paymentMethod'] == 'installments' ? Ar.accent : Ar.green),
                ]),
                const SizedBox(height: 8),
                Wrap(spacing: 14, runSpacing: 4, children: [
                  Text('الإجمالي: ${JphUi.money(c['total'])}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('المدفوع: ${JphUi.money(c['collected'])}', style: const TextStyle(fontWeight: FontWeight.w700, color: Ar.green)),
                  Text('المتبقي: ${JphUi.money(c['remaining'])}', style: const TextStyle(fontWeight: FontWeight.w700, color: Ar.amber)),
                  if (((c['overdue'] as num?) ?? 0) > 0)
                    Text('متأخر: ${JphUi.money(c['overdue'])}', style: const TextStyle(fontWeight: FontWeight.w700, color: Ar.red)),
                ]),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// One client: installments count (all / paid / left), amounts (paid / left / total), then the installments table.
class ClientDetailsPage extends StatefulWidget {
  final String clientKey;
  final String name;
  const ClientDetailsPage({super.key, required this.clientKey, required this.name});

  @override
  State<ClientDetailsPage> createState() => _ClientDetailsPageState();
}

class _ClientDetailsPageState extends State<ClientDetailsPage> {
  Map<String, dynamic> _r = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await cashGet('/sales/clients/detail', {'key': widget.clientKey});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _r = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      final counts = ((_r['counts'] as Map?) ?? const {});
      final amounts = ((_r['amounts'] as Map?) ?? const {});
      final lines = cashList(_r, 'schedule');
      final sales = cashList(_r, 'sales');
      final client = ((_r['client'] as Map?) ?? const {});
      final multi = sales.where((x) => x['status'] == 'active').length > 1;
      TextStyle th = TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: JphUi.sub(isDark));
      return AppBackground(
        child: Directionality(
          textDirection: app.isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                JphUi.header(context, isDark: isDark, isRTL: app.isRTL, title: widget.name),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
                      if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
                      if (!_loading && _r['success'] != true)
                        Text('${_r['message'] ?? 'مش قادر أحمّل بيانات العميل'}', textAlign: TextAlign.center),
                      if (!_loading && _r['success'] == true) ...[
                        if ('${client['phone'] ?? ''}'.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text('الموبايل: ${client['phone']}', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark))),
                          ),
                        JphUi.statGrid([
                          JphUi.stat(isDark, 'إجمالي عدد الأقساط', '${counts['installments'] ?? 0}', Icons.format_list_numbered_rounded, Ar.accent),
                          JphUi.stat(isDark, 'المدفوع', '${counts['paid'] ?? 0}', Icons.check_circle_rounded, Ar.green),
                          JphUi.stat(isDark, 'المتبقي', '${counts['remaining'] ?? 0}', Icons.hourglass_bottom_rounded, Ar.amber),
                        ], phone: 3),
                        const SizedBox(height: 10),
                        JphUi.statGrid([
                          JphUi.stat(isDark, 'المبلغ المدفوع', JphUi.money(amounts['paid']), Icons.price_check_rounded, Ar.green),
                          JphUi.stat(isDark, 'المبلغ المتبقي', JphUi.money(amounts['remaining']), Icons.pending_rounded, Ar.amber),
                          JphUi.stat(isDark, 'إجمالي المبلغ', JphUi.money(amounts['total']), Icons.account_balance_rounded, Ar.accent),
                        ], phone: 3),
                        const SizedBox(height: 16),
                        Text('جدول الأقساط', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                        const SizedBox(height: 8),
                        Container(
                          decoration: JphUi.box(isDark),
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Column(children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              child: Row(children: [
                                Expanded(flex: 3, child: Text('القسط', style: th)),
                                Expanded(flex: 4, child: Text('الميعاد', style: th)),
                                Expanded(flex: 4, child: Text('المبلغ', style: th)),
                                Expanded(flex: 4, child: Text('المدفوع', style: th)),
                                Expanded(flex: 4, child: Text('الحالة', style: th)),
                              ]),
                            ),
                            const Divider(height: 1),
                            if (lines.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('مفيش أقساط')),
                            for (final l in lines)
                              InkWell(
                                onTap: () async {
                                  await Navigator.push(context, MaterialPageRoute(builder: (_) => SaleDetailsPage(saleId: '${l['saleId']}')));
                                  _load();
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Ar.grey.withOpacity(0.15)))),
                                  child: Row(children: [
                                    Expanded(
                                      flex: 3,
                                      child: Text('${l['seq'] == 0 ? 'المقدم' : 'قسط ${l['seq']}'}${multi ? '\n${l['unit']}' : ''}',
                                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
                                    ),
                                    Expanded(flex: 4, child: Text('${l['dueDate']}', style: const TextStyle(fontSize: 12))),
                                    Expanded(flex: 4, child: CountUpText(JphUi.money(l['amount']), style: const TextStyle(fontSize: 12))),
                                    Expanded(flex: 4, child: CountUpText(JphUi.money(l['paid']), style: const TextStyle(fontSize: 12, color: Ar.green))),
                                    Expanded(
                                      flex: 4,
                                      child: Text((_lineStatus[l['status']] ?? ('${l['status']}', Ar.grey)).$1,
                                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: (_lineStatus[l['status']] ?? ('', Ar.grey)).$2)),
                                    ),
                                  ]),
                                ),
                              ),
                          ]),
                        ),
                        const SizedBox(height: 16),
                        Text('الوحدات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                        const SizedBox(height: 8),
                        for (final s in sales)
                          GestureDetector(
                            onTap: () async {
                              await Navigator.push(context, MaterialPageRoute(builder: (_) => SaleDetailsPage(saleId: '${s['id']}')));
                              _load();
                            },
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.all(14),
                              decoration: JphUi.box(isDark),
                              child: Row(children: [
                                JphUi.iconTile(isDark, Icons.home_work_rounded, Ar.accent),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text('${s['projectName']} — وحدة ${s['unitNo']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                                    Text('${s['saleDate']} • ${s['paymentMethod'] == 'installments' ? 'تقسيط' : 'كاش'} • #${s['refNo']}',
                                        style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                                  ]),
                                ),
                                JphUi.chip((_stageAr[s['stage']] ?? ('${s['stage']}', Ar.grey)).$1, (_stageAr[s['stage']] ?? ('', Ar.grey)).$2),
                              ]),
                            ),
                          ),
                      ],
                    ]),
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

// ==================================================================== تسجيل بيع وحدة
class NewSalePage extends StatefulWidget {
  const NewSalePage({super.key});

  @override
  State<NewSalePage> createState() => _NewSalePageState();
}

class _NewSalePageState extends State<NewSalePage> {
  List<Map<String, dynamic>> _projects = [];
  Map<String, dynamic>? _project;
  final _unit = TextEditingController(), _buyer = TextEditingController(), _phone = TextEditingController(), _contact = TextEditingController();
  final _total = TextEditingController(), _down = TextEditingController(), _count = TextEditingController(), _each = TextEditingController();
  final _notes = TextEditingController();
  DateTime _saleDate = DateTime.now(), _downDue = DateTime.now();
  DateTime? _firstDue;
  String _freq = 'monthly';
  String _by = 'count'; // count | amount
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    ApiService.post({'action': 'commission_projects'}).then((r) {
      if (!mounted) return;
      setState(() => _projects = ((r['projects'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList());
    });
  }

  num? _n(TextEditingController c) => num.tryParse(c.text.trim().replaceAll(',', ''));

  /// Preview of the schedule the server will build (same rule: rounding difference on the last installment).
  String get _preview {
    final t = _n(_total), d = _n(_down) ?? 0;
    if (t == null || t <= 0) return '';
    final rest = ((t - d) * 100).round();
    if (rest <= 0) return 'الوحدة مدفوعة بالكامل في المقدم';
    if (_by == 'count') {
      final c = _n(_count)?.toInt();
      if (c == null || c <= 0) return '';
      final each = rest ~/ c;
      return '$c قسط × ${JphUi.money(each / 100)}${rest - each * (c - 1) != each ? ' (الأخير ${JphUi.money((rest - each * (c - 1)) / 100)})' : ''}';
    }
    final e = _n(_each);
    if (e == null || e <= 0) return '';
    final ec = (e * 100).round();
    final c = (rest / ec).ceil();
    return '$c قسط × ${JphUi.money(e)}${rest - ec * (c - 1) != ec ? ' (الأخير ${JphUi.money((rest - ec * (c - 1)) / 100)})' : ''}';
  }

  Future<void> _pickDate(DateTime? current, ValueChanged<DateTime> set) async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: current ?? now, firstDate: DateTime(now.year - 3), lastDate: DateTime(now.year + 15));
    if (d != null) setState(() => set(d));
  }

  Future<void> _save() async {
    String? err;
    final t = _n(_total), d = _n(_down);
    if (_project == null) {
      err = 'اختار المشروع';
    } else if (_unit.text.trim().isEmpty) {
      err = 'اكتب رقم الوحدة';
    } else if (_buyer.text.trim().length < 2) {
      err = 'اكتب اسم المشتري';
    } else if (t == null || t <= 0) {
      err = 'اكتب سعر البيع';
    } else if (d == null || d < 0 || d > t) {
      err = 'المقدم لازم يكون من صفر لحد سعر البيع';
    } else if (d < t && _firstDue == null) {
      err = 'اختار ميعاد أول قسط';
    }
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err), backgroundColor: Ar.red));
      return;
    }
    setState(() => _saving = true);
    final r = await cashPost('/sales', {
      'projectId': _project!['id'], 'unitNo': _unit.text.trim(), 'buyerName': _buyer.text.trim(), 'buyerPhone': _phone.text.trim(),
      'buyerContact': _contact.text.trim(), 'totalPrice': t, 'downPayment': d, 'saleDate': _iso(_saleDate), 'downPaymentDueDate': _iso(_downDue),
      if (d! < t!) ...{
        'frequency': _freq, 'firstDueDate': _iso(_firstDue!),
        if (_by == 'count') 'installmentsCount': _n(_count)?.toInt() else 'installmentAmount': _n(_each),
      },
      'notes': _notes.text.trim(),
    }, ok: 'اتسجل البيع ✅');
    if (!mounted) return;
    setState(() => _saving = false);
    JphUi.toast(context, r);
    if (r['success'] == true) Navigator.pop(context, '${(r['sale'] as Map)['id']}');
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      final isRTL = app.isRTL;
      final full = (_n(_down) ?? 0) >= (_n(_total) ?? double.infinity);
      return AppBackground(
        child: Directionality(
          textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                JphUi.header(context, isDark: isDark, isRTL: isRTL, title: 'تسجيل بيع وحدة'),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 700),
                      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
                        JphUi.picker(isDark: isDark, icon: Icons.apartment_rounded, iconColor: Ar.accent, label: 'المشروع *',
                            value: _project == null ? 'اختار المشروع' : '${_project!['name']}', onTap: () async {
                          final v = await JphUi.sheet<Map<String, dynamic>>(context, isDark, 'المشروع',
                              [for (final p in _projects) (p, '${p['name']}', Icons.apartment_rounded)]);
                          if (v != null) setState(() => _project = v);
                        }),
                        const SizedBox(height: 12),
                        JphUi.input(isDark: isDark, label: 'رقم الوحدة * (نفس طريقة العمولات)', controller: _unit, big: false),
                        const SizedBox(height: 12),
                        JphUi.input(isDark: isDark, label: 'اسم المشتري *', controller: _buyer, big: false),
                        const SizedBox(height: 12),
                        JphUi.input(isDark: isDark, label: 'موبايل المشتري', controller: _phone, big: false),
                        const SizedBox(height: 12),
                        JphUi.input(isDark: isDark, label: 'بيانات تواصل أخرى (عنوان / رقم قومي)', controller: _contact, big: false),
                        const SizedBox(height: 12),
                        JphUi.input(isDark: isDark, label: 'سعر البيع الكلي *', controller: _total, number: true, suffix: 'جنيه', onChanged: (_) => setState(() {})),
                        const SizedBox(height: 12),
                        JphUi.input(isDark: isDark, label: 'المقدم * (الحجز بيتحسب منه)', controller: _down, number: true, suffix: 'جنيه', onChanged: (_) => setState(() {})),
                        const SizedBox(height: 12),
                        Row(children: [
                          Expanded(child: JphUi.picker(isDark: isDark, icon: Icons.event_rounded, iconColor: Ar.green, label: 'تاريخ البيع',
                              value: _iso(_saleDate), onTap: () => _pickDate(_saleDate, (d) => _saleDate = d))),
                          const SizedBox(width: 10),
                          Expanded(child: JphUi.picker(isDark: isDark, icon: Icons.event_available_rounded, iconColor: Ar.amber, label: 'ميعاد المقدم',
                              value: _iso(_downDue), onTap: () => _pickDate(_downDue, (d) => _downDue = d))),
                        ]),
                        if (!full) ...[
                          const SizedBox(height: 16),
                          Text('الأقساط', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                          const SizedBox(height: 8),
                          cashSegmented(isDark, _freqAr, _freq, (v) => setState(() => _freq = v)),
                          const SizedBox(height: 10),
                          cashSegmented(isDark, {'count': 'بعدد الأقساط', 'amount': 'بقيمة القسط'}, _by, (v) => setState(() => _by = v)),
                          const SizedBox(height: 10),
                          if (_by == 'count')
                            JphUi.input(isDark: isDark, label: 'عدد الأقساط', controller: _count, number: true, onChanged: (_) => setState(() {}))
                          else
                            JphUi.input(isDark: isDark, label: 'قيمة القسط', controller: _each, number: true, suffix: 'جنيه', onChanged: (_) => setState(() {})),
                          const SizedBox(height: 10),
                          JphUi.picker(isDark: isDark, icon: Icons.calendar_month_rounded, iconColor: Ar.accent, label: 'ميعاد أول قسط *',
                              value: _firstDue == null ? 'اختار' : _iso(_firstDue!), onTap: () => _pickDate(_firstDue, (d) => _firstDue = d)),
                          if (_preview.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            JphUi.readOnly(isDark: isDark, label: 'جدول الأقساط (فرق التقريب على آخر قسط)', value: _preview, icon: Icons.table_chart_rounded, color: Ar.info),
                          ],
                        ],
                        const SizedBox(height: 12),
                        JphUi.input(isDark: isDark, label: 'ملاحظات', controller: _notes, big: false),
                        const SizedBox(height: 20),
                        ElevatedButton(
                          onPressed: _saving ? null : _save,
                          style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
                              minimumSize: const Size(double.infinity, 56), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                          child: _saving
                              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Text('حفظ البيع', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                        ),
                      ]),
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

// ==================================================================== تفاصيل البيع
class SaleDetailsPage extends StatefulWidget {
  final String saleId;
  const SaleDetailsPage({super.key, required this.saleId});

  @override
  State<SaleDetailsPage> createState() => _SaleDetailsPageState();
}

class _SaleDetailsPageState extends State<SaleDetailsPage> {
  Map<String, dynamic> _r = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await cashGet('/sales/${widget.saleId}');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _r = r;
    });
  }

  Future<void> _collect(Map<String, dynamic> line) async {
    final isDark = Provider.of<AppController>(context, listen: false).isDark;
    // HR collects into the HR cashbox only, المدير / المالك into the office cashbox only
    final can = ApiService.can('cash.hr_operate') && !ApiService.can('cash.office');
    final String recipient = can ? 'hr' : 'manager';
    String kind = 'down_payment', method = 'cash';
    final amount = TextEditingController(text: '${line['remaining']}');
    final ext = TextEditingController();
    final ref = newClientRef();
    await cashFormSheet(context, isDark, line['seq'] == 0 ? 'تحصيل الحجز / المقدم' : 'تحصيل قسط ${line['seq']}', (s) => [
          if (line['seq'] == 0) cashSegmented(isDark, {'reservation': 'مبلغ حجز', 'down_payment': 'مقدم'}, kind, (v) => s(() => kind = v)),
          const SizedBox(height: 10),
          JphUi.readOnly(isDark: isDark, label: 'الخزنة', value: recipient == 'hr' ? 'خزنة المحاسب' : 'خزنة المكتب',
              icon: Icons.account_balance_rounded, color: Ar.accent),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'المبلغ (الباقي ${JphUi.money(line['remaining'])})', controller: amount, number: true, suffix: 'جنيه'),
          const SizedBox(height: 10),
          cashSegmented(isDark, const {'cash': 'كاش', 'bank_transfer': 'تحويل بنكي', 'cheque': 'شيك', 'card': 'كارت', 'wallet': 'محفظة'}, method, (v) => s(() => method = v)),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'رقم الإيصال الورقي (اختياري)', controller: ext, big: false),
        ], () async {
      final r = await cashPost('/sales/${widget.saleId}/collect', {
        'installmentId': line['id'], 'kind': kind, 'amount': num.tryParse(amount.text.trim()), 'recipient': recipient,
        'paymentMethod': method,
        if (ext.text.trim().isNotEmpty) 'externalNo': ext.text.trim(), 'clientRef': ref,
      }, ok: 'اتسجل التحصيل ✅');
      if (r['success'] == true && r['receipt'] is Map) {
        final rc = r['receipt'] as Map;
        r['message'] = 'اتسجل — إيصال ${rc['receiptNo']} بمبلغ ${JphUi.money(rc['amount'])}';
      }
      return r;
    });
    _load();
  }

  Future<void> _cancel() async {
    final isDark = Provider.of<AppController>(context, listen: false).isDark;
    final reason = TextEditingController();
    await cashFormSheet(context, isDark, 'إلغاء البيع (استرداد كامل)', (s) => [
          Text('الأقساط الباقية هتتلغي، والتحصيلات هتفضل متسجلة، والمحصّل كله يبقى مستحق للاسترداد.', style: TextStyle(color: JphUi.sub(isDark))),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'السبب', controller: reason, big: false),
        ], () => cashPost('/sales/${widget.saleId}/cancel', {'reason': reason.text.trim()}, ok: 'اتلغى البيع'));
    _load();
  }

  Future<void> _decide(bool approve) async {
    final isDark = Provider.of<AppController>(context, listen: false).isDark;
    if (approve) {
      final r = await cashPost('/sales/${widget.saleId}/decision', {'decision': 'approve'}, ok: 'اتعتمدت البيعة ✅');
      if (mounted) JphUi.toast(context, r);
    } else {
      final reason = TextEditingController();
      await cashFormSheet(context, isDark, 'رفض البيعة', (s) => [
            Text('لو فيه طلب عمولة مستني مع البيعة هيترفض معاها.', style: TextStyle(color: JphUi.sub(isDark))),
            const SizedBox(height: 10),
            JphUi.input(isDark: isDark, label: 'السبب', controller: reason, big: false),
          ], () => cashPost('/sales/${widget.saleId}/decision', {'decision': 'reject', 'reason': reason.text.trim()}, ok: 'اترفضت البيعة'));
    }
    _load();
  }

  Future<void> _refund(num due) async {
    final isDark = Provider.of<AppController>(context, listen: false).isDark;
    String box = ApiService.can('cash.office') ? 'office' : 'hr';
    final amount = TextEditingController(text: '$due');
    final reason = TextEditingController();
    await cashFormSheet(context, isDark, 'رد فلوس للمشتري', (s) => [
          cashSegmented(isDark, {if (ApiService.can('cash.office')) 'office': 'من خزينة المكتب', if (ApiService.can('cash.hr_operate')) 'hr': 'من خزينة المحاسب'}, box,
              (v) => s(() => box = v)),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'المبلغ (الباقي للاسترداد ${JphUi.money(due)})', controller: amount, number: true, suffix: 'جنيه'),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'ملاحظة', controller: reason, big: false),
        ], () => cashPost('/sales/${widget.saleId}/refund', {'cashbox': box, 'amount': num.tryParse(amount.text.trim()), 'reason': reason.text.trim()}, ok: 'اتسجل الاسترداد ✅'));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      final isRTL = app.isRTL;
      final sale = ((_r['sale'] as Map?) ?? const {}).cast<String, dynamic>();
      final can = ((_r['can'] as Map?) ?? const {});
      final schedule = cashList(_r, 'schedule');
      final receipts = cashList(_r, 'receipts');
      final refunds = cashList(_r, 'refunds');
      return AppBackground(
        child: Directionality(
          textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                JphUi.header(context, isDark: isDark, isRTL: isRTL, title: sale.isEmpty ? 'البيع' : 'وحدة ${sale['unitNo']}'),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : sale.isEmpty
                          ? Center(child: Text('${_r['message'] ?? 'مش موجود'}'))
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 1000),
                                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 60), children: [
                                    Container(
                                      padding: const EdgeInsets.all(16),
                                      decoration: JphUi.box(isDark),
                                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                                        Row(children: [
                                          JphUi.iconTile(isDark, Icons.home_work_rounded, Ar.accent),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                              Text('${sale['projectName']} — ${sale['unitNo']}', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                                              Text('${sale['buyerName']} • ${sale['buyerPhone']} • بيع #${sale['refNo']}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                                            ]),
                                          ),
                                          JphUi.chip((_stageAr[sale['stage']] ?? ('${sale['stage']}', Ar.grey)).$1, (_stageAr[sale['stage']] ?? ('', Ar.grey)).$2),
                                        ]),
                                        const SizedBox(height: 12),
                                        Wrap(spacing: 10, runSpacing: 10, children: [
                                          SizedBox(width: 150, child: JphUi.stat(isDark, 'السعر', JphUi.money(sale['totalPrice']), Icons.sell_rounded, Ar.accent)),
                                          SizedBox(width: 150, child: JphUi.stat(isDark, 'المقدم المدفوع', '${JphUi.money(sale['downPaid'])} / ${JphUi.money(sale['downPayment'])}', Icons.payments_rounded, Ar.green)),
                                          SizedBox(width: 150, child: JphUi.stat(isDark, 'المحصّل', JphUi.money(sale['collected']), Icons.check_circle_rounded, Ar.green)),
                                          SizedBox(width: 150, child: JphUi.stat(isDark, 'الباقي', JphUi.money(sale['remaining']), Icons.hourglass_bottom_rounded, Ar.amber)),
                                          if (sale['status'] == 'cancelled')
                                            SizedBox(width: 150, child: JphUi.stat(isDark, 'مستحق استرداد', JphUi.money(sale['refundDue']), Icons.undo_rounded, Ar.red)),
                                        ]),
                                        if (sale['status'] == 'cancelled')
                                          Padding(padding: const EdgeInsets.only(top: 8), child: Text('اتلغى: ${sale['cancelReason'] ?? ''}', style: const TextStyle(color: Ar.red, fontWeight: FontWeight.w700))),
                                        if (sale['status'] == 'rejected')
                                          Padding(padding: const EdgeInsets.only(top: 8), child: Text('اترفضت: ${sale['rejectReason'] ?? ''}', style: const TextStyle(color: Ar.red, fontWeight: FontWeight.w700))),
                                        if (sale['commission'] is Map)
                                          Padding(
                                            padding: const EdgeInsets.only(top: 8),
                                            child: JphUi.chip('طلب عمولة #${(sale['commission'] as Map)['ref']} — ${(sale['commission'] as Map)['employeeName'] ?? ''}: ${commissionStatus('${(sale['commission'] as Map)['status']}').$1}',
                                                commissionStatus('${(sale['commission'] as Map)['status']}').$2),
                                          ),
                                        Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
                                          if (can['decide'] == true) ...[
                                            ElevatedButton.icon(onPressed: () => _decide(true), icon: const Icon(Icons.check_rounded), label: const Text('اعتماد'),
                                                style: ElevatedButton.styleFrom(backgroundColor: Ar.green, foregroundColor: Colors.white)),
                                            TextButton.icon(onPressed: () => _decide(false), icon: const Icon(Icons.close_rounded, color: Ar.red),
                                                label: const Text('رفض', style: TextStyle(color: Ar.red))),
                                          ],
                                          if (can['cancel'] == true)
                                            TextButton.icon(onPressed: _cancel, icon: const Icon(Icons.block_rounded, color: Ar.red),
                                                label: const Text('إلغاء البيع', style: TextStyle(color: Ar.red))),
                                          if (can['refund'] == true && ((sale['refundDue'] as num?) ?? 0) > 0)
                                            ElevatedButton.icon(onPressed: () => _refund(sale['refundDue'] as num), icon: const Icon(Icons.undo_rounded),
                                                label: const Text('رد فلوس'), style: ElevatedButton.styleFrom(backgroundColor: Ar.red, foregroundColor: Colors.white)),
                                        ]),
                                      ]),
                                    ),
                                    const SizedBox(height: 16),
                                    Text('جدول السداد', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                                    const SizedBox(height: 8),
                                    for (final l in schedule)
                                      Container(
                                        margin: const EdgeInsets.only(bottom: 8),
                                        padding: const EdgeInsets.all(12),
                                        decoration: JphUi.box(isDark),
                                        child: Row(children: [
                                          SizedBox(width: 56, child: Text(l['seq'] == 0 ? 'المقدم' : '#${l['seq']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                                          Expanded(
                                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                              Text('${l['dueDate']} • ${JphUi.money(l['amount'])}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                                              Text('مدفوع ${JphUi.money(l['paid'])} • باقي ${JphUi.money(l['remaining'])}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                                            ]),
                                          ),
                                          JphUi.chip((_lineStatus[l['status']] ?? ('${l['status']}', Ar.grey)).$1, (_lineStatus[l['status']] ?? ('', Ar.grey)).$2),
                                          if (can['collect'] == true && ((l['remaining'] as num?) ?? 0) > 0)
                                            IconButton(tooltip: 'تحصيل', icon: Icon(Icons.add_card_rounded, color: JphUi.primary(isDark)), onPressed: () => _collect(l)),
                                        ]),
                                      ),
                                    const SizedBox(height: 16),
                                    Text('الإيصالات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                                    const SizedBox(height: 8),
                                    if (receipts.isEmpty) Text('مفيش تحصيلات لسه', style: TextStyle(color: JphUi.sub(isDark))),
                                    for (final x in receipts)
                                      Container(
                                        margin: const EdgeInsets.only(bottom: 8),
                                        padding: const EdgeInsets.all(12),
                                        decoration: JphUi.box(isDark),
                                        child: Row(children: [
                                          Expanded(
                                            child: Text('${x['receiptNo']} • ${x['kindAr']} • ${JphUi.date(x['occurredAt'])} • استلمها ${x['actualRecipientName']}${x['status'] == 'reversed' ? ' (اتعكس)' : ''}',
                                                style: TextStyle(color: JphUi.text(isDark))),
                                          ),
                                          CountUpText(JphUi.money(x['amount']), style: const TextStyle(fontWeight: FontWeight.w900, color: Ar.green)),
                                        ]),
                                      ),
                                    if (refunds.isNotEmpty) ...[
                                      const SizedBox(height: 16),
                                      Text('الاسترداد', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                                      for (final x in refunds)
                                        ListTile(title: Text('#${x['refNo']} • ${JphUi.date(x['at'])}'), trailing: CountUpText(JphUi.money(x['amount']), style: const TextStyle(color: Ar.red, fontWeight: FontWeight.w900))),
                                    ],
                                  ]),
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
