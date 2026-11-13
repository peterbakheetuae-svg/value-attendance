import '../../widgets/side_sheet.dart';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../widgets/jph_form_ui.dart';
import 'cash_page.dart' show newClientRef, showBankMoveSheet;
import '../exclusive/exclusive_projects_page.dart' show ProjectsBoxPage, CommissionsDuePage, ExpectedCommissionsPage, PendingSalesMoneyCard, monthQuery, monthLabel;
import '../../widgets/glass_ui.dart';

/// الخزنة the office's way (GET /cash/overview):
///   المتاح = بنك + نقدي (نقدي = خزنة المكتب + خزنة المحاسب)
///   الدخل = عمولات (الربح الوحيد) / مبيعات (حجوزات، تعاقد، أقساط) / ضخ من المالك - المدير العام / أمانات المشاريع الحصري
///   العمولات بتتقسم: سيلز / مدير سيلز / المكتب / شركة تسويق — والمكتب بيطلع منها المرتبات والمصاريف بأنواعها.
/// المحاسب بيشوف خزنته بس (نقدي / بنك).
class CashOverview extends StatefulWidget {
  final bool isDark;
  final ValueListenable<DateTime>? month;
  /// «كل الشهور» from the page's filter icon (no notifier = every month)
  final ValueListenable<bool>? allMonths;
  final Future<void> Function()? onChanged;
  /// the month's figures of GET /finance/dashboard (الموظفين، الحركات، الأقساط، الإدارة، تكلفة التشغيل)
  final Map<String, dynamic>? dash;
  /// tap a box → its list (/finance/dashboard/details)
  final void Function(String key, String title)? onDetails;
  /// إجراءات الخزنة that live on another tab of the cashbox (تحصيل / مصروف / تحويل)
  final void Function(String tab)? onGo;
  const CashOverview({super.key, required this.isDark, this.month, this.allMonths, this.onChanged, this.dash, this.onDetails, this.onGo});

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
  /// The cashbox tiles follow the page's filter icon: every month (null) by default, or the month picked there.
  DateTime? get _filter => (widget.allMonths?.value ?? true) ? null : widget.month?.value;

  @override
  void initState() {
    super.initState();
    widget.month?.addListener(_load);
    widget.allMonths?.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.month?.removeListener(_load);
    widget.allMonths?.removeListener(_load);
    super.dispose();
  }

  int _seq = 0;

  Future<void> _load() async {
    final seq = ++_seq;
    final r = await ApiService.post({'action': 'cash_get', 'path': '/cash/overview', 'query': monthQuery(_filter)});
    if (!mounted || seq != _seq) return;
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
    final pay = _m(exp['payroll']);
    final dash = widget.dash ?? const {};
    final hr = _m(dash['hr']), mg = _m(dash['management']), op = _m(dash['operating']);
    final week = _m(hr['installmentsDueThisWeek']), overdue = _m(hr['overdueInstallments']);
    final hasDash = dash['success'] == true;
    final details = widget.onDetails;
    VoidCallback? det(String key, String label) => details == null ? null : () => details(key, label);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PendingSalesMoneyCard(onChanged: _changed),
      // ------------------------------------------------ إجمالي السيولة
      _liquidity(isDark, av),
      if (_office && _o['projectsBox'] is Map) ...[
        const SizedBox(height: 10),
        _projectsCards(isDark),
      ],
      // ------------------------------------------------ الإيرادات والحركات
      _title(isDark, 'الإيرادات والحركات — ${monthLabel(_filter)}'),
      _grid([
        if (_office) _tile(isDark, 'عمولات المكتب', inc['commissions'], Icons.account_balance_wallet_outlined, tone: _in, onTap: () => _commissionSheet(isDark)),
        _tile(isDark, 'ضخ المالك', inc['injection'], Icons.person_outline_rounded, tone: _in),
        _tile(isDark, 'تحصيلات المبيعات', _m(inc['sales'])['total'], Icons.home_outlined, tone: _in, onTap: () => _salesSheet(isDark, _m(inc['sales']))),
        if (_office) _tile(isDark, 'أمانات الحصري', _m(inc['trust'])['in'], Icons.handshake_outlined, tone: _in, onTap: () => _trustSheet(isDark, _m(inc['trust']))),
      ]),
      // ------------------------------------------------ المصروفات والتكاليف
      _title(isDark, 'المصروفات والتكاليف'),
      _grid([
        _tile(isDark, 'المصروفات', _n(exp['variable']) + _n(pay['advance']) + _n(pay['workExpense']), Icons.receipt_long_outlined, tone: _out,
            onTap: () => _expensesSheet(isDark, exp)),
        _tile(isDark, 'المرتبات', pay['salary'], Icons.groups_outlined, tone: _out, onTap: det('salaries_paid', 'مرتبات اتصرفت')),
        _tile(isDark, 'عمولات الموظفين', pay['commission'], Icons.monetization_on_outlined, tone: _out),
        _tile(isDark, 'المصروفات الثابتة', exp['fixed'], Icons.calendar_month_outlined, tone: _out, onTap: () => _expensesSheet(isDark, exp)),
      ]),
      // ------------------------------------------------ تكلفة تشغيل الشهر
      if (hasDash) ...[
        _title(isDark, 'تكلفة تشغيل الشهر'),
        _operating(isDark, op, av),
      ],
      // ------------------------------------------------ صافي ربح المكتب
      if (_office && _o['result'] is Map) ...[
        _title(isDark, 'صافي ربح المكتب'),
        _result(isDark, _m(_o['result'])),
      ],
      if (hasDash) ...[
        // ------------------------------------------------ ملخص الموظفين
        _title(isDark, 'ملخص الموظفين'),
        _grid([
          _tile(isDark, 'المرتبات المستحقة', hr['salariesDue'], Icons.payments_outlined, onTap: det('salaries', 'مرتبات الشهر')),
          _tile(isDark, 'مرتبات اتصرفت', hr['salariesPaid'], Icons.price_check_rounded, tone: _out, onTap: det('salaries_paid', 'مرتبات اتصرفت')),
          _tile(isDark, 'باقي المرتبات', hr['salariesRemaining'], Icons.hourglass_bottom_rounded, onTap: det('salaries', 'مرتبات الشهر')),
          _tile(isDark, 'سلف مستحقة الخصم', hr['outstandingAdvances'], Icons.request_quote_outlined, onTap: det('advances', 'سلف لسه هتتخصم')),
        ]),
        // ------------------------------------------------ تفاصيل الحركات
        _title(isDark, 'تفاصيل الحركات'),
        _grid([
          _tile(isDark, 'التحصيلات', hr['collections'], Icons.savings_outlined, tone: _in, onTap: det('collections', 'تحصيلات الشهر')),
          _tile(isDark, 'مصروفات خزنة المحاسب', hr['expenses'], Icons.receipt_long_outlined, tone: _out, onTap: det('hr_expenses', 'مصروفات خزنة المحاسب')),
          if (mg.isNotEmpty) _tile(isDark, 'مصروفات المكتب', mg['officeExpenses'], Icons.business_center_outlined, tone: _out,
              onTap: det('office_expenses', 'مصروفات المكتب')),
          _tile(isDark, 'عمولات مستنية الصرف', hr['commissionsAwaitingPayment'], Icons.workspace_premium_outlined,
              onTap: det('commissions_unpaid', 'عمولات مستنية الصرف')),
        ]),
        // ------------------------------------------------ الأقساط والمبيعات
        _title(isDark, 'الأقساط والمبيعات'),
        _grid([
          if (mg.isNotEmpty) _tile(isDark, 'حجوزات', mg['reservations'], Icons.bookmark_added_outlined, tone: _in, onTap: det('reservations', 'الحجوزات (العربون)')),
          if (mg.isNotEmpty) _tile(isDark, 'تعاقدات', mg['contracts'], Icons.handshake_outlined, tone: _in, onTap: det('contracts', 'التعاقدات (المقدمات)')),
          _tile(isDark, 'مستحق خلال أسبوع (${week['count'] ?? 0})', week['amount'], Icons.event_available_outlined, onTap: det('installments_week', 'أقساط مستحقة خلال أسبوع')),
          if (mg.isNotEmpty) _tile(isDark, 'أقساط اتحصلت', mg['installmentsCollected'], Icons.check_circle_outline_rounded, tone: _in,
              onTap: det('installments_collected', 'الأقساط المحصّلة')),
          if (mg.isNotEmpty) _tile(isDark, 'باقي على الوحدات', mg['unitsRemaining'], Icons.home_work_outlined, onTap: det('units_remaining', 'الباقي على الوحدات')),
          _tile(isDark, 'متأخر (${overdue['count'] ?? 0})', overdue['amount'], Icons.warning_amber_rounded, tone: _n(overdue['amount']) > 0 ? _out : null,
              onTap: det('installments_overdue', 'أقساط متأخرة')),
        ]),
        if (mg.isNotEmpty) ...[
          // ------------------------------------------------ الإدارة
          _title(isDark, 'الإدارة'),
          _grid([
            _tile(isDark, 'عمولات الشهر', mg['commissions'], Icons.workspace_premium_outlined, onTap: det('commissions', 'عمولات الشهر')),
            _tile(isDark, 'تحويلات مفتوحة', mg['transfersOpen'], Icons.swap_horiz_rounded, money: false, onTap: det('transfers_open', 'تحويلات مفتوحة')),
          ]),
        ],
      ],
      // ------------------------------------------------ إجراءات الخزنة
      _title(isDark, 'إجراءات الخزنة'),
      _grid([
        _act(isDark, 'إضافة تحصيل', Icons.add_circle_outline_rounded, () => widget.onGo?.call('receipts')),
        _act(isDark, 'إضافة مصروف', Icons.remove_circle_outline_rounded, () => widget.onGo?.call('expenses')),
        _act(isDark, 'تحويل بين الخزائن', Icons.swap_horiz_rounded, () => widget.onGo?.call('transfers')),
        if (_office) _act(isDark, 'توريد / سحب بنك', Icons.account_balance_outlined, () async {
          await showBankMoveSheet(context, isDark);
          await _changed();
        }),
        if (_office) _act(isDark, 'ضخ أموال', Icons.account_balance_wallet_outlined, () async {
          await showInjectSheet(context, isDark);
          await _changed();
        }),
        if (_office) _act(isDark, 'سحب أرباح', Icons.outbox_outlined, () async {
          await showOwnerDrawSheet(context, isDark);
          await _changed();
        }),
      ]),
      const SizedBox(height: 6),
    ]);
  }

  // ------------------------------------------------------------------ one look for every box (the colour is only the figure's)
  static const Color _in = Ar.green;
  static const Color _out = Ar.red;

  Widget _grid(List<Widget> boxes, {int phone = 2}) => JphUi.statGrid(boxes, phone: phone);

  Widget _tile(bool isDark, String label, Object? v, IconData icon, {Color? tone, VoidCallback? onTap, bool money = true}) {
    final box = Container(
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 20, color: JphUi.sub(isDark)),
        const SizedBox(height: 8),
        Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: JphUi.sub(isDark))),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: CountUpText(money ? JphUi.money(v) : '${v ?? 0}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: tone ?? JphUi.text(isDark))),
        ),
      ]),
    );
    return onTap == null ? box : GestureDetector(onTap: onTap, child: box);
  }

  Widget _act(bool isDark, String label, IconData icon, VoidCallback onTap) {
    final p = JphUi.primary(isDark);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [p, Color.lerp(p, Colors.black, 0.3)!]),
          boxShadow: [BoxShadow(color: p.withOpacity(0.25), blurRadius: 12, offset: const Offset(0, 6))],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 22, color: Colors.white),
          const SizedBox(height: 10),
          Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Colors.white)),
        ]),
      ),
    );
  }

  /// the big orange card (the old design): its boxes are white glass inside it
  Widget _orange(bool isDark, List<Widget> children) {
    final p = JphUi.primary(isDark);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: [p, Color.lerp(p, Colors.black, 0.35)!]),
        boxShadow: [BoxShadow(color: p.withOpacity(0.3), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(height: 10), c],
      ]),
    );
  }

  /// one box inside the orange card; [sub] is a line under the figure
  Widget _piece(String label, Object? v, {IconData? icon, String? sub, double size = 19, String? prefix}) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.14), borderRadius: BorderRadius.circular(16)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            if (icon != null) ...[Icon(icon, color: Colors.white70, size: 18), const SizedBox(width: 6)],
            Expanded(child: Text(label, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700, fontSize: 13))),
          ]),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: CountUpText('${prefix ?? ''}${JphUi.money(v)}', style: TextStyle(color: Colors.white, fontSize: size, fontWeight: FontWeight.w900)),
          ),
          if (sub != null) ...[
            const SizedBox(height: 2),
            Text(sub, style: const TextStyle(color: Colors.white70, fontSize: 11.5)),
          ],
        ]),
      );

  Widget _two(Widget a, Widget b) => IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [Expanded(child: a), const SizedBox(width: 10), Expanded(child: b)]),
      );

  Widget _title(bool isDark, String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
        child: Text(t, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      );

  Widget _liquidity(bool isDark, Map<String, dynamic> av) {
    final hr = _m(av['hr']), office = _m(av['office']);
    final full = _office && av['total'] != null;
    return _orange(isDark, [
      _piece(full ? 'إجمالي السيولة' : 'خزنة المحاسب', full ? av['total'] : hr['total'], icon: Icons.account_balance_wallet_rounded, size: 30),
      _two(_piece('البنك', full ? av['bank'] : hr['bank'], icon: Icons.account_balance_rounded),
          _piece('النقدي', full ? av['cash'] : hr['cash'], icon: Icons.payments_rounded)),
      if (full && av['afterTrust'] != null)
        _two(_piece('أمانات المشاريع', av['trust'], icon: Icons.real_estate_agent_rounded),
            _piece('المتاح بعد الأمانة', av['afterTrust'], icon: Icons.verified_rounded)),
      if (full)
        _two(_piece('خزنة المكتب', office['cash'], icon: Icons.business_center_rounded),
            _piece('خزنة المحاسب', hr['cash'], icon: Icons.badge_rounded)),
    ]);
  }

  /// تكلفة تشغيل الشهر: المصروفات الثابتة + المرتبات (قبل أي خصم), what was paid, what is left, and whether the money covers it
  Widget _operating(bool isDark, Map<String, dynamic> op, Map<String, dynamic> av) {
    final remaining = _n(op['remaining']);
    final cover = (_office ? _n(av['afterTrust'] ?? av['total']) : _n(_m(av['hr'])['total'])) - remaining;
    return _orange(isDark, [
      _piece('إجمالي تكلفة تشغيل الشهر', op['total'], icon: Icons.summarize_rounded, size: 28, sub: 'إجمالي الالتزامات التشغيلية للشهر'),
      _two(_piece('المصروفات الثابتة', op['fixed'], icon: Icons.calendar_month_rounded, sub: 'الإيجار والخدمات والفواتير'),
          GestureDetector(
            onTap: () => widget.onDetails?.call('salaries_gross', 'المرتبات قبل أي خصم'),
            child: _piece('المرتبات', op['salaries'], icon: Icons.groups_rounded, sub: 'كل مرتبات الموظفين قبل أي خصومات — دوس للتفاصيل'),
          )),
      _two(_piece('تم دفعه', op['paid'], icon: Icons.check_circle_rounded), _piece('متبقي دفعه', op['remaining'], icon: Icons.hourglass_bottom_rounded)),
      _piece('المبلغ المطلوب توفيره لباقي الشهر', remaining, icon: Icons.savings_rounded, size: 24,
          sub: 'الالتزامات التشغيلية المستحقة وغير المدفوعة حتى نهاية الشهر'),
      _piece(cover >= 0 ? 'فائض التغطية' : 'عجز التغطية', cover.abs(), icon: cover >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded,
          size: 24, prefix: cover >= 0 ? '+' : '−',
          sub: _office ? 'المتاح بعد الأمانة − المطلوب توفيره' : 'رصيد خزنة المحاسب − المطلوب توفيره'),
    ]);
  }

  /// what is behind «المصروفات» / «المصروفات الثابتة»
  void _expensesSheet(bool isDark, Map<String, dynamic> exp) {
    final pay = _m(exp['payroll']);
    _sheet(isDark, 'المصروفات', [
      _row(isDark, 'المرتبات', pay['salary'], color: _out),
      if (_n(pay['commission']) > 0) _row(isDark, 'عمولات اتصرفت للموظفين', pay['commission'], color: _out),
      if (_n(pay['advance']) > 0) _row(isDark, 'سلف', pay['advance'], color: _out),
      if (_n(pay['workExpense']) > 0) _row(isDark, 'مصاريف عمل', pay['workExpense'], color: _out),
      for (final c in _l(exp['byCategory'])) _row(isDark, '${c['name']}', c['amount'], color: _out),
      if (_n(exp['fixed']) > 0) _row(isDark, 'منها مصروفات ثابتة', exp['fixed']),
      const Divider(),
      _row(isDark, 'الإجمالي', exp['total'], bold: true, color: _out),
      if (_n(exp['ownerDraws']) > 0) _row(isDark, 'مسحوبات الملاك (مش مصروف)', exp['ownerDraws']),
    ]);
  }

  Widget _row(bool isDark, String k, Object? v, {Color? color, bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(child: Text(k, style: TextStyle(fontSize: 14, color: bold ? JphUi.text(isDark) : JphUi.sub(isDark), fontWeight: bold ? FontWeight.w800 : FontWeight.w500))),
          CountUpText(JphUi.money(v), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: color ?? JphUi.text(isDark))),
        ]),
      );

  Widget _result(bool isDark, Map<String, dynamic> r) {
    final net = _n(r['net']);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(net >= 0 ? 'صافي الربح النقدي' : 'عجز — محتاج ضخ', style: TextStyle(color: JphUi.sub(isDark), fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: CountUpText(JphUi.money(net.abs()), style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: net >= 0 ? _in : _out)),
        ),
        const SizedBox(height: 8),
        _row(isDark, 'العمولات المحصلة', r['commissions'], color: _in),
        _row(isDark, 'المرتبات والمصاريف المدفوعة', r['costs'], color: _out),
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
  Future<void> _sheet(bool isDark, String title, List<Widget> rows) => showAppSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => Directionality(
          textDirection: ui.TextDirection.rtl,
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(18),
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
            decoration: Glass.sheet(isDark, r: 24),
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
        if ((num.tryParse('${s['refunded'] ?? 0}') ?? 0) > 0) _row(isDark, 'استرداد وحدات للعملاء (مش مصروف)', s['refunded'], color: Ar.red),
        const SizedBox(height: 8),
        Text('فلوس الوحدات مش ربح: الحصري منها أمانة للمالك، والربح هو العمولة بس.', style: TextStyle(color: JphUi.sub(isDark))),
      ]);

  // ------------------------------------------------------------------ خزنة المشاريع / العمولات / عمولات متوقعة
  /// Three tiles above the income; each opens its own page with the full details.
  Widget _projectsCards(bool isDark) {
    final box = _m(_o['projectsBox']), cm = _m(_o['commissions']), ex = _m(_o['expectedCommissions']);
    Future<void> open(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page)).then((_) => _load());
    return _grid([
      _tile(isDark, 'خزنة المشاريع', box['total'], Icons.apartment_rounded, onTap: () => open(ProjectsBoxPage(month: _filter))),
      _tile(isDark, 'عمولات متبقية', cm['remaining'], Icons.schedule_rounded, onTap: () => open(CommissionsDuePage(month: _filter))),
      _tile(isDark, 'عمولات متوقعة', ex['total'], Icons.trending_up_rounded, onTap: () => open(ExpectedCommissionsPage(month: _filter))),
    ], phone: 3);
  }

  String _monthName(String ym) {
    if (ym.length < 7) return 'من غير تاريخ متوقع';
    final m = int.tryParse(ym.substring(5, 7)) ?? 1;
    return '${JphUi.monthsAr[m - 1]} ${ym.substring(0, 4)}';
  }

  void _trustSheet(bool isDark, Map<String, dynamic> t) => _sheet(isDark, 'الأمانات — فلوس ملاك المشاريع الحصري', [
        _row(isDark, 'دخل الشهر (حجز / تعاقد / أقساط)', t['in'], color: Ar.green),
        _row(isDark, 'خرج الشهر (صرف للمالك / رد عربون)', t['out'], color: Ar.red),
        _row(isDark, 'عمولة اتحوّلت للمكتب الشهر ده', t['commissionMoved'], color: Ar.amber.shade800),
        const Divider(),
        _row(isDark, 'في الأمانة دلوقتي (كل المشاريع)', t['balance'], bold: true),
        const SizedBox(height: 8),
        Text('الأمانة بتطلع لمالك المشروع بإذن صرف من صفحة المشروع.', style: TextStyle(color: JphUi.sub(isDark))),
      ]);

  void _commissionSheet(bool isDark) {
    final inc = _m(_o['income']);
    final sp = _m(_o['commissionSplit']);
    _sheet(isDark, 'العمولات', [
      _row(isDark, 'عمولة مستلمة من المطورين', inc['commissionReceived'], color: Ar.green),
      _row(isDark, 'عمولة اتحوّلت من أمانات الحصري', _m(inc['trust'])['commissionMoved'], color: Ar.green),
      const Divider(),
      _row(isDark, 'دخل العمولات', inc['commissions'], bold: true),
      const SizedBox(height: 14),
      Text('تقسيم عمولات صفقات الشهر (${sp['deals'] ?? 0} صفقة)', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      const SizedBox(height: 6),
      _row(isDark, 'السيلز', sp['sales']),
      _row(isDark, 'مدير السيلز', sp['manager']),
      _row(isDark, 'شركات التسويق', sp['marketing']),
      _row(isDark, 'المكتب', sp['office'], color: Ar.green),
      const Divider(),
      _row(isDark, 'إجمالي العمولة', sp['total'], bold: true),
    ]);
  }

  // ------------------------------------------------------------------ actions
  Future<void> _commissionIn(bool isDark) async {
    final pr = await ApiService.post({'action': 'cash_get', 'path': '/exclusive/projects', 'query': {'kind': 'marketing'}});
    if (!mounted) return;
    final projects = _l(pr['projects']);
    Map<String, dynamic>? project;
    String method = 'bank_transfer';
    final amount = TextEditingController(), payer = TextEditingController(), unit = TextEditingController();
    await showAppSheet<void>(
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
              decoration: Glass.sheet(isDark, r: 24),
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


/// ضخ أموال — المالك / المدير العام puts money in (نقدي مكتب / خزنة المحاسب / بنك).
Future<void> showInjectSheet(BuildContext context, bool isDark) async {
    String target = 'office';
    final amount = TextEditingController(), note = TextEditingController();
    final ref = newClientRef(); // pressing the button twice records one injection
    await showAppSheet<void>(
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
              decoration: Glass.sheet(isDark, r: 24),
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('ضخ فلوس في الشركة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  const SizedBox(height: 4),
                  Text('لما الشركة متجيبش أرباح تكفي المرتبات والمصاريف', style: TextStyle(color: JphUi.sub(isDark))),
                  const SizedBox(height: 14),
                  // the same bar as the home's الحضور / الاستراحة / الإجازة
                  JphUi.tabs(isDark, const [('البنك', Icons.account_balance_rounded), ('خزنة المكتب', Icons.business_center_rounded)],
                      const ['bank', 'office'].indexOf(target), (i) => set(() => target = const ['bank', 'office'][i])),
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
}


/// «ضخ أموال» tab (المالك / المدير العام only): every injection, the button, and per owner his share (نسبة الملكية),
/// what he injected, and his part of the office's net profit (commissions after salaries and expenses).
class InjectionsTab extends StatefulWidget {
  final bool isDark;
  final ValueListenable<DateTime>? month;
  final ValueListenable<bool>? allMonths;
  final Future<void> Function()? onChanged;
  const InjectionsTab({super.key, required this.isDark, this.month, this.allMonths, this.onChanged});
  @override
  State<InjectionsTab> createState() => _InjectionsTabState();
}

class _InjectionsTabState extends State<InjectionsTab> {
  Map<String, dynamic>? _d;
  DateTime? get _filter => (widget.allMonths?.value ?? true) ? null : widget.month?.value;

  @override
  void initState() {
    super.initState();
    widget.month?.addListener(_load);
    widget.allMonths?.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.month?.removeListener(_load);
    widget.allMonths?.removeListener(_load);
    super.dispose();
  }

  int _seq = 0;

  Future<void> _load() async {
    final seq = ++_seq;
    final r = await ApiService.post({'action': 'cash_get', 'path': '/cash/injections', 'query': monthQuery(_filter)});
    if (mounted && seq == _seq) setState(() => _d = r);
  }

  Future<void> _shares(bool isDark) async {
    final owners = _l(_d?['owners']);
    final ctrls = {for (final o in owners) '${o['id']}': TextEditingController(text: _n(o['pct']) == 0 ? '' : '${o['pct']}')};
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(18),
            decoration: Glass.sheet(isDark, r: 24),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('نسب الملكية في الشركة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                const SizedBox(height: 12),
                for (final o in owners) ...[
                  JphUi.input(isDark: isDark, label: '${o['name']} ٪', controller: ctrls['${o['id']}']!, number: true, icon: Icons.pie_chart_rounded),
                  const SizedBox(height: 10),
                ],
                SizedBox(
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: () async {
                      final r = await ApiService.post({'action': 'cash_post', 'method': 'put', 'path': '/cash/owners', 'ok': 'اتحفظت النسب ✅', 'body': {
                        'owners': [for (final e in ctrls.entries) {'employeeId': e.key, 'pct': num.tryParse(e.value.text) ?? 0}],
                      }});
                      if (ctx.mounted) JphUi.toast(ctx, r);
                      if (r['success'] == true && ctx.mounted) Navigator.pop(ctx);
                    },
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('حفظ', style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
    _load();
  }

  /// my own account (only the owners have one): what I can still withdraw
  Map<String, dynamic>? get _myAccount {
    final d = _d;
    if (d == null) return null;
    for (final o in _l(d['owners'])) {
      if (o['id'] == d['me'] && o['account'] is Map) return _m(o['account']);
    }
    return null;
  }

  /// سحب أرباح: from my account, waits for another owner's approval
  Future<void> _draw(bool isDark) async {
    await showOwnerDrawSheet(context, isDark, account: _myAccount);
    await _load();
    await widget.onChanged?.call();
  }

  Future<void> _decide(Map<String, dynamic> x, bool approve) async {
    final r = await ApiService.post({'action': 'cash_post', 'path': '/cash/expenses/${x['id']}/decision', 'ok': approve ? 'اتوافق على السحب ✅' : 'اترفض',
      'body': {'decision': approve ? 'approve' : 'reject', if (!approve) 'reason': 'مرفوض من المالك'}});
    if (mounted) JphUi.toast(context, r);
    await _load();
    await widget.onChanged?.call();
  }

  Widget _drawRow(bool isDark, Map<String, dynamic> x) {
    final st = '${x['status']}';
    final (label, color) = switch (st) {
      'posted' => ('اتصرف', Ar.green),
      'pending_approval' => ('مستني موافقة مالك تاني', Ar.amber),
      'rejected' => ('مرفوض', Ar.red),
      _ => ('ملغي', Ar.grey),
    };
    final at = '${x['at'] ?? ''}';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          JphUi.iconTile(isDark, Icons.outbox_rounded, color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${x['ownerName']} — ${x['method'] == 'bank' ? 'من البنك' : 'من خزنة المكتب'}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              Text('${at.length >= 10 ? at.substring(0, 10) : ''}${'${x['note'] ?? ''}'.isEmpty ? '' : ' · ${x['note']}'}'
                  '${x['approvedByName'] != null && st == 'posted' ? ' · وافق ${x['approvedByName']}' : ''}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            CountUpText(JphUi.money(x['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            JphUi.chip(label, color),
          ]),
        ]),
        if (x['canDecide'] == true) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: FilledButton(onPressed: () => _decide(x, true), child: const Text('موافقة'))),
            const SizedBox(width: 10),
            Expanded(child: OutlinedButton(onPressed: () => _decide(x, false), child: const Text('رفض'))),
          ]),
        ],
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final d = _d;
    if (d == null) return const Center(child: CircularProgressIndicator());
    if (d['success'] != true) return Center(child: Text('${d['message'] ?? 'مش متاح'}', style: TextStyle(color: JphUi.sub(isDark))));
    final owners = _l(d['owners']);
    final net = _n(d['net']);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 56,
              child: ElevatedButton.icon(
                onPressed: () async {
                  await showInjectSheet(context, isDark);
                  await _load();
                  await widget.onChanged?.call();
                },
                icon: const Icon(Icons.add_card_rounded),
                label: const Text('ضخ أموال', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
              ),
            ),
          ),
          if (_myAccount != null) ...[
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 56,
                child: OutlinedButton.icon(
                  onPressed: () => _draw(isDark),
                  icon: const Icon(Icons.outbox_rounded),
                  label: const Text('سحب أرباح', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                  style: OutlinedButton.styleFrom(side: BorderSide(color: JphUi.primary(isDark), width: 1.4),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
                ),
              ),
            ),
          ],
        ]),
        const SizedBox(height: 14),
        Text(monthLabel(_filter), textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.sub(isDark))),
        const SizedBox(height: 8),
        JphUi.statGrid([
          JphUi.stat(isDark, 'إجمالي الضخ', JphUi.money(d['total']), Icons.add_card_rounded, Ar.accent),
          JphUi.stat(isDark, net >= 0 ? 'صافي ربح المكتب' : 'عجز المكتب', JphUi.money(net.abs()), net >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded,
              net >= 0 ? Ar.green : Ar.red),
        ]),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(child: Text('الملاك', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
          TextButton.icon(onPressed: () => _shares(isDark), icon: const Icon(Icons.pie_chart_rounded), label: const Text('نسب الملكية')),
        ]),
        for (final o in owners) ...[
          Text('${o['name']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
          const SizedBox(height: 6),
          JphUi.statGrid([
            JphUi.stat(isDark, 'نسبة الملكية', JphUi.pct(o['pct']), Icons.pie_chart_rounded, Ar.accent),
            JphUi.stat(isDark, _n(o['profit']) >= 0 ? 'ربحه من صافي العمولة' : 'نصيبه من العجز', JphUi.money(_n(o['profit']).abs()),
                Icons.workspace_premium_rounded, _n(o['profit']) >= 0 ? Ar.green : Ar.red),
            JphUi.stat(isDark, 'ضخ', JphUi.money(o['injected']), Icons.add_card_rounded, Ar.accent),
            JphUi.stat(isDark, 'إجمالي ضخه (كل الشهور)', JphUi.money(o['injectedAllTime']), Icons.savings_rounded, Ar.green),
            JphUi.stat(isDark, 'مسحوباته', JphUi.money(o['withdrawn']), Icons.outbox_rounded, Ar.amber),
            if (o['account'] is Map)
              JphUi.stat(isDark, 'رصيد حسابه (يقدر يسحب)', JphUi.money(_m(o['account'])['balance']), Icons.account_balance_wallet_rounded, Ar.green),
          ]),
          const SizedBox(height: 14),
        ],
        Text('صافي الربح = العمولات ${JphUi.money(d['commissions'])} − المرتبات والمصروفات ${JphUi.money(d['costs'])}',
            style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
        const SizedBox(height: 14),
        if (_l(d['draws']).isNotEmpty) ...[
          Text('مسحوبات الملاك', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
          const SizedBox(height: 8),
          for (final x in _l(d['draws'])) _drawRow(isDark, x),
          const SizedBox(height: 14),
        ],
        Text('كل الضخ', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
        const SizedBox(height: 8),
        if (_l(d['injections']).isEmpty)
          Padding(padding: const EdgeInsets.all(24), child: Text('مفيش ضخ', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final x in _l(d['injections']))
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: JphUi.box(isDark),
            child: Row(children: [
              JphUi.iconTile(isDark, Icons.add_card_rounded, x['status'] == 'posted' ? Ar.accent : Ar.grey),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${x['byName']} → ${x['target']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                  Text('${x['receiptNo']} · ${'${x['at'] ?? ''}'.length >= 10 ? '${x['at']}'.substring(0, 10) : ''}${'${x['note'] ?? ''}'.isEmpty ? '' : ' · ${x['note']}'}'
                      '${x['status'] == 'posted' ? '' : ' · ملغي'}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                ]),
              ),
              CountUpText(JphUi.money(x['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            ]),
          ),
      ]),
    );
  }
}

/// سحب أرباح (from the injections page or إجراءات الخزنة): from my account, waits for another owner's approval.
Future<void> showOwnerDrawSheet(BuildContext context, bool isDark, {Map<String, dynamic>? account}) async {
    var acc = account;
    if (acc == null) {
      final r = await ApiService.post({'action': 'cash_get', 'path': '/cash/injections'});
      for (final o in _l(r['owners'])) {
        if (o['id'] == r['me'] && o['account'] is Map) acc = _m(o['account']);
      }
      if (acc == null) {
        if (context.mounted) JphUi.toast(context, {'success': false, 'message': 'سحب الأرباح للملاك بس'});
        return;
      }
    }
    final Map<String, dynamic> me = acc;
    final amount = TextEditingController(), note = TextEditingController();
    var bank = false;
    final ref = newClientRef();
    await showAppSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: StatefulBuilder(builder: (ctx, set) => Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(18),
                decoration: Glass.sheet(isDark, r: 24),
                child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text('سحب أرباح', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    const SizedBox(height: 4),
                    Text('رصيد حسابك ${JphUi.money(me['balance'])} — السحب بيتنفذ بعد موافقة مالك تاني', style: TextStyle(color: JphUi.sub(isDark))),
                    const SizedBox(height: 14),
                    JphUi.tabs(isDark, const [('خزنة المكتب (نقدي)', Icons.business_center_rounded), ('البنك', Icons.account_balance_rounded)], bank ? 1 : 0,
                        (i) => set(() => bank = i == 1)),
                    const SizedBox(height: 12),
                    JphUi.input(isDark: isDark, label: 'المبلغ', controller: amount, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
                    const SizedBox(height: 10),
                    JphUi.input(isDark: isDark, label: 'ملاحظة', controller: note, icon: Icons.notes_rounded),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 50,
                      child: FilledButton.icon(
                        onPressed: () async {
                          final r = await ApiService.post({'action': 'cash_post', 'path': '/cash/owner-draws', 'ok': 'اتبعت للموافقة ✅', 'body': {
                            'amount': num.tryParse(amount.text.replaceAll(',', '')), 'paymentMethod': bank ? 'bank' : 'cash', 'note': note.text.trim(), 'clientRef': ref,
                          }});
                          if (ctx.mounted) JphUi.toast(ctx, r);
                          if (r['success'] == true && ctx.mounted) Navigator.pop(ctx);
                        },
                        icon: const Icon(Icons.check_rounded),
                        label: const Text('طلب السحب', style: TextStyle(fontWeight: FontWeight.w800)),
                      ),
                    ),
                  ]),
                ),
              ),
            )),
      ),
    );
}

