import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../widgets/jph_form_ui.dart';
import '../cash/cash_page.dart';
import '../cash/cashbox_hub_page.dart';
import '../commissions/commissions_page.dart';
import '../finance/finance_dashboard_page.dart';
import '../notifications/Send_Notifications_Page.dart';
import '../sales/sales_page.dart';
import '../attendance/attendance_report_page.dart';

/// The home of المالك / المدير العام — laid out like a full overview dashboard (greeting → actions → 4 KPIs →
/// money chart → approvals line → top sales → latest requests → cashboxes → payroll → coming up → needs attention
/// → last activity), in the app's own look. Every card leads to its page. Data: GET /dashboard/owner (one call).
class OwnerOverview extends StatefulWidget {
  final bool isDark;
  final Widget header;
  final String uid, name, role;
  /// the attendance & requests view (the previous home) — still one tap away
  final VoidCallback onOpenClassic;
  const OwnerOverview({super.key, required this.isDark, required this.header, required this.uid, required this.name,
      required this.role, required this.onOpenClassic});

  @override
  State<OwnerOverview> createState() => _OwnerOverviewState();
}

class _OwnerOverviewState extends State<OwnerOverview> {
  Map<String, dynamic>? _d;
  String? _error;
  int _range = 14;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'owner_dashboard', 'range': _range});
    if (!mounted) return;
    setState(() {
      if (r['success'] == true) {
        _d = r;
        _error = null;
      } else {
        _error = '${r['message'] ?? 'مش قادر أحمّل البيانات'}';
      }
    });
  }

  bool get _dark => widget.isDark;
  Color get _text => JphUi.text(_dark);
  Color get _sub => JphUi.sub(_dark);
  Color get _primary => JphUi.primary(_dark);
  Map<String, dynamic> _m(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
  List<Map<String, dynamic>> _l(Object? v) => ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  num _n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
  String _money(Object? v) => JphUi.money(v);
  String _short(num v) {
    final a = v.abs();
    final s = a >= 1e6 ? '${(a / 1e6).toStringAsFixed(a >= 1e7 ? 0 : 1)}م' : a >= 1e3 ? '${(a / 1e3).toStringAsFixed(a >= 1e4 ? 0 : 1)}ك' : a.toStringAsFixed(0);
    return v < 0 ? '-$s' : s;
  }

  void _open(Widget page) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    _load();
  }

  Widget _card({required Widget child, EdgeInsets padding = const EdgeInsets.all(16), Gradient? gradient}) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: padding,
        decoration: gradient == null ? JphUi.box(_dark) : JphUi.box(_dark).copyWith(gradient: gradient, border: null),
        child: child,
      );

  Widget _title(String t, String sub, {String? action, VoidCallback? onTap}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: _text)),
              if (sub.isNotEmpty) Text(sub, style: TextStyle(fontSize: 12.5, color: _sub)),
            ]),
          ),
          if (action != null)
            TextButton(onPressed: onTap, child: Text(action, style: TextStyle(fontWeight: FontWeight.w800, color: _primary))),
        ]),
      );

  // ------------------------------------------------------------------ 2. greeting
  Widget _greeting() {
    final s = _m(_d!['summary']);
    final h = DateTime.now().hour;
    final first = '${_d!['name'] ?? widget.name}'.split(' ').first;
    final parts = <String>[
      'حاضر النهارده ${s['present']} من ${s['employees']}',
      if (_n(s['awaiting']) > 0) '${s['awaiting']} طلب مستني موافقتك',
      if (_n(s['installmentsToday']) > 0) '${s['installmentsToday']} قسط مستحق النهارده',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(h < 12 ? 'صباح الخير يا $first' : 'مساء الخير يا $first',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: _text)),
        const SizedBox(height: 4),
        Text(parts.join(' · '), style: TextStyle(fontSize: 14, height: 1.5, color: _sub)),
      ]),
    );
  }

  // ------------------------------------------------------------------ 3. actions
  Widget _actions() => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _open(const FinanceDashboardPage()),
              icon: const Icon(Icons.bar_chart_rounded),
              label: const Text('التقرير المالي'),
              style: OutlinedButton.styleFrom(
                foregroundColor: _text, minimumSize: const Size.fromHeight(50),
                side: BorderSide(color: _dark ? Colors.white24 : Colors.grey.shade300),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: ElevatedButton.icon(
              onPressed: _quickAction,
              icon: const Icon(Icons.add_rounded),
              label: const Text('إجراء سريع'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
              ),
            ),
          ),
        ]),
      );

  Future<void> _quickAction() async {
    final v = await JphUi.sheet<String>(context, _dark, 'إجراء سريع', [
      ('sale', 'بيع وحدة', Icons.home_work_rounded),
      ('cash', 'مصروف / توريد / تحصيل', Icons.account_balance_wallet_rounded),
      ('finance', 'السلف والمرتبات والعمولات', Icons.payments_rounded),
      ('notify', 'إرسال إشعار', Icons.campaign_rounded),
      ('classic', 'الحضور والطلبات', Icons.fact_check_rounded),
    ]);
    if (!mounted || v == null) return;
    switch (v) {
      case 'sale':
        _open(const SalesPage());
      case 'cash':
        _open(const CashPage());
      case 'finance':
        _open(CashboxHubPage(uid: widget.uid, name: widget.name, role: widget.role));
      case 'notify':
        _open(SendNotificationsPage(uid: widget.uid, name: widget.name, role: widget.role));
      case 'classic':
        widget.onOpenClassic();
    }
  }

  // ------------------------------------------------------------------ 4. KPIs
  Widget _kpis() {
    final k = _m(_d!['kpis']);
    final coll = _m(k['collections']), net = _m(k['net']), cash = _m(k['cash']), att = _m(k['attendance']);
    final prev = _n(coll['prev']), cur = _n(coll['month']);
    final change = prev > 0 ? ((cur - prev) / prev * 100).round() : null;
    final pct = (_n(att['pct']) / 100).clamp(0, 1).toDouble();
    Widget small(String label, String value, IconData icon, Color color, String foot, VoidCallback onTap) => Expanded(
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              height: 132,
              padding: const EdgeInsets.all(14),
              decoration: JphUi.box(_dark),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [Icon(icon, size: 18, color: color), const SizedBox(width: 6), Expanded(child: Text(label, style: TextStyle(color: _sub, fontWeight: FontWeight.w700)))]),
                const Spacer(),
                FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart,
                    child: Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _text))),
                const SizedBox(height: 6),
                Text(foot, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: _sub)),
              ]),
            ),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(children: [
        Row(children: [
          // the highlighted one: this month's collections vs last month
          Expanded(
            child: GestureDetector(
              onTap: () => _open(const CashPage()),
              child: Container(
                height: 132,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(20),
                  gradient: LinearGradient(colors: [_primary, _primary.withOpacity(0.75)], begin: Alignment.topRight, end: Alignment.bottomLeft),
                  boxShadow: [BoxShadow(color: _primary.withOpacity(0.35), blurRadius: 16, offset: const Offset(0, 6))],
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Row(children: [
                    Icon(Icons.trending_up_rounded, size: 18, color: Colors.white),
                    SizedBox(width: 6),
                    Expanded(child: Text('تحصيل الشهر', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800))),
                  ]),
                  const Spacer(),
                  FittedBox(fit: BoxFit.scaleDown, alignment: AlignmentDirectional.centerStart,
                      child: Text(_money(cur), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.white))),
                  const SizedBox(height: 6),
                  Text(change == null ? 'الشهر اللي فات: ${_money(prev)}' : '${change >= 0 ? '↑' : '↓'} ${change.abs()}٪ عن الشهر اللي فات',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white)),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 10),
          small('صافي ربح الشهر', _money(net['net']), Icons.savings_rounded, _n(net['net']) >= 0 ? Colors.green : Colors.red,
              'عمولات ${_short(_n(net['income']))} − رواتب ومصاريف ${_short(_n(net['salaries']) + _n(net['expenses']))}',
              () => _open(const FinanceDashboardPage())),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          small('رصيد الخزن', _money(cash['total']), Icons.account_balance_rounded, Colors.indigo,
              'المكتب ${_short(_n(cash['office']))} · المحاسب ${_short(_n(cash['accountant']))}', () => _open(const CashPage())),
          const SizedBox(width: 10),
          Expanded(
            child: GestureDetector(
              onTap: widget.onOpenClassic,
              child: Container(
                height: 132,
                padding: const EdgeInsets.all(14),
                decoration: JphUi.box(_dark),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [const Icon(Icons.how_to_reg_rounded, size: 18, color: Colors.teal), const SizedBox(width: 6),
                    Expanded(child: Text('الحضور النهارده', style: TextStyle(color: _sub, fontWeight: FontWeight.w700)))]),
                  const Spacer(),
                  Text('${att['pct']}٪', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _text)),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(value: pct, minHeight: 6, color: Colors.teal,
                        backgroundColor: _dark ? Colors.white12 : Colors.grey.shade200),
                  ),
                  const SizedBox(height: 4),
                  Text('${att['present']} من ${att['employees']} · متأخر ${att['late']}', style: TextStyle(fontSize: 12, color: _sub)),
                ]),
              ),
            ),
          ),
        ]),
      ]),
    );
  }

  // ------------------------------------------------------------------ 5. money chart
  Widget _chart() {
    final s = _l(_d!['series']);
    final maxV = s.fold<num>(1, (m, x) => math.max(m, math.max(_n(x['in']), _n(x['out']))));
    final totIn = s.fold<num>(0, (a, x) => a + _n(x['in'])), totOut = s.fold<num>(0, (a, x) => a + _n(x['out']));
    final best = s.isEmpty ? null : s.reduce((a, b) => _n(a['in']) >= _n(b['in']) ? a : b);
    final group = _range > 31 ? 7 : 1; // 13 weeks: one bar per week
    final bars = <Map<String, num>>[];
    for (var i = 0; i < s.length; i += group) {
      final part = s.sublist(i, math.min(i + group, s.length));
      bars.add({'in': part.fold<num>(0, (a, x) => a + _n(x['in'])), 'out': part.fold<num>(0, (a, x) => a + _n(x['out']))});
    }
    final barMax = bars.fold<num>(1, (m, x) => math.max(m, math.max(x['in']!, x['out']!)));
    Widget chip(int v, String label) => Padding(
          padding: const EdgeInsetsDirectional.only(end: 6),
          child: ChoiceChip(
            label: Text(label), selected: _range == v,
            onSelected: (_) { setState(() => _range = v); _load(); },
            selectedColor: _primary.withOpacity(0.18),
            labelStyle: TextStyle(fontWeight: FontWeight.w800, color: _range == v ? _primary : _sub),
          ),
        );
    Widget stat(String l, String v) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l, style: TextStyle(fontSize: 12, color: _sub)),
            FittedBox(fit: BoxFit.scaleDown, child: Text(v, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: _text))),
          ]),
        );
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title('التحصيل مقابل المصروفات', 'كل الخزن — الأخضر داخل، والأحمر خارج', action: 'الخزنة', onTap: () => _open(const CashPage())),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [chip(14, '١٤ يوم'), chip(30, '٣٠ يوم'), chip(91, '١٣ أسبوع')])),
        const SizedBox(height: 12),
        Row(children: [
          stat('دخل', _short(totIn)),
          stat('خرج', _short(totOut)),
          stat('الصافي', _short(totIn - totOut)),
          stat('أعلى يوم', best == null || _n(best['in']) == 0 ? '—' : _short(_n(best['in']))),
        ]),
        const SizedBox(height: 14),
        SizedBox(
          height: 130,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (final b in bars)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(child: _bar(b['in']! / barMax, Colors.green)),
                    const SizedBox(width: 1),
                    Expanded(child: _bar(b['out']! / barMax, Colors.redAccent)),
                  ]),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 6),
        if (s.isNotEmpty)
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(_dayLabel('${s.first['day']}'), style: TextStyle(fontSize: 11, color: _sub)),
            Text(_dayLabel('${s.last['day']}'), style: TextStyle(fontSize: 11, color: _sub)),
          ]),
        if (maxV <= 1) Padding(padding: const EdgeInsets.only(top: 6), child: Text('لسه مفيش حركة فلوس في الفترة دي', style: TextStyle(fontSize: 12, color: _sub))),
      ]),
    );
  }

  Widget _bar(num ratio, Color c) => Container(
        height: math.max(2, 120 * ratio.toDouble()),
        decoration: BoxDecoration(color: c.withOpacity(0.85), borderRadius: const BorderRadius.vertical(top: Radius.circular(4))),
      );

  String _dayLabel(String d) {
    final x = DateTime.tryParse(d);
    return x == null ? d : '${x.day}/${x.month}';
  }

  // ------------------------------------------------------------------ 6. approvals line
  Widget _pipeline() {
    final p = _m(_d!['pipeline']);
    final stages = [
      ('مستني موافقة', p['awaiting'], Icons.hourglass_top_rounded, Colors.orange),
      ('جاهز للصرف', p['toPay'], Icons.payments_rounded, Colors.indigo),
      ('مستني الاستلام', p['awaitingReceipt'], Icons.handshake_rounded, Colors.teal),
      ('اتصرف الشهر ده', p['paid'], Icons.check_circle_rounded, Colors.green),
    ];
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title('خط الموافقات', 'الطلبات والسلف والمصروفات من الطلب للاستلام',
            action: 'فتح', onTap: () => _open(CashboxHubPage(uid: widget.uid, name: widget.name, role: widget.role))),
        Row(children: [
          for (var i = 0; i < stages.length; i++) ...[
            Expanded(
              child: Column(children: [
                JphUi.iconTile(_dark, stages[i].$3, stages[i].$4),
                const SizedBox(height: 6),
                Text('${stages[i].$2 ?? 0}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: _text)),
                Text(stages[i].$1, textAlign: TextAlign.center, style: TextStyle(fontSize: 11.5, color: _sub)),
              ]),
            ),
            if (i < stages.length - 1) Icon(Icons.chevron_left_rounded, color: _sub, size: 18),
          ],
        ]),
      ]),
    );
  }

  // ------------------------------------------------------------------ 7. top sales
  Widget _topSales() {
    final rows = _l(_d!['topSales']);
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title('أفضل السيلز', 'الشهر ده — بقيمة الوحدات', action: 'العمولات', onTap: () => _open(const CommissionsPage())),
        if (rows.isEmpty) Text('لسه مفيش مبيعات متوافق عليها الشهر ده', style: TextStyle(color: _sub)),
        for (var i = 0; i < rows.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              CircleAvatar(radius: 14, backgroundColor: _primary.withOpacity(0.15),
                  child: Text('${i + 1}', style: TextStyle(fontWeight: FontWeight.w900, color: _primary))),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${rows[i]['name']}', style: TextStyle(fontWeight: FontWeight.w800, color: _text)),
                  Text('${rows[i]['units']} وحدة · عمولة ${_money(rows[i]['commission'])}', style: TextStyle(fontSize: 12, color: _sub)),
                ]),
              ),
              Text(_short(_n(rows[i]['value'])), style: TextStyle(fontWeight: FontWeight.w900, color: _text)),
            ]),
          ),
      ]),
    );
  }

  // ------------------------------------------------------------------ 8. latest requests
  static const _kindAr = {'request': 'طلب', 'advance': 'سلفة', 'expense': 'مصروف', 'sale': 'بيع وحدة', 'commission': 'عمولة'};
  static const _whatAr = {
    'full_day_absence': 'إجازة', 'hourly_permission': 'إذن ساعات', 'advance': 'سلفة', 'work_expense': 'مصاريف عمل',
  };

  Widget _latest() {
    final rows = _l(_d!['latest']);
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title('آخر الطلبات', 'مستنية موافقتك', action: 'كل الطلبات', onTap: widget.onOpenClassic),
        if (rows.isEmpty) Text('مفيش حاجة مستنياك 👌', style: TextStyle(color: _sub)),
        for (final x in rows)
          InkWell(
            onTap: () => x['kind'] == 'request'
                ? widget.onOpenClassic()
                : x['kind'] == 'sale'
                    ? _open(const SalesPage())
                    : x['kind'] == 'expense'
                        ? _open(const CashPage())
                        : _open(CashboxHubPage(uid: widget.uid, name: widget.name, role: widget.role)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                JphUi.iconTile(_dark, _kindIcon('${x['kind']}'), Colors.orange),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${x['who']}', style: TextStyle(fontWeight: FontWeight.w800, color: _text)),
                    Text('${_kindAr[x['kind']] ?? ''} · ${_whatAr[x['what']] ?? x['what'] ?? ''} · ${_ago('${x['at']}')}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: _sub)),
                  ]),
                ),
                if (x['amount'] != null) Text(_short(_n(x['amount'])), style: TextStyle(fontWeight: FontWeight.w900, color: _text)),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: Colors.orange.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
                  child: const Text('مستني', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.orange)),
                ),
              ]),
            ),
          ),
      ]),
    );
  }

  IconData _kindIcon(String k) => switch (k) {
        'advance' => Icons.payments_rounded,
        'expense' => Icons.receipt_long_rounded,
        'sale' => Icons.home_work_rounded,
        'commission' => Icons.percent_rounded,
        _ => Icons.event_note_rounded,
      };

  String _ago(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final d = DateTime.now().difference(t.toLocal());
    if (d.inMinutes < 60) return 'من ${math.max(1, d.inMinutes)} دقيقة';
    if (d.inHours < 24) return 'من ${d.inHours} ساعة';
    return 'من ${d.inDays} يوم';
  }

  // ------------------------------------------------------------------ 9. cashboxes
  Widget _wallet() {
    final w = _m(_d!['wallet']);
    final od = _m(w['overdueInstallments']);
    Widget line(String l, Object? v, {Color? c}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Text(l, style: TextStyle(color: _sub, fontWeight: FontWeight.w700))),
            Text(_money(v), style: TextStyle(fontWeight: FontWeight.w900, color: c ?? _text)),
          ]),
        );
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title('الخزنة', '', action: 'فتح', onTap: () => _open(const CashPage())),
        line('خزنة المكتب', w['office']),
        line('خزنة المحاسب', w['accountant']),
        line('أقساط متأخرة (${od['count'] ?? 0})', od['amount'], c: _n(od['amount']) > 0 ? Colors.red : null),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: ElevatedButton.icon(
              onPressed: () => _open(const CashPage()),
              icon: const Icon(Icons.swap_horiz_rounded),
              label: const Text('طلب توريد'),
              style: ElevatedButton.styleFrom(backgroundColor: _primary, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            ),
          ),
          if (_n(w['transfersOpen']) > 0) ...[
            const SizedBox(width: 10),
            Text('${w['transfersOpen']} تحويل مفتوح', style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.w800)),
          ],
        ]),
      ]),
    );
  }

  // ------------------------------------------------------------------ 10. payroll
  Widget _payroll() {
    final p = _m(_d!['payroll']);
    final due = _n(p['due']), paid = _n(p['paid']);
    final pct = due > 0 ? (paid / due).clamp(0, 1).toDouble() : 0.0;
    final now = DateTime.now();
    final daysLeft = DateTime(now.year, now.month + 1, 0).day - now.day;
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title('مرتبات الشهر', 'فاضل $daysLeft يوم على آخر الشهر',
            action: 'المرتبات', onTap: () => _open(CashboxHubPage(uid: widget.uid, name: widget.name, role: widget.role))),
        Row(children: [
          Text('${(pct * 100).round()}٪', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: _text)),
          const SizedBox(width: 10),
          Expanded(child: Text('${_short(paid)} اتصرف من ${_short(due)}', style: TextStyle(color: _sub))),
        ]),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(value: pct, minHeight: 10, color: _primary, backgroundColor: _dark ? Colors.white12 : Colors.grey.shade200),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _mini('المستحق', _money(due))),
          Expanded(child: _mini('اتصرف', _money(paid))),
          Expanded(child: _mini('الباقي', _money(p['remaining']))),
        ]),
      ]),
    );
  }

  Widget _mini(String l, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l, style: TextStyle(fontSize: 12, color: _sub)),
        FittedBox(fit: BoxFit.scaleDown, child: Text(v, style: TextStyle(fontWeight: FontWeight.w900, color: _text))),
      ]);

  // ------------------------------------------------------------------ 11. coming up
  Widget _upcoming() {
    final rows = _l(_d!['upcoming']);
    const days = ['الاتنين', 'التلات', 'الأربع', 'الخميس', 'الجمعة', 'السبت', 'الحد'];
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title('الجاي', 'أقساط الأسبوع ده والإجازات الرسمية', action: 'الأقساط', onTap: () => _open(const SalesPage())),
        if (rows.isEmpty) Text('مفيش حاجة الأسبوع ده', style: TextStyle(color: _sub)),
        for (final x in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Container(
                width: 52, padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(color: _primary.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  Text('${DateTime.tryParse('${x['day']}')?.day ?? ''}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: _primary)),
                  Text(days[(DateTime.tryParse('${x['day']}')?.weekday ?? 1) - 1], style: TextStyle(fontSize: 10.5, color: _sub)),
                ]),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text('${x['title']}', style: TextStyle(fontWeight: FontWeight.w800, color: _text))),
              if (x['amount'] != null) Text(_money(x['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: _text))
              else const Icon(Icons.celebration_rounded, color: Colors.purple),
            ]),
          ),
      ]),
    );
  }

  // ------------------------------------------------------------------ 12. needs attention
  Widget _attention() {
    final a = _m(_d!['attention']);
    final absent = ((a['absent'] as List?) ?? const []).map((e) => '$e').toList();
    final late = ((a['late'] as List?) ?? const []).map((e) => '$e').toList();
    final adv = _m(a['openAdvances']);
    Widget row(IconData i, Color c, String t, String s, String btn, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            JphUi.iconTile(_dark, i, c),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t, style: TextStyle(fontWeight: FontWeight.w800, color: _text)),
                if (s.isNotEmpty) Text(s, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: _sub)),
              ]),
            ),
            TextButton(onPressed: onTap, child: Text(btn, style: TextStyle(fontWeight: FontWeight.w800, color: _primary))),
          ]),
        );
    final report = AttendanceReportPage(uid: widget.uid, name: widget.name, role: widget.role);
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title('محتاج انتباه', ''),
        row(Icons.person_off_rounded, Colors.red, 'غياب النهارده: ${absent.length}', absent.join('، '), 'الحضور', widget.onOpenClassic),
        row(Icons.schedule_rounded, Colors.orange, 'تأخير النهارده: ${late.length}', late.join('، '), 'التقرير', () => _open(report)),
        row(Icons.payments_outlined, Colors.indigo, 'سلف لسه بتتخصم: ${adv['count'] ?? 0}', _money(adv['amount']), 'السلف',
            () => _open(CashboxHubPage(uid: widget.uid, name: widget.name, role: widget.role))),
      ]),
    );
  }

  // ------------------------------------------------------------------ 13. last activity
  static const _actAr = {
    'attendance': 'حضور', 'cash': 'خزنة', 'advance': 'سلفة', 'payout': 'صرف', 'request': 'طلب', 'sale': 'مبيعات',
    'employee': 'موظفين', 'custody': 'عهدة', 'forms': 'استمارات', 'commission': 'عمولات', 'auth': 'دخول',
  };

  Widget _lastActivity() {
    final l = _m(_d!['lastActivity']);
    if (l.isEmpty) return const SizedBox.shrink();
    final area = _actAr['${l['action']}'.split('.').first] ?? '${l['entity'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 10),
      child: Row(children: [
        Icon(Icons.bolt_rounded, size: 16, color: _sub),
        const SizedBox(width: 6),
        Expanded(child: Text('آخر حركة: ${l['actor'] ?? 'السيستم'} — $area · ${_ago('${l['at']}')}',
            style: TextStyle(fontSize: 12, color: _sub))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 900;
    final ready = _d != null;
    final left = ready ? [_chart(), _pipeline(), _topSales(), _latest()] : <Widget>[];
    final right = ready ? [_wallet(), _payroll(), _upcoming(), _attention()] : <Widget>[];
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
          children: [
            widget.header,
            const SizedBox(height: 18),
            if (!ready && _error == null) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(30),
                child: Column(children: [
                  Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: _sub)),
                  TextButton(onPressed: _load, child: const Text('حاول تاني')),
                ]),
              ),
            if (ready) ...[
              _greeting(),
              _actions(),
              _kpis(),
              if (wide)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Column(children: left)),
                  const SizedBox(width: 14),
                  Expanded(child: Column(children: right)),
                ])
              else ...[
                // the same order as the reference overview on a phone
                _chart(), _pipeline(), _topSales(), _latest(), _wallet(), _payroll(), _upcoming(), _attention(),
              ],
              _lastActivity(),
            ],
          ],
        ),
      ),
    );
  }
}
