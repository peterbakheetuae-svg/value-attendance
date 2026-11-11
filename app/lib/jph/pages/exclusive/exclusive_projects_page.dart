import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_dialog.dart';
import '../../widgets/jph_form_ui.dart';

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
Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, String ok) =>
    ApiService.post({'action': 'cash_post', 'path': path, 'body': body, 'ok': ok});

Widget _kv(bool isDark, String k, String v, {Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(child: Text(k, style: TextStyle(fontSize: 14, color: JphUi.sub(isDark)))),
        Text(v, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color ?? JphUi.text(isDark))),
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
      'reserving' => Colors.orange,
      'reserved' => Colors.indigo,
      'contract_pending' || 'cancel_pending' => Colors.deepOrange,
      'contracted' => Colors.teal,
      'completed' => Colors.green,
      'cancelled' => Colors.grey,
      _ => Colors.blueGrey,
    };

Widget _pill(String t, Color c) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.circular(20)),
      child: Text(t, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: c)),
    );

/// A bottom sheet with fields and one save button; returns true when saved.
Future<bool> _form(BuildContext context, bool isDark, String title, List<Widget> Function(StateSetter set) fields,
    Future<bool> Function() save, {String saveLabel = 'حفظ'}) async {
  final r = await showModalBottomSheet<bool>(
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
            decoration: BoxDecoration(color: isDark ? const Color(0xFF1E2230) : Colors.white, borderRadius: BorderRadius.circular(24)),
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
      iconColor: method == 'cash' ? Colors.green : Colors.indigo, label: 'الفلوس', value: method == 'cash' ? 'نقدي' : 'بنك',
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
        if (_reserve && _items.isNotEmpty) _btn(isDark, 'حجز وحدة', Icons.bookmark_add_rounded, () => reserveUnit(context, isDark, _items, then: _load), color: Colors.teal),
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
        await Navigator.push(context, MaterialPageRoute(builder: (_) => ExclusiveProjectPage(projectId: '${p['id']}')));
        _load();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: JphUi.box(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            JphUi.iconTile(isDark, Icons.apartment_rounded, Colors.indigo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${p['name']}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                Text('المالك: ${p['ownerName'] ?? ''}', style: TextStyle(fontSize: 13, color: JphUi.sub(isDark))),
              ]),
            ),
            if (p['status'] != 'active') _pill(p['status'] == 'paused' ? 'متوقف' : 'مقفول', Colors.orange),
            Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _pill('عمولة ${JphUi.pct(p['totalPct'])}', Colors.indigo),
            _pill('عند التعاقد ${JphUi.pct(p['contractPct'])}', Colors.teal),
            _pill('القسط ${JphUi.pct(p['installmentPct'])}', Colors.purple),
            _pill('سيلز ${JphUi.pct(p['salesPct'])} · مدير ${JphUi.pct(p['managerPct'])}', Colors.blueGrey),
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
            _kv(isDark, 'عمولة مستنية التحويل', _money(cm['pending']), color: Colors.orange),
          ],
        ]),
      ),
    );
  }
}

/// حجز وحدة (the salesperson / the management).
Future<void> reserveUnit(BuildContext context, bool isDark, List<Map<String, dynamic>> projects, {String? projectId, VoidCallback? then}) async {
  String? pid = projectId ?? (projects.length == 1 ? '${projects.first['id']}' : null);
  final unit = TextEditingController(), client = TextEditingController(), phone = TextEditingController(),
      price = TextEditingController(), deposit = TextEditingController(), notes = TextEditingController();
  final ok = await _form(context, isDark, 'حجز وحدة', (set) => [
        if (projectId == null)
          JphUi.picker(
            isDark: isDark, icon: Icons.apartment_rounded, iconColor: Colors.indigo, label: 'المشروع',
            value: pid == null ? 'اختار المشروع' : '${projects.firstWhere((p) => '${p['id']}' == pid, orElse: () => const {})['name'] ?? ''}',
            onTap: () async {
              final v = await JphUi.sheet<String>(context, isDark, 'المشروع',
                  [for (final p in projects.where((p) => p['status'] == 'active')) ('${p['id']}', '${p['name']}', Icons.apartment_rounded)], selected: pid);
              if (v != null) set(() => pid = v);
            },
          ),
        JphUi.input(isDark: isDark, label: 'رقم الوحدة', controller: unit, icon: Icons.tag_rounded),
        JphUi.input(isDark: isDark, label: 'اسم العميل', controller: client, icon: Icons.person_rounded),
        JphUi.input(isDark: isDark, label: 'تليفون العميل', controller: phone, icon: Icons.phone_rounded, number: true),
        JphUi.input(isDark: isDark, label: 'إجمالي سعر الوحدة', controller: price, icon: Icons.sell_rounded, number: true, suffix: 'جنيه'),
        JphUi.input(isDark: isDark, label: 'العربون', controller: deposit, icon: Icons.savings_rounded, number: true, suffix: 'جنيه'),
        JphUi.input(isDark: isDark, label: 'ملاحظات', controller: notes, icon: Icons.notes_rounded),
      ], () async {
    if (pid == null) {
      JphUi.toast(context, {'success': false, 'message': 'اختار المشروع'});
      return false;
    }
    final r = await _post('/exclusive/units', {
      'projectId': pid, 'unitNo': unit.text.trim(), 'clientName': client.text.trim(), 'clientPhone': phone.text.trim(),
      'unitPrice': num.tryParse(price.text.replaceAll(',', '')), 'depositAmount': num.tryParse(deposit.text.replaceAll(',', '')), 'notes': notes.text.trim(),
    }, 'اتسجل الحجز — مستني المحاسب يسجل العربون ✅');
    if (context.mounted) JphUi.toast(context, r);
    return r['success'] == true;
  }, saveLabel: 'حجز');
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
      title: p.isEmpty ? 'مشروع حصري' : '${p['name']}',
      child: _d == null
          ? const Center(child: CircularProgressIndicator())
          : _d!['error'] != null
              ? Center(child: Text('${_d!['error']}'))
              : RefreshIndicator(onRefresh: _load, child: _body(isDark, p)),
    );
  }

  Widget _body(bool isDark, Map<String, dynamic> p) {
    final st = _m(p['stats']);
    final can = _m(_d!['can']);
    final cm = _m(st['commission']), ow = _m(st['owner']), u = _m(st['units']);
    final units = _l(_d!['units']).where((x) => _filter.isEmpty || x['status'] == _filter).toList();
    final statement = _l(_d!['statement']);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
      if (st.isNotEmpty) ...[
        _section(isDark, 'أمانة المالك — ${p['ownerName'] ?? ''}', [
          _kv(isDark, 'اتحصّل', _money(st['collected'])),
          _kv(isDark, 'منه بنك', _money(st['bank'])),
          _kv(isDark, 'اترد للعملاء', _money(st['refunded'])),
          _kv(isDark, 'عمولة اتحوّلت للمكتب', _money(cm['transferred'])),
          _kv(isDark, 'اتصرف للمالك', _money(ow['paid'])),
          if (_n(ow['pendingPayout']) > 0) _kv(isDark, 'إذن صرف مستني موافقة', _money(ow['pendingPayout']), color: Colors.orange),
          const Divider(),
          _kv(isDark, 'في الأمانة دلوقتي', _money(ow['inTrust'])),
          _kv(isDark, 'الصافي المستحق للمالك', _money(ow['due']), color: Colors.teal),
        ]),
        _section(isDark, 'عمولتي', [
          _kv(isDark, 'مستحقة لحد دلوقتي', _money(cm['earned'])),
          _kv(isDark, 'اتحوّلت فعلاً', _money(cm['transferred']), color: Colors.green),
          _kv(isDark, 'في الأمانة لسه متحوّلتش', _money(cm['pending']), color: Colors.orange),
          _kv(isDark, 'جاية من أقساط', _money(cm['upcoming'])),
          _kv(isDark, 'محتملة من حجوزات', _money(cm['potential'])),
          _kv(isDark, 'منها للسيلز ومدير المبيعات', _money(cm['staff'])),
        ]),
        if (can['manage'] == true) ...[
          _btn(isDark, 'تحويل عمولة من الأمانة', Icons.swap_horiz_rounded, () => _transfer(isDark, _n(cm['pending'])), color: Colors.green),
          _btn(isDark, 'إذن صرف للمالك', Icons.real_estate_agent_rounded,
              () => _payout(isDark, _n(ow['due']) - _n(ow['pendingPayout'])), color: Colors.indigo),
        ],
      ],
      if (can['reserve'] == true) _btn(isDark, 'حجز وحدة', Icons.bookmark_add_rounded, () => reserveUnit(context, isDark, [p], projectId: '${p['id']}', then: _load), color: Colors.teal),
      if (statement.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'units', label: Text('الوحدات')), ButtonSegment(value: 'statement', label: Text('كشف حساب المالك'))],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
          ),
        ),
      if (_tab == 'units') ...[
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
                  color: s['dir'] == 'in' ? Colors.green : s['dir'] == 'out' ? Colors.red : Colors.orange),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${s['typeAr']}${s['unitNo'] != null ? ' — وحدة ${s['unitNo']}' : ''}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                  Text('${s['who'] ?? ''} · ${_date(s['at'])}${s['method'] != null && s['method'] != 'cash' ? ' · بنك' : ''}',
                      style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                ]),
              ),
              Text('${s['dir'] == 'in' ? '+' : '−'}${_money(s['amount'])}', style: TextStyle(fontWeight: FontWeight.w900, color: s['dir'] == 'in' ? Colors.green : Colors.red)),
            ]),
          ),
    ]);
  }

  Widget _unitCard(bool isDark, Map<String, dynamic> x) {
    final money = _m(x['money']);
    final st = '${x['status']}';
    return GestureDetector(
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => ExclusiveUnitPage(unitId: '${x['id']}')));
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
            isDark: isDark, icon: Icons.category_rounded, iconColor: Colors.indigo, label: 'النوع',
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

  Future<void> _requestContract(bool isDark) async {
    String type = 'installments';
    final price = _n(_u['unitPrice']);
    final down = TextEditingController(), count = TextEditingController(text: '8'), every = TextEditingController(text: '3'),
        pct = TextEditingController(text: '0.5'), note = TextEditingController();
    DateTime first = DateTime.now().add(const Duration(days: 90));
    final ok = await _form(context, isDark, 'طلب تعاقد — وحدة ${_u['unitNo']}', (set) => [
          SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'installments', label: Text('تقسيط')), ButtonSegment(value: 'cash', label: Text('كاش'))],
            selected: {type},
            onSelectionChanged: (s) => set(() {
              type = s.first;
              if (type == 'cash') down.text = '$price';
            }),
          ),
          JphUi.input(isDark: isDark, label: type == 'cash' ? 'المبلغ (السعر كله)' : 'مقدم التعاقد (العربون محسوب منه)', controller: down,
              number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
          if (type == 'installments') ...[
            JphUi.input(isDark: isDark, label: 'عدد الأقساط', controller: count, number: true, icon: Icons.format_list_numbered_rounded),
            JphUi.input(isDark: isDark, label: 'كل كام شهر', controller: every, number: true, icon: Icons.event_repeat_rounded),
            JphUi.picker(
              isDark: isDark, icon: Icons.event_rounded, iconColor: Colors.teal, label: 'أول قسط', value: _date(first.toIso8601String()),
              onTap: () async {
                final d = await showDatePicker(context: context, initialDate: first, firstDate: DateTime.now(), lastDate: DateTime(DateTime.now().year + 15));
                if (d != null) set(() => first = d);
              },
            ),
            JphUi.input(isDark: isDark, label: 'نسبة عمولة كل قسط ٪ (حسب الاتفاق)', controller: pct, number: true, icon: Icons.percent_rounded),
          ],
          JphUi.input(isDark: isDark, label: 'ملاحظة', controller: note, icon: Icons.notes_rounded),
        ], () async {
      final f = '${first.year}-${first.month.toString().padLeft(2, '0')}-${first.day.toString().padLeft(2, '0')}';
      final r = await _post('/exclusive/units/${widget.unitId}/contract', {
        'paymentType': type, 'downPayment': num.tryParse(down.text.replaceAll(',', '')), 'note': note.text.trim(),
        if (type == 'installments') ...{'installmentsCount': int.tryParse(count.text), 'everyMonths': int.tryParse(every.text),
          'firstDueDate': f, 'installmentPct': num.tryParse(pct.text)},
      }, 'اتبعت طلب التعاقد — مستني موافقة المالك / المدير العام ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    }, saveLabel: 'إرسال');
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
          TextButton(onPressed: () => Navigator.pop(ctx, 'reject'), child: const Text('رفض', style: TextStyle(color: Colors.red))),
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
    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
      _section(isDark, '${u['projectName']} — وحدة ${u['unitNo']}', [
        Align(alignment: AlignmentDirectional.centerStart, child: _pill('${u['statusAr']}', _statusColor(st))),
        const SizedBox(height: 8),
        _kv(isDark, 'العميل', '${u['clientName']}${'${u['clientPhone'] ?? ''}'.isEmpty ? '' : ' · ${u['clientPhone']}'}'),
        _kv(isDark, 'السيلز', '${u['salesName']}'),
        _kv(isDark, 'سعر الوحدة', _money(u['unitPrice'])),
        _kv(isDark, 'العربون', _money(u['depositAmount'])),
        if (c.isNotEmpty) ...[
          const Divider(),
          _kv(isDark, 'طريقة الدفع', c['paymentType'] == 'cash' ? 'كاش' : 'تقسيط'),
          _kv(isDark, c['paymentType'] == 'cash' ? 'المبلغ' : 'مقدم التعاقد', _money(c['downPayment'])),
          if (c['paymentType'] == 'installments') ...[
            _kv(isDark, 'الأقساط', '${c['installmentsCount']} قسط كل ${c['everyMonths']} شهر'),
            _kv(isDark, 'أول قسط', _date(c['firstDueDate'])),
            _kv(isDark, 'عمولة كل قسط', JphUi.pct(c['installmentPct'])),
          ],
          if ('${c['rejectReason'] ?? ''}'.isNotEmpty) _kv(isDark, 'سبب رفض التعاقد', '${c['rejectReason']}', color: Colors.red),
        ],
        if ('${u['cancelReason'] ?? ''}'.isNotEmpty) _kv(isDark, 'سبب الإلغاء', '${u['cancelReason']}', color: Colors.red),
      ]),
      _section(isDark, 'الفلوس', [
        _kv(isDark, 'اتحصّل', _money(money['collected'])),
        _kv(isDark, 'نقدي', _money(money['cash'])),
        _kv(isDark, 'بنك', _money(money['bank'])),
        if (_n(money['refunded']) > 0) _kv(isDark, 'اترد للعميل', _money(money['refunded']), color: Colors.red),
        _kv(isDark, 'الباقي من السعر', _money(money['remaining'])),
      ]),
      if (cm.isNotEmpty)
        _section(isDark, 'عمولة المكتب على الوحدة', [
          _kv(isDark, 'مستحقة', _money(cm['earned']), color: Colors.green),
          _kv(isDark, 'جاية من أقساط', _money(cm['upcoming'])),
          _kv(isDark, 'محتملة', _money(cm['potential'])),
          _kv(isDark, 'للسيلز ومدير المبيعات', _money(cm['staff'])),
        ]),
      if (can['collect'] == true) _btn(isDark, 'تسجيل فلوس (عربون / مقدم / قسط)', Icons.add_card_rounded, () => _collect(isDark), color: Colors.green),
      if (can['requestContract'] == true) _btn(isDark, 'طلب تعاقد', Icons.handshake_rounded, () => _requestContract(isDark)),
      if (can['decideContract'] == true) _btn(isDark, 'موافقة / رفض التعاقد', Icons.fact_check_rounded, () => _decide(isDark, 'contract'), color: Colors.deepOrange),
      if (can['decideCancel'] == true) _btn(isDark, 'موافقة / رفض الإلغاء', Icons.fact_check_rounded, () => _decide(isDark, 'cancel'), color: Colors.deepOrange),
      if (can['refund'] == true) _btn(isDark, 'رد العربون للعميل', Icons.undo_rounded, () => _refund(isDark), color: Colors.red),
      if (can['requestCancel'] == true)
        TextButton.icon(onPressed: () => _cancel(isDark), icon: const Icon(Icons.cancel_rounded, color: Colors.red),
            label: const Text('إلغاء الحجز', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w800))),
      if (inst.isNotEmpty)
        _section(isDark, 'الأقساط', [
          for (final i in inst)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                CircleAvatar(radius: 15, backgroundColor: (i['status'] == 'paid' ? Colors.green : i['status'] == 'overdue' ? Colors.red : Colors.indigo).withOpacity(0.15),
                    child: Text('${i['seq']}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(_money(i['amount']), style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                    Text('${_date(i['dueDate'])}${_n(i['paid']) > 0 && i['status'] != 'paid' ? ' · اتدفع ${_money(i['paid'])}' : ''}',
                        style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                  ]),
                ),
                if (i['status'] == 'paid') _pill('اتدفع', Colors.green)
                else if (can['collect'] == true)
                  TextButton(onPressed: () => _collect(isDark, kind: 'installment', inst: i), child: const Text('تحصيل'))
                else _pill(i['status'] == 'overdue' ? 'متأخر' : 'مستحق', i['status'] == 'overdue' ? Colors.red : Colors.indigo),
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
