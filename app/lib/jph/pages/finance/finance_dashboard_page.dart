import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../services/api_service.dart';
import '../../widgets/app_background.dart';
import '../../widgets/jph_form_ui.dart';
import '../cash/cash_page.dart';

/// لوحة المالية — role-based: HR sees the HR cashbox side only; المدير / owner also see the office cashbox and the
/// company-wide figures. Second tab: مؤشرات الموظفين (month vs previous month, alerts and suggestions — advice only).
class FinanceDashboardPage extends StatefulWidget {
  const FinanceDashboardPage({super.key});

  @override
  State<FinanceDashboardPage> createState() => _FinanceDashboardPageState();
}

String _ym(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}';

class _FinanceDashboardPageState extends State<FinanceDashboardPage> {
  String _tab = 'dashboard';
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  bool get _canInsights => ApiService.can('cash.office') || ApiService.can('report.read_all');

  Future<void> _pickMonth() async {
    final now = DateTime.now();
    final months = [for (var i = 0; i < 12; i++) DateTime(now.year, now.month - i)];
    final m = await JphUi.sheet<DateTime>(context, context.read<AppController>().isDark, 'الشهر',
        [for (final d in months) (d, '${JphUi.monthsAr[d.month - 1]} ${d.year}', Icons.event_rounded)]);
    if (m != null) setState(() => _month = m);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      return AppBackground(
        child: Directionality(
          textDirection: app.isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                JphUi.header(context, isDark: isDark, isRTL: app.isRTL, title: 'لوحة المالية',
                    action: TextButton.icon(
                      onPressed: _pickMonth,
                      icon: Icon(Icons.event_rounded, color: JphUi.primary(isDark), size: 18),
                      label: Text(JphUi.monthAr(_ym(_month)), style: TextStyle(color: JphUi.primary(isDark), fontWeight: FontWeight.w800)),
                    )),
                if (_canInsights)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: cashSegmented(isDark, {'dashboard': 'الأرقام', 'insights': 'مؤشرات الموظفين'}, _tab, (v) => setState(() => _tab = v)),
                  ),
                const SizedBox(height: 8),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1000),
                      child: _tab == 'dashboard' || !_canInsights
                          ? _DashboardTab(key: ValueKey('d${_ym(_month)}'), isDark: isDark, month: _ym(_month))
                          : _InsightsTab(key: ValueKey('i${_ym(_month)}'), isDark: isDark, month: _ym(_month)),
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

Widget _section(bool isDark, String title) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
      child: Text(title, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
    );

Widget _grid(List<Widget> tiles) => LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 700 ? 3 : 2;
      final w = (c.maxWidth - (cols - 1) * 10) / cols;
      return Wrap(spacing: 10, runSpacing: 10, children: [for (final t in tiles) SizedBox(width: w, child: t)]);
    });

class _DashboardTab extends StatefulWidget {
  final bool isDark;
  final String month;
  const _DashboardTab({super.key, required this.isDark, required this.month});

  @override
  State<_DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<_DashboardTab> {
  Map<String, dynamic> _r = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await cashGet('/finance/dashboard', {'month': widget.month});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _r = r;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_r['success'] == false) {
      return Center(child: Text('${_r['message'] ?? 'مش متاح'}', style: TextStyle(color: JphUi.sub(isDark))));
    }
    final cash = (_r['cash'] as Map?) ?? const {};
    final hrBox = (cash['hr'] as Map?) ?? const {};
    final office = cash['office'] as Map?;
    final hr = (_r['hr'] as Map?) ?? const {};
    final mg = _r['management'] as Map?;
    final week = (hr['installmentsDueThisWeek'] as Map?) ?? const {};
    final overdue = (hr['overdueInstallments'] as Map?) ?? const {};
    String m(Object? v) => JphUi.money(v);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        _section(isDark, 'الخزن'),
        _grid([
          JphUi.stat(isDark, 'خزنة الـ HR', m(hrBox['bookBalance']), Icons.account_balance_wallet_rounded, Colors.teal),
          if (office != null) JphUi.stat(isDark, 'خزنة المكتب', m(office['bookBalance']), Icons.account_balance_rounded, Colors.indigo),
          if (cash['total'] != null) JphUi.stat(isDark, 'الإجمالي', m(cash['total']), Icons.summarize_rounded, Colors.blue),
          JphUi.stat(isDark, 'مطلوب من المكتب', m(hr['requiredFromOffice']), Icons.call_received_rounded, Colors.red),
        ]),
        _section(isDark, 'الشهر ده'),
        _grid([
          JphUi.stat(isDark, 'التحصيلات', m(hr['collections']), Icons.savings_rounded, Colors.green),
          JphUi.stat(isDark, 'مصروفات الـ HR', m(hr['expenses']), Icons.receipt_long_rounded, Colors.orange),
          JphUi.stat(isDark, 'سلف لسه هتتخصم', m(hr['outstandingAdvances']), Icons.request_quote_rounded, Colors.purple),
          JphUi.stat(isDark, 'عمولات مستنية الصرف', m(hr['commissionsAwaitingPayment']), Icons.workspace_premium_rounded, Colors.amber),
          JphUi.stat(isDark, 'دفعات مرتبات مفتوحة', '${hr['payrollBatchesOpen'] ?? 0}', Icons.payments_rounded, Colors.teal),
        ]),
        _section(isDark, 'الأقساط'),
        _grid([
          JphUi.stat(isDark, 'مستحق خلال أسبوع (${week['count'] ?? 0})', m(week['amount']), Icons.event_available_rounded, Colors.blue),
          JphUi.stat(isDark, 'متأخر (${overdue['count'] ?? 0})', m(overdue['amount']), Icons.warning_amber_rounded, Colors.red),
        ]),
        if (mg != null) ...[
          _section(isDark, 'الإدارة'),
          _grid([
            JphUi.stat(isDark, 'مرتبات اتصرفت', m(mg['salariesPaid']), Icons.payments_rounded, Colors.teal),
            JphUi.stat(isDark, 'مصروفات المكتب', m(mg['officeExpenses']), Icons.receipt_rounded, Colors.orange),
            JphUi.stat(isDark, 'عمولات الشهر', m(mg['commissions']), Icons.workspace_premium_rounded, Colors.amber),
            JphUi.stat(isDark, 'حجز ومقدمات', m(mg['downPayments']), Icons.key_rounded, Colors.green),
            JphUi.stat(isDark, 'أقساط اتحصلت', m(mg['installmentsCollected']), Icons.check_circle_rounded, Colors.green),
            JphUi.stat(isDark, 'باقي على الوحدات', m(mg['unitsRemaining']), Icons.home_work_rounded, Colors.indigo),
            JphUi.stat(isDark, 'تحويلات مفتوحة', '${mg['transfersOpen'] ?? 0}', Icons.swap_horiz_rounded, Colors.blueGrey),
          ]),
        ],
      ]),
    );
  }
}

class _InsightsTab extends StatefulWidget {
  final bool isDark;
  final String month;
  const _InsightsTab({super.key, required this.isDark, required this.month});

  @override
  State<_InsightsTab> createState() => _InsightsTabState();
}

class _InsightsTabState extends State<_InsightsTab> {
  Map<String, dynamic> _r = {};
  bool _loading = true;
  bool _alertsOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await cashGet('/insights/employees', {'month': widget.month});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _r = r;
    });
  }

  Widget _delta(bool isDark, String label, Object? cur, Object? prev, {bool lowerIsBetter = true, String suffix = ''}) {
    final c = (cur as num?), p = (prev as num?);
    Color col = JphUi.sub(isDark);
    IconData? ic;
    if (c != null && p != null && c != p) {
      final better = lowerIsBetter ? c < p : c > p;
      col = better ? Colors.green : Colors.red;
      ic = c > p ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: col.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$label: ${c ?? '—'}$suffix', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
        if (ic != null) Icon(ic, size: 14, color: col),
        Text('  (${p ?? '—'})', style: TextStyle(fontSize: 11, color: JphUi.sub(isDark))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    if (_loading) return const Center(child: CircularProgressIndicator());
    var list = cashList(_r, 'employees');
    if (_alertsOnly) list = list.where((e) => ((e['alerts'] as List?) ?? const []).isNotEmpty).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: JphUi.box(isDark),
          child: Row(children: [
            Icon(Icons.info_outline_rounded, color: JphUi.primary(isDark), size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${_r['note'] ?? ''}\nالرقم بين القوسين = ${JphUi.monthAr('${_r['previousMonth'] ?? ''}')}',
                  style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
            ),
          ]),
        ),
        SwitchListTile(
          value: _alertsOnly,
          onChanged: (v) => setState(() => _alertsOnly = v),
          title: Text('اللي عندهم تنبيهات بس', style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
        ),
        if (list.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش حاجة', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final e in list) _card(isDark, e),
      ]),
    );
  }

  Widget _card(bool isDark, Map<String, dynamic> e) {
    final c = (e['current'] as Map?) ?? const {};
    final p = (e['previous'] as Map?) ?? const {};
    final alerts = ((e['alerts'] as List?) ?? const []).map((x) => '$x').toList();
    final tips = ((e['suggestions'] as List?) ?? const []).map((x) => '$x').toList();
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EmployeeAccountPage(employeeId: '${e['id']}'))),
      child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          JphUi.iconTile(isDark, Icons.person_rounded, alerts.isEmpty ? Colors.green : Colors.orange),
          const SizedBox(width: 10),
          Expanded(child: Text('${e['name']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
          if (c['punctuality'] != null) JphUi.chip('التزام ${c['punctuality']}%', (c['punctuality'] as num) >= 90 ? Colors.green : Colors.orange),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          _delta(isDark, 'أيام حضور', c['attendanceDays'], p['attendanceDays'], lowerIsBetter: false),
          _delta(isDark, 'تأخير', c['lateCount'], p['lateCount']),
          _delta(isDark, 'دقايق تأخير', c['lateMinutes'], p['lateMinutes']),
          _delta(isDark, 'انصراف بدري', c['earlyCount'], p['earlyCount']),
          _delta(isDark, 'غياب', c['absenceDays'], p['absenceDays']),
          _delta(isDark, 'إجازة بدون مرتب', c['unpaidLeaveDays'], p['unpaidLeaveDays']),
          _delta(isDark, 'أذونات', c['permissions'], p['permissions']),
          _delta(isDark, 'زيارات', c['visits'], p['visits'], lowerIsBetter: false),
          _delta(isDark, 'صفقات', c['deals'], p['deals'], lowerIsBetter: false),
          _delta(isDark, 'عمولات', c['commissions'], p['commissions'], lowerIsBetter: false),
          if (c['evaluation'] != null || p['evaluation'] != null) _delta(isDark, 'التقييم', c['evaluation'], p['evaluation'], lowerIsBetter: false, suffix: '/5'),
        ]),
        for (final a in alerts)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 16),
              const SizedBox(width: 6),
              Expanded(child: Text(a, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: JphUi.text(isDark)))),
            ]),
          ),
        for (final t in tips)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              Icon(Icons.lightbulb_outline_rounded, color: JphUi.primary(isDark), size: 16),
              const SizedBox(width: 6),
              Expanded(child: Text(t, style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark)))),
            ]),
          ),
      ]),
    ),
    );
  }
}

const _payKindAr = {'salary': 'مرتب', 'advance': 'سلفة', 'commission': 'عمولة', 'work_expense': 'مصاريف عمل'};
const _payStatusAr = {
  'pending': ('مستني تأكيد', Colors.orange), 'received': ('استلم', Colors.green),
  'cancelled': ('ملغي', Colors.grey), 'disputed': ('بلاغ مشكلة', Colors.red),
};

/// كشف حساب الموظف — what was paid to him (and whether he confirmed it), his advances with their deduction plan,
/// and his commissions.
class EmployeeAccountPage extends StatefulWidget {
  final String employeeId;
  const EmployeeAccountPage({super.key, required this.employeeId});

  @override
  State<EmployeeAccountPage> createState() => _EmployeeAccountPageState();
}

class _EmployeeAccountPageState extends State<EmployeeAccountPage> {
  Map<String, dynamic> _r = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    cashGet('/finance/employee-account/${widget.employeeId}').then((r) {
      if (mounted) setState(() { _loading = false; _r = r; });
    });
  }

  Widget _row(bool isDark, String title, String sub, String amount, (String, Color)? st) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: JphUi.box(isDark),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              if (sub.isNotEmpty) Text(sub, style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(amount, style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            if (st != null) Padding(padding: const EdgeInsets.only(top: 4), child: JphUi.chip(st.$1, st.$2)),
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      final emp = (_r['employee'] as Map?) ?? const {};
      final pays = cashList(_r, 'payments'), advs = cashList(_r, 'advances'), coms = cashList(_r, 'commissions');
      return AppBackground(
        child: Directionality(
          textDirection: app.isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                JphUi.header(context, isDark: isDark, isRTL: app.isRTL, title: 'كشف حساب ${emp['name'] ?? ''}'),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
                              _section(isDark, 'المبالغ المصروفة'),
                              if (pays.isEmpty) Text('مفيش', style: TextStyle(color: JphUi.sub(isDark))),
                              for (final x in pays)
                                _row(isDark, '${_payKindAr[x['kind']] ?? x['kind']} — ${JphUi.monthAr('${x['month']}')}',
                                    [JphUi.date(x['at']), if ('${x['disputeReason'] ?? ''}'.isNotEmpty) 'المشكلة: ${x['disputeReason']}'].join(' · '),
                                    JphUi.money(x['amount']), _payStatusAr[x['status']]),
                              _section(isDark, 'السلف'),
                              if (advs.isEmpty) Text('مفيش', style: TextStyle(color: JphUi.sub(isDark))),
                              for (final x in advs)
                                _row(isDark, 'سلفة ${JphUi.monthAr('${x['month']}')}',
                                    [for (final d in ((x['deductions'] as List?) ?? const []).whereType<Map>())
                                      if (d['status'] == 'active') 'خصم ${JphUi.monthAr('${d['month']}')}: ${JphUi.money(d['amount'])}'].join(' · '),
                                    JphUi.money(x['amount']), null),
                              _section(isDark, 'العمولات'),
                              if (coms.isEmpty) Text('مفيش', style: TextStyle(color: JphUi.sub(isDark))),
                              for (final x in coms)
                                _row(isDark, '${x['project']} — وحدة ${x['unitNo']}', JphUi.monthAr('${x['month']}'), JphUi.money(x['amount']),
                                    x['status'] == 'cancelled' ? ('ملغية', Colors.grey) : null),
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
