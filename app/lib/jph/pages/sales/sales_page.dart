import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/jph_form_ui.dart';
import '../cash/cash_page.dart';

/// المبيعات والأقساط — the operational page for HR and the manager (the Projects page stays as it is):
///  • الأقساط المستحقة: every open installment with filters (overdue, today, dates, project, unit, buyer).
///  • الوحدات المباعة: registered sales, a new sale, and each sale's schedule / collections / cancellation.
class SalesPage extends StatefulWidget {
  const SalesPage({super.key});

  @override
  State<SalesPage> createState() => _SalesPageState();
}

const _lineStatus = {
  'not_due': ('لسه مجاش ميعاده', Colors.blueGrey), 'due': ('مستحق النهارده', Colors.blue), 'partial': ('مدفوع جزئياً', Colors.orange),
  'paid': ('مدفوع', Colors.green), 'overdue': ('متأخر', Colors.red), 'cancelled': ('ملغي', Colors.grey),
};
const _freqAr = {'monthly': 'شهري', 'quarterly': 'كل 3 شهور', 'semiannual': 'كل 6 شهور', 'annual': 'سنوي'};
const _stageAr = {
  'reserved': ('حجز — المقدم لسه مكملش', Colors.orange), 'installments': ('أقساط', Colors.blue),
  'completed': ('اتسدد بالكامل', Colors.green), 'cancelled': ('ملغي', Colors.grey),
};

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _SalesPageState extends State<SalesPage> {
  String _tab = 'due';

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
                JphUi.header(context, isDark: isDark, isRTL: isRTL, title: 'المبيعات والأقساط'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: cashSegmented(isDark, {'due': 'الأقساط المستحقة', 'sales': 'الوحدات المباعة'}, _tab, (v) => setState(() => _tab = v)),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      child: _tab == 'due' ? _DueTab(isDark: isDark) : _SalesTab(isDark: isDark),
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
class _DueTab extends StatefulWidget {
  final bool isDark;
  const _DueTab({required this.isDark});

  @override
  State<_DueTab> createState() => _DueTabState();
}

class _DueTabState extends State<_DueTab> {
  String _filter = 'open'; // open | overdue | today | range
  DateTimeRange? _range;
  final _q = TextEditingController();
  Map<String, dynamic> _r = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final q = _q.text.trim();
    final r = await cashGet('/sales/installments/due', {
      if (_filter == 'overdue') 'overdue': '1',
      if (_filter == 'today') 'today': '1',
      if (_filter == 'range' && _range != null) 'from': _iso(_range!.start),
      if (_filter == 'range' && _range != null) 'to': _iso(_range!.end),
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
        cashSegmented(isDark, {'open': 'كل المفتوح', 'overdue': 'المتأخر', 'today': 'مستحق النهارده', 'range': 'فترة'}, _filter, (v) async {
          if (v == 'range') {
            final now = DateTime.now();
            final picked = await showDateRangePicker(context: context, firstDate: DateTime(now.year - 2), lastDate: DateTime(now.year + 10),
                initialDateRange: _range ?? DateTimeRange(start: now, end: now.add(const Duration(days: 30))));
            if (picked == null) return;
            _range = picked;
          }
          setState(() => _filter = v);
          _load();
        }),
        const SizedBox(height: 10),
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
          Expanded(child: JphUi.stat(isDark, 'الباقي', JphUi.money(totals['remaining']), Icons.hourglass_bottom_rounded, Colors.orange)),
          const SizedBox(width: 10),
          Expanded(child: JphUi.stat(isDark, 'منه متأخر', JphUi.money(totals['overdue']), Icons.warning_rounded, Colors.red)),
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
                JphUi.iconTile(isDark, Icons.event_note_rounded, (_lineStatus[x['status']] ?? ('', Colors.grey)).$2),
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
                  Text(JphUi.money(x['remaining']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  const SizedBox(height: 4),
                  JphUi.chip((_lineStatus[x['status']] ?? ('${x['status']}', Colors.grey)).$1, (_lineStatus[x['status']] ?? ('', Colors.grey)).$2),
                ]),
              ]),
            ),
          ),
      ]),
    );
  }
}

// ==================================================================== الوحدات المباعة
class _SalesTab extends StatefulWidget {
  final bool isDark;
  const _SalesTab({required this.isDark});

  @override
  State<_SalesTab> createState() => _SalesTabState();
}

class _SalesTabState extends State<_SalesTab> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await cashGet('/sales', {'q': _q.text.trim()});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = cashList(r, 'sales');
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        if (ApiService.can('sales.manage'))
          cashBigButton(isDark, 'تسجيل بيع وحدة', Icons.add_home_work_rounded, () async {
            final id = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const NewSalePage()));
            await _load();
            if (id != null && context.mounted) {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => SaleDetailsPage(saleId: id)));
              _load();
            }
          }),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: JphUi.box(isDark),
          child: TextField(
            controller: _q,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(hintText: 'ابحث بالمشتري أو رقم الوحدة أو الموبايل', border: InputBorder.none,
                prefixIcon: Icon(Icons.search_rounded, color: JphUi.primary(isDark))),
          ),
        ),
        const SizedBox(height: 10),
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _items.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش مبيعات مسجلة', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final s in _items)
          GestureDetector(
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => SaleDetailsPage(saleId: '${s['id']}')));
              _load();
            },
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: JphUi.box(isDark),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  JphUi.iconTile(isDark, Icons.home_work_rounded, Colors.indigo),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${s['projectName']} — وحدة ${s['unitNo']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                      Text('${s['buyerName']} • ${s['saleDate']} • #${s['refNo']}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                    ]),
                  ),
                  JphUi.chip((_stageAr[s['stage']] ?? ('${s['stage']}', Colors.grey)).$1, (_stageAr[s['stage']] ?? ('', Colors.grey)).$2),
                ]),
                const SizedBox(height: 8),
                Wrap(spacing: 14, runSpacing: 4, children: [
                  Text('السعر: ${JphUi.money(s['totalPrice'])}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text('المحصّل: ${JphUi.money(s['collected'])}', style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.green)),
                  Text('الباقي: ${JphUi.money(s['remaining'])}', style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.orange)),
                ]),
              ]),
            ),
          ),
      ]),
    );
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
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err), backgroundColor: Colors.red));
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
                        JphUi.picker(isDark: isDark, icon: Icons.apartment_rounded, iconColor: Colors.indigo, label: 'المشروع *',
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
                          Expanded(child: JphUi.picker(isDark: isDark, icon: Icons.event_rounded, iconColor: Colors.teal, label: 'تاريخ البيع',
                              value: _iso(_saleDate), onTap: () => _pickDate(_saleDate, (d) => _saleDate = d))),
                          const SizedBox(width: 10),
                          Expanded(child: JphUi.picker(isDark: isDark, icon: Icons.event_available_rounded, iconColor: Colors.orange, label: 'ميعاد المقدم',
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
                          JphUi.picker(isDark: isDark, icon: Icons.calendar_month_rounded, iconColor: Colors.purple, label: 'ميعاد أول قسط *',
                              value: _firstDue == null ? 'اختار' : _iso(_firstDue!), onTap: () => _pickDate(_firstDue, (d) => _firstDue = d)),
                          if (_preview.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            JphUi.readOnly(isDark: isDark, label: 'جدول الأقساط (فرق التقريب على آخر قسط)', value: _preview, icon: Icons.table_chart_rounded, color: Colors.blue),
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
    final can = ApiService.can('cash.hr_operate');
    String recipient = can ? 'hr' : 'manager';
    String kind = 'down_payment', method = 'cash';
    final amount = TextEditingController(text: '${line['remaining']}');
    final ext = TextEditingController();
    final ref = newClientRef();
    await cashFormSheet(context, isDark, line['seq'] == 0 ? 'تحصيل الحجز / المقدم' : 'تحصيل قسط ${line['seq']}', (s) => [
          if (line['seq'] == 0) cashSegmented(isDark, {'reservation': 'مبلغ حجز', 'down_payment': 'مقدم'}, kind, (v) => s(() => kind = v)),
          const SizedBox(height: 10),
          Text('مين استلم الفلوس فعلاً؟', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
          const SizedBox(height: 6),
          cashSegmented(isDark, {if (can) 'hr': 'HR (خزينة HR)', 'manager': 'المدير بنفسه (خزينة المكتب)'}, recipient, (v) => s(() => recipient = v)),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'المبلغ (الباقي ${JphUi.money(line['remaining'])})', controller: amount, number: true, suffix: 'جنيه'),
          const SizedBox(height: 10),
          cashSegmented(isDark, const {'cash': 'كاش', 'bank_transfer': 'تحويل بنكي', 'cheque': 'شيك', 'card': 'كارت', 'wallet': 'محفظة'}, method, (v) => s(() => method = v)),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'رقم الإيصال الورقي (اختياري)', controller: ext, big: false),
        ], () async {
      String? managerId;
      if (recipient == 'manager' && !ApiService.can('cash.office')) {
        final r = await ApiService.post({'action': 'getActiveEmployees'});
        final people = ((r['employees'] as List?) ?? const []).whereType<Map>().toList();
        if (!mounted) return <String, dynamic>{'success': false, 'message': ''};
        managerId = await JphUi.sheet<String>(context, isDark, 'المدير اللي استلم', [for (final p in people) ('${p['id']}', '${p['name']}', Icons.person_rounded)]);
        if (managerId == null) return <String, dynamic>{'success': false, 'message': 'اختار المدير'};
      }
      final r = await cashPost('/sales/${widget.saleId}/collect', {
        'installmentId': line['id'], 'kind': kind, 'amount': num.tryParse(amount.text.trim()), 'recipient': recipient,
        if (managerId != null) 'recipientId': managerId, 'paymentMethod': method,
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

  Future<void> _refund(num due) async {
    final isDark = Provider.of<AppController>(context, listen: false).isDark;
    String box = ApiService.can('cash.office') ? 'office' : 'hr';
    final amount = TextEditingController(text: '$due');
    final reason = TextEditingController();
    await cashFormSheet(context, isDark, 'رد فلوس للمشتري', (s) => [
          cashSegmented(isDark, {if (ApiService.can('cash.office')) 'office': 'من خزينة المكتب', if (ApiService.can('cash.hr_operate')) 'hr': 'من خزينة HR'}, box,
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
                                          JphUi.iconTile(isDark, Icons.home_work_rounded, Colors.indigo),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                              Text('${sale['projectName']} — ${sale['unitNo']}', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                                              Text('${sale['buyerName']} • ${sale['buyerPhone']} • بيع #${sale['refNo']}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                                            ]),
                                          ),
                                          JphUi.chip((_stageAr[sale['stage']] ?? ('${sale['stage']}', Colors.grey)).$1, (_stageAr[sale['stage']] ?? ('', Colors.grey)).$2),
                                        ]),
                                        const SizedBox(height: 12),
                                        Wrap(spacing: 10, runSpacing: 10, children: [
                                          SizedBox(width: 150, child: JphUi.stat(isDark, 'السعر', JphUi.money(sale['totalPrice']), Icons.sell_rounded, Colors.indigo)),
                                          SizedBox(width: 150, child: JphUi.stat(isDark, 'المقدم المدفوع', '${JphUi.money(sale['downPaid'])} / ${JphUi.money(sale['downPayment'])}', Icons.payments_rounded, Colors.teal)),
                                          SizedBox(width: 150, child: JphUi.stat(isDark, 'المحصّل', JphUi.money(sale['collected']), Icons.check_circle_rounded, Colors.green)),
                                          SizedBox(width: 150, child: JphUi.stat(isDark, 'الباقي', JphUi.money(sale['remaining']), Icons.hourglass_bottom_rounded, Colors.orange)),
                                          if (sale['status'] == 'cancelled')
                                            SizedBox(width: 150, child: JphUi.stat(isDark, 'مستحق استرداد', JphUi.money(sale['refundDue']), Icons.undo_rounded, Colors.red)),
                                        ]),
                                        if (sale['status'] == 'cancelled')
                                          Padding(padding: const EdgeInsets.only(top: 8), child: Text('اتلغى: ${sale['cancelReason'] ?? ''}', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w700))),
                                        Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
                                          if (can['cancel'] == true)
                                            TextButton.icon(onPressed: _cancel, icon: const Icon(Icons.block_rounded, color: Colors.red),
                                                label: const Text('إلغاء البيع', style: TextStyle(color: Colors.red))),
                                          if (can['refund'] == true && ((sale['refundDue'] as num?) ?? 0) > 0)
                                            ElevatedButton.icon(onPressed: () => _refund(sale['refundDue'] as num), icon: const Icon(Icons.undo_rounded),
                                                label: const Text('رد فلوس'), style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white)),
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
                                          JphUi.chip((_lineStatus[l['status']] ?? ('${l['status']}', Colors.grey)).$1, (_lineStatus[l['status']] ?? ('', Colors.grey)).$2),
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
                                          Text(JphUi.money(x['amount']), style: const TextStyle(fontWeight: FontWeight.w900, color: Colors.green)),
                                        ]),
                                      ),
                                    if (refunds.isNotEmpty) ...[
                                      const SizedBox(height: 16),
                                      Text('الاسترداد', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                                      for (final x in refunds)
                                        ListTile(title: Text('#${x['refNo']} • ${JphUi.date(x['at'])}'), trailing: Text(JphUi.money(x['amount']), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w900))),
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
