import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../services/jph_bridge.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/swipe_tabs.dart';
import '../advance_summary.dart';
import '../attendance/attendance_report_page.dart';
import '../../widgets/glass_dialog.dart';
import '../../widgets/glass_ui.dart';

/// الخزنة ← الطلبات: شريط تاني تحت شريط الصفحة — سلف | مرتبات | عمولات.
/// الطريقة الوحيدة لصرف السلف والمرتبات والعمولات:
///   صرف (الموارد البشرية) ← "تم الاستلام" عند الموظف ← وساعتها بس المبلغ بيتخصم من خزنة المحاسب.
/// الشريط ده بالضغط بس (الشريط اللي فوقه هو اللي بيتسحب يمين وشمال).
class FinanceRequestsTabs extends StatelessWidget {
  final String uid;
  final String name;
  final String role;
  final bool isDark;
  final ValueListenable<DateTime> month;
  const FinanceRequestsTabs(
      {super.key, required this.uid, required this.name, required this.role, required this.isDark, required this.month});

  @override
  Widget build(BuildContext context) {
    return SwipeTabs(
      isDark: isDark,
      swipe: false,
      tabs: const [
        ('سلف', Icons.account_balance_wallet_rounded),
        ('مرتبات', Icons.payments_rounded),
        ('عمولات', Icons.trending_up_rounded),
      ],
      pages: [
        FinancialSummaryPage(uid: uid, name: name, role: role, embedded: true, month: month),
        SalariesPayTab(uid: uid, name: name, role: role, isDark: isDark, month: month),
        CommissionsPayTab(isDark: isDark, month: month),
      ],
    );
  }
}

String _ym(DateTime m) => '${m.year}-${m.month.toString().padLeft(2, '0')}';

List<Map<String, dynamic>> _rows(Map<String, dynamic> r, String k) =>
    ((r[k] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: GlassAlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          title: Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800)),
          content: Text(body, textAlign: TextAlign.center),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('تأكيد')),
          ],
        ),
      ),
    ) ==
    true;

Widget _actionButton(String label, IconData icon, Color color, VoidCallback? onTap) => SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label, style: const TextStyle(fontWeight: FontWeight.w800)),
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );

Widget _empty(bool isDark, String text) => Padding(
      padding: const EdgeInsets.only(top: 60),
      child: Column(children: [
        Icon(Icons.inbox_rounded, size: 54, color: JphUi.sub(isDark)),
        const SizedBox(height: 10),
        Text(text, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.sub(isDark))),
      ]),
    );

/// Shared loading / month-following state for the two tabs.
abstract class _MonthTabState<T extends StatefulWidget> extends State<T> {
  ValueListenable<DateTime> get month;
  bool loading = true;
  bool busy = false;
  String? error;

  Future<void> load();

  @override
  void initState() {
    super.initState();
    month.addListener(_onMonth);
    load();
  }

  void _onMonth() => load();

  @override
  void dispose() {
    month.removeListener(_onMonth);
    super.dispose();
  }

  Future<void> run(Map<String, dynamic> body) async {
    setState(() => busy = true);
    try {
      final r = await ApiService.post(body);
      if (!mounted) return;
      JphUi.toast(context, {...r, 'message': r['message'] ?? (r['success'] == true ? 'تم ✅' : 'حصلت مشكلة')});
      if (r['success'] == true) await load();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget list(bool isDark, List<Widget> children) => RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
          children: [
            if (loading) const Padding(padding: EdgeInsets.only(top: 60), child: Center(child: CircularProgressIndicator())),
            if (!loading && error != null) _empty(isDark, error!),
            if (!loading && error == null) ...children,
          ],
        ),
      );
}

// ============================================================================ مرتبات
/// One row per employee for the month in the filter only (not cumulative): name, salary due, and "صرف الراتب".
/// Tapping the row opens that employee's monthly attendance report for the same month.
/// An employee without finance access sees his own salary payments and confirms "تم الاستلام".
class SalariesPayTab extends StatefulWidget {
  final String uid;
  final String name;
  final String role;
  final bool isDark;
  final ValueListenable<DateTime> month;
  const SalariesPayTab({super.key, required this.uid, required this.name, required this.role, required this.isDark, required this.month});

  static bool get seesAll => ApiService.can('finance.disburse') || ApiService.can('finance.read');

  @override
  State<SalariesPayTab> createState() => _SalariesPayTabState();
}

class _SalariesPayTabState extends _MonthTabState<SalariesPayTab> {
  List<Map<String, dynamic>> _rowsAll = [];
  List<Map<String, dynamic>> _mine = [];
  Map<String, dynamic> _totals = {};

  @override
  ValueListenable<DateTime> get month => widget.month;

  @override
  Future<void> load() async {
    if (!mounted) return;
    setState(() {
      loading = true;
      error = null;
    });
    final m = _ym(widget.month.value);
    if (SalariesPayTab.seesAll) {
      final r = await ApiService.post({'action': 'cash_get', 'path': '/payouts/salaries', 'query': {'month': m}});
      if (!mounted) return;
      setState(() {
        loading = false;
        if (r['success'] != true) error = '${r['message'] ?? 'مش قادر أحمّل المرتبات'}';
        _rowsAll = _rows(r, 'salaries');
        _totals = ((r['totals'] as Map?) ?? const {}).cast<String, dynamic>();
      });
    } else {
      final r = await ApiService.post({'action': 'payouts_list', 'scope': 'mine'});
      if (!mounted) return;
      setState(() {
        loading = false;
        if (r['success'] != true) error = '${r['message'] ?? 'مش قادر أحمّل المرتبات'}';
        _mine = _rows(r, 'payouts').where((p) => p['kind'] == 'salary' && '${p['period'] ?? ''}'.startsWith(m)).toList();
      });
    }
  }

  void _openReport(Map<String, dynamic> x) {
    final mm = widget.month.value;
    final code = '${x['employeeCode'] ?? ''}';
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AttendanceReportPage(
          uid: widget.uid,
          name: widget.name,
          role: widget.role,
          initialEmployeeId: code.isEmpty ? null : code,
          initialMonth: mm.month,
          initialYear: mm.year,
        ),
      ),
    );
  }

  Future<void> _pay(Map<String, dynamic> x) async {
    final m = _ym(widget.month.value);
    if (!await _confirm(context, 'صرف الراتب', '${x['employeeName']} — ${JphUi.money(x['remaining'])}\n'
        'مرتب ${JphUi.monthAr(m)} — هيظهر عنده "تم الاستلام"، والمبلغ بيتخصم من الخزنة لما يأكد.')) return;
    await run({'action': 'cash_post', 'path': '/payouts/salary', 'body': {'employeeId': x['employeeId'], 'month': m},
      'ok': 'تم صرف الراتب — مستني الموظف يأكد الاستلام'});
  }

  Future<void> _receive(String payoutId, Object? amount) async {
    if (!await _confirm(context, 'تأكيد الاستلام', 'استلمت ${JphUi.money(amount)}؟')) return;
    await run({'action': 'payout_receive', 'id': payoutId});
  }

  (String, Color) _status(String? s) => switch (s) {
        'unpaid' => ('لم يُصرف', Ar.amber),
        'partly_paid' => ('اتصرف جزء', Ar.amber),
        'awaiting_receipt' => ('اتصرف — مستني تأكيد الاستلام', Ar.green),
        'received' => ('تم الاستلام ✅', Ar.green),
        _ => ('مفيش مستحق', Ar.grey),
      };

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    if (!SalariesPayTab.seesAll) {
      return list(isDark, [
        if (_mine.isEmpty) _empty(isDark, 'مفيش صرف مرتب للشهر ده'),
        for (final p in _mine) _myPayout(isDark, p),
      ]);
    }
    final me = JphBridge.myId;
    return list(isDark, [
      // المستحق • قيد المراجعة (اتصرف ولسه المستلم ما أكدش) • اتصرف (اتأكد استلامه) • الباقي
      JphUi.statGrid([
        JphUi.stat(isDark, 'المستحق', JphUi.money(_totals['due']), Icons.payments_rounded, Ar.accent),
        JphUi.stat(isDark, 'قيد المراجعة', JphUi.money(_totals['awaiting']), Icons.pending_actions_rounded, Ar.green),
        JphUi.stat(isDark, 'اتصرف', JphUi.money(_totals['received']), Icons.check_circle_rounded, Ar.green),
        JphUi.stat(isDark, 'الباقي', JphUi.money(_totals['remaining']), Icons.hourglass_bottom_rounded, Ar.amber),
      ]),
      const SizedBox(height: 12),
      if (_rowsAll.isEmpty) _empty(isDark, 'مفيش مرتبات للشهر ده'),
      for (final x in _rowsAll) _row(isDark, x, me),
    ]);
  }

  Widget _row(bool isDark, Map<String, dynamic> x, String me) {
    final st = _status('${x['status']}');
    final pending = _rows(x, 'payments').where((p) => p['status'] == 'pending' || p['status'] == 'disputed').toList();
    final mineToConfirm = '${x['employeeId']}' == me ? pending : const <Map<String, dynamic>>[];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => _openReport(x),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: JphUi.box(isDark),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                JphUi.iconTile(isDark, Icons.person_rounded, Ar.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${x['employeeName'] ?? ''}',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                    const SizedBox(height: 2),
                    Text(st.$1, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: st.$2)),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('الراتب المستحق', style: TextStyle(fontSize: 11, color: JphUi.sub(isDark))),
                  Text(JphUi.money(x['due']),
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.primary(isDark))),
                ]),
              ]),
              if ((x['paid'] as num? ?? 0) > 0 && (x['remaining'] as num? ?? 0) > 0) ...[
                const SizedBox(height: 6),
                Text('اتصرف ${JphUi.money(x['paid'])} — الباقي ${JphUi.money(x['remaining'])}',
                    style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
              ],
              if (x['canPay'] == true) ...[
                const SizedBox(height: 10),
                _actionButton('صرف الراتب', Icons.payments_rounded, JphUi.primary(isDark), busy ? null : () => _pay(x)),
              ],
              for (final p in mineToConfirm) ...[
                const SizedBox(height: 10),
                _actionButton('تم الاستلام', Icons.check_circle_rounded, Ar.green,
                    busy ? null : () => _receive('${p['id']}', p['amount'])),
              ],
            ]),
          ),
        ),
      ),
    );
  }

  Widget _myPayout(bool isDark, Map<String, dynamic> p) {
    final received = p['status'] == 'received';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          JphUi.iconTile(isDark, Icons.payments_rounded, received ? Ar.green : Ar.green),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('مرتب ${JphUi.monthAr('${p['period'] ?? ''}'.padRight(7).substring(0, 7))}',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              Text(received ? 'تم الاستلام ✅' : 'من ${p['created_by_name'] ?? ''} — مستني تأكيدك',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: received ? Ar.green : Ar.green)),
            ]),
          ),
          Text(JphUi.money(p['amount_egp']),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.primary(isDark))),
        ]),
        if (p['canReceive'] == true) ...[
          const SizedBox(height: 10),
          _actionButton('تم الاستلام', Icons.check_circle_rounded, Ar.green,
              busy ? null : () => _receive('${p['id']}', p['amount_egp'])),
        ],
      ]),
    );
  }
}

// ============================================================================ عمولات
/// Every approved commission of the month in the filter, waiting to be paid (or already paid): صرف → تم الاستلام.
class CommissionsPayTab extends StatefulWidget {
  final bool isDark;
  final ValueListenable<DateTime> month;
  const CommissionsPayTab({super.key, required this.isDark, required this.month});

  static bool get seesAll => ApiService.can('commission.read_all');

  @override
  State<CommissionsPayTab> createState() => _CommissionsPayTabState();
}

class _CommissionsPayTabState extends _MonthTabState<CommissionsPayTab> {
  List<Map<String, dynamic>> _items = [];
  Map<String, dynamic> _totals = {};

  @override
  ValueListenable<DateTime> get month => widget.month;

  @override
  Future<void> load() async {
    if (!mounted) return;
    setState(() {
      loading = true;
      error = null;
    });
    final r = await ApiService.post({
      'action': 'commission_entitlements',
      if (CommissionsPayTab.seesAll) 'scope': 'all',
      'month': _ym(widget.month.value),
    });
    if (!mounted) return;
    setState(() {
      loading = false;
      if (r['success'] != true) error = '${r['message'] ?? 'مش قادر أحمّل العمولات'}';
      _items = _rows(r, 'entitlements').where((x) => x['status'] == 'active').toList();
      _totals = ((r['totals'] as Map?) ?? const {}).cast<String, dynamic>();
    });
  }

  Future<void> _pay(Map<String, dynamic> x) async {
    if (!await _confirm(context, 'صرف العمولة', '${x['employeeName']} — ${JphUi.money(x['amount'])}\n'
        '${x['projectName'] ?? ''} ${x['unitNo'] ?? ''}\nهيظهر عنده "تم الاستلام"، والمبلغ بيتخصم من الخزنة لما يأكد.')) return;
    await run({
      'action': 'payout_create', 'employeeId': x['employeeId'], 'kind': 'commission', 'amount': x['amount'],
      'month': x['period'], 'entitlementId': x['id'],
    });
  }

  Future<void> _receive(Map<String, dynamic> x) async {
    if (!await _confirm(context, 'تأكيد الاستلام', 'استلمت ${JphUi.money(x['amount'])}؟')) return;
    await run({'action': 'payout_receive', 'id': x['payoutId']});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final me = JphBridge.myId;
    final canPay = ApiService.can('finance.disburse');
    return list(isDark, [
      JphUi.statGrid([
        JphUi.stat(isDark, 'عمولات الشهر', JphUi.money(_totals['amount']), Icons.trending_up_rounded, Ar.accent),
        JphUi.stat(isDark, 'لسه ماتصرفتش', JphUi.money(_totals['unpaid']), Icons.hourglass_bottom_rounded, Ar.amber),
      ]),
      const SizedBox(height: 12),
      if (_items.isEmpty) _empty(isDark, 'مفيش عمولات للشهر ده'),
      for (final x in _items) _card(isDark, x, me, canPay),
    ]);
  }

  Widget _card(bool isDark, Map<String, dynamic> x, String me, bool canPay) {
    final pay = paymentStatus('${x['payment']}');
    final mine = '${x['employeeId']}' == me;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          JphUi.iconTile(isDark, Icons.handshake_rounded, Ar.accent),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${x['employeeName'] ?? ''}',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              Text('${x['projectName'] ?? ''} — وحدة ${x['unitNo'] ?? ''} (${x['role'] == 'manager' ? 'مدير المبيعات' : 'المبيعات'})',
                  style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
              const SizedBox(height: 2),
              Text(x['payment'] == 'unpaid' ? 'لم تُصرف' : pay.$1,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: x['payment'] == 'unpaid' ? Ar.amber : pay.$2)),
            ]),
          ),
          Text(JphUi.money(x['amount']),
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.primary(isDark))),
        ]),
        if (canPay && !mine && x['payment'] == 'unpaid') ...[
          const SizedBox(height: 10),
          _actionButton('صرف العمولة', Icons.payments_rounded, JphUi.primary(isDark), busy ? null : () => _pay(x)),
        ],
        if (mine && x['payment'] == 'handed' && (x['payoutId'] ?? '').toString().isNotEmpty) ...[
          const SizedBox(height: 10),
          _actionButton('تم الاستلام', Icons.check_circle_rounded, Ar.green, busy ? null : () => _receive(x)),
        ],
      ]),
    );
  }
}
