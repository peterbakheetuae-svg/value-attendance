import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/api_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/glass_ui.dart';
import '../attendance/attendance_report_page.dart';
import '../cash/cashbox_hub_page.dart';
import '../employees/employees_page.dart';
import '../exclusive/exclusive_projects_page.dart';
import '../finance/finance_dashboard_page.dart';
import '../multi_company/kpi_page.dart';
import 'attendance_today_page.dart';

/// The home of المالك / المدير العام — the Ignara overview, card for card and motion for motion, in the app's
/// colours: greeting + headline → [المالية | الموظفين] → 4 KPI cards (the first one a gradient with a progress bar) →
/// bead chart against a dashed target → pipeline bars → ranked list → latest list → wallet with a sparkline →
/// segmented dial → coming up → needs attention → last activity. Both views share the same cards (GET /dashboard/owner).
class OwnerOverview extends StatefulWidget {
  final bool isDark;
  final Widget header;
  final String uid, name, role;
  /// the attendance & requests view (the previous home)
  final VoidCallback onOpenClassic;
  const OwnerOverview({super.key, required this.isDark, required this.header, required this.uid, required this.name,
      required this.role, required this.onOpenClassic});

  @override
  State<OwnerOverview> createState() => _OwnerOverviewState();
}

// ---------------------------------------------------------------- palette (the app's colours in Ignara's roles)
class _P {
  final bool dark;
  const _P(this.dark);
  // the «Ardena» site's colours (our blue in their orange's place)
  Color get accent => dark ? Glass.blueHi : Glass.blue;
  Color get accentFrom => Glass.blueHi;
  Color get accentTo => Glass.blue;
  LinearGradient get grad => LinearGradient(
      begin: const Alignment(-0.8, -1), end: const Alignment(0.9, 1), colors: [accentFrom, accent, accentTo], stops: const [0, 0.5, 1]);
  Color get card => Glass.card(dark);
  Color get card2 => dark ? Colors.white.withOpacity(0.06) : const Color(0x8CFFFFFF);
  Color get line => Glass.line(dark);
  Color get ink => Glass.ink(dark);
  Color get muted => Glass.muted(dark);
  Color get data => dark ? const Color(0xFFD9D6D0) : const Color(0xFFB3AEA6);
  Color get good => dark ? const Color(0xFF63D985) : const Color(0xFF19733A);
  Color get warn => dark ? const Color(0xFFF7B445) : const Color(0xFFEF9D14);
  Color get bad => const Color(0xFFFF7D6E);
  Color get info => dark ? const Color(0xFF93C1FF) : const Color(0xFF3B78C4);
  Color tone(String? t) => switch (t) {
        'good' => good,
        'warn' => warn,
        'bad' => bad,
        'info' => info,
        'muted' => data,
        _ => accent,
      };
}

const _ease = Glass.ease; // the site's cubic-bezier(.22, 1, .36, 1)

class _OwnerOverviewState extends State<OwnerOverview> {
  String _view = 'finance';
  int _range = 14;
  String? _chip;
  Map<String, dynamic>? _d;
  String? _error;
  int _gen = 0; // bumps on every load → cards replay their entrance

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool quiet = false}) async {
    final r = await ApiService.post({'action': 'owner_dashboard', 'range': _range, 'view': _view});
    if (!mounted) return;
    setState(() {
      if (r['success'] == true) {
        _d = r;
        _error = null;
        if (!quiet) _gen++;
        final chips = ((_m(r['chart'])['chips'] as List?) ?? const []).cast<Map>();
        if (_chip == null || !chips.any((c) => c['key'] == _chip)) _chip = chips.isEmpty ? null : '${chips.first['key']}';
      } else {
        _error = '${r['message'] ?? 'مش قادر أحمّل البيانات'}';
      }
    });
  }

  _P get p => _P(widget.isDark);
  static Map<String, dynamic> _m(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
  static List<Map<String, dynamic>> _l(Object? v) => ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  static num _n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}') ?? 0;

  static String money(num v, {bool unit = true}) {
    final neg = v < 0;
    final s = v.abs().round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    return '${neg ? '-' : ''}$s${unit ? ' ج' : ''}';
  }

  static String short(num v) {
    final a = v.abs();
    final s = a >= 1e6 ? '${(a / 1e6).toStringAsFixed(a >= 1e7 ? 0 : 1)}م' : a >= 1e3 ? '${(a / 1e3).toStringAsFixed(a >= 1e4 ? 0 : 1)}ك' : a.round().toString();
    return v < 0 ? '-$s' : s;
  }

  static String fmt(num v, String? f) => switch (f) {
        'money' => money(v),
        'pct' => '${v.round()}٪',
        _ => v % 1 == 0 ? v.toInt().toString() : v.toStringAsFixed(1),
      };

  static const _days = ['الاتنين', 'التلات', 'الأربع', 'الخميس', 'الجمعة', 'السبت', 'الحد'];
  static const _months = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];

  String _ago(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return '';
    final d = DateTime.now().difference(t.toLocal());
    if (d.inMinutes < 60) return 'من ${math.max(1, d.inMinutes)} د';
    if (d.inHours < 24) return 'من ${d.inHours} س';
    return 'من ${d.inDays} يوم';
  }

  // ---------------------------------------------------------------- navigation
  void _go(String? route) async {
    if (route == null) return;
    Widget? page;
    switch (route) {
      case 'cash':
        page = CashboxHubPage(uid: widget.uid, name: widget.name, role: widget.role, initial: 1);
      case 'finance':
        page = const FinanceDashboardPage();
      case 'finance_requests':
        page = CashboxHubPage(uid: widget.uid, name: widget.name, role: widget.role);
      case 'exclusive':
        page = const ProjectsPage();
      case 'sales':
        page = const SalesHubPage();
      case 'attendance_today':
        page = AttendanceTodayPage(uid: widget.uid, name: widget.name, role: widget.role);
      case 'attendance_report':
        page = AttendanceReportPage(uid: widget.uid, name: widget.name, role: widget.role);
      case 'employees':
        page = EmployeesPage(currentUserId: widget.uid, currentUserName: widget.name, currentUserRole: widget.role);
      case 'kpi':
        page = const KpiPage();
      case 'requests':
        widget.onOpenClassic();
        return;
    }
    if (page == null) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => page!));
    _load(quiet: true);
  }

  void _switch(String v) {
    if (v == _view) return;
    setState(() {
      _view = v;
      _chip = null;
      _d = null;
    });
    _load();
  }

  // ---------------------------------------------------------------- shared pieces
  Widget _card({required Widget child, int i = 0, EdgeInsets padding = const EdgeInsets.all(20), Gradient? gradient, List<BoxShadow>? shadow,
      Widget? overlay}) {
    return _Rise(
      key: ValueKey('c$_gen-$i-$_view'),
      delay: 80 + i * 60,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        // the «Ardena» glass square (or our blue for the highlighted one)
        decoration: gradient == null
            ? Glass.panel(widget.isDark, r: 20)
            : BoxDecoration(
                gradient: gradient,
                borderRadius: BorderRadius.circular(20),
                boxShadow: shadow ?? [BoxShadow(color: Glass.blue.withOpacity(0.35), blurRadius: 30, offset: const Offset(0, 14), spreadRadius: -18)],
              ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(children: [
            if (overlay != null) Positioned.fill(child: overlay),
            Padding(padding: padding, child: child),
          ]),
        ),
      ),
    );
  }

  Widget _head(String title, String sub, {String? link, String? route, bool arrow = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: p.ink)),
              if (sub.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: Text(sub, style: TextStyle(fontSize: 13, color: p.muted))),
            ]),
          ),
          if (arrow)
            _Press(
              onTap: () => _go(route),
              child: Container(
                width: 40, height: 40,
                decoration: BoxDecoration(shape: BoxShape.circle, color: p.card2, border: Border.all(color: p.line)),
                child: Icon(Icons.north_west_rounded, size: 18, color: p.muted),
              ),
            )
          else if (link != null)
            _Press(
              onTap: () => _go(route),
              child: Padding(padding: const EdgeInsets.only(top: 4), child: Text(link, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: p.accent))),
            ),
        ]),
      );

  IconData _icon(String? k) => switch (k) {
        'wallet' => Icons.account_balance_wallet_outlined,
        'percent' => Icons.percent_rounded,
        'owner' => Icons.real_estate_agent_outlined,
        'profit' => Icons.trending_up_rounded,
        'checkin' => Icons.how_to_reg_outlined,
        'people' => Icons.groups_2_outlined,
        'late' => Icons.schedule_rounded,
        'absent' => Icons.person_off_outlined,
        'alert' => Icons.warning_amber_rounded,
        'home' => Icons.home_work_outlined,
        'payroll' => Icons.payments_outlined,
        'calendar' => Icons.event_outlined,
        'clock' => Icons.access_time_rounded,
        _ => Icons.circle_outlined,
      };

  // ---------------------------------------------------------------- 1. greeting + headline + summary
  Widget _greeting() {
    final h = DateTime.now().hour;
    final first = '${_d?['name'] ?? widget.name}'.split(' ').first;
    final summary = ((_d?['summary'] as List?) ?? const []).map((e) => '$e').join(' · ');
    final headline = _view == 'finance' ? 'المالية النهارده' : 'الموظفين النهارده';
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(h < 12 ? 'صباح الخير يا $first' : 'مساء الخير يا $first', style: TextStyle(fontSize: 15, color: p.muted)),
        const SizedBox(height: 6),
        _Headline(key: ValueKey('h$_gen$_view'), text: headline, style: TextStyle(fontSize: 34, height: 1.15, fontWeight: FontWeight.w800, color: p.ink)),
        const SizedBox(height: 8),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Text(summary, key: ValueKey(summary), style: TextStyle(fontSize: 14.5, height: 1.5, color: p.muted)),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- 2. the two buttons: المالية | الموظفين
  Widget _switchButtons() {
    Widget btn(String v, String label, IconData icon) {
      final on = _view == v;
      return Expanded(
        child: _Press(
          onTap: () => _switch(v),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            curve: _ease,
            height: 56,
            decoration: BoxDecoration(
              gradient: on ? p.grad : null,
              color: on ? null : p.card,
              borderRadius: BorderRadius.circular(14),
              border: on ? null : Border.all(color: p.line),
              boxShadow: on ? [BoxShadow(color: p.accent.withOpacity(0.45), blurRadius: 24, offset: const Offset(0, 10), spreadRadius: -8)] : null,
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(icon, size: 20, color: on ? Colors.white : p.ink),
              const SizedBox(width: 10),
              Text(label, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: on ? Colors.white : p.ink)),
            ]),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(children: [
        btn('finance', 'المالية', Icons.bar_chart_rounded),
        const SizedBox(width: 14),
        btn('employees', 'الموظفين', Icons.groups_2_outlined),
      ]),
    );
  }

  // ---------------------------------------------------------------- 3. KPI cards
  Widget _kpis() {
    final ks = _l(_d!['kpis']);
    Widget kpi(Map<String, dynamic> k, int i) {
      final hi = k['highlight'] == true;
      final v = _n(k['value']);
      final tone = k['tone'] == null ? null : p.tone('${k['tone']}');
      final fg = hi ? Colors.white : p.ink;
      return Expanded(
        child: _Rise(
          key: ValueKey('k$_gen-$i-$_view'),
          delay: 40 + i * 60,
          child: _Press(
            onTap: () => _go('${k['route']}'),
            child: Container(
              constraints: const BoxConstraints(minHeight: 168),
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
              decoration: BoxDecoration(
                gradient: hi ? p.grad : null,
                color: hi ? null : p.card,
                borderRadius: BorderRadius.circular(20),
                border: hi ? null : Border.all(color: p.line),
                boxShadow: hi
                    ? [BoxShadow(color: p.accent.withOpacity(0.5), blurRadius: 34, offset: const Offset(0, 16), spreadRadius: -14)]
                    : [BoxShadow(color: Colors.black.withOpacity(widget.isDark ? 0.25 : 0.05), blurRadius: 24, offset: const Offset(0, 12), spreadRadius: -16)],
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(_icon('${k['icon']}'), size: 19, color: hi ? Colors.white : p.accent),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${k['label']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: hi ? Colors.white.withOpacity(0.92) : p.muted))),
                ]),
                const SizedBox(height: 14),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: _CountUp(key: ValueKey('n$_gen-$i-$_view'), value: v.toDouble(), format: (x) => fmt(x, '${k['format']}'),
                      style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: tone ?? fg, fontFeatures: const [ui.FontFeature.tabularFigures()])),
                ),
                const Spacer(),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: hi ? Colors.black.withOpacity(0.18) : (tone ?? p.good).withOpacity(0.14),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text('${k['foot'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: hi ? Colors.white : (tone ?? p.good))),
                ),
                if (hi && k['progress'] != null) ...[
                  const SizedBox(height: 12),
                  _Bar(key: ValueKey('kb$_gen$_view'), value: _n(k['progress']).toDouble().clamp(0, 1), height: 7,
                      fill: const LinearGradient(colors: [Colors.white, Colors.white]), track: Colors.black.withOpacity(0.22), delay: 500),
                ],
              ]),
            ),
          ),
        ),
      );
    }

    if (ks.length < 4) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(children: [
        IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [kpi(ks[0], 0), const SizedBox(width: 14), kpi(ks[1], 1)])),
        const SizedBox(height: 14),
        IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [kpi(ks[2], 2), const SizedBox(width: 14), kpi(ks[3], 3)])),
      ]),
    );
  }

  // ---------------------------------------------------------------- 4. bead chart against the target
  Widget _chart(int i) {
    final c = _m(_d!['chart']);
    final series = _l(_m(c['series'])[_chip ?? '']);
    final unit = '${c['unit']}';
    final target = _n(c['target']).toDouble();
    final stats = _l(c['stats']);
    final chips = _l(c['chips']);
    Widget seg() {
      Widget o(int v, String label) => Expanded(
            child: _Press(
              onTap: () {
                if (_range == v) return;
                setState(() => _range = v);
                _load(quiet: true);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: _ease,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _range == v ? (widget.isDark ? const Color(0xFFF3F2EF) : Colors.white) : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: _range == v ? [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 8, offset: const Offset(0, 2))] : null,
                ),
                child: Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                    color: _range == v ? const Color(0xFF1D1E21) : p.muted)),
              ),
            ),
          );
      return Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.line)),
        child: Row(children: [o(14, '١٤ يوم'), o(30, '٣٠ يوم'), o(91, '١٣ أسبوع')]),
      );
    }

    Widget stat(Map<String, dynamic> s) {
      final v = _n(s['value']);
      final dashed = s['dashed'] == true;
      return Padding(
        padding: const EdgeInsetsDirectional.only(end: 22, bottom: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (dashed) ...[
              SizedBox(width: 20, child: CustomPaint(painter: _DashPainter(p.accent), size: const Size(20, 2))),
              const SizedBox(width: 6),
            ],
            Text('${s['label']}', style: TextStyle(fontSize: 14, color: p.muted)),
          ]),
          const SizedBox(height: 3),
          Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
            CountUpText(fmt(v, '${s['format']}'), style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: p.ink)),
            if (s['of'] != null) Text(' من ${s['of']}', style: TextStyle(fontSize: 14, color: p.muted)),
            if (s['day'] != null) Text(' · ${_dayShort('${s['day']}')}', style: TextStyle(fontSize: 13, color: p.muted)),
          ]),
        ]),
      );
    }

    return _card(
      i: i,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _head('${c['title']}', '${c['sub']}'),
        seg(),
        const SizedBox(height: 18),
        Wrap(children: stats.map(stat).toList()),
        const SizedBox(height: 10),
        if (chips.length > 1)
          SizedBox(
            height: 48,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              for (final ch in chips)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: _Press(
                    onTap: () => setState(() => _chip = '${ch['key']}'),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        gradient: _chip == ch['key'] ? p.grad : null,
                        color: _chip == ch['key'] ? null : p.card2,
                        borderRadius: BorderRadius.circular(12),
                        border: _chip == ch['key'] ? null : Border.all(color: p.line),
                      ),
                      child: Text('${ch['label']}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600,
                          color: _chip == ch['key'] ? Colors.white : p.ink)),
                    ),
                  ),
                ),
            ]),
          ),
        const SizedBox(height: 16),
        SizedBox(
          height: 250,
          child: _Beads(
            key: ValueKey('beads$_gen$_view'),
            values: series.map((x) => _n(x['value']).toDouble()).toList(),
            labels: series.map((x) => _dayShort('${x['day']}')).toList(),
            target: target,
            targetLabel: unit == 'money' ? short(target) : fmt(target, 'count'),
            axis: (v) => unit == 'money' ? short(v) : fmt(v, 'count'),
            palette: p,
          ),
        ),
      ]),
    );
  }

  String _dayShort(String d) {
    final x = DateTime.tryParse(d);
    if (x == null) return d;
    return '${_days[x.weekday - 1].substring(0, 3)} ${x.day}';
  }

  // ---------------------------------------------------------------- 5. pipeline bars
  Widget _pipeline(int i) {
    final c = _m(_d!['pipeline']);
    final rows = _l(c['rows']);
    final maxV = rows.fold<num>(1, (m, r) => math.max(m, _n(r['value'])));
    final f = _m(c['footer']);
    return _card(
      i: i,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _head('${c['title']}', '${c['sub']}', route: '${c['route']}', arrow: true),
        for (var k = 0; k < rows.length; k++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Row(children: [
              SizedBox(width: 108, child: Text('${rows[k]['label']}', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: p.ink))),
              Expanded(
                child: _Bar(
                  key: ValueKey('pb$_gen$_view$k'),
                  value: (_n(rows[k]['value']) / maxV).toDouble(),
                  height: 14,
                  fill: k == 0 ? p.grad : LinearGradient(colors: [p.tone('${rows[k]['tone']}'), p.tone('${rows[k]['tone']}')]),
                  track: p.card2,
                  delay: 400 + k * 80,
                ),
              ),
              SizedBox(width: 56, child: Text('${rows[k]['value']}', textAlign: TextAlign.end,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: p.ink))),
            ]),
          ),
        Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Divider(height: 1, color: p.line)),
        Row(children: [
          Icon(_icon('${f['icon']}'), size: 19, color: p.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '${f['text'] ?? ''} '),
              TextSpan(text: '${f['strong'] ?? ''}', style: TextStyle(fontWeight: FontWeight.w800, color: p.ink)),
            ]), style: TextStyle(fontSize: 14.5, color: p.muted), maxLines: 2),
          ),
          _outlineBtn('${c['button'] ?? 'فتح'}', () => _go('${c['route']}')),
        ]),
      ]),
    );
  }

  Widget _outlineBtn(String label, VoidCallback onTap) => _Press(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: p.line.withOpacity(0.9), width: 1.4),
              color: p.card2.withOpacity(0.4)),
          child: Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: p.ink)),
        ),
      );

  // ---------------------------------------------------------------- 6. ranked list
  Widget _ranked(int i) {
    final c = _m(_d!['ranked']);
    final rows = _l(c['rows']);
    final colors = [p.accent, p.bad, p.warn, p.good, p.data];
    return _card(
      i: i,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _head('${c['title']}', '${c['sub']}', route: '${c['route']}', arrow: true),
        if (rows.isEmpty) _empty('${c['empty'] ?? ''}'),
        for (var k = 0; k < rows.length; k++) ...[
          if (k > 0) Divider(height: 1, color: p.line),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Row(children: [
              SizedBox(width: 22, child: Text('${k + 1}', style: TextStyle(fontSize: 15, color: p.muted))),
              const SizedBox(width: 6),
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: colors[k % colors.length].withOpacity(0.14),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colors[k % colors.length].withOpacity(0.35)),
                ),
                child: Icon(_view == 'finance' ? Icons.apartment_rounded : Icons.person_rounded, size: 21, color: colors[k % colors.length]),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${rows[k]['title']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: p.ink)),
                  const SizedBox(height: 4),
                  Row(children: [
                    Flexible(child: Text('${rows[k]['sub']} · ', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: p.muted))),
                    SizedBox(width: 80, child: _Bar(key: ValueKey('rb$_gen$_view$k'), value: _n(rows[k]['progress']).toDouble(), height: 5,
                        fill: p.grad, track: p.card2, delay: 450 + k * 70)),
                  ]),
                ]),
              ),
              const SizedBox(width: 10),
              CountUpText(fmt(_n(rows[k]['value']), '${rows[k]['format']}'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: p.ink)),
            ]),
          ),
        ],
      ]),
    );
  }

  Widget _empty(String s) => Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(s, style: TextStyle(fontSize: 14, color: p.muted)));

  // ---------------------------------------------------------------- 7. latest list
  Widget _latest(int i) {
    final c = _m(_d!['latest']);
    final rows = _l(c['rows']);
    return _card(
      i: i,
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _head('${c['title']}', '${c['sub']}', link: 'الكل', route: '${c['route']}'),
        if (rows.isEmpty) _empty('${c['empty'] ?? ''}'),
        for (var k = 0; k < rows.length; k++) ...[
          if (k > 0) Divider(height: 1, color: p.line),
          _Press(
            onTap: () => _go(_routeOf('${rows[k]['kind']}', '${c['route']}')),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${rows[k]['title']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: p.ink)),
                    const SizedBox(height: 4),
                    Text(_ago('${rows[k]['at']}'), style: TextStyle(fontSize: 13.5, color: p.muted)),
                    const SizedBox(height: 8),
                    Text('${rows[k]['sub']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.5, color: p.muted)),
                  ]),
                ),
                const SizedBox(width: 10),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (rows[k]['amount'] != null)
                    CountUpText(money(_n(rows[k]['amount'])), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: p.ink))
                  else
                    const SizedBox(height: 18),
                  const SizedBox(height: 18),
                  _chipStatus('${rows[k]['status']}', p.tone('${rows[k]['tone']}')),
                ]),
              ]),
            ),
          ),
        ],
      ]),
    );
  }

  String _routeOf(String kind, String fallback) => switch (kind) {
        'advance' || 'transfer' => 'finance_requests',
        'owner_payout' || 'expense' => 'cash',
        'contract' || 'cancel' => 'exclusive',
        'request' || 'outing' => 'requests',
        _ => fallback,
      };

  Widget _chipStatus(String s, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(color: c.withOpacity(0.16), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 7),
          Text(s, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: c)),
        ]),
      );

  // ---------------------------------------------------------------- 8. wallet card
  Widget _wallet(int i) {
    final c = _m(_d!['wallet']);
    final rows = _l(c['rows']);
    final btn = _m(c['button']);
    final warn = c['warn'] == null ? null : _m(c['warn']);
    final spark = ((c['spark'] as List?) ?? const []).map((x) => _n(x).toDouble()).toList();
    return _card(
      i: i,
      overlay: IgnorePointer(
        child: Align(
          alignment: AlignmentDirectional.topEnd,
          child: Container(
            width: 220, height: 220,
            transform: Matrix4.translationValues(0, -80, 0),
            decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [p.accent.withOpacity(0.28), Colors.transparent])),
          ),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.credit_card_rounded, size: 20, color: p.accent),
          const SizedBox(width: 10),
          Expanded(child: Text('${c['title']}', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: p.ink))),
          _Press(
            onTap: () => _go('${c['route']}'),
            child: Container(
              width: 40, height: 40,
              decoration: BoxDecoration(shape: BoxShape.circle, color: p.accent.withOpacity(0.10), border: Border.all(color: p.accent.withOpacity(0.25))),
              child: Icon(Icons.north_west_rounded, size: 18, color: p.accent),
            ),
          ),
        ]),
        const SizedBox(height: 18),
        Text('${c['label']}', style: TextStyle(fontSize: 14, color: p.muted)),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: _CountUp(key: ValueKey('w$_gen$_view'), value: _n(c['value']).toDouble(), format: (x) => fmt(x, '${c['format']}'),
              style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: p.ink, letterSpacing: -1)),
        ),
        const SizedBox(height: 14),
        SizedBox(height: 70, child: _Spark(key: ValueKey('sp$_gen$_view'), values: spark, line: p.ink.withOpacity(0.9), fill: p.ink.withOpacity(0.12))),
        Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Divider(height: 1, color: p.line)),
        Row(children: [
          for (final r in rows)
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${r['label']}', style: TextStyle(fontSize: 14, color: p.muted)),
                const SizedBox(height: 4),
                CountUpText(fmt(_n(r['value']), '${r['format']}'), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: p.ink)),
              ]),
            ),
        ]),
        const SizedBox(height: 18),
        _Press(
          onTap: () => _go('${btn['route']}'),
          child: Container(
            height: 54,
            decoration: BoxDecoration(gradient: p.grad, borderRadius: BorderRadius.circular(14),
                boxShadow: [BoxShadow(color: p.accent.withOpacity(0.4), blurRadius: 20, offset: const Offset(0, 8), spreadRadius: -8)]),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.account_balance_rounded, size: 20, color: Colors.white),
              const SizedBox(width: 10),
              Text('${btn['label']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
            ]),
          ),
        ),
        if (warn != null) ...[
          const SizedBox(height: 10),
          _Press(
            onTap: () => _go('${warn['route']}'),
            child: Container(
              height: 48,
              decoration: BoxDecoration(color: p.bad.withOpacity(0.13), borderRadius: BorderRadius.circular(12)),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.warning_amber_rounded, size: 20, color: p.bad),
                const SizedBox(width: 8),
                Text('${warn['label']}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: p.bad)),
              ]),
            ),
          ),
        ],
      ]),
    );
  }

  // ---------------------------------------------------------------- 9. dial
  Widget _ring(int i) {
    final c = _m(_d!['ring']);
    final stats = _l(c['stats']);
    final extra = _l(c['extra']);
    return _card(
      i: i,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _head('${c['title']}', '${c['sub']}', route: '${c['route']}', link: c['route'] == null ? null : 'التفاصيل'),
        Center(
          child: SizedBox(
            width: 240, height: 240,
            child: _Dial(
              key: ValueKey('d$_gen$_view'),
              value: _n(c['pct']).toDouble(),
              palette: p,
              center: '${c['center']}',
              sub: '${c['centerSub']}',
            ),
          ),
        ),
        const SizedBox(height: 18),
        Row(children: [
          for (var k = 0; k < stats.length; k++)
            Expanded(
              child: Column(
                crossAxisAlignment: k == 0 ? CrossAxisAlignment.start : k == stats.length - 1 ? CrossAxisAlignment.end : CrossAxisAlignment.center,
                children: [
                  Text('${stats[k]['label']}', style: TextStyle(fontSize: 14, color: p.muted)),
                  const SizedBox(height: 4),
                  Text(_view == 'finance' ? short(_n(stats[k]['value'])) : fmt(_n(stats[k]['value']), '${stats[k]['format']}') + (stats[k]['of'] != null ? ' من ${stats[k]['of']}' : ''),
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800,
                          color: stats[k]['tone'] == null ? p.ink : p.tone('${stats[k]['tone']}'))),
                  if ('${stats[k]['name'] ?? ''}'.isNotEmpty)
                    Text('${stats[k]['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: p.muted)),
                ],
              ),
            ),
        ]),
        if (extra.isNotEmpty) ...[
          Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Divider(height: 1, color: p.line)),
          for (final e in extra)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text('${e['label']}', style: TextStyle(fontSize: 14, color: p.muted))),
                CountUpText(fmt(_n(e['value']), '${e['format']}'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: p.ink)),
              ]),
            ),
        ],
      ]),
    );
  }

  // ---------------------------------------------------------------- 10. coming up
  Widget _coming(int i) {
    final c = _m(_d!['coming']);
    final rows = _l(c['rows']);
    return _card(
      i: i,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _head('${c['title']}', '${c['sub']}', link: 'الكل', route: '${c['route']}'),
        if (rows.isEmpty) _empty('${c['empty'] ?? ''}'),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Container(
                width: 64, height: 66,
                decoration: BoxDecoration(color: p.card2, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.line)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(13),
                  child: Stack(children: [
                    PositionedDirectional(start: 0, top: 0, bottom: 0, child: Container(width: 3.5, color: p.tone('${r['tone']}'))),
                    Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text('${DateTime.tryParse('${r['day']}')?.day ?? ''}', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: p.ink)),
                  Text(() {
                    final d = DateTime.tryParse('${r['day']}');
                    return d == null ? '' : _days[d.weekday - 1];
                  }(), style: TextStyle(fontSize: 12, color: p.muted)),
                    ])),
                  ]),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${r['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: p.ink)),
                  const SizedBox(height: 4),
                  Text('${r['sub'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: p.muted)),
                ]),
              ),
              if (r['amount'] != null)
                Text(short(_n(r['amount'])), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: p.ink))
              else
                CircleAvatar(radius: 18, backgroundColor: p.tone('${r['tone']}').withOpacity(0.25),
                    child: Text('${r['title']}'.trim().isEmpty ? '' : '${r['title']}'.trim().split(' ').last.characters.first,
                        style: TextStyle(fontWeight: FontWeight.w800, color: p.ink))),
            ]),
          ),
      ]),
    );
  }

  // ---------------------------------------------------------------- 11. needs attention + activity
  Widget _attention(int i) {
    final c = _m(_d!['attention']);
    final rows = _l(c['rows']);
    final last = _m(_d!['last']);
    const tints = [Color(0xFFB98A5E), Color(0xFF5E8AB9), Color(0xFFC07A3C), Color(0xFF7A5EB9)];
    return _card(
      i: i,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _head('${c['title']}', '${c['sub']}', link: 'الكل', route: '${c['route']}'),
        if (rows.isEmpty) _empty('${c['empty'] ?? ''}'),
        for (var k = 0; k < rows.length; k++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(color: tints[k % tints.length].withOpacity(0.16), borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: tints[k % tints.length].withOpacity(0.35))),
                child: Icon(_icon('${rows[k]['icon']}'), size: 21, color: tints[k % tints.length]),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${rows[k]['title']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: p.ink)),
                  const SizedBox(height: 3),
                  Text('${rows[k]['sub'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: p.muted)),
                ]),
              ),
              const SizedBox(width: 10),
              _outlineBtn('${rows[k]['button'] ?? 'فتح'}', () => _go('${rows[k]['route']}')),
            ]),
          ),
        if (last.isNotEmpty) ...[
          Padding(padding: const EdgeInsets.symmetric(vertical: 14), child: Divider(height: 1, color: p.line)),
          Row(children: [
            Icon(Icons.bolt_rounded, size: 19, color: p.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(TextSpan(children: [
                TextSpan(text: '${last['actor'] ?? 'السيستم'} ', style: TextStyle(fontWeight: FontWeight.w800, color: p.ink)),
                TextSpan(text: '${_actAr('${last['action']}')} · ${_ago('${last['at']}')}'),
              ]), style: TextStyle(fontSize: 14, color: p.muted)),
            ),
          ]),
          const SizedBox(height: 10),
          Text(() {
            final d = DateTime.tryParse('${_d!['date']}');
            return d == null ? '' : 'اتحدّث ${d.day} ${_months[d.month - 1]}';
          }(), style: TextStyle(fontSize: 13.5, color: p.muted)),
        ],
      ]),
    );
  }

  String _actAr(String a) {
    const m = {
      'attendance': 'سجّل حركة حضور', 'cash': 'سجّل حركة خزنة', 'advance': 'اتعامل مع سلفة', 'payout': 'صرف فلوس', 'request': 'اتعامل مع طلب',
      'sale': 'سجّل مبيعات', 'employee': 'عدّل بيانات موظف', 'custody': 'اتعامل مع عهدة', 'forms': 'عمل استمارة', 'commission': 'اتعامل مع عمولة',
      'exclusive': 'اتعامل مع مشروع حصري', 'auth': 'سجّل دخول',
    };
    return m[a.split('.').first] ?? 'عمل حركة';
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 980;
    final ready = _d != null;
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: () => _load(),
        color: p.accent,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
          children: [
            widget.header,
            const SizedBox(height: 18),
            _greeting(),
            // عربون حجز / مقدم تعاقد مستني «تم الاستلام»
            const PendingSalesMoneyCard(),
            _switchButtons(),
            if (!ready && _error == null) const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator())),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.all(30),
                child: Column(children: [
                  Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
                  TextButton(onPressed: _load, child: const Text('حاول تاني')),
                ]),
              ),
            if (ready) ...[
              _kpis(),
              if (wide)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 3, child: Column(children: [_chart(0), _pipeline(1), _ranked(2), _latest(3)])),
                  const SizedBox(width: 16),
                  Expanded(flex: 2, child: Column(children: [_wallet(4), _ring(5), _coming(6), _attention(7)])),
                ])
              else ...[
                _chart(0), _pipeline(1), _ranked(2), _latest(3), _wallet(4), _ring(5), _coming(6), _attention(7),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

// =================================================================== motion pieces

/// Cards: rise in (opacity 0 → 1, y 26 → 0, expo.out, staggered) — Ignara's page entrance.
class _Rise extends StatelessWidget {
  final Widget child;
  final int delay;
  const _Rise({super.key, required this.child, this.delay = 0});

  @override
  Widget build(BuildContext context) {
    return _Delayed(
      delay: delay,
      duration: 800,
      curve: _ease,
      builder: (t) => Opacity(opacity: t.clamp(0, 1), child: Transform.translate(offset: Offset(0, 26 * (1 - t)), child: child)),
    );
  }
}

/// The headline: each word rises from below with a small tilt (yPercent 115 → 0, rotation 6° → 0, power4.out).
class _Headline extends StatelessWidget {
  final String text;
  final TextStyle style;
  const _Headline({super.key, required this.text, required this.style});

  @override
  Widget build(BuildContext context) {
    final words = text.split(' ');
    return Wrap(children: [
      for (var i = 0; i < words.length; i++)
        ClipRect(
          child: _Delayed(
            delay: 60 + i * 70,
            duration: 850,
            curve: const Cubic(0.165, 0.84, 0.44, 1),
            builder: (t) => Transform.translate(
              offset: Offset(0, (1 - t) * (style.fontSize ?? 30) * 1.15),
              child: Transform.rotate(angle: (1 - t) * 6 * math.pi / 180, child: Text('${words[i]}${i < words.length - 1 ? ' ' : ''}', style: style)),
            ),
          ),
        ),
    ]);
  }
}

/// A value 0 → t after a delay.
class _Delayed extends StatefulWidget {
  final int delay, duration;
  final Curve curve;
  final Widget Function(double t) builder;
  const _Delayed({required this.delay, required this.duration, required this.curve, required this.builder});

  @override
  State<_Delayed> createState() => _DelayedState();
}

class _DelayedState extends State<_Delayed> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: Duration(milliseconds: widget.duration));

  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(animation: _c, builder: (_, __) => widget.builder(widget.curve.transform(_c.value)));
}

/// Numbers count up to their value (1.2 s, expo.out) and tween again when the value changes.
class _CountUp extends StatefulWidget {
  final double value;
  final String Function(double) format;
  final TextStyle style;
  const _CountUp({super.key, required this.value, required this.format, required this.style});

  @override
  State<_CountUp> createState() => _CountUpState();
}

class _CountUpState extends State<_CountUp> {
  double _from = 0;

  @override
  void didUpdateWidget(covariant _CountUp old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) _from = old.value;
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        key: ValueKey(widget.value),
        tween: Tween(begin: _from, end: widget.value),
        duration: const Duration(milliseconds: 1200),
        curve: _ease,
        builder: (_, v, __) => Text(widget.format(widget.value % 1 == 0 ? v.roundToDouble() : v), style: widget.style),
      );
}

/// Rounded bar that fills from the start (scaleX 0 → value, 1 s, expo.out, with a delay for the stagger).
class _Bar extends StatelessWidget {
  final double value, height;
  final Gradient fill;
  final Color track;
  final int delay;
  const _Bar({super.key, required this.value, required this.height, required this.fill, required this.track, this.delay = 400});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: BoxDecoration(color: track, borderRadius: BorderRadius.circular(height)),
      child: _Delayed(
        delay: delay,
        duration: 1000,
        curve: _ease,
        builder: (t) => FractionallySizedBox(
          alignment: AlignmentDirectional.centerStart,
          widthFactor: (value.isNaN ? 0 : value.clamp(0, 1)) * t,
          child: Container(decoration: BoxDecoration(gradient: fill, borderRadius: BorderRadius.circular(height))),
        ),
      ),
    );
  }
}

/// The wallet's line: draws itself (1.2 s, power2.inOut) over a soft area.
class _Spark extends StatelessWidget {
  final List<double> values;
  final Color line, fill;
  const _Spark({super.key, required this.values, required this.line, required this.fill});

  @override
  Widget build(BuildContext context) => _Delayed(
        delay: 300,
        duration: 1200,
        curve: Curves.easeInOutQuad,
        builder: (t) => CustomPaint(painter: _SparkPainter(values, line, fill, t), size: Size.infinite),
      );
}

class _SparkPainter extends CustomPainter {
  final List<double> v;
  final Color line, fill;
  final double t;
  _SparkPainter(this.v, this.line, this.fill, this.t);

  @override
  void paint(Canvas canvas, Size s) {
    if (v.length < 2) return;
    final lo = v.reduce(math.min), hi = v.reduce(math.max);
    final span = (hi - lo).abs() < 1e-9 ? 1.0 : hi - lo;
    final pts = [
      for (var i = 0; i < v.length; i++) Offset(s.width * (1 - i / (v.length - 1)), s.height * 0.9 - (v[i] - lo) / span * s.height * 0.75),
    ];
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      final mx = (a.dx + b.dx) / 2;
      path.cubicTo(mx, a.dy, mx, b.dy, b.dx, b.dy);
    }
    final area = Path.from(path)
      ..lineTo(pts.last.dx, s.height)
      ..lineTo(pts.first.dx, s.height)
      ..close();
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(s.width * (1 - t), 0, s.width * t, s.height));
    canvas.drawPath(area, Paint()..color = fill);
    canvas.restore();
    for (final m in path.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * t),
          Paint()..color = line..style = PaintingStyle.stroke..strokeWidth = 3..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(covariant _SparkPainter o) => o.t != t || o.v != v;
}

class _DashPainter extends CustomPainter {
  final Color c;
  _DashPainter(this.c);
  @override
  void paint(Canvas canvas, Size s) {
    final paint = Paint()..color = c..strokeWidth = 2.2..strokeCap = StrokeCap.round;
    for (double x = 0; x < s.width; x += 7) {
      canvas.drawLine(Offset(x, s.height / 2), Offset(math.min(x + 4, s.width), s.height / 2), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter o) => false;
}

/// The segmented dial: ticks around an open ring; the reached ones light up one after another.
class _Dial extends StatelessWidget {
  final double value;
  final _P palette;
  final String center, sub;
  const _Dial({super.key, required this.value, required this.palette, required this.center, required this.sub});

  @override
  Widget build(BuildContext context) => _Delayed(
        delay: 350,
        duration: 1400,
        curve: _ease,
        builder: (t) => CustomPaint(
          painter: _DialPainter(value.clamp(0, 1), t, palette),
          child: Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(center, style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: palette.ink)),
              Text(sub, style: TextStyle(fontSize: 13, color: palette.muted)),
            ]),
          ),
        ),
      );
}

class _DialPainter extends CustomPainter {
  final double v, t;
  final _P p;
  _DialPainter(this.v, this.t, this.p);

  @override
  void paint(Canvas canvas, Size s) {
    const ticks = 44;
    const start = math.pi * 0.72, sweep = math.pi * 1.56; // open at the bottom
    final c = Offset(s.width / 2, s.height / 2);
    final r1 = s.width / 2 - 4, r0 = r1 - 26;
    final on = (ticks * v).round();
    final lit = (on * t).round();
    for (var i = 0; i < ticks; i++) {
      final a = start + sweep * i / (ticks - 1);
      final dir = Offset(math.cos(a), math.sin(a));
      final active = i < lit;
      final col = active ? Color.lerp(p.accentFrom, p.accentTo, i / math.max(1, on))! : p.data.withOpacity(0.28);
      canvas.drawLine(c + dir * r0, c + dir * r1, Paint()..color = col..strokeWidth = 6.5..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(covariant _DialPainter o) => o.t != t || o.v != v;
}

/// The bead chart: one stem per day rising with a bead on top; the days at or above the target are lit (accent,
/// glowing), the others grey; the dashed target line with its label slides into place.
class _Beads extends StatelessWidget {
  final List<double> values;
  final List<String> labels;
  final double target;
  final String targetLabel;
  final String Function(double) axis;
  final _P palette;
  const _Beads({super.key, required this.values, required this.labels, required this.target, required this.targetLabel,
      required this.axis, required this.palette});

  @override
  Widget build(BuildContext context) => _Delayed(
        delay: 200,
        duration: 1300,
        curve: _ease,
        builder: (t) => CustomPaint(painter: _BeadsPainter(values, labels, target, targetLabel, axis, palette, t), size: Size.infinite),
      );
}

class _BeadsPainter extends CustomPainter {
  final List<double> v;
  final List<String> labels;
  final double target, t;
  final String targetLabel;
  final String Function(double) axis;
  final _P p;
  _BeadsPainter(this.v, this.labels, this.target, this.targetLabel, this.axis, this.p, this.t);

  @override
  void paint(Canvas canvas, Size s) {
    final maxV = [...v, target, 1.0].reduce(math.max) * 1.15;
    const left = 56.0, bottom = 26.0;
    final h = s.height - bottom;
    final w = s.width - left;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    void text(String str, Offset at, Color c, double size, {bool center = false}) {
      tp.text = TextSpan(text: str, style: TextStyle(color: c, fontSize: size, fontWeight: FontWeight.w600));
      tp.layout();
      tp.paint(canvas, center ? at - Offset(tp.width / 2, 0) : at);
    }

    // grid + axis
    for (var g = 0; g <= 5; g++) {
      final y = h - h * g / 5;
      canvas.drawLine(Offset(left, y), Offset(s.width, y), Paint()..color = p.line..strokeWidth = 1);
      text(axis(maxV * g / 5), Offset(0, y - 8), p.muted, 12);
    }
    final n = v.length;
    if (n == 0) return;
    final step = w / n;
    // stems + beads (staggered)
    for (var i = 0; i < n; i++) {
      final k = ((t * 1.25) - i * (0.25 / n)).clamp(0.0, 1.0);
      final e = Curves.easeOutExpo.transform(k);
      final x = left + step * (i + 0.5);
      final val = v[i] * e;
      final y = h - h * (val / maxV);
      final lit = target > 0 && v[i] >= target;
      final color = lit ? p.accent : p.data;
      final stroke = n > 20 ? 4.0 : 7.0;
      {
        final paint = Paint()..strokeWidth = stroke..strokeCap = StrokeCap.round;
        paint.shader = ui.Gradient.linear(Offset(x, y), Offset(x, h), [color, color.withOpacity(lit ? 0.55 : 0.6)]);
        canvas.drawLine(Offset(x, h), Offset(x, y), paint);
        final r = n > 20 ? 5.0 : 9.0;
        if (lit) canvas.drawCircle(Offset(x, y), r + 6, Paint()..color = color.withOpacity(0.25)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
        canvas.drawCircle(Offset(x, y), r, Paint()..color = lit ? color : p.card);
        canvas.drawCircle(Offset(x, y), r, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = lit ? 0 : 3.5);
      }
      if (n <= 16 ? i % 2 == 0 : i % (n ~/ 6 + 1) == 0) text(labels[i], Offset(x, h + 8), p.muted, 11.5, center: true);
    }
    // the target line (fades in, slides up into place)
    if (target > 0) {
      final k = ((t - 0.3) / 0.7).clamp(0.0, 1.0);
      final y = h - h * (target / maxV) * Curves.easeOutExpo.transform(k);
      final paint = Paint()..color = p.accent.withOpacity(k)..strokeWidth = 2;
      for (double x = left; x < s.width; x += 10) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + 5, s.width), y), paint);
      }
      tp.text = TextSpan(text: targetLabel, style: TextStyle(color: Colors.white.withOpacity(k), fontSize: 12, fontWeight: FontWeight.w800));
      tp.layout();
      final box = RRect.fromRectAndRadius(Rect.fromLTWH(0, y - 13, tp.width + 16, 26), const Radius.circular(8));
      canvas.drawRRect(box, Paint()..color = p.accent.withOpacity(k));
      tp.paint(canvas, Offset(8, y - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _BeadsPainter o) => o.t != t || o.v != v || o.target != target;
}

/// A tap with Ignara's little press-in.
class _Press extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const _Press({required this.child, this.onTap});

  @override
  State<_Press> createState() => _PressState();
}

class _PressState extends State<_Press> {
  bool _down = false;

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedScale(scale: _down ? 0.97 : 1, duration: const Duration(milliseconds: 160), curve: Curves.easeOutBack, child: widget.child),
      );
}
