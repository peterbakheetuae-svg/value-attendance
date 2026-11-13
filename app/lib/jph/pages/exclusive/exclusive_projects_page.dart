import '../../widgets/side_sheet.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_dialog.dart';
import '../../widgets/doc_logos.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../commissions/commission_project_page.dart';
import '../attendance/attendance_widgets.dart' show SquareIconButton;
import '../../forms/reservation_form_pdf.dart';

part '../projects/projects_hub.dart';

/// المشاريع الحصري — the office holds every payment for the project's owner and earns its commission in stages.
///  - السيلز: حجز وحدة، طلب تعاقد، طلب إلغاء.
///  - المحاسب: تسجيل العربون / المقدم / الأقساط (نقدي أو بنك)، رد العربون.
///  - المالك / المدير العام: موافقة التعاقد والإلغاء، تحويل العمولة من الأمانة، إذن صرف للمالك.
class ExclusiveProjectsPage extends StatelessWidget {
  const ExclusiveProjectsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    return _Shell(title: 'المشاريع الحصري', child: ExclusiveProjectsList(isDark: app.isDark));
  }
}

class _Shell extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? action;
  const _Shell({required this.title, required this.child, this.action});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    return AppBackground(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: app.isDark, isRTL: true, title: title, action: action),
              Expanded(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1000), child: child))),
            ]),
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ helpers
Map<String, dynamic> _m(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
List<Map<String, dynamic>> _l(Object? v) => ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
num _n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
String _money(Object? v) => JphUi.money(v);
String _date(Object? v) {
  final d = DateTime.tryParse('${v ?? ''}');
  return d == null ? '' : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

Future<Map<String, dynamic>> _get(String path, [Map<String, String>? q]) =>
    ApiService.post({'action': 'cash_get', 'path': path, if (q != null) 'query': q});
/// حصري / تسويق is المالك / المدير العام's and the accountant's business only — nobody else sees which is which.
bool _seesKind() => ApiService.can('cash.office') || ApiService.can('cash.hr_operate');

Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, String ok, {String? method}) =>
    ApiService.post({'action': 'cash_post', 'path': path, 'body': body, 'ok': ok, if (method != null) 'method': method});

Widget _kv(bool isDark, String k, String v, {Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(child: Text(k, style: TextStyle(fontSize: 14, color: JphUi.sub(isDark)))),
        // amounts and percentages count up like the dashboard's figures
        (v.endsWith('جنيه') || v.endsWith('%') ? CountUpText(v, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color ?? JphUi.text(isDark))) : Text(v, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color ?? JphUi.text(isDark)))),
      ]),
    );

Widget _section(bool isDark, String title, List<Widget> children, {Widget? trailing}) => Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
          if (trailing != null) trailing,
        ]),
        const SizedBox(height: 10),
        ...children,
      ]),
    );

Widget _btn(bool isDark, String label, IconData icon, VoidCallback onTap, {Color? color}) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SizedBox(
        height: 50,
        child: ElevatedButton.icon(
          onPressed: onTap,
          icon: Icon(icon),
          label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          style: ElevatedButton.styleFrom(
            backgroundColor: color ?? JphUi.primary(isDark), foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
      ),
    );

Color _statusColor(String s) => switch (s) {
      'reserving' => Ar.amber,
      'reserved' => Ar.accent,
      'contract_pending' || 'cancel_pending' => Ar.amber,
      'contracted' => Ar.green,
      'completed' => Ar.green,
      'cancelled' => Ar.grey,
      _ => Ar.grey,
    };

Widget _pill(String t, Color c) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.circular(20)),
      child: Text(t, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: c)),
    );

/// A bottom sheet with fields and one save button; returns true when saved.
Future<bool> _form(BuildContext context, bool isDark, String title, List<Widget> Function(StateSetter set) fields,
    Future<bool> Function() save, {String saveLabel = 'حفظ'}) async {
  final r = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Directionality(
      textDirection: ui.TextDirection.rtl,
      child: StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.9),
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(16),
            decoration: Glass.sheet(isDark, r: 24),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                  IconButton(onPressed: () => Navigator.pop(ctx, false), icon: Icon(Icons.close_rounded, color: JphUi.sub(isDark))),
                ]),
                const SizedBox(height: 8),
                ...fields(set).expand((w) => [w, const SizedBox(height: 10)]),
                const SizedBox(height: 6),
                _btn(isDark, saveLabel, Icons.check_rounded, () async {
                  if (await save() && ctx.mounted) Navigator.pop(ctx, true);
                }),
              ]),
            ),
          ),
        ),
      ),
    ),
  );
  return r == true;
}

Widget _methodPicker(BuildContext context, bool isDark, String method, ValueChanged<String> onPick) => JphUi.picker(
      isDark: isDark, icon: method == 'cash' ? Icons.payments_rounded : Icons.account_balance_rounded,
      iconColor: method == 'cash' ? Ar.green : Ar.accent, label: 'الفلوس', value: method == 'cash' ? 'نقدي' : 'بنك',
      onTap: () async {
        final v = await JphUi.sheet<String>(context, isDark, 'الفلوس', [
          ('cash', 'نقدي', Icons.payments_rounded),
          ('bank_transfer', 'بنك (تحويل)', Icons.account_balance_rounded),
          ('cheque', 'شيك', Icons.receipt_rounded),
          ('card', 'كارت', Icons.credit_card_rounded),
          ('wallet', 'محفظة', Icons.phone_iphone_rounded),
        ], selected: method);
        if (v != null) onPick(v);
      },
    );

// ==================================================================== the list
class ExclusiveProjectsList extends StatefulWidget {
  final bool isDark;
  const ExclusiveProjectsList({super.key, required this.isDark});

  @override
  State<ExclusiveProjectsList> createState() => _ExclusiveProjectsListState();
}

class _ExclusiveProjectsListState extends State<ExclusiveProjectsList> {
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];
  bool _manage = false, _reserve = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/exclusive/projects');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = _l(r['projects']);
      _manage = r['canManage'] == true;
      _reserve = r['canReserve'] == true;
    });
  }

  Future<void> _add() async {
    final isDark = widget.isDark;
    final name = TextEditingController(), owner = TextEditingController(), phone = TextEditingController();
    final total = TextEditingController(text: '5'), contract = TextEditingController(text: '3'), sales = TextEditingController(text: '0.2'),
        manager = TextEditingController(text: '0.1'), inst = TextEditingController(text: '0.5');
    final ok = await _form(context, isDark, 'مشروع حصري جديد', (set) => [
          JphUi.input(isDark: isDark, label: 'اسم المشروع', controller: name, icon: Icons.apartment_rounded),
          JphUi.input(isDark: isDark, label: 'اسم مالك العقار', controller: owner, icon: Icons.person_rounded),
          JphUi.input(isDark: isDark, label: 'تليفون المالك', controller: phone, icon: Icons.phone_rounded, number: true),
          JphUi.input(isDark: isDark, label: 'إجمالي عمولتي ٪', controller: total, number: true, icon: Icons.percent_rounded),
          JphUi.input(isDark: isDark, label: 'منها عند التعاقد ٪', controller: contract, number: true, icon: Icons.handshake_rounded),
          JphUi.input(isDark: isDark, label: 'السيلز ٪ (من نسبة التعاقد)', controller: sales, number: true, icon: Icons.person_outline_rounded),
          JphUi.input(isDark: isDark, label: 'مدير المبيعات ٪', controller: manager, number: true, icon: Icons.groups_rounded),
          JphUi.input(isDark: isDark, label: 'نسبة كل قسط ٪ (افتراضي — تتغير لكل وحدة)', controller: inst, number: true, icon: Icons.event_repeat_rounded),
        ], () async {
      final r = await _post('/exclusive/projects', {
        'name': name.text.trim(), 'ownerName': owner.text.trim(), 'ownerPhone': phone.text.trim(),
        'totalPct': num.tryParse(total.text), 'contractPct': num.tryParse(contract.text), 'salesPct': num.tryParse(sales.text),
        'managerPct': num.tryParse(manager.text), 'installmentPct': num.tryParse(inst.text),
      }, 'اتضاف المشروع ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
        if (_manage) _btn(isDark, 'إضافة مشروع حصري', Icons.add_rounded, _add),
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _items.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('لسه مفيش مشاريع حصري', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final p in _items) _projectCard(p),
      ]),
    );
  }

  Widget _projectCard(Map<String, dynamic> p) {
    final isDark = widget.isDark;
    final st = _m(p['stats']);
    final u = _m(st['units']), cm = _m(st['commission']), ow = _m(st['owner']);
    return GestureDetector(
      onTap: () async {
        await pushSide(context, ExclusiveProjectPage(projectId: '${p['id']}'));
        _load();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: JphUi.box(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            JphUi.iconTile(isDark, Icons.apartment_rounded, Ar.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${p['name']}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                Text('المالك: ${p['ownerName'] ?? ''}', style: TextStyle(fontSize: 13, color: JphUi.sub(isDark))),
              ]),
            ),
            if (p['status'] != 'active') _pill(p['status'] == 'paused' ? 'متوقف' : 'مقفول', Ar.amber),
            Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _pill('عمولة ${JphUi.pct(p['totalPct'])}', Ar.accent),
            _pill('عند التعاقد ${JphUi.pct(p['contractPct'])}', Ar.green),
            if (_seesKind()) _pill('القسط ${JphUi.pct(p['installmentPct'])}', Ar.accent),
            _pill('سيلز ${JphUi.pct(p['salesPct'])} · مدير ${JphUi.pct(p['managerPct'])}', Ar.grey),
          ]),
          if (st.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _pill('محجوز ${u['reserved']}', _statusColor('reserved')),
              _pill('متعاقد ${u['contracted']}', _statusColor('contracted')),
              _pill('مكتمل ${u['completed']}', _statusColor('completed')),
              _pill('ملغي ${u['cancelled']}', _statusColor('cancelled')),
            ]),
            const SizedBox(height: 8),
            _kv(isDark, 'في الأمانة', _money(ow['inTrust'])),
            _kv(isDark, 'المستحق للمالك', _money(ow['due'])),
            _kv(isDark, 'عمولة مستنية التحويل', _money(cm['pending']), color: Ar.amber),
          ],
        ]),
      ),
    );
  }
}

/// «المصدر»: the office (no marketing commission) or a marketing company paid by commission.
/// «مصدر العميل» — the same picker as «اختار الموظف» in تقرير الحضور: the office or a marketing company paid by commission.
Widget _sourcePicker(BuildContext context, bool isDark, List<Map<String, dynamic>> mks, Map<String, dynamic>? mk,
        void Function(Map<String, dynamic>?) onPick) =>
    Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      JphUi.picker(
        isDark: isDark,
        icon: Icons.campaign_rounded,
        iconColor: Ar.green,
        label: 'مصدر العميل',
        value: mk == null ? 'المكتب' : '${mk['name']}',
        onTap: () async {
          final v = await JphUi.sheet<String>(context, isDark, 'مصدر العميل', [
            ('office', 'المكتب', Icons.business_rounded),
            for (final m in mks) ('${m['id']}', '${m['name']}', Icons.campaign_rounded),
          ], selected: mk == null ? 'office' : '${mk['id']}', icon: Icons.campaign_rounded);
          if (v == null) return;
          onPick(v == 'office' ? null : mks.firstWhere((m) => '${m['id']}' == v));
        },
      ),
      if (mk == null && _seesKind()) Padding(padding: const EdgeInsets.only(top: 4),
          child: Text('المكتب = مفيش عمولة لشركة تسويق', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark)))),
    ]);

Widget _cashBankPicker(bool isDark, String method, ValueChanged<String> onPick) => Wrap(spacing: 8, children: [
      ChoiceChip(label: const Text('نقدي'), avatar: const Icon(Icons.payments_rounded, size: 18), selected: method == 'cash', onSelected: (_) => onPick('cash')),
      ChoiceChip(label: const Text('بنك'), avatar: const Icon(Icons.account_balance_rounded, size: 18), selected: method != 'cash',
          onSelected: (_) => onPick('bank_transfer')),
    ]);

/// The contract terms of an exclusive unit (كاش / تقسيط); a marketing unit needs none (its money is the developer's).
class _Terms {
  String type = 'installments';
  final down = TextEditingController(), count = TextEditingController(text: '8'), every = TextEditingController(text: '3'),
      note = TextEditingController();
  DateTime first = DateTime.now().add(const Duration(days: 90));

  List<Widget> fields(BuildContext context, bool isDark, StateSetter set, {required num? price, num deposit = 0}) => [
        if (deposit > 0)
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Ar.green.withOpacity(0.10), borderRadius: BorderRadius.circular(14)),
            child: Row(children: [
              const Icon(Icons.lock_rounded, color: Ar.green, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text('مبلغ الحجز (العربون) — مايتغيرش، وبيتخصم من المقدم',
                  style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark)))),
              CountUpText(_money(deposit), style: const TextStyle(fontWeight: FontWeight.w900, color: Ar.green)),
            ]),
          ),
        SegmentedButton<String>(
          segments: const [ButtonSegment(value: 'installments', label: Text('تقسيط')), ButtonSegment(value: 'cash', label: Text('كاش'))],
          selected: {type},
          onSelectionChanged: (s) => set(() => type = s.first),
        ),
        if (type == 'cash')
          Text('الكاش: السعر كله${price != null && price > 0 ? ' (${_money(price)})' : ''}'
              '${deposit > 0 && price != null ? ' — الباقي بعد العربون ${_money(price - deposit)}' : ''}', style: TextStyle(color: JphUi.sub(isDark)))
        else ...[
          JphUi.input(isDark: isDark, label: 'إجمالي مقدم التعاقد', controller: down, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
          if (deposit > 0)
            AnimatedBuilder(
              animation: down,
              builder: (_, __) {
                final d = num.tryParse(down.text.replaceAll(',', '')) ?? 0;
                return Text(d >= deposit ? 'الباقي من المقدم بعد العربون: ${_money(d - deposit)}' : 'المقدم لازم يكون أكبر من العربون',
                    style: TextStyle(fontWeight: FontWeight.w800, color: d >= deposit ? Ar.green : Ar.red));
              },
            ),
          JphUi.input(isDark: isDark, label: 'عدد الأقساط', controller: count, number: true, icon: Icons.format_list_numbered_rounded),
          JphUi.input(isDark: isDark, label: 'كل كام شهر', controller: every, number: true, icon: Icons.event_repeat_rounded),
          JphUi.picker(
            isDark: isDark, icon: Icons.event_rounded, iconColor: Ar.green, label: 'أول قسط', value: _date(first.toIso8601String()),
            onTap: () async {
              final d = await showDatePicker(context: context, initialDate: first, firstDate: DateTime.now(), lastDate: DateTime(DateTime.now().year + 15));
              if (d != null) set(() => first = d);
            },
          ),
        ],
      ];

  Map<String, dynamic> body() {
    final f = '${first.year}-${first.month.toString().padLeft(2, '0')}-${first.day.toString().padLeft(2, '0')}';
    return {
      'paymentType': type, 'note': note.text.trim(),
      if (type == 'installments') ...{'downPayment': num.tryParse(down.text.replaceAll(',', '')), 'installmentsCount': int.tryParse(count.text),
        'everyMonths': int.tryParse(every.text), 'firstDueDate': f},
    };
  }
}

/// «استمارة حجز وحدة» — the form's details, one form with the rest (no separate section): the unit (type / floor
/// picked like «اختار الموظف», net + loaded area, the meter price × the loaded area = the price), the maintenance
/// deposit and the agreed down payment (a % of the price or an amount), the dates and the client's papers.
class _ResForm {
  String unitType = '', floor = '';
  bool maintPct = false, downPct = false;
  final netArea = TextEditingController(), area = TextEditingController(), meter = TextEditingController(),
      activity = TextEditingController(), maintenance = TextEditingController(), nationalId = TextEditingController(),
      address = TextEditingController(), plannedDown = TextEditingController(), plannedInst = TextEditingController();
  DateTime? downDue;
  DateTime? paidOn = DateTime.now();

  static const unitTypes = ['تجاري', 'إداري', 'سكني', 'طبي'];
  static const floors = ['بدروم', 'أرضي', 'ميزانين', 'أول علوي', 'ثاني علوي', 'ثالث علوي', 'رابع علوي', 'خامس علوي', 'روف'];

  _ResForm([Map<String, dynamic>? f]) {
    if (f == null) return;
    unitType = '${f['unitType'] ?? ''}';
    floor = '${f['floor'] ?? ''}';
    netArea.text = f['netAreaM2'] == null ? '' : '${f['netAreaM2']}';
    area.text = f['areaM2'] == null ? '' : '${f['areaM2']}';
    meter.text = f['meterPrice'] == null ? '' : '${f['meterPrice']}';
    activity.text = '${f['activity'] ?? ''}';
    maintPct = f['maintenancePct'] != null;
    maintenance.text = maintPct ? '${f['maintenancePct']}' : (_n(f['maintenanceDeposit']) > 0 ? '${f['maintenanceDeposit']}' : '');
    downPct = f['plannedDownPct'] != null;
    plannedDown.text = downPct ? '${f['plannedDownPct']}' : (f['plannedDownPayment'] == null ? '' : '${f['plannedDownPayment']}');
    nationalId.text = '${f['clientNationalId'] ?? ''}';
    address.text = '${f['clientAddress'] ?? ''}';
    plannedInst.text = f['plannedInstallments'] == null ? '' : '${f['plannedInstallments']}';
    downDue = DateTime.tryParse('${f['downPaymentDue'] ?? ''}');
    paidOn = DateTime.tryParse('${f['depositPaidOn'] ?? ''}');
  }

  /// a unit of the project's inventory fills the unit's part
  void fillFrom(Map<String, dynamic> u) {
    unitType = '${u['unitType'] ?? ''}';
    floor = '${u['floor'] ?? ''}';
    netArea.text = u['netAreaM2'] == null ? '' : '${u['netAreaM2']}';
    area.text = u['areaM2'] == null ? '' : '${u['areaM2']}';
    meter.text = u['meterPrice'] == null ? '' : '${u['meterPrice']}';
    if ('${u['activity'] ?? ''}'.isNotEmpty) activity.text = '${u['activity']}';
  }

  static num? _num(TextEditingController c) => num.tryParse(c.text.replaceAll(',', '').trim());
  static String _iso(DateTime? d) => d == null ? '' : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// the loaded area × the meter price → the unit's price
  void _price(TextEditingController price) {
    final a = _num(area), m = _num(meter);
    if (a != null && m != null && a > 0 && m > 0) price.text = (a * m).toStringAsFixed((a * m) % 1 == 0 ? 0 : 2);
  }

  List<Widget> fields(BuildContext context, bool isDark, StateSetter set, {required TextEditingController price, bool reservation = true}) {
    Widget pick(String label, IconData icon, String value, List<String> opts, ValueChanged<String> onPick) => JphUi.picker(
          isDark: isDark, icon: icon, iconColor: Ar.accent, label: label, value: value.isEmpty ? 'اختار' : value,
          onTap: () async {
            final v = await JphUi.sheet<String>(context, isDark, label, [
              for (final o in opts) (o, o, icon),
              if (value.isNotEmpty && !opts.contains(value)) (value, value, icon),
              ('__other', 'تاني…', Icons.edit_rounded),
            ], selected: value, icon: icon);
            if (v == null) return;
            if (v != '__other') return set(() => onPick(v));
            if (!context.mounted) return;
            final c = TextEditingController(text: value);
            final t = await showDialog<String>(
              context: context,
              builder: (ctx) => GlassAlertDialog(
                title: Text(label),
                content: TextField(controller: c, autofocus: true),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
                  FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('تمام')),
                ],
              ),
            );
            if (t != null && t.isNotEmpty) set(() => onPick(t));
          },
        );
    Widget date(String label, DateTime? v, ValueChanged<DateTime> onPick) => JphUi.picker(
          isDark: isDark, icon: Icons.event_rounded, iconColor: Ar.green, label: label, value: v == null ? 'اختار التاريخ' : _date(v.toIso8601String()),
          onTap: () async {
            final d = await showDatePicker(context: context, initialDate: v ?? DateTime.now(), firstDate: DateTime(DateTime.now().year - 2),
                lastDate: DateTime(DateTime.now().year + 5));
            if (d != null) set(() => onPick(d));
          },
        );
    // a % of the unit's price, or an amount
    Widget pctOrAmount(String label, IconData icon, TextEditingController c, bool pct, ValueChanged<bool> onMode) =>
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(label, style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark)))),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: const [ButtonSegment(value: false, label: Text('مبلغ')), ButtonSegment(value: true, label: Text('نسبة ٪'))],
              selected: {pct},
              onSelectionChanged: (x) => set(() => onMode(x.first)),
            ),
          ]),
          const SizedBox(height: 6),
          JphUi.input(isDark: isDark, label: pct ? '$label (٪ من سعر الوحدة)' : label, controller: c, icon: icon, number: true,
              suffix: pct ? '٪' : 'جنيه'),
          if (pct)
            AnimatedBuilder(
              animation: Listenable.merge([c, price]),
              builder: (_, __) {
                final p = _num(price), v = _num(c);
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(p == null || v == null ? '' : '= ${_money((p * v / 100).round())}',
                      style: TextStyle(fontWeight: FontWeight.w800, color: Ar.green.shade600)),
                );
              },
            ),
        ]);
    return [
      pick('نوع الوحدة', Icons.category_rounded, unitType, unitTypes, (x) => unitType = x),
      pick('الدور', Icons.layers_rounded, floor, floors, (x) => floor = x),
      JphUi.input(isDark: isDark, label: 'المساحة الصافية (متر)', controller: netArea, icon: Icons.square_foot_rounded, number: true),
      JphUi.input(isDark: isDark, label: 'المساحة بالتحميل (متر)', controller: area, icon: Icons.aspect_ratio_rounded, number: true,
          onChanged: (_) => _price(price)),
      JphUi.input(isDark: isDark, label: 'سعر المتر', controller: meter, icon: Icons.price_change_rounded, number: true, suffix: 'جنيه',
          onChanged: (_) => _price(price)),
      Text('سعر الوحدة = المساحة بالتحميل × سعر المتر', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
      JphUi.input(isDark: isDark, label: 'النشاط', controller: activity, icon: Icons.storefront_rounded),
      pctOrAmount('وديعة الصيانة', Icons.build_rounded, maintenance, maintPct, (x) => maintPct = x),
      pctOrAmount('إجمالي المقدم المتفق عليه', Icons.payments_rounded, plannedDown, downPct, (x) => downPct = x),
      date('آخر موعد لاستكمال المقدم', downDue, (d) => downDue = d),
      JphUi.input(isDark: isDark, label: 'عدد الأقساط', controller: plannedInst, icon: Icons.format_list_numbered_rounded, number: true),
      if (reservation) date('تاريخ سداد دفعة الحجز', paidOn, (d) => paidOn = d),
      JphUi.input(isDark: isDark, label: 'الرقم القومي للعميل', controller: nationalId, icon: Icons.badge_rounded, number: true),
      JphUi.input(isDark: isDark, label: 'عنوان العميل', controller: address, icon: Icons.home_rounded),
    ];
  }

  Map<String, dynamic> body() => {
        'unitType': unitType, 'floor': floor, 'netAreaM2': _num(netArea), 'areaM2': _num(area), 'meterPrice': _num(meter),
        'activity': activity.text.trim(), 'clientNationalId': nationalId.text.trim(), 'clientAddress': address.text.trim(),
        'maintenancePct': maintPct ? _num(maintenance) : null, 'maintenanceDeposit': maintPct ? 0 : (_num(maintenance) ?? 0),
        'plannedDownPct': downPct ? _num(plannedDown) : null, 'plannedDownPayment': downPct ? null : _num(plannedDown),
        'downPaymentDue': downDue == null ? null : _iso(downDue), 'plannedInstallments': int.tryParse(plannedInst.text),
        'depositPaidOn': paidOn == null ? null : _iso(paidOn),
      };
}

/// «تم استلام المبلغ»: whoever receives the money says where it went in — نقدي أو بنك.
Future<String?> _askCashOrBank(BuildContext context, String title, String content) => showDialog<String>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(title),
        content: Text('$content\n\nالفلوس دخلت فين؟', textAlign: TextAlign.center),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('لسه')),
          OutlinedButton.icon(onPressed: () => Navigator.pop(ctx, 'bank_transfer'), icon: const Icon(Icons.account_balance_rounded), label: const Text('بنك')),
          FilledButton.icon(onPressed: () => Navigator.pop(ctx, 'cash'), icon: const Icon(Icons.payments_rounded), label: const Text('نقدي')),
        ],
      ),
    );

// ------------------------------------------------------------------ صورة المشروع
final Map<String, Future<Uint8List?>> _projImg = {};
Future<Uint8List?> _projectImage(String id, Object? at) => _projImg.putIfAbsent('$id@$at', () async {
      final r = await _get('/exclusive/projects/$id/image');
      final s = '${r['image'] ?? ''}';
      final i = s.indexOf(',');
      return i < 0 ? null : base64Decode(s.substring(i + 1));
    });

/// a picture from the gallery, small enough to keep (≤ 1 MB)
Future<(String, String)?> _pickProjectImage(BuildContext context) async {
  XFile? f;
  try {
    f = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 72, maxWidth: 1600, maxHeight: 1600);
  } catch (_) {
    f = null;
  }
  if (f == null) return null;
  final bytes = await f.readAsBytes();
  if (bytes.length > 1000000) {
    if (context.mounted) JphUi.toast(context, {'success': false, 'message': 'الصورة كبيرة — اختار صورة أصغر من 1 ميجا'});
    return null;
  }
  final name = f.name.toLowerCase();
  final mime = name.endsWith('.png') ? 'image/png' : name.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
  return (mime, base64Encode(bytes));
}

Future<bool> _uploadProjectImage(BuildContext context, String id, (String, String) img) async {
  final r = await _post('/exclusive/projects/$id/image', {'mime': img.$1, 'image': img.$2}, 'اتحفظت صورة المشروع ✅', method: 'put');
  _projImg.removeWhere((k, _) => k.startsWith('$id@'));
  if (context.mounted) JphUi.toast(context, r);
  return r['success'] == true;
}

/// the project's picture (or nothing while it loads / when it has none)
class _ProjectPhoto extends StatelessWidget {
  final String id;
  final Object? at;
  const _ProjectPhoto({required this.id, required this.at});

  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: _projectImage(id, at),
        builder: (_, s) => s.data == null
            ? (at == null || s.connectionState == ConnectionState.done ? const DefaultPhoto() : const SizedBox.shrink())
            : Image.memory(s.data!, fit: BoxFit.cover, width: double.infinity, height: double.infinity, gaplessPlayback: true),
      );
}

// ------------------------------------------------------------------ وحدات المشروع (المخزون)
Future<bool> _editInventory(BuildContext context, bool isDark, String projectId, [Map<String, dynamic>? u]) async {
  final no = TextEditingController(text: '${u?['unitNo'] ?? ''}'), price = TextEditingController(text: u?['unitPrice'] == null ? '' : '${u!['unitPrice']}'),
      notes = TextEditingController(text: '${u?['notes'] ?? ''}');
  final rf = _ResForm()..fillFrom(u ?? const {});
  bool active = u?['active'] != false;
  return _form(context, isDark, u == null ? 'إضافة وحدة للمشروع' : 'تعديل الوحدة ${u['unitNo']}', (set) {
    final f = rf.fields(context, isDark, set, price: price);
    return [
      JphUi.input(isDark: isDark, label: 'رقم الوحدة', controller: no, icon: Icons.tag_rounded),
      ...f.take(7), // نوع الوحدة … النشاط
      JphUi.input(isDark: isDark, label: 'إجمالي سعر الوحدة', controller: price, icon: Icons.sell_rounded, number: true, suffix: 'جنيه'),
      JphUi.input(isDark: isDark, label: 'ملاحظات', controller: notes, icon: Icons.notes_rounded),
      if (u != null)
        SwitchListTile(value: active, onChanged: (v) => set(() => active = v), title: Text(active ? 'متاحة للبيع' : 'موقوفة', style: TextStyle(color: JphUi.text(isDark)))),
    ];
  }, () async {
    final b = rf.body();
    final body = {
      'unitNo': no.text.trim(), 'unitType': b['unitType'], 'floor': b['floor'], 'netAreaM2': b['netAreaM2'], 'areaM2': b['areaM2'],
      'meterPrice': b['meterPrice'], 'unitPrice': _ResForm._num(price), 'activity': b['activity'], 'notes': notes.text.trim(),
      if (u != null) 'active': active,
    };
    final r = u == null
        ? await _post('/exclusive/projects/$projectId/inventory', body, 'اتضافت الوحدة ✅')
        : await _post('/exclusive/inventory/${u['id']}', body, 'اتعدلت الوحدة ✅', method: 'patch');
    if (context.mounted) JphUi.toast(context, r);
    return r['success'] == true;
  }, saveLabel: 'حفظ');
}

class _InventoryList extends StatefulWidget {
  final String projectId;
  final bool isDark;
  const _InventoryList({required this.projectId, required this.isDark});

  @override
  State<_InventoryList> createState() => _InventoryListState();
}

class _InventoryListState extends State<_InventoryList> {
  List<Map<String, dynamic>> _units = [];
  bool _edit = false, _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/exclusive/projects/${widget.projectId}/inventory');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _units = _l(r['units']);
      _edit = r['canEdit'] == true;
    });
  }

  Color _c(String s) => s == 'contracted' ? Ar.green : s == 'reserved' ? Ar.amber : Ar.info;

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_edit)
        _btn(isDark, 'إضافة وحدة للمشروع', Icons.add_home_work_rounded, () async {
          if (await _editInventory(context, isDark, widget.projectId)) _load();
        }),
      if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
      if (!_loading && _units.isEmpty)
        Padding(padding: const EdgeInsets.all(24), child: Text('مفيش وحدات متسجلة للمشروع لسه', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
      ResponsiveGrid(minTileWidth: 300, maxCols: 4, children: [
        for (final u in _units)
          GestureDetector(
            onTap: !_edit ? null : () async {
              if (await _editInventory(context, isDark, widget.projectId, u)) _load();
            },
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: JphUi.box(isDark),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text('وحدة ${u['unitNo']}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
                  _pill(u['active'] == false ? 'موقوفة' : '${u['stateAr']}', u['active'] == false ? Ar.grey : _c('${u['state']}')),
                ]),
                const SizedBox(height: 4),
                Text([u['unitType'], u['floor'], if ('${u['activity'] ?? ''}'.isNotEmpty) u['activity']].where((x) => '${x ?? ''}'.isNotEmpty).join(' · '),
                    style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: GlassStat(isDark: isDark, label: 'صافي', value: u['netAreaM2'] == null ? '—' : '${u['netAreaM2']} م')),
                  const SizedBox(width: 6),
                  Expanded(child: GlassStat(isDark: isDark, label: 'بالتحميل', value: u['areaM2'] == null ? '—' : '${u['areaM2']} م')),
                  const SizedBox(width: 6),
                  Expanded(child: GlassStat(isDark: isDark, label: 'السعر', value: u['unitPrice'] == null ? '—' : _money(u['unitPrice']))),
                ]),
                if (u['clientName'] != null) ...[
                  const SizedBox(height: 6),
                  Text('العميل: ${u['clientName']}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
                ],
              ]),
            ),
          ),
      ]),
    ]);
  }
}

/// حجز جديد / تعاقد جديد — from «المبيعات» only.
///  حصري: العربون بيدخل خزنة المحاسب على طول (نقدي أو بنك)؛ تعاقد جديد = حجز + تعاقد مرة واحدة.
///  تسويق: مفيش فلوس بتدخل عندنا — عمولة محتملة لحد التعاقد.
Future<void> newUnit(BuildContext context, bool isDark, List<Map<String, dynamic>> projects, {bool contract = false, VoidCallback? then}) async {
  final active = projects.where((p) => p['status'] == 'active').toList();
  String? pid = active.length == 1 ? '${active.first['id']}' : null;
  final unit = TextEditingController(), client = TextEditingController(), phone = TextEditingController(),
      price = TextEditingController(), deposit = TextEditingController(), notes = TextEditingController();
  final mks = _l((await _get('/marketing-companies'))['companies']).where((m) => m['kind'] == 'commission' && m['status'] == 'active').toList();
  Map<String, dynamic>? mk;
  final terms = _Terms();
  DateTime? expected; // التاريخ المتوقع للتعاقد — the expected commission falls in that month
  final rf = _ResForm();
  Map<String, dynamic> project() => active.firstWhere((p) => '${p['id']}' == pid, orElse: () => const {});
  // the project's units: picking one fills the unit's details
  List<Map<String, dynamic>> inv = [];
  String? invId;
  bool manual = false;
  Future<void> loadInv(StateSetter set) async {
    final r = pid == null ? const <String, dynamic>{} : await _get('/exclusive/projects/$pid/inventory');
    set(() {
      inv = _l(r['units']).where((u) => u['active'] != false).toList();
      invId = null;
      manual = inv.isEmpty;
    });
  }
  // a client already on the system: his data comes by his phone
  String looked = '';
  Future<void> lookup(StateSetter set) async {
    final d = phone.text.replaceAll(RegExp(r'\D'), '');
    if (d.length < 10 || d == looked) return;
    looked = d;
    final r = await _get('/exclusive/clients/lookup', {'phone': d});
    final c = r['client'];
    if (c is! Map) return;
    set(() {
      if (client.text.trim().isEmpty) client.text = '${c['name'] ?? ''}';
      if (rf.nationalId.text.trim().isEmpty) rf.nationalId.text = '${c['nationalId'] ?? ''}';
      if (rf.address.text.trim().isEmpty) rf.address.text = '${c['address'] ?? ''}';
    });
    if (context.mounted) JphUi.toast(context, {'success': true, 'message': 'عميل متسجل — اتملت بياناته'});
  }
  if (pid != null) {
    inv = _l((await _get('/exclusive/projects/$pid/inventory'))['units']).where((u) => u['active'] != false).toList();
    manual = inv.isEmpty;
  }
  if (!context.mounted) return;
  final ok = await _form(context, isDark, contract ? 'تعاقد جديد' : 'حجز جديد', (set) {
    final p = project();
    final exclusive = p['kind'] == 'exclusive';
    return [
      JphUi.picker(
        isDark: isDark, icon: Icons.apartment_rounded, iconColor: Ar.accent, label: 'المشروع',
        value: p.isEmpty ? 'اختار المشروع' : '${p['name']}${_seesKind() ? ' — ${exclusive ? 'حصري' : 'تسويق'}' : ''}',
        onTap: () async {
          final v = await JphUi.sheet<String>(context, isDark, 'المشروع', [
            for (final x in active)
              ('${x['id']}', '${x['name']}${_seesKind() ? ' — ${x['kind'] == 'marketing' ? 'تسويق' : 'حصري'}' : ''}', Icons.apartment_rounded),
          ], selected: pid);
          if (v != null && v != pid) {
            set(() => pid = v);
            await loadInv(set);
          }
        },
      ),
      // the unit: from the project's units (fills its details) or typed by hand
      if (inv.isNotEmpty)
        JphUi.picker(
          isDark: isDark, icon: Icons.home_work_rounded, iconColor: Ar.accent, label: 'الوحدة',
          value: invId != null ? 'وحدة ${unit.text}' : manual ? 'وحدة مش في القايمة' : 'اختار الوحدة',
          onTap: () async {
            final free = inv.where((u) => u['state'] == 'free').toList();
            final v = await JphUi.sheet<String>(context, isDark, 'الوحدة', [
              for (final u in free)
                ('${u['id']}', 'وحدة ${u['unitNo']}${'${u['unitType'] ?? ''}'.isNotEmpty ? ' · ${u['unitType']}' : ''}'
                    '${'${u['floor'] ?? ''}'.isNotEmpty ? ' · ${u['floor']}' : ''}${u['unitPrice'] != null ? ' · ${_money(u['unitPrice'])}' : ''}',
                    Icons.home_work_rounded),
              ('__manual', 'وحدة مش في القايمة', Icons.edit_rounded),
            ], selected: invId, icon: Icons.home_work_rounded);
            if (v == null) return;
            set(() {
              if (v == '__manual') {
                manual = true;
                invId = null;
                return;
              }
              final u = inv.firstWhere((x) => '${x['id']}' == v);
              manual = false;
              invId = v;
              unit.text = '${u['unitNo']}';
              if (u['unitPrice'] != null) price.text = '${u['unitPrice']}';
              rf.fillFrom(u);
            });
          },
        ),
      if (inv.isEmpty || manual) JphUi.input(isDark: isDark, label: 'رقم الوحدة', controller: unit, icon: Icons.tag_rounded),
      JphUi.input(isDark: isDark, label: 'تليفون العميل', controller: phone, icon: Icons.phone_rounded, number: true,
          onChanged: (_) => lookup(set)),
      JphUi.input(isDark: isDark, label: 'اسم العميل', controller: client, icon: Icons.person_rounded),
      JphUi.input(isDark: isDark, label: 'إجمالي سعر الوحدة', controller: price, icon: Icons.sell_rounded, number: true, suffix: 'جنيه'),
      _sourcePicker(context, isDark, mks, mk, (m) => set(() => mk = m)),
      if (exclusive && !contract)
        JphUi.input(isDark: isDark, label: 'العربون (بيدخل الخزنة)', controller: deposit, icon: Icons.savings_rounded, number: true, suffix: 'جنيه'),
      if (!contract)
        JphUi.picker(
          isDark: isDark, icon: Icons.event_available_rounded, iconColor: Ar.accent, label: 'التاريخ المتوقع للتعاقد',
          value: expected == null ? 'اختار التاريخ' : _date(expected!.toIso8601String()),
          onTap: () async {
            final d = await showDatePicker(context: context, initialDate: expected ?? DateTime.now().add(const Duration(days: 30)),
                firstDate: DateTime.now(), lastDate: DateTime(DateTime.now().year + 5));
            if (d != null) set(() => expected = d);
          },
        ),
      if (exclusive && contract) ...terms.fields(context, isDark, set, price: num.tryParse(price.text.replaceAll(',', ''))),
      if (!exclusive && p.isNotEmpty && _seesKind())
        Text(contract ? 'التعاقد بيخلّي العمولة واجبة التحصيل من المطور.' : 'الحجز في مشروع تسويق: عمولة محتملة لحد التعاقد — مفيش فلوس بتدخل عندنا.',
            style: TextStyle(color: JphUi.sub(isDark))),
      ...rf.fields(context, isDark, set, price: price, reservation: !contract),
      JphUi.input(isDark: isDark, label: 'ملاحظات', controller: notes, icon: Icons.notes_rounded),
    ];
  }, () async {
    if (pid == null) {
      JphUi.toast(context, {'success': false, 'message': 'اختار المشروع'});
      return false;
    }
    if (!contract && expected == null) {
      JphUi.toast(context, {'success': false, 'message': 'اختار التاريخ المتوقع للتعاقد'});
      return false;
    }
    final exclusive = project()['kind'] == 'exclusive';
    final r = await _post('/exclusive/units', {
      'projectId': pid, 'unitNo': unit.text.trim(), 'clientName': client.text.trim(), 'clientPhone': phone.text.trim(),
      'unitPrice': num.tryParse(price.text.replaceAll(',', '')), 'notes': notes.text.trim(),
      if (invId != null) 'inventoryId': invId,
      ...rf.body(),
      if (exclusive && !contract) 'depositAmount': num.tryParse(deposit.text.replaceAll(',', '')),
      if (mk != null) 'marketingCompanyId': mk!['id'],
      if (!contract && expected != null)
        'expectedContractDate': '${expected!.year}-${expected!.month.toString().padLeft(2, '0')}-${expected!.day.toString().padLeft(2, '0')}',
      if (contract) 'contract': exclusive ? terms.body() : {'paymentType': 'cash'},
    }, contract ? 'اتسجل التعاقد ✅' : 'اتسجل الحجز ✅');
    if (context.mounted) JphUi.toast(context, r);
    return r['success'] == true;
  }, saveLabel: contract ? 'تعاقد' : 'حجز');
  if (ok) then?.call();
}

// ==================================================================== one project
class ExclusiveProjectPage extends StatefulWidget {
  final String projectId;
  const ExclusiveProjectPage({super.key, required this.projectId});

  @override
  State<ExclusiveProjectPage> createState() => _ExclusiveProjectPageState();
}

class _ExclusiveProjectPageState extends State<ExclusiveProjectPage> {
  Map<String, dynamic>? _d;
  String _tab = 'units';
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/exclusive/projects/${widget.projectId}');
    if (!mounted) return;
    setState(() => _d = r['success'] == true ? r : {'error': r['message']});
  }

  Future<void> _transfer(bool isDark, num max) async {
    final amount = TextEditingController(text: max > 0 ? '$max' : ''), note = TextEditingController();
    final ok = await _form(context, isDark, 'تحويل عمولة من الأمانة', (set) => [
          Text('المتاح للتحويل: ${_money(max)}', style: TextStyle(color: JphUi.sub(isDark))),
          JphUi.input(isDark: isDark, label: 'المبلغ', controller: amount, number: true, suffix: 'جنيه', icon: Icons.percent_rounded),
          JphUi.input(isDark: isDark, label: 'ملاحظة', controller: note, icon: Icons.notes_rounded),
        ], () async {
      final r = await _post('/exclusive/projects/${widget.projectId}/commission-transfer',
          {'amount': num.tryParse(amount.text.replaceAll(',', '')), 'note': note.text.trim()}, 'اتحوّلت العمولة ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    }, saveLabel: 'تحويل');
    if (ok) _load();
  }

  Future<void> _payout(bool isDark, num max) async {
    final amount = TextEditingController(), note = TextEditingController();
    final ok = await _form(context, isDark, 'إذن صرف لمالك العقار', (set) => [
          Text('المتاح للمالك: ${_money(max)} — بيتصرف من خزنة المكتب بعد موافقة المالك / المدير العام التاني',
              style: TextStyle(color: JphUi.sub(isDark))),
          JphUi.input(isDark: isDark, label: 'المبلغ', controller: amount, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
          JphUi.input(isDark: isDark, label: 'ملاحظة', controller: note, icon: Icons.notes_rounded),
        ], () async {
      final r = await _post('/exclusive/projects/${widget.projectId}/owner-payout',
          {'amount': num.tryParse(amount.text.replaceAll(',', '')), 'note': note.text.trim()}, 'اتبعت إذن الصرف — مستني الموافقة ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    }, saveLabel: 'إرسال');
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final p = _m(_d?['project']);
    return _Shell(
      title: p.isEmpty ? 'المشروع' : '${p['name']}',
      action: p.isNotEmpty && _seesKind()
          ? IconButton(tooltip: 'تعديل المشروع', icon: const Icon(Icons.edit_rounded), onPressed: () => _editProject(isDark, p))
          : null,
      child: _d == null
          ? const Center(child: CircularProgressIndicator())
          : _d!['error'] != null
              ? Center(child: Text('${_d!['error']}'))
              : RefreshIndicator(onRefresh: _load, child: _body(isDark, p)),
    );
  }

  /// تعديل المشروع: الاسم + صورة المشروع
  Future<void> _editProject(bool isDark, Map<String, dynamic> p) async {
    final exclusive = p['kind'] != 'marketing';
    final name = TextEditingController(text: '${p['name']}');
    (String, String)? img;
    final ok = await _form(context, isDark, 'تعديل المشروع', (set) => [
          if (exclusive) JphUi.input(isDark: isDark, label: 'اسم المشروع', controller: name, icon: Icons.apartment_rounded),
          if (img == null)
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: AspectRatio(aspectRatio: 2.4, child: _ProjectPhoto(id: '${p['id']}', at: p['imageAt'])),
            ),
          JphUi.picker(
            isDark: isDark,
            icon: Icons.add_photo_alternate_rounded,
            iconColor: Ar.accent,
            label: 'صورة المشروع',
            value: img != null ? 'اتختارت صورة جديدة ✓' : (p['imageAt'] == null ? 'اختار صورة' : 'تغيير الصورة'),
            onTap: () async {
              final x = await _pickProjectImage(context);
              if (x != null) set(() => img = x);
            },
          ),
        ], () async {
      var done = true;
      if (exclusive && name.text.trim().length >= 2 && name.text.trim() != '${p['name']}') {
        final r = await _post('/exclusive/projects/${p['id']}', {'name': name.text.trim()}, 'اتعدّل المشروع ✅', method: 'patch');
        if (mounted) JphUi.toast(context, r);
        done = r['success'] == true;
      }
      if (done && img != null && mounted) done = await _uploadProjectImage(context, '${p['id']}', img!);
      return done;
    });
    if (ok) _load();
  }

  Future<void> _changeDeveloper(bool isDark, Map<String, dynamic> p) async {
    final devs = _l((await _get('/exclusive/developers'))['developers']);
    if (!mounted) return;
    final v = await JphUi.sheet<String>(context, isDark, 'المطور', [for (final d in devs) ('${d['id']}', '${d['name']}', Icons.business_rounded)],
        selected: p['developerId'] == null ? null : '${p['developerId']}');
    if (v == null) return;
    final r = await _post('/exclusive/projects/${p['id']}/developer', {'developerId': v}, 'اتغيّر المطور ✅');
    if (mounted) JphUi.toast(context, r);
    _load();
  }

  Widget _body(bool isDark, Map<String, dynamic> p) {
    final st = _m(p['stats']);
    final can = _m(_d!['can']);
    final cm = _m(st['commission']), ow = _m(st['owner']), u = _m(st['units']);
    final units = _l(_d!['units']).where((x) => _filter.isEmpty || x['status'] == _filter).toList();
    final statement = _l(_d!['statement']);
    final marketing = p['kind'] == 'marketing';
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
      // the project's picture (changed from «تعديل المشروع», not here)
      Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: AspectRatio(aspectRatio: 2.4, child: _ProjectPhoto(id: '${p['id']}', at: p['imageAt'])),
          ),
        ),
      if (_m(_d!['can'])['manage'] == true || p['developerName'] != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            const Icon(Icons.business_rounded, color: Ar.accent),
            const SizedBox(width: 8),
            Expanded(child: Text('المطور: ${p['developerName'] ?? 'مش محدد'}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
            if (_m(_d!['can'])['manage'] == true) TextButton(onPressed: () => _changeDeveloper(isDark, p), child: const Text('تغيير')),
          ]),
        ),
      if (marketing && st.isNotEmpty) ...[
        _section(isDark, 'عمولة المشروع', [
          Wrap(spacing: 6, runSpacing: 6, children: [
            _pill('عمولة ${JphUi.pct(p['totalPct'])}', Ar.accent),
            _pill('سيلز ${JphUi.pct(p['salesPct'])} · مدير ${JphUi.pct(p['managerPct'])}', Ar.grey),
            _pill('المكتب ${JphUi.pct(p['companyPct'])}', Ar.green),
          ]),
          const SizedBox(height: 8),
          _kv(isDark, 'مبيعات متعاقد عليها', _money(st['sales'])),
          _kv(isDark, 'إجمالي العمولة', _money(cm['earned'])),
          _kv(isDark, 'للسيلز ومدير المبيعات', _money(cm['staff'])),
          _kv(isDark, 'لشركات التسويق', _money(cm['marketing'])),
          _kv(isDark, 'نصيب المكتب', _money(cm['office']), color: Ar.green),
          _kv(isDark, 'محتملة من حجوزات', _money(cm['potential'])),
        ]),
      ],
      if (marketing)
        TextButton.icon(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CommissionProjectPage(projectId: '${p['id']}'))),
          icon: const Icon(Icons.receipt_long_rounded),
          label: const Text('طلبات العمولة على المشروع', style: TextStyle(fontWeight: FontWeight.w800)),
        ),
      if (!marketing && st.isNotEmpty) ...[
        _section(isDark, 'أمانة المالك — ${p['ownerName'] ?? ''}', [
          _kv(isDark, 'اتحصّل', _money(st['collected'])),
          _kv(isDark, 'منه بنك', _money(st['bank'])),
          _kv(isDark, 'اترد للعملاء', _money(st['refunded'])),
          _kv(isDark, 'عمولة اتحوّلت للمكتب', _money(cm['transferred'])),
          _kv(isDark, 'اتصرف للمالك', _money(ow['paid'])),
          if (_n(ow['pendingPayout']) > 0) _kv(isDark, 'إذن صرف مستني موافقة', _money(ow['pendingPayout']), color: Ar.amber),
          const Divider(),
          _kv(isDark, 'في الأمانة دلوقتي', _money(ow['inTrust'])),
          _kv(isDark, 'الصافي المستحق للمالك', _money(ow['due']), color: Ar.green),
        ]),
        _section(isDark, 'عمولتي', [
          _kv(isDark, 'مستحقة لحد دلوقتي', _money(cm['earned'])),
          _kv(isDark, 'اتحوّلت فعلاً', _money(cm['transferred']), color: Ar.green),
          _kv(isDark, 'في الأمانة لسه متحوّلتش', _money(cm['pending']), color: Ar.amber),
          _kv(isDark, 'جاية من أقساط', _money(cm['upcoming'])),
          _kv(isDark, 'محتملة من حجوزات', _money(cm['potential'])),
          _kv(isDark, 'منها للسيلز ومدير المبيعات', _money(cm['staff'])),
          if (_n(cm['marketing']) > 0) _kv(isDark, 'منها لشركات التسويق', _money(cm['marketing'])),
        ]),
        if (can['manage'] == true) ...[
          _btn(isDark, 'تحويل عمولة من الأمانة', Icons.swap_horiz_rounded, () => _transfer(isDark, _n(cm['pending'])), color: Ar.green),
          _btn(isDark, 'إذن صرف للمالك', Icons.real_estate_agent_rounded,
              () => _payout(isDark, _n(ow['due']) - _n(ow['pendingPayout'])), color: Ar.accent),
        ],
      ],
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: SegmentedButton<String>(
          segments: [
            const ButtonSegment(value: 'units', label: Text('الحجوزات والتعاقدات')),
            const ButtonSegment(value: 'inventory', label: Text('وحدات المشروع')),
            if (statement.isNotEmpty) const ButtonSegment(value: 'statement', label: Text('كشف حساب المالك')),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
      ),
      if (_tab == 'inventory')
        _InventoryList(projectId: '${p['id']}', isDark: isDark)
      else if (_tab == 'units') ...[
        if (u.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final f in [('', 'الكل'), ('reserved', 'محجوز'), ('contract_pending', 'مستني تعاقد'), ('contracted', 'متعاقد'), ('completed', 'مكتمل'), ('cancelled', 'ملغي')])
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: ChoiceChip(label: Text(f.$2), selected: _filter == f.$1, onSelected: (_) => setState(() => _filter = f.$1)),
                ),
            ]),
          ),
        const SizedBox(height: 8),
        if (units.isEmpty) Padding(padding: const EdgeInsets.all(24), child: Text('مفيش وحدات', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final x in units) _unitCard(isDark, x),
      ] else
        for (final s in statement)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: JphUi.box(isDark),
            child: Row(children: [
              Icon(s['dir'] == 'in' ? Icons.south_west_rounded : s['dir'] == 'out' ? Icons.north_east_rounded : Icons.swap_horiz_rounded,
                  color: s['dir'] == 'in' ? Ar.green : s['dir'] == 'out' ? Ar.red : Ar.amber),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${s['typeAr']}${s['unitNo'] != null ? ' — وحدة ${s['unitNo']}' : ''}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                  Text('${s['who'] ?? ''} · ${_date(s['at'])}${s['method'] != null && s['method'] != 'cash' ? ' · بنك' : ''}',
                      style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                ]),
              ),
              Text('${s['dir'] == 'in' ? '+' : '−'}${_money(s['amount'])}', style: TextStyle(fontWeight: FontWeight.w900, color: s['dir'] == 'in' ? Ar.green : Ar.red)),
            ]),
          ),
    ]);
  }

  Widget _unitCard(bool isDark, Map<String, dynamic> x) {
    final money = _m(x['money']);
    final st = '${x['status']}';
    return GestureDetector(
      onTap: () async {
        await pushSide(context, ExclusiveUnitPage(unitId: '${x['id']}'));
        _load();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: JphUi.box(isDark),
        child: Row(children: [
          JphUi.iconTile(isDark, Icons.home_work_rounded, _statusColor(st)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('وحدة ${x['unitNo']} — ${x['clientName']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                _pill('${x['statusAr']}', _statusColor(st)),
              ]),
              const SizedBox(height: 4),
              Text('${_money(x['unitPrice'])} · اتحصّل ${_money(money['collected'])} · ${x['salesName']}',
                  style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ==================================================================== one unit
class ExclusiveUnitPage extends StatefulWidget {
  final String unitId;
  const ExclusiveUnitPage({super.key, required this.unitId});

  @override
  State<ExclusiveUnitPage> createState() => _ExclusiveUnitPageState();
}

class _ExclusiveUnitPageState extends State<ExclusiveUnitPage> {
  Map<String, dynamic>? _d;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/exclusive/units/${widget.unitId}');
    if (!mounted) return;
    setState(() => _d = r['success'] == true ? r : {'error': r['message']});
  }

  Map<String, dynamic> get _u => _m(_d?['unit']);

  Future<void> _collect(bool isDark, {String kind = 'reservation', Map<String, dynamic>? inst}) async {
    String k = kind, method = 'cash';
    final c = _m(_u['contract']), money = _m(_u['money']);
    num suggest() => k == 'reservation'
        ? _n(_u['depositAmount']) - _n(money['depositPaid'])
        : k == 'down_payment'
            ? _n(c['downPayment']) - _n(money['downPaid'])
            : _n(inst?['left']);
    final amount = TextEditingController(text: suggest() > 0 ? '${suggest()}' : '');
    final ext = TextEditingController(), notes = TextEditingController();
    final st = '${_u['status']}';
    final kinds = [
      if (['reserving', 'reserved', 'contract_pending'].contains(st)) ('reservation', 'عربون حجز', Icons.bookmark_rounded),
      if (['contract_pending', 'contracted'].contains(st) && _n(c['downPayment']) - _n(money['downPaid']) > 0) ('down_payment', 'مقدم تعاقد', Icons.handshake_rounded),
      if (st == 'contracted' && c['paymentType'] == 'installments') ('installment', 'قسط', Icons.event_repeat_rounded),
    ];
    if (kinds.isEmpty) return;
    if (!kinds.any((x) => x.$1 == k)) k = kinds.first.$1;
    final ok = await _form(context, isDark, 'تسجيل فلوس — وحدة ${_u['unitNo']}', (set) => [
          JphUi.picker(
            isDark: isDark, icon: Icons.category_rounded, iconColor: Ar.accent, label: 'النوع',
            value: kinds.firstWhere((x) => x.$1 == k).$2,
            onTap: inst != null ? null : () async {
              final v = await JphUi.sheet<String>(context, isDark, 'النوع', kinds, selected: k);
              if (v != null) set(() { k = v; amount.text = suggest() > 0 ? '${suggest()}' : ''; });
            },
          ),
          if (inst != null) Text('القسط ${inst['seq']} — ميعاده ${_date(inst['dueDate'])}', style: TextStyle(color: JphUi.sub(isDark))),
          JphUi.input(isDark: isDark, label: 'المبلغ', controller: amount, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
          _methodPicker(context, isDark, method, (v) => set(() => method = v)),
          JphUi.input(isDark: isDark, label: 'رقم الإيصال الورقي (لو فيه)', controller: ext, icon: Icons.receipt_long_rounded),
          JphUi.input(isDark: isDark, label: 'ملاحظات', controller: notes, icon: Icons.notes_rounded),
        ], () async {
      final r = await _post('/exclusive/units/${widget.unitId}/receipts', {
        'kind': k, 'amount': num.tryParse(amount.text.replaceAll(',', '')), 'paymentMethod': method,
        'externalNo': ext.text.trim(), 'notes': notes.text.trim(), if (inst != null) 'installmentId': inst['id'],
      }, 'اتسجلت الفلوس في خزنة المحاسب ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    }, saveLabel: 'تسجيل');
    if (ok) _load();
  }

  /// تعديل الحجز / التعاقد: before the contract everything of the reservation; after it the client's details only.
  Future<void> _edit(bool isDark) async {
    final u = _u;
    final contracted = '${u['status']}' == 'contracted';
    final exclusive = u['projectKind'] != 'marketing';
    final depositPending = _l(_d!['pendingPayments']).any((x) => x['kind'] == 'reservation');
    final unit = TextEditingController(text: '${u['unitNo']}'), client = TextEditingController(text: '${u['clientName']}'),
        phone = TextEditingController(text: '${u['clientPhone'] ?? ''}'), price = TextEditingController(text: '${u['unitPrice']}'),
        deposit = TextEditingController(text: '${u['depositAmount']}'), notes = TextEditingController(text: '${u['notes'] ?? ''}');
    DateTime? expected = u['expectedContractDate'] != null ? DateTime.tryParse('${u['expectedContractDate']}') : null;
    final mks = contracted ? <Map<String, dynamic>>[] : _l((await _get('/marketing-companies'))['companies'])
        .where((m) => m['kind'] == 'commission' && m['status'] == 'active').toList();
    final rf = _ResForm(_m(u['form']));
    Map<String, dynamic>? mk;
    for (final m in mks) {
      if (m['id'] == u['marketingCompanyId']) mk = m;
    }
    if (!mounted) return;
    final ok = await _form(context, isDark, contracted ? 'تعديل التعاقد' : 'تعديل الحجز', (set) => [
          if (!contracted) JphUi.input(isDark: isDark, label: 'رقم الوحدة', controller: unit, icon: Icons.tag_rounded),
          JphUi.input(isDark: isDark, label: 'اسم العميل', controller: client, icon: Icons.person_rounded),
          JphUi.input(isDark: isDark, label: 'تليفون العميل', controller: phone, icon: Icons.phone_rounded, number: true),
          if (!contracted) ...[
            JphUi.input(isDark: isDark, label: 'إجمالي سعر الوحدة', controller: price, icon: Icons.sell_rounded, number: true, suffix: 'جنيه'),
            if (exclusive && depositPending)
              JphUi.input(isDark: isDark, label: 'العربون (لسه مستني تأكيد الاستلام)', controller: deposit, icon: Icons.savings_rounded, number: true, suffix: 'جنيه'),
            if (exclusive && !depositPending) _kv(isDark, 'العربون (اتأكد استلامه — مايتغيرش)', _money(u['depositAmount'])),
            JphUi.picker(
              isDark: isDark, icon: Icons.event_available_rounded, iconColor: Ar.accent, label: 'التاريخ المتوقع للتعاقد',
              value: expected == null ? 'اختار التاريخ' : _date(expected!.toIso8601String()),
              onTap: () async {
                final d = await showDatePicker(context: context, initialDate: expected ?? DateTime.now(), firstDate: DateTime.now().subtract(const Duration(days: 365)),
                    lastDate: DateTime(DateTime.now().year + 5));
                if (d != null) set(() => expected = d);
              },
            ),
            _sourcePicker(context, isDark, mks, mk, (m) => set(() => mk = m)),
          ],
          if (contracted) Text('بعد التعاقد الفلوس والأقساط ثابتة — بيتعدّل بيانات العميل والاستمارة والملاحظات بس.', style: TextStyle(color: JphUi.sub(isDark))),
          ...rf.fields(context, isDark, set, price: price, reservation: !contracted),
          JphUi.input(isDark: isDark, label: 'ملاحظات', controller: notes, icon: Icons.notes_rounded),
        ], () async {
      final r = await _post('/exclusive/units/${widget.unitId}', {
        'clientName': client.text.trim(), 'clientPhone': phone.text.trim(), 'notes': notes.text.trim(),
        ...rf.body(),
        if (!contracted) ...{
          'unitNo': unit.text.trim(), 'unitPrice': num.tryParse(price.text.replaceAll(',', '')),
          if (exclusive && depositPending) 'depositAmount': num.tryParse(deposit.text.replaceAll(',', '')),
          if (expected != null)
            'expectedContractDate': '${expected!.year}-${expected!.month.toString().padLeft(2, '0')}-${expected!.day.toString().padLeft(2, '0')}',
          'marketingCompanyId': mk?['id'],
        },
      }, 'اتحفظ التعديل ✅', method: 'patch');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    }, saveLabel: 'حفظ');
    if (ok) _load();
  }

  /// «تم استلام المبلغ»: the amount on the reservation / contract, nobody types it.
  Future<void> _receive(bool isDark, Map<String, dynamic> x) async {
    final method = await _askCashOrBank(context, 'تم استلام ${x['kindAr']}', '${_money(x['amount'])}\nهيدخل ${hrBox ? 'خزنة المحاسب' : 'خزنة المكتب'}');
    if (method == null) return;
    final r = await _post('/exclusive/payments/${x['id']}/receive', {'paymentMethod': method}, 'اتأكد الاستلام ✅');
    if (mounted) JphUi.toast(context, r);
    _load();
  }

  bool get hrBox => ApiService.can('cash.hr_operate') && !ApiService.can('cash.office');

  Future<void> _receiveInstallment(bool isDark, Map<String, dynamic> i) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text('تم استلام القسط ${i['seq']}'),
        content: Text('${_money(i['left'])}\nهيدخل ${hrBox ? 'خزنة المحاسب' : 'خزنة المكتب'}', textAlign: TextAlign.center),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('لسه')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('نقدي')),
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('بنك')),
        ],
      ),
    );
    if (yes == null) return;
    final r = await _post('/exclusive/units/${widget.unitId}/receipts',
        {'kind': 'installment', 'installmentId': i['id'], 'paymentMethod': yes ? 'cash' : 'bank_transfer'}, 'اتسجل استلام القسط ✅');
    if (mounted) JphUi.toast(context, r);
    _load();
  }

  /// تحويل لتعاقد: by the salesperson himself — the contract money goes into the cashbox, the commission becomes receivable.
  Future<void> _requestContract(bool isDark) async {
    final marketing = _u['projectKind'] == 'marketing';
    final terms = _Terms();
    String method = 'cash';
    final ok = await _form(context, isDark, 'تحويل لتعاقد — وحدة ${_u['unitNo']}', (set) => [
          if (marketing)
            Text(_seesKind() ? 'العمولة هتبقى واجبة التحصيل من المطور (${_money(_n(_u['unitPrice']))} سعر الوحدة).'
                : 'تأكيد التعاقد على الوحدة (${_money(_n(_u['unitPrice']))}).', style: TextStyle(color: JphUi.sub(isDark)))
          else ...[
            ...terms.fields(context, isDark, set, price: _n(_u['unitPrice']), deposit: _n(_u['depositAmount'])),
            Text('الفلوس اتدفعت', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
            _cashBankPicker(isDark, method, (v) => set(() => method = v)),
          ],
          JphUi.input(isDark: isDark, label: 'ملاحظة', controller: terms.note, icon: Icons.notes_rounded),
        ], () async {
      final r = await _post('/exclusive/units/${widget.unitId}/contract', {
        ...(marketing ? {'paymentType': 'cash', 'note': terms.note.text.trim()} : terms.body()), 'paymentMethod': method,
      }, 'اتسجل التعاقد ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    }, saveLabel: 'تعاقد');
    if (ok) _load();
  }

  /// تم التحصيل: المالك / المدير العام — the commission enters the commissions.
  Future<void> _collectCommission(bool isDark) async {
    final cm = _m(_u['commission']);
    final marketing = _u['projectKind'] == 'marketing';
    String method = 'bank_transfer';
    final ok = await _form(context, isDark, 'تم تحصيل العمولة — وحدة ${_u['unitNo']}', (set) => [
          Text(marketing ? 'العمولة اللي دفعها المطور بتدخل العمولات.' : 'العمولة بتطلع من أمانة المالك وتدخل العمولات.',
              style: TextStyle(color: JphUi.sub(isDark))),
          _kv(isDark, 'العمولة الواجبة التحصيل', _money(cm['receivable']), color: Ar.amber.shade800),
          if (marketing) ...[
            Text('اتحصّلت', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
            Wrap(spacing: 8, children: [
              ChoiceChip(label: const Text('بنك'), selected: method == 'bank_transfer', onSelected: (_) => set(() => method = 'bank_transfer')),
              ChoiceChip(label: const Text('نقدي — خزنة المكتب'), selected: method == 'cash', onSelected: (_) => set(() => method = 'cash')),
              ChoiceChip(label: const Text('شيك'), selected: method == 'cheque', onSelected: (_) => set(() => method = 'cheque')),
            ]),
          ],
        ], () async {
      final r = await _post('/exclusive/units/${widget.unitId}/commission-collected',
          {if (marketing) 'paymentMethod': method}, 'اتسجل تحصيل العمولة ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    }, saveLabel: 'تم التحصيل');
    if (ok) _load();
  }

  Future<void> _decide(bool isDark, String what) async {
    final yes = await showDialog<String>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(what == 'contract' ? 'طلب التعاقد' : 'طلب إلغاء الحجز'),
        content: Text(what == 'contract' ? 'توافق على التعاقد؟ هيتعمل جدول الأقساط وعمولة السيلز ومدير المبيعات.' : 'توافق على إلغاء الحجز؟ العربون هيرجع للعميل من المحاسب.',
            textAlign: TextAlign.center),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'reject'), child: const Text('رفض', style: TextStyle(color: Ar.red))),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'approve'), child: const Text('موافقة')),
        ],
      ),
    );
    if (yes == null || !mounted) return;
    var reason = '';
    if (yes == 'reject' && what == 'contract') {
      final c = TextEditingController();
      final ok = await _form(context, isDark, 'سبب الرفض', (set) => [JphUi.input(isDark: isDark, label: 'السبب', controller: c)], () async {
        reason = c.text.trim();
        return reason.length >= 3;
      }, saveLabel: 'رفض');
      if (!ok) return;
    }
    final r = await _post('/exclusive/units/${widget.unitId}/${what == 'contract' ? 'contract' : 'cancel'}/decision',
        {'decision': yes, if (reason.isNotEmpty) 'reason': reason}, yes == 'approve' ? 'اتوافق ✅' : 'اترفض');
    if (mounted) JphUi.toast(context, r);
    _load();
  }

  Future<void> _cancel(bool isDark) async {
    final c = TextEditingController();
    final ok = await _form(context, isDark, 'إلغاء الحجز', (set) => [
          Text('بعد موافقة المالك / المدير العام، العربون بيرجع للعميل.', style: TextStyle(color: JphUi.sub(isDark))),
          JphUi.input(isDark: isDark, label: 'السبب', controller: c, icon: Icons.notes_rounded),
        ], () async {
      final r = await _post('/exclusive/units/${widget.unitId}/cancel', {'reason': c.text.trim()}, 'اتبعت طلب الإلغاء ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    }, saveLabel: 'إرسال');
    if (ok) _load();
  }

  Future<void> _refund(bool isDark) async {
    final money = _m(_u['money']);
    final left = _n(money['collected']) - _n(money['refunded']);
    final a = TextEditingController(text: '$left');
    final ok = await _form(context, isDark, 'رد العربون للعميل', (set) => [
          JphUi.input(isDark: isDark, label: 'المبلغ', controller: a, number: true, suffix: 'جنيه', icon: Icons.undo_rounded),
        ], () async {
      final r = await _post('/exclusive/units/${widget.unitId}/refund', {'amount': num.tryParse(a.text.replaceAll(',', ''))}, 'اتسجل رد العربون ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    }, saveLabel: 'تسجيل');
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final u = _u;
    return _Shell(
      title: u.isEmpty ? 'الوحدة' : 'وحدة ${u['unitNo']}',
      child: _d == null
          ? const Center(child: CircularProgressIndicator())
          : _d!['error'] != null
              ? Center(child: Text('${_d!['error']}'))
              : RefreshIndicator(onRefresh: _load, child: _body(isDark, u)),
    );
  }

  Widget _body(bool isDark, Map<String, dynamic> u) {
    final can = _m(u['can']), money = _m(u['money']), c = _m(u['contract']), cm = _m(u['commission']);
    final inst = _l(_d!['installments']);
    final receipts = _l(_d!['receipts']);
    final st = '${u['status']}';
    final pending = _l(_d!['pendingPayments']);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
      _section(isDark, '${u['projectName']} — وحدة ${u['unitNo']}', [
        Align(alignment: AlignmentDirectional.centerStart, child: _pill('${u['statusAr']}', _statusColor(st))),
        const SizedBox(height: 8),
        _kv(isDark, 'العميل', '${u['clientName']}${'${u['clientPhone'] ?? ''}'.isEmpty ? '' : ' · ${u['clientPhone']}'}'),
        if (_seesKind()) _kv(isDark, 'نوع المشروع', u['projectKind'] == 'marketing' ? 'تسويق' : 'حصري'),
        if (u['expectedContractDate'] != null && !['contracted', 'cancelled'].contains(st))
          _kv(isDark, 'التاريخ المتوقع للتعاقد', _date('${u['expectedContractDate']}')),
        _kv(isDark, 'السيلز', '${u['salesName']}'),
        if (u['marketingCompanyName'] != null) _kv(isDark, 'عن طريق', _seesKind() ? '${u['marketingCompanyName']} (${JphUi.pct(u['marketingPct'])})' : '${u['marketingCompanyName']}'),
        _kv(isDark, 'سعر الوحدة', _money(u['unitPrice'])),
        _kv(isDark, 'العربون', _money(u['depositAmount'])),
        if (c.isNotEmpty) ...[
          const Divider(),
          _kv(isDark, 'طريقة الدفع', c['paymentType'] == 'cash' ? 'كاش' : 'تقسيط'),
          _kv(isDark, c['paymentType'] == 'cash' ? 'المبلغ' : 'مقدم التعاقد', _money(c['downPayment'])),
          if (c['paymentType'] == 'installments') ...[
            _kv(isDark, 'الأقساط', '${c['installmentsCount']} قسط كل ${c['everyMonths']} شهر'),
            _kv(isDark, 'أول قسط', _date(c['firstDueDate'])),
            if (u['projectKind'] != 'marketing' && _seesKind()) _kv(isDark, 'عمولة كل قسط', JphUi.pct(c['installmentPct'])),
          ],
          if ('${c['rejectReason'] ?? ''}'.isNotEmpty) _kv(isDark, 'سبب رفض التعاقد', '${c['rejectReason']}', color: Ar.red),
        ],
        if ('${u['cancelReason'] ?? ''}'.isNotEmpty) _kv(isDark, 'سبب الإلغاء', '${u['cancelReason']}', color: Ar.red),
      ]),
      _section(isDark, 'الفلوس', [
        _kv(isDark, 'اتحصّل', _money(money['collected'])),
        if (_n(money['pending']) > 0) _kv(isDark, 'مستني تأكيد الاستلام', _money(money['pending']), color: Ar.amber),
        _kv(isDark, 'نقدي', _money(money['cash'])),
        _kv(isDark, 'بنك', _money(money['bank'])),
        if (_n(money['refunded']) > 0) _kv(isDark, 'اترد للعميل', _money(money['refunded']), color: Ar.red),
        _kv(isDark, 'الباقي من السعر', _money(money['remaining'])),
      ]),
      if (cm.isNotEmpty)
        _section(isDark, 'عمولة الوحدة', [
          if (_n(cm['potential']) > 0) _kv(isDark, 'محتملة (لحد التعاقد)', _money(cm['potential']), color: Ar.accent),
          if (st == 'contracted' || st == 'completed') ...[
            _kv(isDark, 'واجبة التحصيل', _money(cm['receivable']), color: Ar.amber),
            _kv(isDark, 'اتحصّلت', _money(cm['collected']), color: Ar.green),
          ],
          if (_n(cm['upcoming']) > 0) _kv(isDark, 'جاية من أقساط', _money(cm['upcoming'])),
          _kv(isDark, 'للسيلز ومدير المبيعات', _money(cm['staff'])),
          if (_n(cm['marketing']) > 0) _kv(isDark, 'لشركة التسويق', _money(cm['marketing'])),
          if (_n(cm['office']) > 0) _kv(isDark, 'نصيب المكتب', _money(cm['office']), color: Ar.green),
        ]),
      if (pending.isNotEmpty)
        _section(isDark, 'مستني تأكيد الاستلام', [
          for (final x in pending)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                const Icon(Icons.hourglass_top_rounded, color: Ar.amber),
                const SizedBox(width: 8),
                Expanded(child: Text('${x['kindAr']}', style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark)))),
                CountUpText(_money(x['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
              ]),
            ),
          if (can['receive'] == true) ...[
            const SizedBox(height: 8),
            for (final x in pending)
              _btn(isDark, 'تم استلام ${x['kindAr']} (${_money(x['amount'])})', Icons.task_alt_rounded, () => _receive(isDark, x), color: Ar.green),
          ],
        ]),
      if (_m(u['myCommission']).isNotEmpty)
        _section(isDark, 'عمولتك', [
          _kv(isDark, _m(u['myCommission'])['state'] == 'earned' ? 'مستحقة (بعد اعتماد المدير)' : 'محتملة (لحد التعاقد)',
              _money(_m(u['myCommission'])['amount']), color: Ar.green),
        ]),
      if (can['edit'] == true)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: OutlinedButton.icon(
            onPressed: () => _edit(isDark),
            icon: const Icon(Icons.edit_rounded),
            label: Text(st == 'contracted' ? 'تعديل التعاقد' : 'تعديل الحجز', style: const TextStyle(fontWeight: FontWeight.w800)),
            style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          ),
        ),
      if (st != 'cancelled')
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: OutlinedButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReservationFormPage(unit: u))),
            icon: const Icon(Icons.print_rounded),
            label: const Text('طباعة استمارة الحجز', style: TextStyle(fontWeight: FontWeight.w800)),
            style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          ),
        ),
      // the reservation's two buttons: إلغاء الحجز / تعاقد
      if (['reserving', 'reserved', 'contract_pending'].contains(st) && (can['requestCancel'] == true || can['requestContract'] == true || st == 'reserving'))
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            if (can['requestCancel'] == true)
              Expanded(
                child: SizedBox(
                  height: 54,
                  child: OutlinedButton.icon(
                    onPressed: () => _cancel(isDark),
                    icon: const Icon(Icons.cancel_rounded, color: Ar.red),
                    label: const Text('إلغاء الحجز', style: TextStyle(color: Ar.red, fontWeight: FontWeight.w900, fontSize: 16)),
                    style: OutlinedButton.styleFrom(side: const BorderSide(color: Ar.red), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                  ),
                ),
              ),
            if (can['requestCancel'] == true) const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 54,
                child: FilledButton.icon(
                  onPressed: can['requestContract'] == true ? () => _requestContract(isDark) : null,
                  icon: const Icon(Icons.handshake_rounded),
                  label: const Text('تعاقد', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                  style: FilledButton.styleFrom(backgroundColor: JphUi.primary(isDark), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                ),
              ),
            ),
          ]),
        ),
      if (st == 'reserving')
        Padding(padding: const EdgeInsets.only(bottom: 10),
            child: Text('التعاقد بيتفتح بعد ما المحاسب / المدير يأكد استلام العربون.', style: TextStyle(color: JphUi.sub(isDark)))),
      if (can['collectCommission'] == true)
        _btn(isDark, 'تم تحصيل العمولة', Icons.workspace_premium_rounded, () => _collectCommission(isDark), color: Ar.amber.shade800),
      if (can['decideContract'] == true) _btn(isDark, 'موافقة / رفض التعاقد', Icons.fact_check_rounded, () => _decide(isDark, 'contract'), color: Ar.amber),
      if (can['decideCancel'] == true) _btn(isDark, 'موافقة / رفض الإلغاء', Icons.fact_check_rounded, () => _decide(isDark, 'cancel'), color: Ar.amber),
      if (can['refund'] == true) _btn(isDark, 'رد العربون للعميل', Icons.undo_rounded, () => _refund(isDark), color: Ar.red),
      if (inst.isNotEmpty)
        _section(isDark, 'الأقساط', [
          for (final i in inst)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                CircleAvatar(radius: 15, backgroundColor: (i['status'] == 'paid' ? Ar.green : i['status'] == 'overdue' ? Ar.red : Ar.accent).withOpacity(0.15),
                    child: Text('${i['seq']}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    CountUpText(_money(i['amount']), style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                    Text('${_date(i['dueDate'])}${_n(i['paid']) > 0 && i['status'] != 'paid' ? ' · اتدفع ${_money(i['paid'])}' : ''}',
                        style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                  ]),
                ),
                if (i['status'] == 'paid') _pill('اتدفع', Ar.green)
                else if (can['collect'] == true)
                  TextButton(onPressed: () => _receiveInstallment(isDark, i), child: const Text('تم الاستلام'))
                else _pill(i['status'] == 'overdue' ? 'متأخر' : 'مستحق', i['status'] == 'overdue' ? Ar.red : Ar.accent),
              ]),
            ),
        ]),
      if (receipts.isNotEmpty)
        _section(isDark, 'الإيصالات', [
          for (final r in receipts)
            _kv(isDark, '${r['kindAr']} · ${_date(r['at'])} · ${r['method'] == 'cash' ? 'نقدي' : 'بنك'} · ${r['receiptNo']}', _money(r['amount'])),
        ]),
    ]);
  }
}
