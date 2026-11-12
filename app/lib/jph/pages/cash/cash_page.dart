import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/jph_form_ui.dart';
import '../../forms/payment_voucher_pdf.dart';
import 'cash_overview.dart';

/// الخزينة — the office cashbox (المدير / owner only) and the HR cashbox.
/// Tabs by permission: الأرصدة • الحركات • التحويلات • المصروفات • التحصيلات.
/// Everything shown comes from the API already filtered by role (HR never receives office data).
class CashPage extends StatefulWidget {
  /// true = the "الخزنة" tab of the cashbox page: no own header, and the movements live in the "السجل" tab
  final bool embedded;
  /// the cashbox page's month filter (the figures of الأرصدة follow it)
  final ValueListenable<DateTime>? month;
  /// the hub's «كل الشهور» (true) for the cashbox tiles
  final ValueListenable<bool>? allMonths;
  const CashPage({super.key, this.embedded = false, this.month, this.allMonths});

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

const _boxAr = {'office': 'خزينة المكتب', 'hr': 'خزينة المحاسب'};
// فلوس المبيعات (حجز / تعاقد / أقساط) والعمولات بتدخل من «المبيعات» بزرار «تم الاستلام» — مش يدوي
const _receiptKinds = {
  'other': 'تحصيل آخر',
  'settlement': 'تسوية',
};
const _methods = {'cash': 'كاش', 'bank_transfer': 'تحويل بنكي', 'cheque': 'شيك', 'card': 'كارت', 'wallet': 'محفظة'};
const _ledgerAr = {
  'opening': 'رصيد افتتاحي', 'adjustment': 'تسوية جرد', 'receipt': 'تحصيل', 'receipt_reversal': 'عكس تحصيل',
  'expense': 'مصروف', 'expense_reversal': 'عكس مصروف', 'transfer_in': 'تحويل وارد', 'transfer_out': 'تحويل صادر',
  'fund_in': 'صرف أموال من المدير', 'fund_out': 'صرف أموال للمحاسب', 'payout_salary': 'صرف قبض', 'payout_advance': 'صرف سلفة',
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
        // ضخ أموال: المالك / المدير العام only
        if (_can['office'] == true) ('injections', 'ضخ أموال', Icons.add_card_rounded),
        if (!widget.embedded) ('ledger', 'الحركات', Icons.receipt_long_rounded),
        ('transfers', 'التحويلات', Icons.swap_horiz_rounded),
        ('expenses', 'المصروفات', Icons.shopping_bag_rounded),
        ('receipts', 'التحصيلات', Icons.call_received_rounded),
      ];
      final Widget body = _loading
          ? const Center(child: CircularProgressIndicator())
          : _summary['success'] != true
              ? Center(child: Text('${_summary['message'] ?? 'مش متاح'}', style: TextStyle(color: JphUi.sub(isDark))))
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: switch (_tab) {
                      'ledger' => CashLedgerView(isDark: isDark, can: _can),
                      'injections' => InjectionsTab(isDark: isDark, month: widget.month, allMonths: widget.allMonths, onChanged: _load),
                      'transfers' => _TransfersTab(isDark: isDark, can: _can, onChanged: _load),
                      'expenses' => _ExpensesTab(isDark: isDark, can: _can, threshold: _summary['expenseApprovalThreshold'], onChanged: _load),
                      'receipts' => _ReceiptsTab(isDark: isDark, can: _can, onChanged: _load),
                      _ => _SummaryTab(isDark: isDark, summary: _summary, onChanged: _load, month: widget.month, allMonths: widget.allMonths),
                    },
                  ),
                );
      if (widget.embedded) {
        return Column(children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: _segmented(isDark, {for (final t in tabs) t.$1: t.$2}, _tab, (v) => setState(() => _tab = v)),
          ),
          const SizedBox(height: 8),
          Expanded(child: body),
        ]);
      }
      return AppBackground(
        child: Directionality(
          textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                JphUi.header(context, isDark: isDark, isRTL: isRTL, title: 'الخزينة',
                    action: IconButton(icon: Icon(Icons.refresh_rounded, color: JphUi.primary(isDark)), onPressed: _load)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: _segmented(isDark, {for (final t in tabs) t.$1: t.$2}, _tab, (v) => setState(() => _tab = v)),
                ),
                const SizedBox(height: 8),
                Expanded(child: body),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

// ==================================================================== الأرصدة
String _ym(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

/// الأرصدة: الخزنتين + كل أرقام الشهر (كانت في لوحة المالية). كل مربع بيتفتح على تفاصيله.
class _SummaryTab extends StatefulWidget {
  final bool isDark;
  final Map<String, dynamic> summary;
  final Future<void> Function() onChanged;
  final ValueListenable<DateTime>? month;
  final ValueListenable<bool>? allMonths;
  const _SummaryTab({required this.isDark, required this.summary, required this.onChanged, this.month, this.allMonths});

  @override
  State<_SummaryTab> createState() => _SummaryTabState();
}

class _SummaryTabState extends State<_SummaryTab> {
  Map<String, dynamic> _d = {};
  bool _loading = true;

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
    setState(() => _loading = true);
    final r = await _get('/finance/dashboard', {'month': _ym(_month)});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _d = r;
    });
  }

  Future<void> _refresh() async {
    await widget.onChanged();
    await _load();
  }

  Widget _box(BuildContext context, String key, Map<String, dynamic> b) {
    final isDark = widget.isDark;
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

  /// tap a box → what is behind it
  Future<void> _details(String key, String title) async {
    final isDark = widget.isDark;
    final future = _get('/finance/dashboard/details', {'key': key, 'month': _ym(_month)});
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Container(
          margin: const EdgeInsets.all(16),
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: isDark ? const Color(0xFF1E1E1E) : Colors.white, borderRadius: BorderRadius.circular(26)),
          child: FutureBuilder<Map<String, dynamic>>(
            future: future,
            builder: (_, snap) {
              final r = snap.data ?? const {};
              final rows = _list(r, 'rows');
              return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Icon(Icons.filter_alt_rounded, color: JphUi.primary(isDark), size: 26),
                  Expanded(child: Text('$title — ${JphUi.monthsAr[_month.month - 1]}', textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                  GestureDetector(onTap: () => Navigator.pop(ctx), child: Icon(Icons.close_rounded, color: JphUi.sub(isDark), size: 26)),
                ]),
                const SizedBox(height: 12),
                if (snap.connectionState != ConnectionState.done)
                  const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()))
                else if (r['success'] == false)
                  Padding(padding: const EdgeInsets.all(20), child: Text('${r['message'] ?? 'مش متاح'}', textAlign: TextAlign.center))
                else ...[
                  JphUi.stat(isDark, 'الإجمالي (${rows.length})', JphUi.money(r['total']), Icons.summarize_rounded, Colors.indigo),
                  const SizedBox(height: 10),
                  if (rows.isEmpty)
                    Padding(padding: const EdgeInsets.all(20), child: Text('مفيش حاجة', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
                  Flexible(
                    child: ListView(shrinkWrap: true, children: [
                      for (final x in rows)
                        Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isDark ? Colors.white.withOpacity(0.08) : Colors.grey.shade50,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: isDark ? Colors.white24 : Colors.grey.shade300),
                          ),
                          child: Row(children: [
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('${x['title']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                                if ('${x['sub'] ?? ''}'.isNotEmpty) Text('${x['sub']}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                              ]),
                            ),
                            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                              Text(JphUi.money(x['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                              if ('${x['tag'] ?? ''}'.isNotEmpty) JphUi.chip('${x['tag']}', Colors.blueGrey),
                            ]),
                          ]),
                        ),
                    ]),
                  ),
                ],
              ]);
            },
          ),
        ),
      ),
    );
  }

  Widget _tile(String label, Object? value, IconData icon, Color color, String? key, {bool money = true}) {
    final box = JphUi.stat(widget.isDark, label, money ? JphUi.money(value) : '${value ?? 0}', icon, color);
    if (key == null) return box;
    return GestureDetector(onTap: () => _details(key, label), child: box);
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: JphUi.text(widget.isDark))),
      );

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final summary = widget.summary;
    final can = ((summary['can'] as Map?) ?? const {}).cast<String, dynamic>();
    final hr = ((_d['hr'] as Map?) ?? const {});
    final mg = _d['management'] as Map?;
    final week = ((hr['installmentsDueThisWeek'] as Map?) ?? const {});
    final overdue = ((hr['overdueInstallments'] as Map?) ?? const {});
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        // the office's way: المتاح (بنك / نقدي مكتب / نقدي محاسب) → الدخل (عمولات، مبيعات، ضخ، أمانات) → المصروفات → الصافي
        CashOverview(isDark: isDark, month: widget.month, allMonths: widget.allMonths, onChanged: _refresh),
        if (summary['office'] is Map) _box(context, 'office', (summary['office'] as Map).cast<String, dynamic>()),
        if (summary['hr'] is Map) _box(context, 'hr', (summary['hr'] as Map).cast<String, dynamic>()),
        if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _d['success'] == true) ...[
          _section('الشهر ده — دوس على أي مربع تشوف تفاصيله'),
          JphUi.statGrid([
            _tile('المرتبات المستحقة', hr['salariesDue'], Icons.payments_rounded, Colors.teal, 'salaries'),
            _tile('مرتبات اتصرفت', hr['salariesPaid'], Icons.price_check_rounded, Colors.green, 'salaries_paid'),
            _tile('باقي من المرتبات', hr['salariesRemaining'], Icons.hourglass_bottom_rounded, Colors.orange, 'salaries'),
            _tile('التحصيلات', hr['collections'], Icons.savings_rounded, Colors.green, 'collections'),
            _tile('مصروفات خزنة المحاسب', hr['expenses'], Icons.receipt_long_rounded, Colors.deepOrange, 'hr_expenses'),
            _tile('سلف لسه هتتخصم', hr['outstandingAdvances'], Icons.request_quote_rounded, Colors.purple, 'advances'),
            _tile('عمولات مستنية الصرف', hr['commissionsAwaitingPayment'], Icons.workspace_premium_rounded, Colors.amber, 'commissions_unpaid'),
          ]),
          _section('الأقساط'),
          JphUi.statGrid([
            _tile('مستحق خلال أسبوع (${week['count'] ?? 0})', week['amount'], Icons.event_available_rounded, Colors.blue, 'installments_week'),
            _tile('متأخر (${overdue['count'] ?? 0})', overdue['amount'], Icons.warning_amber_rounded, Colors.red, 'installments_overdue'),
          ]),
          if (mg != null) ...[
            _section('الإدارة'),
            JphUi.statGrid([
              _tile('مصروفات المكتب', mg['officeExpenses'], Icons.receipt_rounded, Colors.orange, 'office_expenses'),
              _tile('عمولات الشهر', mg['commissions'], Icons.workspace_premium_rounded, Colors.amber, 'commissions'),
              _tile('حجز ومقدمات', mg['downPayments'], Icons.key_rounded, Colors.green, 'down_payments'),
              _tile('أقساط اتحصلت', mg['installmentsCollected'], Icons.check_circle_rounded, Colors.green, 'installments_collected'),
              _tile('باقي على الوحدات', mg['unitsRemaining'], Icons.home_work_rounded, Colors.indigo, 'units_remaining'),
              _tile('تحويلات مفتوحة', mg['transfersOpen'], Icons.swap_horiz_rounded, Colors.blueGrey, 'transfers_open', money: false),
            ]),
          ],
        ],
        if (can['settings'] == true) ...[
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: () => _adjustSheet(context, isDark, _refresh),
            icon: const Icon(Icons.tune_rounded),
            label: const Text('رصيد افتتاحي / تسوية جرد'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => _thresholdSheet(context, isDark, summary['expenseApprovalThreshold'], _refresh),
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

/// A form that is always shown on its tab (like طلبات المالية), not hidden behind a button.
/// A cashbox form that opens from its button (طلب توريد / تحويل أموال، تسجيل مصروف، تحصيل) and folds back after sending.
Widget _inlineForm(bool isDark,
        {required String title, required IconData icon, required List<Widget> children, required String button,
        required bool saving, required VoidCallback onSubmit, String? opener}) =>
    _FoldingForm(isDark: isDark, title: title, icon: icon, button: button, saving: saving, onSubmit: onSubmit, opener: opener ?? title,
        children: children);

class _FoldingForm extends StatefulWidget {
  final bool isDark, saving;
  final String title, button, opener;
  final IconData icon;
  final List<Widget> children;
  final VoidCallback onSubmit;
  const _FoldingForm({required this.isDark, required this.title, required this.icon, required this.children, required this.button,
      required this.saving, required this.onSubmit, required this.opener});
  @override
  State<_FoldingForm> createState() => _FoldingFormState();
}

class _FoldingFormState extends State<_FoldingForm> {
  bool _open = false;

  @override
  void didUpdateWidget(covariant _FoldingForm old) {
    super.didUpdateWidget(old);
    if (old.saving && !widget.saving) setState(() => _open = false); // sent: fold back
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: !_open
          ? Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: SizedBox(
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: () => setState(() => _open = true),
                  icon: Icon(widget.icon),
                  label: Text(widget.opener, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                  style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
                ),
              ),
            )
          : Container(
              margin: const EdgeInsets.only(bottom: 18),
              padding: const EdgeInsets.all(16),
              decoration: JphUi.box(isDark),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  JphUi.iconTile(isDark, widget.icon, JphUi.primary(isDark)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(widget.title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
                  IconButton(onPressed: () => setState(() => _open = false), icon: Icon(Icons.close_rounded, color: JphUi.sub(isDark))),
                ]),
                const SizedBox(height: 14),
                ...widget.children,
                const SizedBox(height: 16),
                SizedBox(
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: widget.saving ? null : widget.onSubmit,
                    icon: widget.saving
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.send_rounded),
                    label: Text(widget.button, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                    style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
                  ),
                ),
              ]),
            ),
    );
  }
}

Future<void> _adjustSheet(BuildContext context, bool isDark, Future<void> Function() done) async {
  String box = 'office', kind = 'opening';
  final amount = TextEditingController(), reason = TextEditingController(), counted = TextEditingController();
  await _formSheet(context, isDark, 'رصيد افتتاحي / تسوية جرد', (setS) => [
        _segmented(isDark, {'office': 'خزينة المكتب', 'hr': 'خزينة المحاسب'}, box, (v) => setS(() => box = v)),
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
        Text('أي مصروف من خزينة المحاسب أكبر من المبلغ ده يستنى موافقة المدير الأول.', style: TextStyle(color: JphUi.sub(isDark))),
        const SizedBox(height: 10),
        JphUi.input(isDark: isDark, label: 'المبلغ', controller: c, number: true, suffix: 'جنيه'),
      ], () => _post('/cash/settings', {'expenseApprovalThreshold': num.tryParse(c.text.trim())}, ok: 'اتحفظ ✅', patch: true));
  await done();
}

/// Same look as the home-page tab bar (glass pill, the chosen one filled); scrolls when there are many choices.
Widget _segmented(bool isDark, Map<String, String> options, String value, ValueChanged<String> onChanged) {
  final p = JphUi.primary(isDark);
  final t = isDark ? Colors.white : Colors.black;
  return Container(
    padding: const EdgeInsets.all(5),
    decoration: BoxDecoration(
      color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.35),
      borderRadius: BorderRadius.circular(30),
    ),
    child: LayoutBuilder(builder: (context, c) {
      Widget item(MapEntry<String, String> e, {bool expand = false}) {
        final w = GestureDetector(
          onTap: () => onChanged(e.key),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
            decoration: BoxDecoration(color: value == e.key ? p : Colors.transparent, borderRadius: BorderRadius.circular(24)),
            child: Text(e.value, textAlign: TextAlign.center, maxLines: 1,
                style: TextStyle(color: value == e.key ? Colors.white : t, fontWeight: FontWeight.w700)),
          ),
        );
        return expand ? Expanded(child: w) : w;
      }
      // few choices share the width; many choices scroll sideways
      if (options.length <= 3) return Row(children: [for (final e in options.entries) item(e, expand: true)]);
      return SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [for (final e in options.entries) item(e)]));
    }),
  );
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
/// كل حركات الفلوس في الخزنة (وارد / صادر) بفلتر الشهر — تبويب "السجل".
class CashLedgerView extends StatefulWidget {
  final bool isDark;
  final Map<String, dynamic> can;
  /// the cashbox page's month filter (then this view has no filter button of its own)
  final ValueListenable<DateTime>? month;
  const CashLedgerView({super.key, required this.isDark, required this.can, this.month});

  @override
  State<CashLedgerView> createState() => _LedgerTabState();
}

class _LedgerTabState extends State<CashLedgerView> {
  late String _box = widget.can['office'] == true ? 'office' : 'hr';
  late DateTime _month = widget.month?.value ?? DateTime(DateTime.now().year, DateTime.now().month);
  Map<String, dynamic> _r = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    widget.month?.addListener(_onMonth);
    _load();
  }

  void _onMonth() {
    _month = widget.month!.value;
    _load();
  }

  @override
  void dispose() {
    widget.month?.removeListener(_onMonth);
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final last = DateTime(_month.year, _month.month + 1, 0);
    String d(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
    final r = await _get('/cash/ledger', {'cashbox': _box, 'from': d(_month), 'to': d(last)});
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
          _segmented(isDark, {'office': 'خزينة المكتب', 'hr': 'خزينة المحاسب'}, _box, (v) {
            _box = v;
            _load();
          }),
        if (widget.month == null) JphUi.filterButton(isDark, '${JphUi.monthsAr[_month.month - 1]} ${_month.year}', () async {
          final m = await JphUi.pickMonth(context, isDark, _month);
          if (m != null) {
            _month = m;
            _load();
          }
        }),
        const SizedBox(height: 6),
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
  // طلب تحويل (HR يطلب من المكتب) / طلب توريد (المدير يطلب من الـ HR)
  late String _dir = widget.can['hrDesk'] == true ? 'office_to_hr' : 'hr_to_office';
  final _amount = TextEditingController(), _reason = TextEditingController();
  bool _saving = false;

  Map<String, (String, IconData)> get _kinds => {
        if (widget.can['office'] == true) 'hr_to_office': ('طلب توريد أموال', Icons.call_made_rounded),
        if (widget.can['hrDesk'] == true || widget.can['office'] == true) 'office_to_hr': ('طلب تحويل أموال', Icons.call_received_rounded),
      };
  List<Map<String, dynamic>> _moves = [];

  /// طلب توريد / تحويل أموال — each from its own button (the form in a sheet).
  Future<void> _request(String dir) async {
    final isDark = widget.isDark;
    final amount = TextEditingController(), reason = TextEditingController();
    await _formSheet(context, isDark, dir == 'office_to_hr' ? 'طلب تحويل أموال من خزنة المكتب إلى المحاسب' : 'طلب توريد أموال من خزنة المحاسب للمكتب',
        (setS) => [
              JphUi.input(isDark: isDark, label: 'المبلغ *', controller: amount, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
              const SizedBox(height: 14),
              JphUi.input(isDark: isDark, label: 'السبب *', controller: reason, icon: Icons.notes_rounded, big: false),
            ],
        () => _post('/cash/transfers', {'direction': dir, 'amount': num.tryParse(amount.text.trim()), 'reason': reason.text.trim()},
            ok: 'اتبعت الطلب ✅'));
    await _load();
    await widget.onChanged();
  }

  /// نقل أموال من البنك إلى خزنة المكتب: the box's total stays, only its bank part becomes cash.
  Future<void> _bankMove() async {
    final isDark = widget.isDark;
    final amount = TextEditingController(), note = TextEditingController();
    await _formSheet(context, isDark, 'نقل أموال من البنك إلى خزنة المكتب', (setS) => [
          Text('الرصيد الإجمالي مش بيتغير — بس الفلوس بتتنقل من رصيد البنك للنقدي.', style: TextStyle(color: JphUi.sub(isDark))),
          const SizedBox(height: 12),
          JphUi.input(isDark: isDark, label: 'المبلغ *', controller: amount, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
          const SizedBox(height: 14),
          JphUi.input(isDark: isDark, label: 'ملاحظة', controller: note, icon: Icons.notes_rounded, big: false),
        ], () => _post('/cash/bank-moves', {'amount': num.tryParse(amount.text.trim()), 'note': note.text.trim()}, ok: 'اتنقلت الفلوس للنقدي ✅'));
    await _load();
    await widget.onChanged();
  }

  Future<void> _send() async {
    setState(() => _saving = true);
    final r = await _post('/cash/transfers', {'direction': _dir, 'amount': num.tryParse(_amount.text.trim()), 'reason': _reason.text.trim()},
        ok: 'اتبعت الطلب ✅');
    if (!mounted) return;
    setState(() => _saving = false);
    JphUi.toast(context, r);
    if (r['success'] == true) {
      _amount.clear();
      _reason.clear();
      await _load();
      await widget.onChanged();
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/cash/transfers');
    final m = widget.can['office'] == true ? await _get('/cash/bank-moves') : const <String, dynamic>{};
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = _list(r, 'transfers');
      _moves = _list(m, 'moves');
    });
  }

  Future<void> _act(String path, Map<String, dynamic> body, String ok) async {
    final r = await _post(path, body, ok: ok);
    if (!mounted) return;
    JphUi.toast(context, r);
    await _load();
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        // طلب توريد أموال | طلب تحويل أموال — side by side; نقل من البنك under them (المالك / المدير العام)
        if (_kinds.isNotEmpty)
          Row(children: [
            for (final (i, k) in _kinds.entries.indexed) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: ElevatedButton.icon(
                    onPressed: () => _request(k.key),
                    icon: Icon(k.value.$2),
                    label: FittedBox(fit: BoxFit.scaleDown, child: Text(k.value.$1, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900))),
                    style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
                  ),
                ),
              ),
            ],
          ]),
        if (widget.can['office'] == true) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 54,
            child: OutlinedButton.icon(
              onPressed: _bankMove,
              icon: const Icon(Icons.account_balance_rounded),
              label: const Text('نقل أموال من البنك إلى خزنة المكتب', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900)),
              style: OutlinedButton.styleFrom(side: BorderSide(color: JphUi.primary(isDark), width: 1.4),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
            ),
          ),
        ],
        const SizedBox(height: 16),
        if (_moves.isNotEmpty) ...[
          Text('نقل من البنك للنقدي', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
          const SizedBox(height: 6),
          for (final m in _moves.take(10))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                const Icon(Icons.account_balance_rounded, color: Colors.teal, size: 20),
                const SizedBox(width: 8),
                Expanded(child: Text('${m['byName']} · ${'${m['at'] ?? ''}'.length >= 10 ? '${m['at']}'.substring(0, 10) : ''}${'${m['note'] ?? ''}'.isEmpty ? '' : ' · ${m['note']}'}',
                    style: TextStyle(color: JphUi.sub(isDark)))),
                Text(JphUi.money(m['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
              ]),
            ),
          const SizedBox(height: 12),
        ],
        Text('التحويلات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
        const SizedBox(height: 8),
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
              Text('${toHr ? 'المكتب ← المحاسب' : 'المحاسب ← المكتب'} • #${t['refNo']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
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

  // HR records the HR cashbox only; المدير / المالك record the office cashbox only
  String get _box => widget.can['hrDesk'] == true ? 'hr' : 'office';
  bool get _canRecord => widget.can['hrDesk'] == true || widget.can['office'] == true;
  final _amount = TextEditingController(), _category = TextEditingController(), _reason = TextEditingController(),
      _beneficiary = TextEditingController(), _notes = TextEditingController();
  String _ref = newClientRef();
  bool _saving = false;
  String _method = 'cash';
  int _view = 0; // 0 مصاريف • 1 مصاريف ثابتة
  Map<String, dynamic>? _mk; // the marketing company paid (its fee / its commission)
  List<Map<String, dynamic>> _mks = [];
  static const _cats = ['إيجار', 'نت', 'كهرباء', 'مياه', 'ضيافة', 'شركة تسويق', 'إعلانات', 'صيانة', 'أدوات مكتبية', 'مواصلات'];

  Future<void> _loadMk() async {
    if (_mks.isNotEmpty || widget.can['office'] != true) return;
    final r = await _get('/marketing-companies');
    if (mounted) setState(() => _mks = _list(r, 'companies').where((m) => m['status'] == 'active').toList());
  }

  Future<void> _add() async {
    setState(() => _saving = true);
    final r = await _post('/cash/expenses', {
      'cashbox': _box, 'amount': num.tryParse(_amount.text.trim()), 'category': _category.text.trim(), 'reason': _reason.text.trim(),
      'beneficiary': _beneficiary.text.trim(), 'notes': _notes.text.trim(), 'clientRef': _ref, 'paymentMethod': _method,
      if (_mk != null && _category.text.trim() == 'شركة تسويق') 'marketingCompanyId': _mk!['id'],
    }, ok: 'اتسجل المصروف ✅');
    if (!mounted) return;
    setState(() => _saving = false);
    JphUi.toast(context, r);
    if (r['success'] == true) {
      for (final c in [_amount, _category, _reason, _beneficiary, _notes]) {
        c.clear();
      }
      _ref = newClientRef();
      await _load();
      await widget.onChanged();
    }
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
        if (_canRecord) ...[
          JphUi.tabs(isDark, const [('مصاريف', Icons.shopping_bag_rounded), ('مصاريف ثابتة', Icons.event_repeat_rounded)], _view,
              (i) => setState(() => _view = i)),
          const SizedBox(height: 14),
        ],
        if (_canRecord && _view == 1)
          _FixedExpenses(isDark: isDark, can: widget.can, onChanged: () async {
            await _load();
            await widget.onChanged();
          })
        else ...[
        if (_canRecord)
          _inlineForm(isDark,
              title: 'تسجيل مصروف', opener: 'تسجيل مصروف', icon: Icons.shopping_bag_rounded, button: 'تسجيل المصروف', saving: _saving, onSubmit: _add,
              children: [
                JphUi.readOnly(isDark: isDark, label: 'من', value: _boxAr[_box]!, icon: Icons.account_balance_wallet_rounded,
                    color: _box == 'hr' ? Colors.teal : Colors.indigo),
                const SizedBox(height: 14),
                JphUi.input(isDark: isDark, label: 'المبلغ *', controller: _amount, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
                const SizedBox(height: 14),
                JphUi.input(isDark: isDark, label: 'البند * (إيجار، كهرباء، ضيافة...)', controller: _category, icon: Icons.category_rounded, big: false),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final c in _cats)
                    ChoiceChip(label: Text(c), selected: _category.text.trim() == c, onSelected: (_) {
                      setState(() => _category.text = c);
                      if (c == 'شركة تسويق') _loadMk();
                    }),
                ]),
                if (_category.text.trim() == 'شركة تسويق' && _mks.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    for (final m in _mks)
                      ChoiceChip(label: Text('${m['name']} (${m['kindAr']})'), selected: _mk?['id'] == m['id'], onSelected: (_) => setState(() {
                        _mk = m;
                        if (_beneficiary.text.trim().isEmpty) _beneficiary.text = '${m['name']}';
                        if (_amount.text.trim().isEmpty && ((m['monthlyFee'] as num?) ?? 0) > 0) _amount.text = '${m['monthlyFee']}';
                      })),
                  ]),
                ],
                const SizedBox(height: 14),
                _segmented(isDark, const {'cash': 'نقدي', 'bank': 'من البنك'}, _method, (v) => setState(() => _method = v)),
                const SizedBox(height: 14),
                JphUi.input(isDark: isDark, label: 'سبب الصرف *', controller: _reason, icon: Icons.notes_rounded, big: false),
                const SizedBox(height: 14),
                JphUi.input(isDark: isDark, label: 'المستفيد *', controller: _beneficiary, icon: Icons.person_rounded, big: false),
                const SizedBox(height: 14),
                JphUi.input(isDark: isDark, label: 'ملاحظات (اختياري)', controller: _notes, icon: Icons.edit_note_rounded, big: false),
                if (_box == 'hr')
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text('المصروف أكبر من ${JphUi.money(widget.threshold)} بيستنى موافقة المدير قبل ما يتخصم.',
                        style: TextStyle(color: JphUi.sub(isDark))),
                  ),
              ]),
        Text('المصروفات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
        const SizedBox(height: 8),
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
              if (x['status'] == 'posted' || x['status'] == 'pending_approval')
                _receiptActions(context, isDark, x, x['hasAttachment'] == true, _load),
            ]),
          ),
        ],
      ]),
    );
  }
}

/// «طباعة إيصال» (يمضي عليه المستلم) و«صورة الإيصال الموقّع» (إضافة / عرض) لأي مصروف.
Widget _receiptActions(BuildContext context, bool isDark, Map<String, dynamic> x, bool hasPhoto, Future<void> Function() reload) {
  return Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 6, children: [
      OutlinedButton.icon(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PaymentVoucherPage(expense: x))),
        icon: const Icon(Icons.print_rounded, size: 18),
        label: const Text('طباعة إيصال'),
      ),
      if (hasPhoto)
        OutlinedButton.icon(
          onPressed: () => _viewReceiptPhoto(context, '${x['id']}'),
          icon: const Icon(Icons.image_rounded, size: 18, color: Colors.green),
          label: const Text('صورة الإيصال'),
        ),
      OutlinedButton.icon(
        onPressed: () async {
          if (await _uploadReceiptPhoto(context, '${x['id']}')) await reload();
        },
        icon: const Icon(Icons.add_a_photo_rounded, size: 18),
        label: Text(hasPhoto ? 'تغيير الصورة' : 'إضافة صورة الإيصال الموقّع'),
      ),
    ]),
  );
}

Future<bool> _uploadReceiptPhoto(BuildContext context, String expenseId) async {
  XFile? f;
  try {
    f = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 60, maxWidth: 1400, maxHeight: 1400);
  } catch (_) {
    f = null;
  }
  if (f == null) return false;
  final bytes = await f.readAsBytes();
  if (!context.mounted) return false;
  if (bytes.length > 600000) {
    JphUi.toast(context, {'success': false, 'message': 'الصورة كبيرة — اختار صورة أصغر من 600 KB'});
    return false;
  }
  final r = await _post('/cash/expenses/$expenseId/attachment', {'attachment': base64Encode(bytes)}, ok: 'اتضافت صورة الإيصال ✅');
  if (!context.mounted) return false;
  JphUi.toast(context, r);
  return r['success'] == true;
}

Future<void> _viewReceiptPhoto(BuildContext context, String expenseId) async {
  final r = await _get('/cash/expenses/$expenseId/attachment');
  if (!context.mounted) return;
  final b64 = r['attachment'];
  if (r['success'] == false || b64 is! String) {
    JphUi.toast(context, r);
    return;
  }
  await showDialog(
    context: context,
    builder: (ctx) => Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: InteractiveViewer(child: Image.memory(base64Decode(b64), fit: BoxFit.contain))),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('قفل')),
      ]),
    ),
  );
}

// ==================================================================== مصاريف ثابتة
IconData _catIcon(String c) => switch (c) {
      'إيجار' => Icons.home_work_rounded,
      'مرتب أوفيس بوي' => Icons.person_rounded,
      'نت' => Icons.wifi_rounded,
      'كهرباء' => Icons.bolt_rounded,
      'مياه' => Icons.water_drop_rounded,
      'تليفون' => Icons.phone_rounded,
      'نظافة' => Icons.cleaning_services_rounded,
      'أمن' => Icons.security_rounded,
      _ => Icons.category_rounded,
    };

Future<String?> _askText(BuildContext context, bool isDark, String title, String initial) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: ui.TextDirection.rtl,
      child: AlertDialog(
        title: Text(title),
        content: TextField(controller: c, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('تمام')),
        ],
      ),
    ),
  );
}

class _FixedExpenses extends StatefulWidget {
  final bool isDark;
  final Map<String, dynamic> can;
  final Future<void> Function() onChanged;
  const _FixedExpenses({required this.isDark, required this.can, required this.onChanged});

  @override
  State<_FixedExpenses> createState() => _FixedExpensesState();
}

class _FixedExpensesState extends State<_FixedExpenses> {
  List<Map<String, dynamic>> _items = [];
  String _payFrom = 'office'; // «صرف» بيتخصم من خزنة اللي داس (المحاسب ← خزنته، المدير ← خزنة المكتب)
  bool _loading = true;
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  static const _months = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
  static const _cats = ['إيجار', 'مرتب أوفيس بوي', 'نت', 'كهرباء', 'مياه', 'تليفون', 'نظافة', 'أمن', 'اشتراكات'];

  String get _m => '${_month.year}-${_month.month.toString().padLeft(2, '0')}';
  String get _monthAr => '${_months[_month.month - 1]} ${_month.year}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/cash/fixed-expenses', {'month': _m});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = _list(r, 'fixed');
      _payFrom = r['payFrom'] == 'hr' ? 'hr' : 'office';
    });
  }

  Future<void> _edit([Map<String, dynamic>? f]) async {
    final isDark = widget.isDark;
    final name = TextEditingController(text: f?['name'] ?? ''), category = TextEditingController(text: f?['category'] ?? ''),
        amount = TextEditingController(text: f == null ? '' : '${f['amount']}'), beneficiary = TextEditingController(text: f?['beneficiary'] ?? ''),
        notes = TextEditingController(text: f?['notes'] ?? '');
    String method = f?['paymentMethod'] ?? 'cash';
    bool active = f?['active'] != false;
    await _formSheet(context, isDark, f == null ? 'إضافة مصروف ثابت' : 'تعديل المصروف الثابت', (setS) => [
          JphUi.input(isDark: isDark, label: 'الاسم * (إيجار المكتب، الأوفيس بوي...)', controller: name, icon: Icons.label_rounded, big: false),
          const SizedBox(height: 14),
          // the same picker as «اختار الموظف» in تقرير الحضور
          JphUi.picker(
            isDark: isDark,
            icon: Icons.category_rounded,
            iconColor: Colors.indigo,
            label: 'البند *',
            value: category.text.trim().isEmpty ? 'اختار البند' : category.text.trim(),
            onTap: () async {
              final cur = category.text.trim();
              final v = await JphUi.sheet<String>(context, isDark, 'البند', [
                for (final c in _cats) (c, c, _catIcon(c)),
                if (cur.isNotEmpty && !_cats.contains(cur)) (cur, cur, Icons.category_rounded),
                ('__other', 'بند تاني…', Icons.edit_rounded),
              ], selected: cur, icon: Icons.category_rounded);
              if (v == null) return;
              if (v == '__other') {
                if (!context.mounted) return;
                final t = await _askText(context, isDark, 'اسم البند', cur);
                if (t != null && t.trim().isNotEmpty) setS(() => category.text = t.trim());
              } else {
                setS(() => category.text = v);
              }
            },
          ),
          const SizedBox(height: 14),
          JphUi.input(isDark: isDark, label: 'المبلغ الشهري *', controller: amount, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
          const SizedBox(height: 14),
          JphUi.input(isDark: isDark, label: 'المستلم * (صاحب الشقة، الأوفيس بوي...)', controller: beneficiary, icon: Icons.person_rounded, big: false),
          const SizedBox(height: 14),
          _segmented(isDark, const {'cash': 'نقدي', 'bank': 'من البنك'}, method, (v) => setS(() => method = v)),
          const SizedBox(height: 14),
          JphUi.input(isDark: isDark, label: 'ملاحظات (اختياري)', controller: notes, icon: Icons.edit_note_rounded, big: false),
          if (f != null)
            SwitchListTile(
              value: active,
              onChanged: (v) => setS(() => active = v),
              title: Text(active ? 'شغّال (بيتصرف كل شهر)' : 'موقوف', style: TextStyle(color: JphUi.text(isDark), fontWeight: FontWeight.w700)),
            ),
        ], () {
      final body = {
        'name': name.text.trim(), 'category': category.text.trim(), 'amount': num.tryParse(amount.text.trim()),
        'beneficiary': beneficiary.text.trim(), 'paymentMethod': method, 'notes': notes.text.trim(),
        if (f != null) 'active': active,
      };
      return f == null
          ? _post('/cash/fixed-expenses', body, ok: 'اتضاف المصروف الثابت ✅')
          : _post('/cash/fixed-expenses/${f['id']}', body, ok: 'اتعدل ✅', patch: true);
    });
    await _load();
  }

  Future<void> _pay(Map<String, dynamic> f) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: AlertDialog(
          title: const Text('صرف المصروف الثابت'),
          content: Text('هيتسجل مصروف «${f['name']}» عن $_monthAr بمبلغ ${JphUi.money(f['amount'])} لـ ${f['beneficiary']} '
              'من ${_boxAr[_payFrom]} (${f['paymentMethod'] == 'bank' ? 'من البنك' : 'نقدي'}).'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('صرف')),
          ],
        ),
      ),
    );
    if (yes != true || !mounted) return;
    final r = await _post('/cash/fixed-expenses/${f['id']}/pay', {'month': _m}, ok: 'اتصرف ✅ — اطبع الإيصال وخلّي المستلم يمضي');
    if (!mounted) return;
    JphUi.toast(context, r);
    if (r['success'] == true) {
      await _load();
      await widget.onChanged();
      final e = r['expense'];
      if (e is Map && mounted) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => PaymentVoucherPage(expense: e.cast<String, dynamic>())));
      }
    }
  }

  Map<String, dynamic> _voucher(Map<String, dynamic> f, Map paid) => {
        'id': paid['expenseId'], 'refNo': paid['refNo'], 'amount': f['amount'], 'beneficiary': f['beneficiary'], 'category': f['category'],
        'reason': '${f['name']} — $_monthAr', 'cashbox': paid['cashbox'] ?? _payFrom, 'paymentMethod': f['paymentMethod'], 'notes': f['notes'],
      };

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final total = _items.where((f) => f['active'] != false).fold<num>(0, (s, f) => s + ((f['amount'] as num?) ?? 0));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ElevatedButton.icon(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add_rounded),
        label: const Text('إضافة مصروف ثابت', style: TextStyle(fontWeight: FontWeight.w900)),
        style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 52), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
      ),
      const SizedBox(height: 14),
      Row(children: [
        Expanded(child: Text('المصاريف الثابتة • ${JphUi.money(total)} شهريًا',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
        TextButton.icon(
          onPressed: () async {
            final m = await JphUi.pickMonth(context, isDark, _month);
            if (m == null) return;
            setState(() {
              _month = DateTime(m.year, m.month);
              _loading = true;
            });
            await _load();
          },
          icon: const Icon(Icons.calendar_month_rounded, size: 18),
          label: Text(_monthAr),
        ),
      ]),
      const SizedBox(height: 8),
      if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
      if (!_loading && _items.isEmpty)
        Padding(padding: const EdgeInsets.all(30),
            child: Text('مفيش مصاريف ثابتة — ضيف الإيجار أو الأوفيس بوي أو الفواتير الثابتة', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
      for (final f in _items)
        Builder(builder: (context) {
          final paid = f['paid'] is Map ? f['paid'] as Map : null;
          final active = f['active'] != false;
          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: JphUi.box(isDark),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                JphUi.iconTile(isDark, Icons.event_repeat_rounded, active ? Colors.indigo : Colors.grey),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${f['name']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text('${f['category']} • ${f['beneficiary']}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                    Text(f['paymentMethod'] == 'bank' ? 'من البنك' : 'نقدي', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                  ]),
                ),
                Text(JphUi.money(f['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
              ]),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 6, children: [
                if (!active) JphUi.chip('موقوف', Colors.grey),
                if (paid != null && paid['status'] == 'posted')
                  JphUi.chip('اتصرف $_monthAr من ${_boxAr[paid['cashbox']] ?? ''} • #${paid['refNo']}', Colors.green),
                if (paid != null && paid['status'] == 'pending_approval') JphUi.chip('مستني موافقة المدير', Colors.orange),
                if (paid == null && active) JphUi.chip('لسه متصرفش $_monthAr', Colors.deepOrange),
                if (paid != null && paid['hasAttachment'] == true) JphUi.chip('الإيصال الموقّع متصوّر', Colors.teal),
              ]),
              const SizedBox(height: 6),
              Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 6, children: [
                TextButton.icon(onPressed: () => _edit(f), icon: const Icon(Icons.edit_rounded, size: 18), label: const Text('تعديل')),
                if (paid == null && active)
                  ElevatedButton.icon(
                    onPressed: () => _pay(f),
                    icon: const Icon(Icons.payments_rounded, size: 18),
                    label: const Text('صرف'),
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                  ),
              ]),
              if (paid != null) _receiptActions(context, isDark, _voucher(f, paid), paid['hasAttachment'] == true, _load),
            ]),
          );
        }),
    ]);
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

  // HR: the HR cashbox only; المدير / المالك: the office cashbox only (neither collects into the other's cashbox)
  late final String _recipient = widget.can['hrDesk'] == true ? 'hr' : 'manager';
  String _kind = 'other', _method = 'cash';
  final _amount = TextEditingController(), _payer = TextEditingController(), _phone = TextEditingController(),
      _purpose = TextEditingController(), _extNo = TextEditingController(), _notes = TextEditingController();
  String _ref = newClientRef();
  bool _saving = false;
  /// the client's unit this money is for: the collection goes on its installments automatically
  Map<String, dynamic>? _sale;

  bool get _saleKind => const {'reservation', 'down_payment', 'installment'}.contains(_kind);
  bool get _canLink => ApiService.can('sales.manage') && ApiService.can('sales.view');

  /// العميل ← (لو عنده أكتر من وحدة) الوحدة — fills the payer and links the receipt to the sale.
  Future<void> _pickClient() async {
    final isDark = widget.isDark;
    final r = await _get('/sales/clients');
    if (!mounted) return;
    final clients = _list(r, 'clients').where((c) => ((c['remaining'] as num?) ?? 0) > 0).toList();
    if (clients.isEmpty) {
      JphUi.toast(context, {'success': false, 'message': '${r['message'] ?? 'مفيش عملاء عليهم مبالغ'}'});
      return;
    }
    final key = await JphUi.sheet<String>(context, isDark, 'العميل', [
      for (final c in clients) ('${c['key']}', '${c['name']} — باقي ${JphUi.money(c['remaining'])}', Icons.person_rounded),
    ], icon: Icons.people_alt_rounded);
    if (key == null || !mounted) return;
    final d = await _get('/sales/clients/detail', {'key': key});
    if (!mounted) return;
    final sales = _list(d, 'sales').where((x) => x['status'] == 'active' && ((x['remaining'] as num?) ?? 0) > 0).toList();
    if (sales.isEmpty) return;
    Map<String, dynamic>? sale = sales.length == 1 ? sales.first : null;
    if (sale == null) {
      final id = await JphUi.sheet<String>(context, isDark, 'الوحدة', [
        for (final x in sales) ('${x['id']}', '${x['projectName']} — وحدة ${x['unitNo']} (باقي ${JphUi.money(x['remaining'])})', Icons.home_work_rounded),
      ], icon: Icons.home_work_rounded);
      if (id == null) return;
      sale = sales.firstWhere((x) => '${x['id']}' == id);
    }
    setState(() {
      _sale = sale;
      _payer.text = '${sale!['buyerName'] ?? ''}';
      _phone.text = '${sale['buyerPhone'] ?? ''}';
      _purpose.text = '${sale['projectName']} — وحدة ${sale['unitNo']}';
    });
  }

  Future<void> _add() async {
    setState(() => _saving = true);
    final body = {
      'recipient': _recipient, 'kind': _kind, 'amount': num.tryParse(_amount.text.trim()), 'payerName': _payer.text.trim(),
      'payerPhone': _phone.text.trim(), 'purpose': _purpose.text.trim(), 'paymentMethod': _method,
      if (_extNo.text.trim().isNotEmpty) 'externalNo': _extNo.text.trim(), 'notes': _notes.text.trim(), 'clientRef': _ref,
    };
    // linked to a client's unit → spread over its open installments automatically (one receipt per installment)
    final r = _sale != null && _saleKind
        ? await _post('/sales/${_sale!['id']}/collect-auto', body, ok: 'اتسجل التحصيل واتربط بأقساط العميل ✅')
        : await _post('/cash/receipts', body, ok: 'اتسجل التحصيل ✅');
    if (!mounted) return;
    setState(() => _saving = false);
    JphUi.toast(context, r);
    if (r['success'] == true) {
      for (final c in [_amount, _payer, _phone, _purpose, _extNo, _notes]) {
        c.clear();
      }
      _ref = newClientRef();
      _sale = null;
      await _load();
      await widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        if (widget.can['hrDesk'] == true || widget.can['office'] == true)
          _inlineForm(isDark,
              title: 'تسجيل تحصيل (إيصال)', opener: 'تحصيل', icon: Icons.receipt_rounded, button: 'تسجيل التحصيل', saving: _saving, onSubmit: _add,
              children: [
                JphUi.readOnly(isDark: isDark, label: 'الخزنة',
                    value: _recipient == 'hr' ? 'خزنة المحاسب' : 'خزنة المكتب', icon: Icons.account_balance_rounded, color: Colors.indigo),
                const SizedBox(height: 14),
                _segmented(isDark, _receiptKinds, _kind, (v) => setState(() => _kind = v)),
                const SizedBox(height: 14),
                if (_saleKind && _canLink) ...[
                  JphUi.picker(
                    isDark: isDark,
                    icon: Icons.people_alt_rounded,
                    iconColor: Colors.indigo,
                    label: 'العميل (بيتربط بأقساطه تلقائي)',
                    value: _sale == null ? 'اختار العميل' : '${_sale!['buyerName']} — ${_sale!['projectName']} ${_sale!['unitNo']}',
                    onTap: _pickClient,
                  ),
                  if (_sale != null)
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton(onPressed: () => setState(() => _sale = null), child: const Text('من غير ربط بعميل')),
                    ),
                  const SizedBox(height: 14),
                ],
                JphUi.input(isDark: isDark, label: 'المبلغ *', controller: _amount, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
                const SizedBox(height: 14),
                JphUi.input(isDark: isDark, label: 'اسم الدافع *', controller: _payer, icon: Icons.person_rounded, big: false),
                const SizedBox(height: 14),
                JphUi.input(isDark: isDark, label: 'موبايل الدافع (اختياري)', controller: _phone, icon: Icons.phone_iphone_rounded, big: false),
                const SizedBox(height: 14),
                JphUi.input(isDark: isDark, label: 'الغرض * (المشروع / الوحدة / التفاصيل)', controller: _purpose, icon: Icons.notes_rounded, big: false),
                const SizedBox(height: 14),
                _segmented(isDark, _methods, _method, (v) => setState(() => _method = v)),
                const SizedBox(height: 14),
                JphUi.input(isDark: isDark, label: 'رقم الإيصال الورقي (اختياري)', controller: _extNo, icon: Icons.tag_rounded, big: false),
                const SizedBox(height: 14),
                JphUi.input(isDark: isDark, label: 'ملاحظات (اختياري)', controller: _notes, icon: Icons.edit_note_rounded, big: false),
              ]),
        Text('التحصيلات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
        const SizedBox(height: 8),
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
