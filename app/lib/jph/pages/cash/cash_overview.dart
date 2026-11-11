import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../widgets/jph_form_ui.dart';
import 'cash_page.dart' show newClientRef;

/// الخزنة the office's way (GET /cash/overview):
///   المتاح = بنك + نقدي (نقدي = خزنة المكتب + خزنة المحاسب)
///   الدخل = عمولات (الربح الوحيد) / مبيعات (حجوزات، تعاقد، أقساط) / ضخ من المالك - المدير العام / أمانات المشاريع الحصري
///   العمولات بتتقسم: سيلز / مدير سيلز / المكتب / شركة تسويق — والمكتب بيطلع منها المرتبات والمصاريف بأنواعها.
/// المحاسب بيشوف خزنته بس (نقدي / بنك).
class CashOverview extends StatefulWidget {
  final bool isDark;
  final ValueListenable<DateTime>? month;
  final Future<void> Function()? onChanged;
  const CashOverview({super.key, required this.isDark, this.month, this.onChanged});

  @override
  State<CashOverview> createState() => _CashOverviewState();
}

Map<String, dynamic> _m(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
List<Map<String, dynamic>> _l(Object? v) => ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
num _n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
String _d(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class _CashOverviewState extends State<CashOverview> {
  Map<String, dynamic> _o = {};
  bool _loading = true;

  bool get _office => ApiService.can('cash.office');
  DateTime get _month => widget.month?.value ?? DateTime(DateTime.now().year, DateTime.now().month);

  @override
  void initState() {
    super.initState();
    widget.month?.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.month?.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final m = _month;
    final r = await ApiService.post({'action': 'cash_get', 'path': '/cash/overview',
      'query': {'from': _d(m), 'to': _d(DateTime(m.year, m.month + 1, 0))}});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _o = r;
    });
  }

  Future<void> _changed() async {
    await _load();
    await widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    if (_loading) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    if (_o['success'] != true) return const SizedBox.shrink();
    final av = _m(_o['available']);
    final inc = _m(_o['income']);
    final exp = _m(_o['expenses']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _available(isDark, av),
      const SizedBox(height: 14),
      _title(isDark, 'الدخل — ${JphUi.monthsAr[_month.month - 1]}'),
      JphUi.statGrid([
        if (_office) _tap(JphUi.stat(isDark, 'عمولات (ربحي)', JphUi.money(inc['commissions']), Icons.workspace_premium_rounded, Colors.amber.shade700),
            () => _commissionSheet(isDark)),
        _tap(JphUi.stat(isDark, 'مبيعات', JphUi.money(_m(inc['sales'])['total']), Icons.home_work_rounded, Colors.teal), () => _salesSheet(isDark, _m(inc['sales']))),
        JphUi.stat(isDark, 'ضخ من المالك / المدير العام', JphUi.money(inc['injection']), Icons.add_card_rounded, Colors.indigo),
        if (_office) _tap(JphUi.stat(isDark, 'أمانات (الحصري)', JphUi.money(_m(inc['trust'])['balance']), Icons.real_estate_agent_rounded, Colors.purple),
            () => _trustSheet(isDark, _m(inc['trust']))),
      ]),
      const SizedBox(height: 14),
      _expenses(isDark, exp),
      if (_office && _o['result'] is Map) ...[
        const SizedBox(height: 14),
        _result(isDark, _m(_o['result'])),
      ],
      if (_office) ...[
        const SizedBox(height: 14),
        // العمولات بتدخل من «تم التحصيل» على الوحدة في المبيعات — مفيش إدخال يدوي
        _action(isDark, 'ضخ فلوس', Icons.add_card_rounded, Colors.indigo, () => _inject(isDark)),
      ],
      const SizedBox(height: 6),
    ]);
  }

  Widget _tap(Widget w, VoidCallback onTap) => GestureDetector(onTap: onTap, child: w);

  Widget _title(bool isDark, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(t, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      );

  Widget _available(bool isDark, Map<String, dynamic> av) {
    final hr = _m(av['hr']), office = _m(av['office']);
    final full = _office && av['total'] != null;
    final p = JphUi.primary(isDark);
    Widget piece(String label, Object? v, IconData icon, {List<Widget> under = const []}) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.14), borderRadius: BorderRadius.circular(16)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, color: Colors.white70, size: 18),
                const SizedBox(width: 6),
                Expanded(child: Text(label, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, fontSize: 13))),
              ]),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(JphUi.money(v), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 19)),
              ),
              ...under,
            ]),
          ),
        );
    Widget sub(String label, Object? v) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            Expanded(child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12))),
            Text(JphUi.money(v), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12.5)),
          ]),
        );
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [p, Color.lerp(p, Colors.black, 0.35)!]),
        boxShadow: [BoxShadow(color: p.withOpacity(0.3), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(full ? 'إجمالي المبالغ المتاحة' : 'خزنة المحاسب', style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(JphUi.money(full ? av['total'] : hr['total']),
              style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900)),
        ),
        const SizedBox(height: 14),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          piece('بنك', full ? av['bank'] : hr['bank'], Icons.account_balance_rounded),
          const SizedBox(width: 10),
          piece('نقدي', full ? av['cash'] : hr['cash'], Icons.payments_rounded, under: [
            if (full) ...[
              const SizedBox(height: 4),
              sub('خزنة المكتب', office['cash']),
              sub('خزنة المحاسب', hr['cash']),
            ],
          ]),
        ]),
      ]),
    );
  }

  Widget _row(bool isDark, String k, Object? v, {Color? color, bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(child: Text(k, style: TextStyle(fontSize: 14, color: bold ? JphUi.text(isDark) : JphUi.sub(isDark), fontWeight: bold ? FontWeight.w800 : FontWeight.w500))),
          Text(JphUi.money(v), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: color ?? JphUi.text(isDark))),
        ]),
      );

  Widget _expenses(bool isDark, Map<String, dynamic> exp) {
    final pay = _m(exp['payroll']);
    final cats = _l(exp['byCategory']);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          JphUi.iconTile(isDark, Icons.receipt_long_rounded, Colors.deepOrange),
          const SizedBox(width: 12),
          Expanded(child: Text('المصروفات', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
          Text(JphUi.money(exp['total']), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: Colors.deepOrange)),
        ]),
        const SizedBox(height: 8),
        _row(isDark, 'المرتبات', pay['salary']),
        if (_n(pay['commission']) > 0) _row(isDark, 'عمولات اتصرفت للموظفين', pay['commission']),
        if (_n(pay['advance']) > 0) _row(isDark, 'سلف', pay['advance']),
        if (_n(pay['workExpense']) > 0) _row(isDark, 'مصاريف عمل', pay['workExpense']),
        for (final c in cats) _row(isDark, '${c['name']}', c['amount']),
        if (cats.isEmpty && _n(exp['payrollTotal']) == 0)
          Padding(padding: const EdgeInsets.all(8), child: Text('مفيش مصروفات الشهر ده', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
      ]),
    );
  }

  Widget _result(bool isDark, Map<String, dynamic> r) {
    final net = _n(r['net']);
    final c = net >= 0 ? Colors.green : Colors.red;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _row(isDark, 'العمولات (الدخل الحقيقي)', r['commissions'], color: Colors.amber.shade800),
        _row(isDark, 'المرتبات والمصاريف', r['costs'], color: Colors.deepOrange),
        const Divider(),
        Row(children: [
          Icon(net >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded, color: c),
          const SizedBox(width: 8),
          Expanded(child: Text(net >= 0 ? 'صافي ربح المكتب' : 'عجز — محتاج ضخ', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: c))),
          Text(JphUi.money(net.abs()), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 19, color: c)),
        ]),
      ]),
    );
  }

  Widget _action(bool isDark, String label, IconData icon, Color color, VoidCallback onTap) => SizedBox(
        height: 50,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, color: color),
          label: Text(label, style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
          style: OutlinedButton.styleFrom(side: BorderSide(color: color.withOpacity(0.5)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        ),
      );

  // ------------------------------------------------------------------ the details sheets
  Future<void> _sheet(bool isDark, String title, List<Widget> rows) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => Directionality(
          textDirection: ui.TextDirection.rtl,
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(18),
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            decoration: BoxDecoration(color: isDark ? const Color(0xFF1E2230) : Colors.white, borderRadius: BorderRadius.circular(24)),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                  IconButton(onPressed: () => Navigator.pop(ctx), icon: Icon(Icons.close_rounded, color: JphUi.sub(isDark))),
                ]),
                const SizedBox(height: 6),
                ...rows,
              ]),
            ),
          ),
        ),
      );

  void _salesSheet(bool isDark, Map<String, dynamic> s) => _sheet(isDark, 'المبيعات — الفلوس اللي دخلت', [
        _row(isDark, 'حجوزات (عربون)', s['reservation']),
        _row(isDark, 'تعاقد (مقدمات)', s['contract']),
        _row(isDark, 'أقساط', s['installment']),
        const Divider(),
        _row(isDark, 'الإجمالي', s['total'], bold: true),
        const SizedBox(height: 8),
        Text('فلوس الوحدات مش ربح: الحصري منها أمانة للمالك، والربح هو العمولة بس.', style: TextStyle(color: JphUi.sub(isDark))),
      ]);

  void _trustSheet(bool isDark, Map<String, dynamic> t) => _sheet(isDark, 'الأمانات — فلوس ملاك المشاريع الحصري', [
        _row(isDark, 'دخل الشهر (حجز / تعاقد / أقساط)', t['in'], color: Colors.green),
        _row(isDark, 'خرج الشهر (صرف للمالك / رد عربون)', t['out'], color: Colors.red),
        _row(isDark, 'عمولة اتحوّلت للمكتب الشهر ده', t['commissionMoved'], color: Colors.amber.shade800),
        const Divider(),
        _row(isDark, 'في الأمانة دلوقتي (كل المشاريع)', t['balance'], bold: true),
        const SizedBox(height: 8),
        Text('الأمانة بتطلع لمالك المشروع بإذن صرف من صفحة المشروع.', style: TextStyle(color: JphUi.sub(isDark))),
      ]);

  void _commissionSheet(bool isDark) {
    final inc = _m(_o['income']);
    final sp = _m(_o['commissionSplit']);
    _sheet(isDark, 'العمولات', [
      _row(isDark, 'عمولة مستلمة من المطورين', inc['commissionReceived'], color: Colors.green),
      _row(isDark, 'عمولة اتحوّلت من أمانات الحصري', _m(inc['trust'])['commissionMoved'], color: Colors.green),
      const Divider(),
      _row(isDark, 'دخل العمولات', inc['commissions'], bold: true),
      const SizedBox(height: 14),
      Text('تقسيم عمولات صفقات الشهر (${sp['deals'] ?? 0} صفقة)', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      const SizedBox(height: 6),
      _row(isDark, 'السيلز', sp['sales']),
      _row(isDark, 'مدير السيلز', sp['manager']),
      _row(isDark, 'شركات التسويق', sp['marketing']),
      _row(isDark, 'المكتب', sp['office'], color: Colors.teal),
      const Divider(),
      _row(isDark, 'إجمالي العمولة', sp['total'], bold: true),
    ]);
  }

  // ------------------------------------------------------------------ actions
  Future<void> _inject(bool isDark) async {
    String target = 'office';
    final amount = TextEditingController(), note = TextEditingController();
    final ref = newClientRef(); // pressing the button twice records one injection
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: StatefulBuilder(builder: (ctx, set) {
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: isDark ? const Color(0xFF1E2230) : Colors.white, borderRadius: BorderRadius.circular(24)),
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('ضخ فلوس في الشركة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  const SizedBox(height: 4),
                  Text('لما الشركة متجيبش أرباح تكفي المرتبات والمصاريف', style: TextStyle(color: JphUi.sub(isDark))),
                  const SizedBox(height: 14),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final t in const [('office', 'نقدي — خزنة المكتب'), ('hr', 'نقدي — خزنة المحاسب'), ('bank', 'البنك')])
                      ChoiceChip(label: Text(t.$2), selected: target == t.$1, onSelected: (_) => set(() => target = t.$1)),
                  ]),
                  const SizedBox(height: 12),
                  JphUi.input(isDark: isDark, label: 'المبلغ', controller: amount, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
                  const SizedBox(height: 10),
                  JphUi.input(isDark: isDark, label: 'ملاحظة (مثلاً: تكملة مرتبات)', controller: note, icon: Icons.notes_rounded),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: () async {
                        final r = await ApiService.post({'action': 'cash_post', 'path': '/cash/injections', 'ok': 'اتسجل الضخ ✅', 'body': {
                          'target': target, 'amount': num.tryParse(amount.text.replaceAll(',', '')), 'note': note.text.trim(),
                          'clientRef': ref,
                        }});
                        if (ctx.mounted) JphUi.toast(ctx, r);
                        if (r['success'] == true && ctx.mounted) Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('تسجيل الضخ', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ]),
              ),
            ),
          );
        }),
      ),
    );
    await _changed();
  }

  Future<void> _commissionIn(bool isDark) async {
    final pr = await ApiService.post({'action': 'cash_get', 'path': '/exclusive/projects', 'query': {'kind': 'marketing'}});
    if (!mounted) return;
    final projects = _l(pr['projects']);
    Map<String, dynamic>? project;
    String method = 'bank_transfer';
    final amount = TextEditingController(), payer = TextEditingController(), unit = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: StatefulBuilder(builder: (ctx, set) {
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(18),
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.9),
              decoration: BoxDecoration(color: isDark ? const Color(0xFF1E2230) : Colors.white, borderRadius: BorderRadius.circular(24)),
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('عمولة مستلمة من المطور', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  const SizedBox(height: 12),
                  Wrap(spacing: 8, runSpacing: 8, children: [
                    for (final p in projects)
                      ChoiceChip(label: Text('${p['name']}'), selected: project?['id'] == p['id'], onSelected: (_) => set(() {
                        project = p;
                        if (payer.text.trim().isEmpty) payer.text = '${p['name']}';
                      })),
                  ]),
                  const SizedBox(height: 12),
                  JphUi.input(isDark: isDark, label: 'المبلغ', controller: amount, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
                  const SizedBox(height: 10),
                  JphUi.input(isDark: isDark, label: 'من (المطور)', controller: payer, icon: Icons.business_rounded),
                  const SizedBox(height: 10),
                  JphUi.input(isDark: isDark, label: 'الوحدات (اختياري)', controller: unit, icon: Icons.tag_rounded),
                  const SizedBox(height: 10),
                  Wrap(spacing: 8, children: [
                    for (final t in const [('bank_transfer', 'البنك'), ('cash', 'نقدي — خزنة المكتب'), ('cheque', 'شيك')])
                      ChoiceChip(label: Text(t.$2), selected: method == t.$1, onSelected: (_) => set(() => method = t.$1)),
                  ]),
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: () async {
                        final r = await ApiService.post({'action': 'cash_post', 'path': '/cash/receipts', 'ok': 'اتسجلت العمولة ✅', 'body': {
                          'recipient': 'manager', 'kind': 'commission', 'amount': num.tryParse(amount.text.replaceAll(',', '')),
                          'payerName': payer.text.trim(), 'paymentMethod': method, if (project != null) 'projectId': project!['id'],
                          'purpose': 'عمولة${project != null ? ' ${project!['name']}' : ''}${unit.text.trim().isEmpty ? '' : ' — ${unit.text.trim()}'}',
                        }});
                        if (ctx.mounted) JphUi.toast(ctx, r);
                        if (r['success'] == true && ctx.mounted) Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('تسجيل', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ]),
              ),
            ),
          );
        }),
      ),
    );
    await _changed();
  }
}

