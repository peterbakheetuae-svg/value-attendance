import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import '../core/async_view.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../core/save_file.dart';
import '../core/session.dart';
import '../design/app_colors.dart';
import '../design/glass.dart';
import '../design/glass_page.dart';
import '../design/primary_button.dart';
import 'common.dart';

/// Monthly reports: filters (month · department · team · sales manager), per-employee
/// summaries from /reports/monthly, Excel export (server) and PDF/print (client, RTL Cairo).
class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});
  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  String? _dept, _team, _mgr;
  Key _k = UniqueKey();
  bool _exporting = false;
  Map<String, dynamic>? _last;

  Map<String, String?> get _query => {'month': Fmt.month(_month), 'departmentId': _dept, 'teamId': _team, 'salesManagerId': _mgr};

  Future<void> _xlsx() async {
    setState(() => _exporting = true);
    try {
      final bytes = await context.read<Session>().api.bytes('/reports/monthly.xlsx', _query);
      await saveXlsx('monthly-report-${Fmt.month(_month)}', bytes);
      if (mounted) showSnack(context, t('export_ready'));
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    final full = s.has('report.read_all');
    return GlassPage(
      title: t('monthly_reports'),
      actions: [
        IconButton(tooltip: t('export_excel'), icon: const Icon(Icons.table_view_rounded), onPressed: _exporting ? null : _xlsx),
        IconButton(tooltip: t('export_pdf'), icon: const Icon(Icons.picture_as_pdf_rounded), onPressed: _last == null ? null : () => printTeamReport(_last!, _month)),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          MonthPicker(month: _month, onChanged: (m) => setState(() { _month = m; _k = UniqueKey(); })),
          if (full) _RefFilter(path: '/departments', listKey: 'departments', label: t('department'), nameKey: 'name_ar', value: _dept, onChanged: (v) => setState(() { _dept = v; _k = UniqueKey(); })),
          if (full) _RefFilter(path: '/teams', listKey: 'teams', label: t('team'), nameKey: 'name', value: _team, onChanged: (v) => setState(() { _team = v; _k = UniqueKey(); })),
          if (full) _RefFilter(path: '/employees', query: const {'role': 'sales_manager'}, listKey: 'employees', label: t('sales_manager'), nameKey: 'full_name', value: _mgr, onChanged: (v) => setState(() { _mgr = v; _k = UniqueKey(); })),
        ]),
        const SizedBox(height: 12),
        AsyncView<Map<String, dynamic>>(
          key: _k,
          load: () async {
            final r = await s.api.get('/reports/monthly', _query);
            WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) setState(() => _last = r); });
            return r;
          },
          builder: (ctx, d, _) {
            final reps = d.list('reports');
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (d['complete'] == false) Padding(padding: const EdgeInsets.only(bottom: 8), child: StatusChip(t('period_incomplete'), color: AppColors.warning)),
              if (reps.isEmpty) EmptyState(t('no_report_data')),
              for (final r in reps) Padding(padding: const EdgeInsets.only(bottom: 10), child: GlassCard(
                radius: 20,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => EmployeeReportPage(employeeId: r.obj('employee')!.s('id'), month: _month))),
                child: _ReportRow(r: r),
              )),
            ]);
          },
        ),
      ]),
    );
  }
}

class _ReportRow extends StatelessWidget {
  final Map<String, dynamic> r;
  const _ReportRow({required this.r});
  @override
  Widget build(BuildContext context) {
    final e = r.obj('employee')!, a = r.obj('attendance')!, sm = r.obj('summary')!, k = r.obj('kpi');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(e.s('fullName'), style: const TextStyle(fontWeight: FontWeight.w800))),
        Text(sm['overallPercent'] == null ? '—' : Fmt.percent(sm['overallPercent']), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppColors.primary)),
      ]),
      Text([e.s('jobTitle'), if (e['teamName'] != null) e.s('teamName')].where((x) => x.isNotEmpty).join(' · '), style: const TextStyle(fontSize: 12)),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        StatusChip('${t('attendance')}: ${Fmt.percent(a['attendancePercent'])}', color: statusColor(sm.s('attendanceStatus'))),
        StatusChip('${t('kpi')}: ${k?['weightedScore'] == null ? t('status_${sm.s('kpiStatus')}') : Fmt.num1(k!['weightedScore'])}', color: statusColor(sm.s('kpiStatus'))),
        StatusChip('${t('evaluation')}: ${t('status_${sm.s('evaluationStatus')}')}', color: statusColor(sm.s('evaluationStatus'))),
        if ((a['lateArrivals'] ?? 0) > 0) StatusChip('${t('late_arrivals')}: ${a['lateArrivals']}', color: AppColors.warning),
        if ((a['unapprovedAbsenceDays'] ?? 0) > 0) StatusChip('${t('unapproved_absence')}: ${a['unapprovedAbsenceDays']}', color: AppColors.error),
      ]),
    ]);
  }
}

class _RefFilter extends StatelessWidget {
  final String path, listKey, label, nameKey;
  final Map<String, String>? query;
  final String? value;
  final ValueChanged<String?> onChanged;
  const _RefFilter({required this.path, required this.listKey, required this.label, required this.nameKey, required this.value, required this.onChanged, this.query});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 220,
        child: FutureBuilder<Map<String, dynamic>>(
          future: context.read<Session>().api.get(path, query),
          builder: (ctx, snap) {
            final items = snap.data?.list(listKey) ?? const [];
            return DropdownButtonFormField<String?>(
              value: items.any((x) => x['id'] == value) ? value : null,
              isExpanded: true,
              decoration: glassInput(context, label),
              items: [DropdownMenuItem<String?>(value: null, child: Text(t('all'))),
                for (final x in items) DropdownMenuItem<String?>(value: x.s('id'), child: Text(x.s(nameKey), overflow: TextOverflow.ellipsis))],
              onChanged: onChanged,
            );
          },
        ),
      );
}

/// One employee's monthly report (attendance · requests · KPI · evaluation · summary).
class EmployeeReportPage extends StatelessWidget {
  final String employeeId;
  final DateTime month;
  const EmployeeReportPage({super.key, required this.employeeId, required this.month});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return AsyncView<Map<String, dynamic>>(
      load: () => s.api.get('/reports/monthly/employee/$employeeId', {'month': Fmt.month(month)}),
      builder: (ctx, d, _) {
        final r = d.obj('report')!;
        final e = r.obj('employee')!, a = r.obj('attendance')!, rq = r.obj('requests')!, k = r.obj('kpi'), ev = r.obj('evaluation')!, sm = r.obj('summary')!;
        return GlassPage(
          title: '${t('monthly_report')} — ${Fmt.monthLabel(month)}',
          actions: [IconButton(tooltip: t('export_pdf'), icon: const Icon(Icons.picture_as_pdf_rounded), onPressed: () => printEmployeeReport(r, month))],
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            GlassCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(e.s('fullName'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
              Text([e.s('code'), e.s('jobTitle'), if (e['teamName'] != null) e.s('teamName'), if (e['salesManagerName'] != null) e.s('salesManagerName')].where((x) => x.isNotEmpty).join(' · ')),
              if (r['complete'] == false) Padding(padding: const EdgeInsets.only(top: 8), child: StatusChip(t('period_incomplete'), color: AppColors.warning)),
            ])),
            SectionTitle(t('attendance')),
            MiniCardGrid(children: [
              GlassMiniCard(title: t('working_days'), value: '${a['workingDays']}'),
              GlassMiniCard(title: t('days_attended'), value: '${a['attendedDays']}'),
              GlassMiniCard(title: t('absence_days'), value: '${a['absenceDays']}'),
              GlassMiniCard(title: t('approved_absence'), value: '${a['approvedAbsenceDays']}'),
              GlassMiniCard(title: t('unapproved_absence'), value: '${a['unapprovedAbsenceDays']}'),
              GlassMiniCard(title: t('late_arrivals'), value: '${a['lateArrivals']}'),
              GlassMiniCard(title: t('early_departures'), value: '${a['earlyDepartures']}'),
              GlassMiniCard(title: t('working_hours'), value: Fmt.minutes(a['workedMinutes'])),
              GlassMiniCard(title: t('overtime_hours'), value: Fmt.minutes(a['overtimeMinutes'])),
              GlassMiniCard(title: t('hourly_permissions'), value: '${a['hourlyPermissions']}'),
              GlassMiniCard(title: t('attendance_percent'), value: Fmt.percent(a['attendancePercent'])),
            ]),
            SectionTitle(t('requests')),
            MiniCardGrid(children: [
              GlassMiniCard(title: t('total'), value: '${rq['total']}'),
              GlassMiniCard(title: t('status_approved'), value: '${rq['approved']}'),
              GlassMiniCard(title: t('status_rejected'), value: '${rq['rejected']}'),
              GlassMiniCard(title: t('status_pending'), value: '${rq['pending']}'),
              GlassMiniCard(title: t('hourly_permissions'), value: '${rq['hourlyPermissions']}'),
              GlassMiniCard(title: t('absence_requests'), value: '${rq['absenceRequests']}'),
            ]),
            SectionTitle(t('kpi')),
            if (k == null || (k.list('items')).isEmpty) EmptyState(t('no_kpis_assigned')) else MiniCardGrid(children: [
              GlassMiniCard(title: t('kpi_status'), value: t('status_${sm.s('kpiStatus')}')),
              GlassMiniCard(title: t('monthly_target'), value: k['target'] == null ? t('mixed_units') : Fmt.num1(k['target'])),
              GlassMiniCard(title: t('actual'), value: k['actual'] == null ? '—' : Fmt.num1(k['actual'])),
              GlassMiniCard(title: t('achievement'), value: Fmt.percent(k['achievementPercent'])),
              GlassMiniCard(title: t('weighted_score'), value: k['weightedScore'] == null ? '—' : Fmt.num1(k['weightedScore'])),
              GlassMiniCard(title: t('change_vs_previous'), value: k['change'] == null ? '—' : Fmt.num1(k['change'])),
            ]),
            SectionTitle(t('evaluation')),
            GlassCard(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Column(children: [
              InfoTile(title: t('manager_score'), value: Fmt.percent(ev['managerScore'])),
              InfoTile(title: t('hr_score'), value: Fmt.percent(ev['hrScore'])),
              if (ev.s('strengths').isNotEmpty) InfoTile(title: t('strengths'), value: ev.s('strengths')),
              if (ev.s('improvements').isNotEmpty) InfoTile(title: t('areas_for_improvement'), value: ev.s('improvements')),
              if (ev.s('comments').isNotEmpty) InfoTile(title: t('comments'), value: ev.s('comments')),
              if (ev.s('recommendations').isNotEmpty) InfoTile(title: t('manager_recommendations'), value: ev.s('recommendations')),
            ])),
            SectionTitle(t('summary')),
            GlassCard(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Column(children: [
              InfoTile(title: t('overall_performance'), value: sm['overallPercent'] == null ? '—' : Fmt.percent(sm['overallPercent'])),
              InfoTile(title: t('based_on'), value: (sm['components'] as List).map((c) => t(c.toString())).join(' + ')),
              InfoTile(title: t('attendance_status'), value: t('status_${sm.s('attendanceStatus')}')),
              InfoTile(title: t('kpi_status'), value: t('status_${sm.s('kpiStatus')}')),
              InfoTile(title: t('evaluation_status'), value: t('status_${sm.s('evaluationStatus')}')),
            ])),
            const SizedBox(height: 16),
            PrimaryButton(label: t('export_pdf'), icon: Icons.picture_as_pdf_rounded, onTap: () => printEmployeeReport(r, month)),
          ]),
        );
      },
    );
  }
}

/// Accountant view: payroll-related attendance + approved adjustments, money in EGP only.
class PayrollPage extends StatefulWidget {
  const PayrollPage({super.key});
  @override
  State<PayrollPage> createState() => _PayrollPageState();
}

class _PayrollPageState extends State<PayrollPage> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  Key _k = UniqueKey();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return GlassPage(
      title: t('payroll_summary'),
      actions: [IconButton(tooltip: t('export_excel'), icon: const Icon(Icons.table_view_rounded), onPressed: () async {
        try {
          final b = await s.api.bytes('/reports/payroll.xlsx', {'month': Fmt.month(_month)});
          await saveXlsx('payroll-${Fmt.month(_month)}', b);
          if (context.mounted) showSnack(context, t('export_ready'));
        } catch (e) { if (context.mounted) showSnack(context, errorText(e), error: true); }
      })],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(alignment: AlignmentDirectional.centerStart, child: MonthPicker(month: _month, onChanged: (m) => setState(() { _month = m; _k = UniqueKey(); }))),
        const SizedBox(height: 12),
        AsyncView<Map<String, dynamic>>(
          key: _k,
          load: () => s.api.get('/reports/payroll', {'month': Fmt.month(_month)}),
          builder: (ctx, d, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (d['complete'] == false) Padding(padding: const EdgeInsets.only(bottom: 8), child: StatusChip(t('period_incomplete'), color: AppColors.warning)),
            for (final r in d.list('rows')) Padding(padding: const EdgeInsets.only(bottom: 10), child: GlassCard(radius: 20, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${r.obj('employee')!.s('fullName')} · ${r.obj('employee')!.s('code')}', style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                StatusChip('${t('days_attended')}: ${r.obj('attendance')!['attendedDays']}/${r.obj('attendance')!['workingDays']}', color: AppColors.primary),
                StatusChip('${t('approved_absence')}: ${r.obj('attendance')!['approvedAbsenceDays']}', color: AppColors.secondary),
                StatusChip('${t('unpaid_days')}: ${r.obj('attendance')!['unpaidAbsenceDays']}', color: AppColors.error),
                StatusChip('${t('unapproved_absence')}: ${r.obj('attendance')!['unapprovedAbsenceDays']}', color: AppColors.error),
                StatusChip('${t('late_minutes')}: ${r.obj('attendance')!['lateMinutes']}', color: AppColors.warning),
              ]),
              const GlassDivider(margin: EdgeInsets.symmetric(vertical: 8)),
              if (r.obj('money')!.containsKey('baseSalary')) InfoTile(title: t('base_salary'), value: Fmt.egp(r.obj('money')!['baseSalary'])),
              if (r.obj('payroll') != null) ..._payrollLines(r.obj('payroll')!)
              else ...[
                InfoTile(title: t('approved_deductions'), value: Fmt.egp(r.obj('money')!['approvedDeductions'])),
                InfoTile(title: t('approved_bonuses'), value: Fmt.egp(r.obj('money')!['approvedBonuses'])),
              ],
            ]))),
          ]),
        ),
      ]),
    );
  }
}

/// Automatic deductions breakdown (Value HR rules) in the original InfoTile style.
List<Widget> _payrollLines(Map<String, dynamic> p) {
  final auto = p.obj('rules')?['auto'] == true;
  String daysMin(Map<String, dynamic>? x) => '${x?['days'] ?? 0} ${t('day_unit')} · ${x?['minutes'] ?? 0} ${t('min_short')}';
  return [
    InfoTile(title: t('day_wage'), value: Fmt.egp(p['dayWage'])),
    if (!auto) Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(t('auto_deductions_off'), style: const TextStyle(fontSize: 12, color: AppColors.warning))),
    InfoTile(title: '${t('late_deduction')} (${daysMin(p.obj('late'))})', value: Fmt.egp(p.obj('late')?['amount'])),
    InfoTile(title: '${t('early_deduction')} (${daysMin(p.obj('early'))})', value: Fmt.egp(p.obj('early')?['amount'])),
    InfoTile(title: '${t('absence_deduction')} (${p.obj('absence')?['days'] ?? 0} ${t('day_unit')})', value: Fmt.egp(p.obj('absence')?['amount'])),
    InfoTile(title: '${t('unpaid_deduction')} (${p.obj('unpaid')?['days'] ?? 0} ${t('day_unit')})', value: Fmt.egp(p.obj('unpaid')?['amount'])),
    InfoTile(title: t('admin_deductions'), value: Fmt.egp(p['adminDeductions'])),
    InfoTile(title: t('approved_bonuses'), value: Fmt.egp(p['bonuses'])),
    const GlassDivider(margin: EdgeInsets.symmetric(vertical: 6)),
    InfoTile(title: t('total_deductions'), value: Fmt.egp(p['totalDeductions'])),
    InfoTile(title: p['complete'] == true ? t('net_salary') : t('net_salary_to_date'), value: Fmt.egp(p['net'])),
  ];
}

// ----------------------------------------------------------------------------- PDF (RTL, Cairo)

Future<pw.ThemeData> _pdfTheme() async {
  final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
  return pw.ThemeData.withFont(base: regular, bold: bold);
}

pw.Widget _kv(String k, String v) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [pw.Text(k), pw.Text(v, style: pw.TextStyle(fontWeight: pw.FontWeight.bold))]),
    );

pw.Widget _section(String title, List<pw.Widget> rows) => pw.Container(
      margin: const pw.EdgeInsets.only(top: 10),
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColor.fromInt(0xFFE2E8F0)), borderRadius: const pw.BorderRadius.all(pw.Radius.circular(10))),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        pw.Text(title, style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold, color: PdfColor.fromInt(0xFF4F46E5))),
        pw.SizedBox(height: 6),
        ...rows,
      ]),
    );

pw.Widget _pdfHeader(String title, DateTime month, bool complete) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      pw.Text(t('app_name'), style: pw.TextStyle(fontSize: 11, color: PdfColor.fromInt(0xFF64748B))),
      pw.Text(title, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
      pw.Text('${Fmt.monthLabel(month)}${complete ? '' : ' — ${t('period_incomplete')}'}'),
      pw.Divider(color: PdfColor.fromInt(0xFF4F46E5)),
    ]);

Future<void> printEmployeeReport(Map<String, dynamic> r, DateTime month) async {
  final theme = await _pdfTheme();
  final e = r.obj('employee')!, a = r.obj('attendance')!, rq = r.obj('requests')!, k = r.obj('kpi'), ev = r.obj('evaluation')!, sm = r.obj('summary')!;
  final doc = pw.Document(theme: theme);
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    textDirection: I18n.isRtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
    build: (_) => [
      _pdfHeader('${t('monthly_report')} — ${e.s('fullName')}', month, r['complete'] == true),
      _kv(t('employee_code'), e.s('code')), _kv(t('job_title'), e.s('jobTitle')), _kv(t('team'), e['teamName']?.toString() ?? '—'),
      _section(t('attendance'), [
        _kv(t('working_days'), '${a['workingDays']}'), _kv(t('days_attended'), '${a['attendedDays']}'),
        _kv(t('absence_days'), '${a['absenceDays']}'), _kv(t('approved_absence'), '${a['approvedAbsenceDays']}'),
        _kv(t('unapproved_absence'), '${a['unapprovedAbsenceDays']}'), _kv(t('late_arrivals'), '${a['lateArrivals']}'),
        _kv(t('early_departures'), '${a['earlyDepartures']}'), _kv(t('working_hours'), Fmt.minutes(a['workedMinutes'])),
        _kv(t('overtime_hours'), Fmt.minutes(a['overtimeMinutes'])), _kv(t('hourly_permissions'), '${a['hourlyPermissions']}'),
        _kv(t('attendance_percent'), Fmt.percent(a['attendancePercent'])),
      ]),
      _section(t('requests'), [
        _kv(t('total'), '${rq['total']}'), _kv(t('status_approved'), '${rq['approved']}'), _kv(t('status_rejected'), '${rq['rejected']}'),
        _kv(t('status_pending'), '${rq['pending']}'), _kv(t('hourly_permissions'), '${rq['hourlyPermissions']}'), _kv(t('absence_requests'), '${rq['absenceRequests']}'),
      ]),
      _section(t('kpi'), k == null ? [pw.Text(t('no_kpis_assigned'))] : [
        _kv(t('kpi_status'), t('status_${sm.s('kpiStatus')}')),
        _kv(t('monthly_target'), k['target'] == null ? t('mixed_units') : Fmt.num1(k['target'])),
        _kv(t('actual'), k['actual'] == null ? '—' : Fmt.num1(k['actual'])),
        _kv(t('achievement'), Fmt.percent(k['achievementPercent'])), _kv(t('weighted_score'), Fmt.num1(k['weightedScore'])),
        _kv(t('change_vs_previous'), k['change'] == null ? '—' : Fmt.num1(k['change'])),
        for (final it in k.list('items')) _kv('  ${it.s('nameAr')}', '${it['actual'] == null ? t('status_not_evaluated') : Fmt.num1(it['actual'])} / ${Fmt.num1(it['target'])}'),
      ]),
      _section(t('evaluation'), [
        _kv(t('manager_score'), Fmt.percent(ev['managerScore'])), _kv(t('hr_score'), Fmt.percent(ev['hrScore'])),
        if (ev.s('strengths').isNotEmpty) _kv(t('strengths'), ev.s('strengths')),
        if (ev.s('improvements').isNotEmpty) _kv(t('areas_for_improvement'), ev.s('improvements')),
        if (ev.s('recommendations').isNotEmpty) _kv(t('manager_recommendations'), ev.s('recommendations')),
      ]),
      _section(t('summary'), [
        _kv(t('overall_performance'), Fmt.percent(sm['overallPercent'])),
        _kv(t('attendance_status'), t('status_${sm.s('attendanceStatus')}')),
        _kv(t('kpi_status'), t('status_${sm.s('kpiStatus')}')),
        _kv(t('evaluation_status'), t('status_${sm.s('evaluationStatus')}')),
      ]),
    ],
  ));
  await Printing.layoutPdf(name: 'report-${e.s('code')}-${Fmt.month(month)}.pdf', onLayout: (_) async => doc.save());
}

Future<void> printTeamReport(Map<String, dynamic> d, DateTime month) async {
  final theme = await _pdfTheme();
  final doc = pw.Document(theme: theme);
  final reps = d.list('reports');
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4.landscape,
    textDirection: I18n.isRtl ? pw.TextDirection.rtl : pw.TextDirection.ltr,
    build: (_) => [
      _pdfHeader(t('monthly_reports'), month, d['complete'] == true),
      pw.TableHelper.fromTextArray(
        headers: [t('full_name'), t('days_attended'), t('absence_days'), t('late_arrivals'), t('attendance_percent'), t('weighted_score'), t('manager_score'), t('overall_performance')],
        data: [for (final r in reps) [
          r.obj('employee')!.s('fullName'),
          '${r.obj('attendance')!['attendedDays']}/${r.obj('attendance')!['workingDays']}',
          '${r.obj('attendance')!['absenceDays']}', '${r.obj('attendance')!['lateArrivals']}',
          Fmt.percent(r.obj('attendance')!['attendancePercent']),
          r.obj('kpi')?['weightedScore'] == null ? '—' : Fmt.num1(r.obj('kpi')!['weightedScore']),
          Fmt.percent(r.obj('evaluation')!['managerScore']),
          Fmt.percent(r.obj('summary')!['overallPercent']),
        ]],
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
        headerDecoration: const pw.BoxDecoration(color: PdfColor.fromInt(0xFF4F46E5)),
        cellAlignment: pw.Alignment.center,
      ),
    ],
  ));
  await Printing.layoutPdf(name: 'monthly-report-${Fmt.month(month)}.pdf', onLayout: (_) async => doc.save());
}
