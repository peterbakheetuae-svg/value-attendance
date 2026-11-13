import 'package:flutter/material.dart';

import '../pages/cash/cash_page.dart';
import '../pages/sales/sales_page.dart';
import '../services/api_service.dart';
import 'jph_form_ui.dart';
import 'glass_dialog.dart';
import 'glass_ui.dart';

/// تبويب "مبيعات" في طلبات المالية: بيع وحدة (كاش أو تقسيط) ببيانات العميل، ومعاه طلب العمولة.
///  - السيلز: البيعة بتروح للإدارة تعتمدها، وطلب العمولة باسمه.
///  - الـ HR / المدير: البيعة بتتسجل على طول، ويقدروا يختاروا الموظف صاحب العمولة.
/// تحت الفورم: مبيعاتي، وللإدارة البيعات اللي مستنية الاعتماد.
class SalesTab extends StatefulWidget {
  final bool isDark;
  const SalesTab({super.key, required this.isDark});

  @override
  State<SalesTab> createState() => _SalesTabState();
}

const _freqAr = {'monthly': 'شهري', 'quarterly': 'كل 3 شهور', 'semiannual': 'كل 6 شهور', 'annual': 'سنوي'};

(String, Color) saleStatusAr(String? s) => switch (s) {
      'pending' => ('مستنية اعتماد الإدارة', Ar.amber),
      'active' => ('معتمدة', Ar.green),
      'rejected' => ('مرفوضة', Ar.red),
      'cancelled' => ('ملغية', Ar.grey),
      _ => ('--', Ar.grey),
    };

String _iso(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _SalesTabState extends State<SalesTab> {
  List<Map<String, dynamic>> _projects = [];
  List<Map<String, dynamic>> _people = [];
  Map<String, dynamic>? _project;
  String? _seller; // commission owner (HR / المدير only); null = me
  bool _withCommission = true;
  bool _installments = false;
  String _freq = 'monthly';
  DateTime _downDue = DateTime.now();
  DateTime _firstDue = DateTime(DateTime.now().year, DateTime.now().month + 1, DateTime.now().day);
  bool _loading = true, _saving = false;
  Map<String, dynamic> _can = {};
  List<Map<String, dynamic>> _mine = [];
  List<Map<String, dynamic>> _pending = [];

  final _unit = TextEditingController();
  final _price = TextEditingController();
  final _area = TextEditingController();
  final _client = TextEditingController();
  final _phone = TextEditingController();
  final _down = TextEditingController();
  final _count = TextEditingController();
  final _notes = TextEditingController();

  bool get _manage => _can['manage'] == true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_unit, _price, _area, _client, _phone, _down, _count, _notes]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final pr = await ApiService.post({'action': 'commission_projects', 'status': 'active'});
    final mine = await cashGet('/sales', {'mine': '1'});
    final can = ((mine['can'] as Map?) ?? const {}).cast<String, dynamic>();
    Map<String, dynamic> pend = {};
    if (can['approve'] == true) pend = await cashGet('/sales', {'status': 'pending'});
    List<Map<String, dynamic>> people = [];
    if (can['manage'] == true) {
      final r = await ApiService.post({'action': 'getActiveEmployees'});
      people = ((r['employees'] as List?) ?? const []).whereType<Map>()
          .map((m) => <String, dynamic>{'id': '${m['id']}', 'name': '${m['name']}'}).toList();
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _projects = ((pr['projects'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>())
          .where((p) => p['status'] == 'active').toList();
      _can = can;
      _mine = cashList(mine, 'sales');
      _pending = cashList(pend, 'sales');
      _people = people;
    });
  }

  num? _n(TextEditingController c) => num.tryParse(c.text.trim().replaceAll(',', ''));
  num? get _total => (_n(_price) != null && _n(_area) != null) ? ((_n(_price)! * _n(_area)!) * 100).round() / 100 : null;
  num? get _commission =>
      (_total != null && _project?['salesPct'] != null) ? ((_total! * (_project!['salesPct'] as num) / 100) * 100).round() / 100 : null;
  num? get _each {
    final rest = (_total ?? 0) - (_n(_down) ?? 0), n = _n(_count);
    if (!_installments || n == null || n <= 0 || rest <= 0) return null;
    return (rest / n * 100).floor() / 100;
  }

  Future<void> _pickDate(bool first) async {
    final d = await showDatePicker(
      context: context,
      initialDate: first ? _firstDue : _downDue,
      firstDate: DateTime(2020),
      lastDate: DateTime(2045),
      locale: const Locale('ar'),
    );
    if (d != null) setState(() => first ? _firstDue = d : _downDue = d);
  }

  Future<void> _submit() async {
    String? err;
    final total = _total;
    if (_project == null) {
      err = 'اختار المشروع';
    } else if (_unit.text.trim().isEmpty) {
      err = 'اكتب رقم الوحدة';
    } else if (total == null || total <= 0) {
      err = 'اكتب المساحة وسعر المتر';
    } else if (_client.text.trim().length < 2) {
      err = 'اكتب اسم العميل';
    } else if (_phone.text.trim().length < 8) {
      err = 'اكتب رقم موبايل العميل';
    } else if (_installments && ((_n(_count) ?? 0) < 1)) {
      err = 'اكتب عدد الأقساط';
    } else if (_installments && (_n(_down) ?? 0) >= total) {
      err = 'المقدم لازم يبقى أقل من الإجمالي في التقسيط';
    }
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err), backgroundColor: Ar.red));
      return;
    }
    setState(() => _saving = true);
    final now = DateTime.now();
    final r = await cashPost('/sales', {
      'projectId': _project!['id'], 'unitNo': _unit.text.trim(),
      'buyerName': _client.text.trim(), 'buyerPhone': _phone.text.trim(),
      'totalPrice': total, 'saleDate': _iso(now),
      'downPayment': _installments ? (_n(_down) ?? 0) : total,
      'downPaymentDueDate': _iso(_installments ? _downDue : now),
      if (_installments) ...{'frequency': _freq, 'installmentsCount': _n(_count)!.toInt(), 'firstDueDate': _iso(_firstDue)},
      'notes': _notes.text.trim(),
      'withCommission': _withCommission,
      if (_withCommission) ...{'pricePerM2': _n(_price), 'areaM2': _n(_area), if (_manage && _seller != null) 'employeeId': _seller},
    }, ok: _manage ? 'اتسجلت البيعة ✅' : 'اتبعتت البيعة للإدارة تعتمدها ✅');
    if (!mounted) return;
    setState(() => _saving = false);
    JphUi.toast(context, r);
    if (r['success'] == true) {
      for (final c in [_unit, _price, _area, _client, _phone, _down, _count, _notes]) {
        c.clear();
      }
      setState(() => _seller = null);
      _load();
    }
  }

  Future<void> _decide(Map<String, dynamic> s, bool approve) async {
    final reason = TextEditingController();
    if (!approve) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => GlassAlertDialog(
          title: const Text('رفض البيعة'),
          content: TextField(controller: reason, decoration: const InputDecoration(hintText: 'السبب')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('رجوع')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('رفض', style: TextStyle(color: Ar.red))),
          ],
        ),
      );
      if (go != true) return;
    }
    final r = await cashPost('/sales/${s['id']}/decision',
        {'decision': approve ? 'approve' : 'reject', if (!approve) 'reason': reason.text.trim()},
        ok: approve ? 'اتعتمدت ✅' : 'اترفضت');
    if (!mounted) return;
    JphUi.toast(context, r);
    _load();
  }

  Widget _saleCard(Map<String, dynamic> s, {bool decide = false}) {
    final isDark = widget.isDark;
    final st = saleStatusAr('${s['status']}');
    final com = s['commission'] as Map?;
    return GestureDetector(
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => SaleDetailsPage(saleId: '${s['id']}')));
        _load();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: JphUi.box(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            JphUi.iconTile(isDark, Icons.home_work_rounded, st.$2),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${s['projectName']} — وحدة ${s['unitNo']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                Text('${s['buyerName']}  •  ${s['buyerPhone'] ?? ''}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                if (decide) Text('سجلها: ${s['createdByName']}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
              ]),
            ),
            JphUi.chip(st.$1, st.$2),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 6, children: [
            JphUi.chip(JphUi.money(s['totalPrice']), Ar.accent),
            JphUi.chip(s['paymentMethod'] == 'installments' ? 'تقسيط (${s['installmentsCount']} قسط)' : 'كاش', Ar.green),
            if (com != null) JphUi.chip('عمولة ${com['employeeName'] ?? ''}: ${commissionStatus('${com['status']}').$1}', commissionStatus('${com['status']}').$2),
          ]),
          if ('${s['rejectReason'] ?? ''}'.isNotEmpty)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text('السبب: ${s['rejectReason']}', style: const TextStyle(color: Ar.red, fontSize: 12.5))),
          if (decide)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _decide(s, true),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('اعتماد'),
                    style: ElevatedButton.styleFrom(backgroundColor: Ar.green, foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _decide(s, false),
                    icon: const Icon(Icons.close_rounded, color: Ar.red),
                    label: const Text('رفض', style: TextStyle(color: Ar.red)),
                    style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                  ),
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final primary = JphUi.primary(isDark);
    if (_loading) return const Center(child: CircularProgressIndicator());
    final sellerName = _seller == null ? 'أنا' : _people.where((p) => p['id'] == _seller).map((p) => '${p['name']}').firstOrNull ?? 'أنا';
    final pending = _pending;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        if (pending.isNotEmpty) ...[
          Text('مستنية اعتمادك (${pending.length})', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
          const SizedBox(height: 8),
          for (final s in pending) _saleCard(s, decide: true),
          const SizedBox(height: 12),
        ],
        Text('بيع وحدة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
        const SizedBox(height: 12),
        JphUi.picker(
          isDark: isDark, icon: Icons.apartment_rounded, iconColor: Ar.accent, label: 'المشروع *',
          value: _project == null ? (_projects.isEmpty ? 'مفيش مشاريع متاحة' : 'اختار المشروع') : '${_project!['name']}',
          onTap: () async {
            final v = await JphUi.sheet<String>(context, isDark, 'اختار المشروع',
                [for (final p in _projects) ('${p['id']}', '${p['name']}', Icons.apartment_rounded)],
                selected: _project?['id']?.toString(), icon: Icons.apartment_rounded);
            if (v != null) setState(() => _project = _projects.firstWhere((p) => '${p['id']}' == v));
          },
        ),
        const SizedBox(height: 14),
        JphUi.input(isDark: isDark, label: 'رقم الوحدة *', controller: _unit, hint: 'مثال: A-101', icon: Icons.tag_rounded, big: false),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: JphUi.input(isDark: isDark, label: 'المساحة (م²) *', controller: _area, hint: '150', number: true,
              icon: Icons.square_foot_rounded, onChanged: (_) => setState(() {}))),
          const SizedBox(width: 12),
          Expanded(child: JphUi.input(isDark: isDark, label: 'سعر المتر *', controller: _price, hint: '30000', number: true,
              icon: Icons.sell_rounded, onChanged: (_) => setState(() {}))),
        ]),
        const SizedBox(height: 14),
        JphUi.readOnly(isDark: isDark, label: 'إجمالي قيمة الوحدة', value: JphUi.money(_total), icon: Icons.home_work_rounded, color: Ar.info),
        const SizedBox(height: 18),
        Text('بيانات العميل', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
        const SizedBox(height: 10),
        JphUi.input(isDark: isDark, label: 'اسم العميل *', controller: _client, icon: Icons.person_rounded, big: false),
        const SizedBox(height: 14),
        JphUi.input(isDark: isDark, label: 'رقم الموبايل *', controller: _phone, hint: '01xxxxxxxxx', icon: Icons.phone_iphone_rounded,
            number: true, big: false),
        const SizedBox(height: 18),
        Text('طريقة الدفع', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
        const SizedBox(height: 10),
        JphUi.tabs(isDark, const [('كاش', Icons.payments_rounded), ('تقسيط', Icons.calendar_view_month_rounded)], _installments ? 1 : 0,
            (i) => setState(() => _installments = i == 1)),
        if (_installments) ...[
          const SizedBox(height: 14),
          JphUi.input(isDark: isDark, label: 'المقدم', controller: _down, hint: '0', number: true, icon: Icons.savings_rounded,
              onChanged: (_) => setState(() {})),
          const SizedBox(height: 14),
          JphUi.picker(isDark: isDark, icon: Icons.event_rounded, iconColor: Ar.amber, label: 'ميعاد دفع المقدم',
              value: JphUi.date(_downDue.toIso8601String()), onTap: () => _pickDate(false)),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: JphUi.input(isDark: isDark, label: 'عدد الأقساط *', controller: _count, hint: '36', number: true,
                icon: Icons.format_list_numbered_rounded, onChanged: (_) => setState(() {}), big: false)),
            const SizedBox(width: 12),
            Expanded(
              child: JphUi.picker(isDark: isDark, icon: Icons.repeat_rounded, iconColor: Ar.accent, label: 'كل قد إيه',
                  value: _freqAr[_freq]!, onTap: () async {
                final v = await JphUi.sheet<String>(context, isDark, 'دورية الأقساط',
                    [for (final e in _freqAr.entries) (e.key, e.value, Icons.repeat_rounded)], selected: _freq, icon: Icons.repeat_rounded);
                if (v != null) setState(() => _freq = v);
              }),
            ),
          ]),
          const SizedBox(height: 14),
          JphUi.picker(isDark: isDark, icon: Icons.event_available_rounded, iconColor: Ar.green, label: 'ميعاد أول قسط',
              value: JphUi.date(_firstDue.toIso8601String()), onTap: () => _pickDate(true)),
          if (_each != null) ...[
            const SizedBox(height: 14),
            JphUi.readOnly(isDark: isDark, label: 'قيمة القسط تقريبًا', value: JphUi.money(_each), icon: Icons.calculate_rounded, color: Ar.green),
          ],
        ],
        const SizedBox(height: 18),
        Container(
          decoration: JphUi.box(isDark),
          child: SwitchListTile(
            value: _withCommission,
            onChanged: (v) => setState(() => _withCommission = v),
            activeColor: primary,
            title: Text('مع طلب عمولة', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
            subtitle: Text(_project == null ? 'اختار المشروع الأول' : 'العمولة المتوقعة: ${JphUi.money(_commission)} (${JphUi.pct(_project?['salesPct'])})',
                style: TextStyle(color: JphUi.sub(isDark))),
          ),
        ),
        if (_withCommission && _manage) ...[
          const SizedBox(height: 14),
          JphUi.picker(
            isDark: isDark, icon: Icons.badge_rounded, iconColor: Ar.green, label: 'العمولة لمين', value: sellerName,
            onTap: () async {
              final v = await JphUi.sheet<String>(context, isDark, 'اختار الموظف صاحب العمولة',
                  [('', 'أنا', Icons.person_rounded), for (final p in _people) ('${p['id']}', '${p['name']}', Icons.person_outline_rounded)],
                  selected: _seller ?? '', icon: Icons.badge_rounded);
              if (v != null) setState(() => _seller = v.isEmpty ? null : v);
            },
          ),
        ],
        const SizedBox(height: 14),
        JphUi.input(isDark: isDark, label: 'ملاحظات (اختياري)', controller: _notes, icon: Icons.notes_rounded, big: false),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: isDark ? Ar.amber.shade900.withOpacity(0.25) : Ar.amber.shade50,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: isDark ? Ar.amber.shade700 : Ar.amber.shade200, width: 1.5),
          ),
          child: Row(children: [
            Icon(Icons.info_outline_rounded, color: isDark ? Ar.amber.shade300 : Ar.amber.shade800),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                  _manage
                      ? 'البيعة بتتسجل على طول وجدول الأقساط بيتعمل لوحده. طلب العمولة بيروح للمدير العام يعتمده ويحدد شهر نزولها.'
                      : 'البيعة بتروح للإدارة تعتمدها قبل أي تحصيل، وطلب العمولة بيروح للمدير العام يعتمده.',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? Ar.amber.shade200 : Ar.amber.shade900)),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 58,
          child: ElevatedButton.icon(
            onPressed: _saving ? null : _submit,
            icon: _saving
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send_rounded),
            label: Text(_manage ? 'تسجيل البيعة' : 'إرسال البيعة للاعتماد', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            style: ElevatedButton.styleFrom(backgroundColor: primary, foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
          ),
        ),
        const SizedBox(height: 24),
        Text('مبيعاتي', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
        const SizedBox(height: 8),
        if (_mine.isEmpty) Text('لسه مفيش', style: TextStyle(color: JphUi.sub(isDark))),
        for (final s in _mine) _saleCard(s),
      ]),
    );
  }
}
