import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/jph_form_ui.dart';
import '../cash/cash_page.dart';

/// دفعات المرتبات — HR prepares the month (every employee's calculation is frozen), submits it, المدير / owner
/// approves or returns it, then HR pays each employee and the employee confirms receipt (or reports a problem).
/// Second tab: السلف — set by hand how much of each approved advance is deducted, and in which month (2 stages max).
class PayrollBatchesPage extends StatefulWidget {
  const PayrollBatchesPage({super.key});

  @override
  State<PayrollBatchesPage> createState() => _PayrollBatchesPageState();
}

const _batchStatus = {
  'draft': ('مسودة', Colors.blueGrey), 'pending_approval': ('مستنية الموافقة', Colors.orange), 'approved': ('معتمدة', Colors.green),
  'returned': ('اترجعت للمراجعة', Colors.red), 'cancelled': ('ملغية', Colors.grey),
};
const _lineStatusAr = {
  'draft': ('مسودة', Colors.blueGrey), 'pending_approval': ('مستنية الموافقة', Colors.orange), 'returned': ('اترجعت', Colors.red),
  'approved': ('معتمد — لسه ماتصرفش', Colors.blue), 'partly_paid': ('اتصرف جزء', Colors.orange),
  'awaiting_confirmation': ('اتصرف — مستني تأكيد الموظف', Colors.teal), 'confirmed': ('الموظف أكد الاستلام', Colors.green),
  'disputed': ('فيه بلاغ مشكلة', Colors.red),
};

class _PayrollBatchesPageState extends State<PayrollBatchesPage> {
  String _tab = 'batches';

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
                JphUi.header(context, isDark: isDark, isRTL: isRTL, title: 'دفعات المرتبات'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: cashSegmented(isDark, {'batches': 'المرتبات الشهرية', 'advances': 'خصم السلف'}, _tab, (v) => setState(() => _tab = v)),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      child: _tab == 'batches' ? _BatchesTab(isDark: isDark) : _AdvancesTab(isDark: isDark),
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

class _BatchesTab extends StatefulWidget {
  final bool isDark;
  const _BatchesTab({required this.isDark});

  @override
  State<_BatchesTab> createState() => _BatchesTabState();
}

class _BatchesTabState extends State<_BatchesTab> {
  Map<String, dynamic> _r = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await cashGet('/payroll-batches');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _r = r;
    });
  }

  Future<void> _create() async {
    final now = DateTime.now();
    final months = [for (var i = -2; i <= 1; i++) DateTime(now.year, now.month + i)];
    final m = await JphUi.sheet<DateTime>(context, widget.isDark, 'مرتبات شهر',
        [for (final d in months) (d, '${JphUi.monthsAr[d.month - 1]} ${d.year}', Icons.event_rounded)]);
    if (m == null) return;
    final r = await cashPost('/payroll-batches', {'month': '${m.year}-${m.month.toString().padLeft(2, '0')}'}, ok: 'اتجهزت المسودة ✅');
    if (!mounted) return;
    JphUi.toast(context, r);
    await _load();
    if (r['success'] == true && r['batch'] is Map && mounted) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => BatchDetailsPage(batchId: '${(r['batch'] as Map)['id']}')));
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final list = cashList(_r, 'batches');
    final can = ((_r['can'] as Map?) ?? const {});
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        if (can['prepare'] == true) cashBigButton(isDark, 'تجهيز مرتبات شهر', Icons.add_task_rounded, _create),
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && list.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش دفعات لسه', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final b in list)
          GestureDetector(
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => BatchDetailsPage(batchId: '${b['id']}')));
              _load();
            },
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(14),
              decoration: JphUi.box(isDark),
              child: Row(children: [
                JphUi.iconTile(isDark, Icons.payments_rounded, Colors.teal),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('مرتبات ${JphUi.monthAr('${b['month']}')} • #${b['refNo']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text('${b['employees']} موظف • جهّزها ${b['preparedByName']}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(JphUi.money(b['total']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  const SizedBox(height: 4),
                  JphUi.chip((_batchStatus[b['status']] ?? ('${b['status']}', Colors.grey)).$1, (_batchStatus[b['status']] ?? ('', Colors.grey)).$2),
                ]),
              ]),
            ),
          ),
      ]),
    );
  }
}

class BatchDetailsPage extends StatefulWidget {
  final String batchId;
  const BatchDetailsPage({super.key, required this.batchId});

  @override
  State<BatchDetailsPage> createState() => _BatchDetailsPageState();
}

class _BatchDetailsPageState extends State<BatchDetailsPage> {
  Map<String, dynamic> _r = {};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await cashGet('/payroll-batches/${widget.batchId}');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _r = r;
    });
  }

  Future<void> _act(String path, Map<String, dynamic> body, String ok) async {
    setState(() => _busy = true);
    final r = await cashPost('/payroll-batches/${widget.batchId}/$path', body, ok: ok);
    if (!mounted) return;
    setState(() => _busy = false);
    JphUi.toast(context, r);
    if (r['success'] == true) {
      setState(() => _r = r);
    }
  }

  Future<void> _return() async {
    final isDark = Provider.of<AppController>(context, listen: false).isDark;
    final reason = TextEditingController();
    await cashFormSheet(context, isDark, 'رجّع الدفعة للمراجعة', (s) => [JphUi.input(isDark: isDark, label: 'السبب', controller: reason, big: false)],
        () => cashPost('/payroll-batches/${widget.batchId}/decision', {'decision': 'return', 'reason': reason.text.trim()}, ok: 'اترجعت'));
    _load();
  }

  Future<void> _pay(Map<String, dynamic> l) async {
    final isDark = Provider.of<AppController>(context, listen: false).isDark;
    String method = 'cash';
    final amount = TextEditingController(text: '${l['remaining']}');
    await cashFormSheet(context, isDark, 'صرف مرتب ${l['employeeName']}', (s) => [
          Text('بيتصرف من خزينة HR، والموظف بيأكد الاستلام من التطبيق.', style: TextStyle(color: JphUi.sub(isDark))),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'المبلغ (الباقي ${JphUi.money(l['remaining'])})', controller: amount, number: true, suffix: 'جنيه'),
          const SizedBox(height: 10),
          cashSegmented(isDark, const {'cash': 'كاش', 'bank_transfer': 'تحويل بنكي', 'wallet': 'محفظة', 'cheque': 'شيك'}, method, (v) => s(() => method = v)),
        ], () => cashPost('/payroll-batches/${widget.batchId}/lines/${l['id']}/pay', {'amount': num.tryParse(amount.text.trim()), 'method': method}, ok: 'اتصرف ✅'));
    _load();
  }

  void _details(Map<String, dynamic> l) {
    final isDark = Provider.of<AppController>(context, listen: false).isDark;
    final s = ((l['snapshot'] as Map?) ?? const {}).cast<String, dynamic>();
    num v(String k) => (s[k] as num?) ?? 0;
    num sub(String k) => ((s[k] as Map?)?['amount'] as num?) ?? 0;
    final rows = <(String, String)>[
      ('المرتب الأساسي', JphUi.money(s['baseSalary'])),
      ('مرتب أيام الحضور', JphUi.money(s['attendanceSalary'])),
      ('خصم التأخير (${((s['late'] as Map?)?['days']) ?? 0} يوم)', JphUi.money(sub('late'))),
      ('خصم الانصراف بدري', JphUi.money(sub('early'))),
      ('خصم الغياب (${((s['absence'] as Map?)?['days']) ?? 0} يوم)', JphUi.money(sub('absence'))),
      ('إجازة بدون مرتب (${((s['unpaid'] as Map?)?['days']) ?? 0} يوم)', JphUi.money(sub('unpaid'))),
      ('خصومات إدارية', JphUi.money(v('adminDeductions'))),
      ('سلف مخصومة', JphUi.money(v('advances'))),
      ('عمولات معتمدة', JphUi.money(v('commissions'))),
      ('مكافآت', JphUi.money(v('bonuses'))),
      ('مصاريف عمل', JphUi.money(v('workExpenses'))),
      ('صافي المستحق', JphUi.money(l['net'])),
    ];
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          decoration: BoxDecoration(color: isDark ? const Color(0xFF1E1E1E) : Colors.white, borderRadius: const BorderRadius.vertical(top: Radius.circular(26))),
          child: ListView(shrinkWrap: true, children: [
            Text('تفاصيل حساب ${l['employeeName']}', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            const SizedBox(height: 10),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Expanded(child: Text(r.$1, style: TextStyle(color: JphUi.sub(isDark), fontWeight: FontWeight.w600))),
                  Text(r.$2, style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                ]),
              ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      final isRTL = app.isRTL;
      final b = ((_r['batch'] as Map?) ?? const {}).cast<String, dynamic>();
      final can = ((_r['can'] as Map?) ?? const {});
      final lines = cashList(_r, 'lines');
      return AppBackground(
        child: Directionality(
          textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                JphUi.header(context, isDark: isDark, isRTL: isRTL, title: b.isEmpty ? 'الدفعة' : 'مرتبات ${JphUi.monthAr('${b['month']}')}'),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
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
                                      Expanded(child: Text('دفعة #${b['refNo']} • ${b['employees']} موظف', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                                      JphUi.chip((_batchStatus[b['status']] ?? ('${b['status']}', Colors.grey)).$1, (_batchStatus[b['status']] ?? ('', Colors.grey)).$2),
                                    ]),
                                    const SizedBox(height: 10),
                                    Row(children: [
                                      Expanded(child: JphUi.stat(isDark, 'إجمالي الصافي', JphUi.money(b['total']), Icons.summarize_rounded, Colors.indigo)),
                                      const SizedBox(width: 10),
                                      Expanded(child: JphUi.stat(isDark, 'اتصرف', JphUi.money(b['paid']), Icons.check_circle_rounded, Colors.green)),
                                    ]),
                                    if ('${b['returnReason'] ?? ''}'.isNotEmpty)
                                      Padding(padding: const EdgeInsets.only(top: 8), child: Text('سبب الإرجاع: ${b['returnReason']}', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w700))),
                                    const SizedBox(height: 8),
                                    Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 6, children: [
                                      if (can['refresh'] == true)
                                        OutlinedButton.icon(onPressed: _busy ? null : () => _act('refresh', {}, 'اتحسبت من جديد ✅'),
                                            icon: const Icon(Icons.refresh_rounded), label: const Text('إعادة الحساب')),
                                      if (can['submit'] == true)
                                        ElevatedButton.icon(onPressed: _busy ? null : () => _act('submit', {}, 'اتبعتت للموافقة ✅'), icon: const Icon(Icons.send_rounded),
                                            label: const Text('إرسال للموافقة'), style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white)),
                                      if (can['decide'] == true) ...[
                                        TextButton(onPressed: _busy ? null : _return, child: const Text('رجّعها', style: TextStyle(color: Colors.red))),
                                        ElevatedButton.icon(onPressed: _busy ? null : () => _act('decision', {'decision': 'approve'}, 'اتوافق ✅'), icon: const Icon(Icons.verified_rounded),
                                            label: const Text('موافقة'), style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white)),
                                      ],
                                      if (can['cancel'] == true)
                                        TextButton(onPressed: _busy ? null : () => _act('cancel', {}, 'اتلغت'), child: const Text('إلغاء المسودة')),
                                    ]),
                                  ]),
                                ),
                                const SizedBox(height: 14),
                                for (final l in lines)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 10),
                                    padding: const EdgeInsets.all(14),
                                    decoration: JphUi.box(isDark),
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                                      Row(children: [
                                        JphUi.iconTile(isDark, Icons.person_rounded, Colors.teal),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                            Text('${l['employeeName']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                                            Text('صافي ${JphUi.money(l['net'])} • اتصرف ${JphUi.money(l['paid'])}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                                          ]),
                                        ),
                                        JphUi.chip((_lineStatusAr[l['status']] ?? ('${l['status']}', Colors.grey)).$1, (_lineStatusAr[l['status']] ?? ('', Colors.grey)).$2),
                                      ]),
                                      Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
                                        TextButton.icon(onPressed: () => _details(l), icon: const Icon(Icons.receipt_long_rounded), label: const Text('تفاصيل الحساب')),
                                        if (can['pay'] == true && ((l['remaining'] as num?) ?? 0) > 0)
                                          ElevatedButton.icon(onPressed: () => _pay(l), icon: const Icon(Icons.payments_rounded), label: const Text('صرف'),
                                              style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white)),
                                      ]),
                                      for (final p in ((l['payments'] as List?) ?? const []).whereType<Map>())
                                        Text('• ${JphUi.money(p['amount'])} — ${p['status'] == 'received' ? 'اتأكد الاستلام' : p['status'] == 'disputed' ? 'بلاغ: ${p['disputeReason'] ?? ''}' : 'مستني التأكيد'}',
                                            style: TextStyle(fontSize: 12, color: p['status'] == 'disputed' ? Colors.red : JphUi.sub(isDark))),
                                    ]),
                                  ),
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

// ==================================================================== خصم السلف
class _AdvancesTab extends StatefulWidget {
  final bool isDark;
  const _AdvancesTab({required this.isDark});

  @override
  State<_AdvancesTab> createState() => _AdvancesTabState();
}

class _AdvancesTabState extends State<_AdvancesTab> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await cashGet('/advances/open');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = cashList(r, 'advances');
    });
  }

  Future<void> _add(Map<String, dynamic> a) async {
    final isDark = widget.isDark;
    final now = DateTime.now();
    String month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    final left = a['mode'] == 'manual' ? a['remaining'] : a['amount'];
    final amount = TextEditingController(text: '$left');
    final months = {for (var i = -1; i <= 3; i++) (() {
      final d = DateTime(now.year, now.month + i);
      return '${d.year}-${d.month.toString().padLeft(2, '0')}';
    })(): ''};
    await cashFormSheet(context, isDark, 'خصم من سلفة ${a['employeeName']}', (s) => [
          Text('بتحدد المبلغ اللي يتخصم والشهر. السلفة بتتخصم على مرحلتين بالكتير.', style: TextStyle(color: JphUi.sub(isDark))),
          const SizedBox(height: 10),
          cashSegmented(isDark, {for (final m in months.keys) m: JphUi.monthAr(m)}, month, (v) => s(() => month = v)),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'المبلغ', controller: amount, number: true, suffix: 'جنيه'),
        ], () => cashPost('/advances/${a['id']}/deductions', {'month': month, 'amount': num.tryParse(amount.text.trim())}, ok: 'اتسجل الخصم ✅'));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final canSet = ApiService.can('payroll.prepare');
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _items.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش سلف معتمدة', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final a in _items)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: JphUi.box(isDark),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                JphUi.iconTile(isDark, Icons.account_balance_wallet_rounded, Colors.orange),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${a['employeeName']} • سلفة ${JphUi.monthAr('${a['month']}')}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text(a['mode'] == 'manual' ? 'الباقي: ${JphUi.money(a['remaining'])}' : 'من غير جدول: بتتخصم كلها من مرتب شهرها',
                        style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                  ]),
                ),
                Text(JphUi.money(a['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
              ]),
              for (final d in ((a['deductions'] as List?) ?? const []).whereType<Map>())
                Row(children: [
                  Expanded(child: Text('• ${JphUi.monthAr('${d['month']}')}: ${JphUi.money(d['amount'])}${d['status'] == 'cancelled' ? ' (ملغي)' : ''}',
                      style: TextStyle(color: JphUi.sub(isDark)))),
                  if (canSet && d['status'] == 'active')
                    TextButton(
                      onPressed: () async {
                        final r = await cashPost('/advances/deductions/${d['id']}/cancel', {}, ok: 'اتلغى الخصم');
                        if (context.mounted) JphUi.toast(context, r);
                        _load();
                      },
                      child: const Text('إلغاء', style: TextStyle(color: Colors.red)),
                    ),
                ]),
              if (canSet && (a['mode'] != 'manual' || ((a['remaining'] as num?) ?? 0) > 0))
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(onPressed: () => _add(a), icon: const Icon(Icons.add_rounded), label: const Text('تحديد خصم')),
                ),
            ]),
          ),
      ]),
    );
  }
}
