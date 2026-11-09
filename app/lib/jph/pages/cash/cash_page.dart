import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/jph_form_ui.dart';

/// الخزينة — the office cashbox (المدير / owner only) and the HR cashbox.
/// Tabs by permission: الأرصدة • الحركات • التحويلات • المصروفات • التحصيلات.
/// Everything shown comes from the API already filtered by role (HR never receives office data).
class CashPage extends StatefulWidget {
  const CashPage({super.key});

  @override
  State<CashPage> createState() => _CashPageState();
}

String newClientRef() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

const _boxAr = {'office': 'خزينة المكتب', 'hr': 'خزينة HR'};
const _receiptKinds = {
  'reservation': 'مبلغ حجز',
  'down_payment': 'مقدم وحدة',
  'installment': 'قسط',
  'settlement': 'تسوية',
  'other': 'تحصيل آخر',
};
const _methods = {'cash': 'كاش', 'bank_transfer': 'تحويل بنكي', 'cheque': 'شيك', 'card': 'كارت', 'wallet': 'محفظة'};
const _ledgerAr = {
  'opening': 'رصيد افتتاحي', 'adjustment': 'تسوية جرد', 'receipt': 'تحصيل', 'receipt_reversal': 'عكس تحصيل',
  'expense': 'مصروف', 'expense_reversal': 'عكس مصروف', 'transfer_in': 'تحويل وارد', 'transfer_out': 'تحويل صادر',
  'fund_in': 'صرف أموال من المدير', 'fund_out': 'صرف أموال لـ HR', 'payout_salary': 'صرف قبض', 'payout_advance': 'صرف سلفة',
  'payout_commission': 'صرف عمولة', 'payout_work_expense': 'صرف مصاريف عمل',
};

Future<Map<String, dynamic>> _get(String path, [Map<String, dynamic> query = const {}]) =>
    ApiService.post({'action': 'cash_get', 'path': path, 'query': query});
Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, {String? ok, bool patch = false}) =>
    ApiService.post({'action': 'cash_post', 'path': path, 'body': body, 'ok': ok, if (patch) 'method': 'patch'});

List<Map<String, dynamic>> _list(Map<String, dynamic> r, String k) =>
    ((r[k] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

class _CashPageState extends State<CashPage> {
  Map<String, dynamic> _summary = {};
  bool _loading = true;
  String _tab = 'summary';

  Map<String, dynamic> get _can => ((_summary['can'] as Map?) ?? const {}).cast<String, dynamic>();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/cash/summary');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _summary = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      final isRTL = app.isRTL;
      final tabs = <(String, String, IconData)>[
        ('summary', 'الأرصدة', Icons.account_balance_wallet_rounded),
        ('ledger', 'الحركات', Icons.receipt_long_rounded),
        ('transfers', 'التحويلات', Icons.swap_horiz_rounded),
        ('expenses', 'المصروفات', Icons.shopping_bag_rounded),
        ('receipts', 'التحصيلات', Icons.call_received_rounded),
      ];
      return AppBackground(
        child: Directionality(
          textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                JphUi.header(context, isDark: isDark, isRTL: isRTL, title: 'الخزينة',
                    action: IconButton(icon: Icon(Icons.refresh_rounded, color: JphUi.primary(isDark)), onPressed: _load)),
                SizedBox(
                  height: 46,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    children: [
                      for (final t in tabs)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(end: 8),
                          child: ChoiceChip(
                            selected: _tab == t.$1,
                            onSelected: (_) => setState(() => _tab = t.$1),
                            avatar: Icon(t.$3, size: 18, color: _tab == t.$1 ? Colors.white : JphUi.primary(isDark)),
                            label: Text(t.$2, style: TextStyle(fontWeight: FontWeight.w800, color: _tab == t.$1 ? Colors.white : JphUi.text(isDark))),
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
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _summary['success'] != true
                          ? Center(child: Text('${_summary['message'] ?? 'مش متاح'}', style: TextStyle(color: JphUi.sub(isDark))))
                          : Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 1000),
                                child: switch (_tab) {
                                  'ledger' => _LedgerTab(isDark: isDark, can: _can),
                                  'transfers' => _TransfersTab(isDark: isDark, can: _can, onChanged: _load),
                                  'expenses' => _ExpensesTab(isDark: isDark, can: _can, threshold: _summary['expenseApprovalThreshold'], onChanged: _load),
                                  'receipts' => _ReceiptsTab(isDark: isDark, can: _can, onChanged: _load),
                                  _ => _SummaryTab(isDark: isDark, summary: _summary, onChanged: _load),
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

// ==================================================================== الأرصدة
class _SummaryTab extends StatelessWidget {
  final bool isDark;
  final Map<String, dynamic> summary;
  final Future<void> Function() onChanged;
  const _SummaryTab({required this.isDark, required this.summary, required this.onChanged});

  Widget _box(BuildContext context, String key, Map<String, dynamic> b) {
    final bal = (b['bookBalance'] as num?) ?? 0;
    final neg = bal < 0;
    final inT = ((b['incomingTransfers'] as Map?) ?? const {});
    final outT = ((b['outgoingTransfers'] as Map?) ?? const {});
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          JphUi.iconTile(isDark, key == 'office' ? Icons.account_balance_rounded : Icons.badge_rounded, key == 'office' ? Colors.indigo : Colors.teal),
          const SizedBox(width: 12),
          Expanded(child: Text(_boxAr[key]!, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
        ]),
        const SizedBox(height: 10),
        Text('الرصيد الدفتري', style: TextStyle(color: JphUi.sub(isDark), fontWeight: FontWeight.w600)),
        Text(JphUi.money(bal), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: neg ? Colors.red : JphUi.text(isDark))),
        if (key == 'hr' && ((b['deficit'] as num?) ?? 0) > 0)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(12)),
            child: Text('عجز: مطلوب تحويل ${JphUi.money(b['deficit'])} من خزينة المكتب لتغطيته. الرصيد السالب مش فلوس موجودة — ده مبلغ مستحق بين الخزنتين.',
                style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w700)),
          ),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 6, children: [
          if (((inT['count'] as num?) ?? 0) > 0) JphUi.chip('وارد في الطريق: ${JphUi.money(inT['amount'])}', Colors.blue),
          if (((outT['count'] as num?) ?? 0) > 0) JphUi.chip('صادر في الطريق: ${JphUi.money(outT['amount'])}', Colors.orange),
          if (key == 'hr' && (((b['expensesAwaitingApproval'] as Map?)?['count'] as num?) ?? 0) > 0)
            JphUi.chip('مصروفات مستنية موافقة: ${JphUi.money((b['expensesAwaitingApproval'] as Map)['amount'])}', Colors.purple),
        ]),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final can = ((summary['can'] as Map?) ?? const {}).cast<String, dynamic>();
    return RefreshIndicator(
      onRefresh: onChanged,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        if (summary['office'] is Map) _box(context, 'office', (summary['office'] as Map).cast<String, dynamic>()),
        if (summary['hr'] is Map) _box(context, 'hr', (summary['hr'] as Map).cast<String, dynamic>()),
        if (summary['total'] != null)
          JphUi.stat(isDark, 'إجمالي الفلوس في الخزنتين', JphUi.money(summary['total']), Icons.savings_rounded, Colors.green),
        if (can['settings'] == true) ...[
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () => _adjustSheet(context, isDark, onChanged),
            icon: const Icon(Icons.tune_rounded),
            label: const Text('رصيد افتتاحي / تسوية جرد'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _thresholdSheet(context, isDark, summary['expenseApprovalThreshold'], onChanged),
            icon: const Icon(Icons.rule_rounded),
            label: Text('حد موافقة المصروفات: ${JphUi.money(summary['expenseApprovalThreshold'])}'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          ),
        ],
      ]),
    );
  }
}

Future<void> _adjustSheet(BuildContext context, bool isDark, Future<void> Function() done) async {
  String box = 'office', kind = 'opening';
  final amount = TextEditingController(), reason = TextEditingController(), counted = TextEditingController();
  await _formSheet(context, isDark, 'رصيد افتتاحي / تسوية جرد', (setS) => [
        _segmented(isDark, {'office': 'خزينة المكتب', 'hr': 'خزينة HR'}, box, (v) => setS(() => box = v)),
        const SizedBox(height: 10),
        _segmented(isDark, {'opening': 'رصيد افتتاحي', 'adjustment': 'تسوية جرد'}, kind, (v) => setS(() => kind = v)),
        const SizedBox(height: 10),
        JphUi.input(isDark: isDark, label: kind == 'opening' ? 'المبلغ' : 'الفرق (+ زيادة / − عجز)', controller: amount, number: true, suffix: 'جنيه'),
        if (kind == 'adjustment') ...[
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'الكاش اللي اتعد فعلاً (اختياري)', controller: counted, number: true, suffix: 'جنيه', big: false),
        ],
        const SizedBox(height: 10),
        JphUi.input(isDark: isDark, label: 'السبب', controller: reason, big: false),
      ], () async {
    final r = await _post('/cash/adjustments', {
      'cashbox': box, 'kind': kind, 'amount': num.tryParse(amount.text.trim()), 'reason': reason.text.trim(),
      if (counted.text.trim().isNotEmpty) 'countedCash': num.tryParse(counted.text.trim()),
    }, ok: 'اتسجل ✅');
    return r;
  });
  await done();
}

Future<void> _thresholdSheet(BuildContext context, bool isDark, Object? current, Future<void> Function() done) async {
  final c = TextEditingController(text: '${current ?? ''}');
  await _formSheet(context, isDark, 'حد موافقة المصروفات', (setS) => [
        Text('أي مصروف من خزينة HR أكبر من المبلغ ده يستنى موافقة المدير الأول.', style: TextStyle(color: JphUi.sub(isDark))),
        const SizedBox(height: 10),
        JphUi.input(isDark: isDark, label: 'المبلغ', controller: c, number: true, suffix: 'جنيه'),
      ], () => _post('/cash/settings', {'expenseApprovalThreshold': num.tryParse(c.text.trim())}, ok: 'اتحفظ ✅', patch: true));
  await done();
}

Widget _segmented(bool isDark, Map<String, String> options, String value, ValueChanged<String> onChanged) {
  return Wrap(spacing: 8, runSpacing: 8, children: [
    for (final e in options.entries)
      ChoiceChip(
        selected: value == e.key,
        onSelected: (_) => onChanged(e.key),
        label: Text(e.value, style: TextStyle(fontWeight: FontWeight.w800, color: value == e.key ? Colors.white : JphUi.text(isDark))),
        selectedColor: JphUi.primary(isDark),
        backgroundColor: isDark ? Colors.white.withOpacity(0.12) : Colors.grey.shade100,
        showCheckmark: false,
      ),
  ]);
}

/// A bottom-sheet form in the app style; [submit] returns the API result (sheet closes on success).
Future<void> _formSheet(BuildContext context, bool isDark, String title, List<Widget> Function(StateSetter setS) fields,
    Future<Map<String, dynamic>> Function() submit) {
  bool saving = false;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
      return Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.92),
          padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + MediaQuery.of(ctx).viewInsets.bottom),
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          ),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Center(child: Container(width: 44, height: 5, decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(4)))),
              const SizedBox(height: 12),
              Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
              const SizedBox(height: 14),
              ...fields(setS),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: saving
                    ? null
                    : () async {
                        setS(() => saving = true);
                        final r = await submit();
                        setS(() => saving = false);
                        if (!ctx.mounted) return;
                        JphUi.toast(ctx, r);
                        if (r['success'] == true) Navigator.pop(ctx);
                      },
                style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 54), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
                child: saving
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('حفظ', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
              ),
            ]),
          ),
        ),
      );
    }),
  );
}

// ==================================================================== الحركات
class _LedgerTab extends StatefulWidget {
  final bool isDark;
  final Map<String, dynamic> can;
  const _LedgerTab({required this.isDark, required this.can});

  @override
  State<_LedgerTab> createState() => _LedgerTabState();
}

class _LedgerTabState extends State<_LedgerTab> {
  late String _box = widget.can['office'] == true ? 'office' : 'hr';
  Map<String, dynamic> _r = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await _get('/cash/ledger', {'cashbox': _box});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _r = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final entries = _list(_r, 'entries');
    final totals = ((_r['totals'] as Map?) ?? const {});
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        if (widget.can['office'] == true)
          _segmented(isDark, {'office': 'خزينة المكتب', 'hr': 'خزينة HR'}, _box, (v) {
            _box = v;
            _load();
          }),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: JphUi.stat(isDark, 'إجمالي الوارد', JphUi.money(totals['in']), Icons.south_west_rounded, Colors.green)),
          const SizedBox(width: 10),
          Expanded(child: JphUi.stat(isDark, 'إجمالي الصادر', JphUi.money(totals['out']), Icons.north_east_rounded, Colors.red)),
        ]),
        const SizedBox(height: 12),
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && entries.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش حركات', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final e in entries)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: JphUi.box(isDark),
            child: Row(children: [
              Icon(((e['amount'] as num?) ?? 0) >= 0 ? Icons.add_circle_rounded : Icons.remove_circle_rounded,
                  color: ((e['amount'] as num?) ?? 0) >= 0 ? Colors.green : Colors.red),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${_ledgerAr[e['type']] ?? e['type']}${e['refNo'] != null ? ' #${e['refNo']}' : ''}',
                      style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                  Text('${e['label'] ?? ''} • ${e['byName'] ?? ''} • ${JphUi.date(e['at'])}',
                      style: TextStyle(fontSize: 12, color: JphUi.sub(isDark)), maxLines: 2, overflow: TextOverflow.ellipsis),
                ]),
              ),
              Text(JphUi.money(e['amount']), style: TextStyle(fontWeight: FontWeight.w900,
                  color: ((e['amount'] as num?) ?? 0) >= 0 ? Colors.green : Colors.red)),
            ]),
          ),
      ]),
    );
  }
}

// ==================================================================== التحويلات
const _trStatus = {
  'requested': ('مطلوب', Colors.orange), 'approved': ('اتوافق — مستني التسليم', Colors.blue),
  'executed': ('اتسلّم — مستني تأكيد الاستلام', Colors.teal), 'received': ('تم', Colors.green),
  'rejected': ('مرفوض', Colors.red), 'cancelled': ('ملغي', Colors.grey),
};

class _TransfersTab extends StatefulWidget {
  final bool isDark;
  final Map<String, dynamic> can;
  final Future<void> Function() onChanged;
  const _TransfersTab({required this.isDark, required this.can, required this.onChanged});

  @override
  State<_TransfersTab> createState() => _TransfersTabState();
}

class _TransfersTabState extends State<_TransfersTab> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/cash/transfers');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = _list(r, 'transfers');
    });
  }

  Future<void> _act(String path, Map<String, dynamic> body, String ok) async {
    final r = await _post(path, body, ok: ok);
    if (!mounted) return;
    JphUi.toast(context, r);
    await _load();
    await widget.onChanged();
  }

  Future<void> _request(String direction) async {
    final amount = TextEditingController(), reason = TextEditingController();
    await _formSheet(context, widget.isDark, direction == 'office_to_hr' ? 'طلب تحويل من خزينة المكتب' : 'طلب توريد من خزينة HR', (s) => [
          JphUi.input(isDark: widget.isDark, label: 'المبلغ', controller: amount, number: true, suffix: 'جنيه'),
          const SizedBox(height: 10),
          JphUi.input(isDark: widget.isDark, label: 'السبب', controller: reason, big: false),
        ], () => _post('/cash/transfers', {'direction': direction, 'amount': num.tryParse(amount.text.trim()), 'reason': reason.text.trim()}, ok: 'اتبعت الطلب ✅'));
    await _load();
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        if (widget.can['hrOperate'] == true)
          _bigButton(isDark, 'طلب تحويل من خزينة المكتب لـ HR', Icons.call_received_rounded, () => _request('office_to_hr')),
        if (widget.can['office'] == true)
          _bigButton(isDark, 'طلب توريد من خزينة HR للمكتب', Icons.call_made_rounded, () => _request('hr_to_office')),
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _items.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش تحويلات', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final t in _items) _card(t),
      ]),
    );
  }

  Widget _card(Map<String, dynamic> t) {
    final isDark = widget.isDark;
    final can = ((t['can'] as Map?) ?? const {});
    final st = _trStatus[t['status']] ?? ('${t['status']}', Colors.grey);
    final toHr = t['direction'] == 'office_to_hr';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          JphUi.iconTile(isDark, toHr ? Icons.call_received_rounded : Icons.call_made_rounded, toHr ? Colors.teal : Colors.indigo),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${toHr ? 'المكتب ← HR' : 'HR ← المكتب'} • #${t['refNo']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
              Text('${t['reason']} • ${t['requestedByName']} • ${JphUi.date(t['requestedAt'])}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
            ]),
          ),
          Text(JphUi.money(t['amountExecuted'] ?? t['amountRequested']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 6, children: [
          JphUi.chip(st.$1, st.$2),
          if (t['executedByName'] != null) JphUi.chip('سلّمها: ${t['executedByName']}', Colors.blueGrey),
          if (t['receivedByName'] != null) JphUi.chip('استلمها: ${t['receivedByName']}', Colors.green),
          if ('${t['rejectReason'] ?? ''}'.isNotEmpty) JphUi.chip('السبب: ${t['rejectReason']}', Colors.red),
        ]),
        Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
          if (can['decide'] == true) ...[
            TextButton(onPressed: () => _reject(t), child: const Text('رفض', style: TextStyle(color: Colors.red))),
            ElevatedButton(onPressed: () => _act('/cash/transfers/${t['id']}/decision', {'decision': 'approve'}, 'اتوافق ✅'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white), child: const Text('موافقة')),
          ],
          if (can['execute'] == true)
            ElevatedButton(onPressed: () => _execute(t), style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
                child: const Text('تسليم الفلوس')),
          if (can['receive'] == true)
            ElevatedButton(onPressed: () => _act('/cash/transfers/${t['id']}/receive', {}, 'تم تأكيد الاستلام ✅'),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white), child: const Text('تم الاستلام')),
          if (can['cancel'] == true)
            TextButton(onPressed: () => _act('/cash/transfers/${t['id']}/cancel', {}, 'اتلغى'), child: const Text('إلغاء')),
        ]),
      ]),
    );
  }

  Future<void> _reject(Map<String, dynamic> t) async {
    final reason = TextEditingController();
    await _formSheet(context, widget.isDark, 'سبب الرفض', (s) => [JphUi.input(isDark: widget.isDark, label: 'السبب', controller: reason, big: false)],
        () => _post('/cash/transfers/${t['id']}/decision', {'decision': 'reject', 'reason': reason.text.trim()}, ok: 'اترفض'));
    await _load();
  }

  Future<void> _execute(Map<String, dynamic> t) async {
    final amount = TextEditingController(text: JphUi.money(t['amountRequested']).replaceAll(RegExp(r'[^0-9.]'), ''));
    await _formSheet(context, widget.isDark, 'تسليم الفلوس', (s) => [
          Text('اكتب المبلغ اللي اتسلّم فعلاً. الأرصدة مش هتتحرك غير لما الطرف التاني يأكد الاستلام.', style: TextStyle(color: JphUi.sub(widget.isDark))),
          const SizedBox(height: 10),
          JphUi.input(isDark: widget.isDark, label: 'المبلغ المسلَّم', controller: amount, number: true, suffix: 'جنيه'),
        ], () => _post('/cash/transfers/${t['id']}/execute', {'amount': num.tryParse(amount.text.trim())}, ok: 'اتسجل التسليم ✅'));
    await _load();
    await widget.onChanged();
  }
}

Widget _bigButton(bool isDark, String label, IconData icon, VoidCallback onTap) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
      ),
    );

// ==================================================================== المصروفات
const _expStatus = {
  'posted': ('اتصرف', Colors.green), 'pending_approval': ('مستني موافقة المدير', Colors.orange),
  'rejected': ('مرفوض', Colors.red), 'reversed': ('اتعكس', Colors.grey),
};

class _ExpensesTab extends StatefulWidget {
  final bool isDark;
  final Map<String, dynamic> can;
  final Object? threshold;
  final Future<void> Function() onChanged;
  const _ExpensesTab({required this.isDark, required this.can, required this.threshold, required this.onChanged});

  @override
  State<_ExpensesTab> createState() => _ExpensesTabState();
}

class _ExpensesTabState extends State<_ExpensesTab> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/cash/expenses');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = _list(r, 'expenses');
    });
  }

  Future<void> _add() async {
    final isDark = widget.isDark;
    String box = widget.can['hrOperate'] == true ? 'hr' : 'office';
    final amount = TextEditingController(), category = TextEditingController(), reason = TextEditingController(),
        beneficiary = TextEditingController(), notes = TextEditingController();
    final ref = newClientRef();
    await _formSheet(context, isDark, 'تسجيل مصروف', (s) => [
          if (widget.can['office'] == true && widget.can['hrOperate'] == true)
            _segmented(isDark, {'hr': 'خزينة HR', 'office': 'خزينة المكتب'}, box, (v) => s(() => box = v)),
          if (widget.can['office'] == true && widget.can['hrOperate'] != true) Text('من خزينة المكتب', style: TextStyle(color: JphUi.sub(isDark))),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'المبلغ', controller: amount, number: true, suffix: 'جنيه'),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'البند (إيجار، كهرباء، ضيافة...)', controller: category, big: false),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'سبب الصرف', controller: reason, big: false),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'المستفيد', controller: beneficiary, big: false),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'ملاحظات (اختياري)', controller: notes, big: false),
          if (box == 'hr' && widget.can['office'] != true)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('المصروف أكبر من ${JphUi.money(widget.threshold)} بيستنى موافقة المدير قبل ما يتخصم.', style: TextStyle(color: JphUi.sub(isDark))),
            ),
        ], () => _post('/cash/expenses', {
          'cashbox': box, 'amount': num.tryParse(amount.text.trim()), 'category': category.text.trim(), 'reason': reason.text.trim(),
          'beneficiary': beneficiary.text.trim(), 'notes': notes.text.trim(), 'clientRef': ref,
        }, ok: 'اتسجل المصروف ✅'));
    await _load();
    await widget.onChanged();
  }

  Future<void> _act(String path, Map<String, dynamic> body, String ok) async {
    final r = await _post(path, body, ok: ok);
    if (!mounted) return;
    JphUi.toast(context, r);
    await _load();
    await widget.onChanged();
  }

  Future<void> _withReason(String title, String path, Map<String, dynamic> body, String ok) async {
    final reason = TextEditingController();
    await _formSheet(context, widget.isDark, title, (s) => [JphUi.input(isDark: widget.isDark, label: 'السبب', controller: reason, big: false)],
        () => _post(path, {...body, 'reason': reason.text.trim()}, ok: ok));
    await _load();
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final office = widget.can['office'] == true;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        if (widget.can['hrOperate'] == true || office) _bigButton(isDark, 'تسجيل مصروف', Icons.add_rounded, _add),
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _items.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش مصروفات', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final x in _items)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: JphUi.box(isDark),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                JphUi.iconTile(isDark, Icons.shopping_bag_rounded, Colors.deepOrange),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${x['category']} • #${x['refNo']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text('${x['reason']} • ${x['beneficiary']}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                    Text('${_boxAr[x['cashbox']]} • ${x['recordedByName']} • ${JphUi.date(x['occurredAt'])}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                  ]),
                ),
                Text(JphUi.money(x['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 6, children: [
                JphUi.chip((_expStatus[x['status']] ?? ('${x['status']}', Colors.grey)).$1, (_expStatus[x['status']] ?? ('', Colors.grey)).$2),
                if (x['reviewedAt'] != null) JphUi.chip('اتراجع: ${x['reviewedByName'] ?? ''}', Colors.blueGrey),
                if ('${x['rejectReason'] ?? ''}'.isNotEmpty) JphUi.chip('السبب: ${x['rejectReason']}', Colors.red),
                if ('${x['reverseReason'] ?? ''}'.isNotEmpty) JphUi.chip('عكس: ${x['reverseReason']}', Colors.grey),
              ]),
              if (office)
                Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
                  if (x['status'] == 'pending_approval') ...[
                    TextButton(onPressed: () => _withReason('سبب الرفض', '/cash/expenses/${x['id']}/decision', {'decision': 'reject'}, 'اترفض'),
                        child: const Text('رفض', style: TextStyle(color: Colors.red))),
                    ElevatedButton(onPressed: () => _act('/cash/expenses/${x['id']}/decision', {'decision': 'approve'}, 'اتوافق ✅'),
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white), child: const Text('موافقة')),
                  ],
                  if (x['status'] == 'posted' && x['reviewedAt'] == null)
                    TextButton(onPressed: () => _act('/cash/expenses/${x['id']}/review', {}, 'اتراجع ✅'), child: const Text('تمت المراجعة')),
                  if (x['status'] == 'posted')
                    TextButton(onPressed: () => _withReason('عكس المصروف', '/cash/expenses/${x['id']}/reverse', {}, 'اتعكس'),
                        child: const Text('عكس', style: TextStyle(color: Colors.red))),
                ]),
            ]),
          ),
      ]),
    );
  }
}

// ==================================================================== التحصيلات
class _ReceiptsTab extends StatefulWidget {
  final bool isDark;
  final Map<String, dynamic> can;
  final Future<void> Function() onChanged;
  const _ReceiptsTab({required this.isDark, required this.can, required this.onChanged});

  @override
  State<_ReceiptsTab> createState() => _ReceiptsTabState();
}

class _ReceiptsTabState extends State<_ReceiptsTab> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/cash/receipts', {'q': _q.text.trim()});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = _list(r, 'receipts');
    });
  }

  Future<void> _add() async {
    final isDark = widget.isDark;
    String recipient = widget.can['hrOperate'] == true ? 'hr' : 'manager';
    String kind = 'reservation', method = 'cash';
    final amount = TextEditingController(), payer = TextEditingController(), phone = TextEditingController(),
        purpose = TextEditingController(), extNo = TextEditingController(), notes = TextEditingController();
    final ref = newClientRef();
    await _formSheet(context, isDark, 'تسجيل تحصيل', (s) => [
          Text('مين استلم الفلوس فعلاً؟', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
          const SizedBox(height: 6),
          _segmented(isDark, {
            if (widget.can['hrOperate'] == true) 'hr': 'HR (خزينة HR)',
            'manager': 'المدير بنفسه (خزينة المكتب)',
          }, recipient, (v) => s(() => recipient = v)),
          const SizedBox(height: 10),
          _segmented(isDark, _receiptKinds, kind, (v) => s(() => kind = v)),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'المبلغ', controller: amount, number: true, suffix: 'جنيه'),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'اسم الدافع', controller: payer, big: false),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'موبايل الدافع (اختياري)', controller: phone, big: false),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'الغرض (المشروع / الوحدة / التفاصيل)', controller: purpose, big: false),
          const SizedBox(height: 10),
          _segmented(isDark, _methods, method, (v) => s(() => method = v)),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'رقم الإيصال الورقي (اختياري)', controller: extNo, big: false),
          const SizedBox(height: 10),
          JphUi.input(isDark: isDark, label: 'ملاحظات (اختياري)', controller: notes, big: false),
        ], () async => _post('/cash/receipts', {
          'recipient': recipient, 'kind': kind, 'amount': num.tryParse(amount.text.trim()), 'payerName': payer.text.trim(),
          'payerPhone': phone.text.trim(), 'purpose': purpose.text.trim(), 'paymentMethod': method,
          if (extNo.text.trim().isNotEmpty) 'externalNo': extNo.text.trim(), 'notes': notes.text.trim(), 'clientRef': ref,
          if (recipient == 'manager' && widget.can['office'] != true) 'recipientId': await _pickManager(),
        }, ok: 'اتسجل التحصيل ✅'));
    await _load();
    await widget.onChanged();
  }

  /// HR typing in a collection the manager received: pick that manager.
  Future<String?> _pickManager() async {
    final r = await ApiService.post({'action': 'getActiveEmployees'});
    final people = ((r['employees'] as List?) ?? const []).whereType<Map>().toList();
    if (!mounted) return null;
    return JphUi.sheet<String>(context, widget.isDark, 'المدير اللي استلم',
        [for (final p in people) ('${p['id']}', '${p['name']}', Icons.person_rounded)]);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        _bigButton(isDark, 'تسجيل تحصيل (إيصال)', Icons.add_rounded, _add),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: JphUi.box(isDark),
          child: TextField(
            controller: _q,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(hintText: 'ابحث بالاسم أو رقم الإيصال', border: InputBorder.none,
                prefixIcon: Icon(Icons.search_rounded, color: JphUi.primary(isDark))),
          ),
        ),
        const SizedBox(height: 10),
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _items.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش تحصيلات', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final x in _items)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: JphUi.box(isDark),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                JphUi.iconTile(isDark, Icons.receipt_rounded, Colors.green),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${x['receiptNo']} • ${x['kindAr'] ?? x['kind']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text('${x['payerName']} • ${x['purpose']}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                    Text('استلمها: ${x['actualRecipientName']} • ${_boxAr[x['cashbox']]} • ${JphUi.date(x['occurredAt'])}',
                        style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                  ]),
                ),
                Text(JphUi.money(x['amount']), style: TextStyle(fontWeight: FontWeight.w900,
                    color: x['status'] == 'reversed' ? Colors.grey : Colors.green, decoration: x['status'] == 'reversed' ? TextDecoration.lineThrough : null)),
              ]),
              if (x['status'] == 'reversed')
                Padding(padding: const EdgeInsets.only(top: 6), child: JphUi.chip('اتعكس: ${x['reverseReason'] ?? ''}', Colors.grey)),
              if (widget.can['office'] == true && x['status'] == 'posted')
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    onPressed: () async {
                      final reason = TextEditingController();
                      await _formSheet(context, isDark, 'عكس التحصيل', (s) => [JphUi.input(isDark: isDark, label: 'السبب', controller: reason, big: false)],
                          () => _post('/cash/receipts/${x['id']}/reverse', {'reason': reason.text.trim()}, ok: 'اتعكس'));
                      await _load();
                      await widget.onChanged();
                    },
                    child: const Text('عكس', style: TextStyle(color: Colors.red)),
                  ),
                ),
            ]),
          ),
      ]),
    );
  }
}

// shared with the sales / installments pages
Future<Map<String, dynamic>> cashGet(String path, [Map<String, dynamic> query = const {}]) => _get(path, query);
Future<Map<String, dynamic>> cashPost(String path, Map<String, dynamic> body, {String? ok}) => _post(path, body, ok: ok);
List<Map<String, dynamic>> cashList(Map<String, dynamic> r, String k) => _list(r, k);
Future<void> cashFormSheet(BuildContext context, bool isDark, String title, List<Widget> Function(StateSetter setS) fields,
        Future<Map<String, dynamic>> Function() submit) =>
    _formSheet(context, isDark, title, fields, submit);
Widget cashSegmented(bool isDark, Map<String, String> options, String value, ValueChanged<String> onChanged) =>
    _segmented(isDark, options, value, onChanged);
Widget cashBigButton(bool isDark, String label, IconData icon, VoidCallback onTap) => _bigButton(isDark, label, icon, onTap);
