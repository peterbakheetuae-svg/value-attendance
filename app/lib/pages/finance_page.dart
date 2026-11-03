import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/async_view.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../design/app_colors.dart';
import '../design/glass.dart';
import '../design/glass_page.dart';
import '../design/primary_button.dart';
import 'common.dart';
import 'kpi_page.dart';

/// Salary adjustments in EGP. Four-eyes: the server refuses self-approval and self-adjustment.
class FinancePage extends StatefulWidget {
  const FinancePage({super.key});
  @override
  State<FinancePage> createState() => _FinancePageState();
}

class _FinancePageState extends State<FinancePage> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  Key _k = UniqueKey();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return GlassPage(
      title: t('financial_adjustments'),
      floating: s.has('finance.manage') ? FloatingActionButton.extended(
        backgroundColor: AppColors.primary, foregroundColor: Colors.white, icon: const Icon(Icons.add), label: Text(t('new_adjustment')),
        onPressed: () async { if (await _create(context) == true) setState(() => _k = UniqueKey()); },
      ) : null,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(alignment: AlignmentDirectional.centerStart, child: MonthPicker(month: _month, onChanged: (m) => setState(() { _month = m; _k = UniqueKey(); }))),
        const SizedBox(height: 12),
        AsyncView<Map<String, dynamic>>(
          key: _k,
          load: () => s.api.get('/finance/adjustments', {'month': Fmt.month(_month)}),
          builder: (ctx, d, reload) {
            final list = d.list('adjustments');
            if (list.isEmpty) return EmptyState(t('no_adjustments'));
            return Column(children: [
              for (final a in list) Padding(padding: const EdgeInsets.only(bottom: 10), child: GlassCard(radius: 20, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Icon(a['kind'] == 'bonus' ? Icons.add_circle : Icons.remove_circle, color: a['kind'] == 'bonus' ? AppColors.success : AppColors.error),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${a.s('employee_name')} · ${t('adj_${a.s('kind')}')}', style: const TextStyle(fontWeight: FontWeight.w800))),
                  StatusPill(a.s('status')),
                ]),
                InfoTile(title: t('amount'), value: Fmt.egp(a['amount_egp'])),
                InfoTile(title: t('reason'), value: a.s('reason')),
                InfoTile(title: t('created_by'), value: a.s('created_by_name')),
                if (a['decided_by_name'] != null) InfoTile(title: t('decided_by'), value: a.s('decided_by_name')),
                if (a['canDecide'] == true) Row(children: [
                  Expanded(child: TextButton(onPressed: () => _decide(context, a.s('id'), 'approve', reload), child: Text(t('approve')))),
                  Expanded(child: TextButton(onPressed: () => _decide(context, a.s('id'), 'reject', reload), child: Text(t('reject'), style: const TextStyle(color: AppColors.error)))),
                ]),
              ]))),
            ]);
          },
        ),
      ]),
    );
  }

  Future<void> _decide(BuildContext context, String id, String decision, Future<void> Function() reload) async {
    String? comment;
    if (decision == 'reject') {
      final c = TextEditingController();
      final ok = await showGlassSheet<bool>(context, title: t('reject'), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: c, decoration: glassInput(context, t('rejection_reason_required'))),
        const SizedBox(height: 12),
        PrimaryButton(label: t('reject'), color: AppColors.error, onTap: () => Navigator.pop(context, c.text.trim().length >= 3)),
      ]));
      if (ok != true) return;
      comment = c.text.trim();
    }
    try {
      await context.read<Session>().api.post('/finance/adjustments/$id/decision', {'decision': decision, if (comment != null) 'comment': comment});
      await reload();
    } catch (e) { if (context.mounted) showSnack(context, errorText(e), error: true); }
  }

  Future<bool?> _create(BuildContext context) async {
    final s = context.read<Session>();
    Map<String, dynamic> emps;
    try { emps = await s.api.get('/reports/payroll', {'month': Fmt.month(_month)}); } catch (e) { if (context.mounted) showSnack(context, errorText(e), error: true); return false; }
    final list = emps.list('rows').map((r) => r.obj('employee')!).where((e) => e['id'] != s.id).toList();
    String? emp;
    String kind = 'deduction';
    final amount = TextEditingController(), reason = TextEditingController();
    if (!context.mounted) return false;
    return showGlassSheet<bool>(context, title: t('new_adjustment'), child: StatefulBuilder(builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DropdownButtonFormField<String>(value: emp, isExpanded: true, decoration: glassInput(ctx, t('employee')),
          items: [for (final e in list) DropdownMenuItem(value: e.s('id'), child: Text('${e.s('fullName')} · ${e.s('code')}'))],
          onChanged: (v) => set(() => emp = v)),
      const SizedBox(height: 10),
      FilterChips<String>(options: [('deduction', t('adj_deduction')), ('bonus', t('adj_bonus'))], value: kind, onChanged: (v) => set(() => kind = v)),
      const SizedBox(height: 10),
      TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: glassInput(ctx, '${t('amount')} (${t('egp')})')),
      const SizedBox(height: 10),
      TextField(controller: reason, decoration: glassInput(ctx, t('reason'))),
      const SizedBox(height: 16),
      PrimaryButton(label: t('save'), onTap: () async {
        final v = double.tryParse(amount.text.trim());
        if (emp == null || v == null || v <= 0 || reason.text.trim().length < 3) { showSnack(ctx, t('fill_required'), error: true); return; }
        try {
          await s.api.post('/finance/adjustments', {'employeeId': emp, 'month': Fmt.month(_month), 'kind': kind, 'amountEgp': v, 'reason': reason.text.trim()});
          if (ctx.mounted) Navigator.pop(ctx, true);
        } catch (e) { if (ctx.mounted) showSnack(ctx, errorText(e), error: true); }
      }),
    ])));
  }
}

/// KPI status of every readable sales employee for a month.
class KpiOverviewPage extends StatefulWidget {
  const KpiOverviewPage({super.key});
  @override
  State<KpiOverviewPage> createState() => _KpiOverviewPageState();
}

class _KpiOverviewPageState extends State<KpiOverviewPage> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  Key _k = UniqueKey();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return GlassPage(
      title: t('kpi_overview'),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(alignment: AlignmentDirectional.centerStart, child: MonthPicker(month: _month, onChanged: (m) => setState(() { _month = m; _k = UniqueKey(); }))),
        const SizedBox(height: 12),
        AsyncView<Map<String, dynamic>>(
          key: _k,
          load: () => s.api.get('/kpi/overview', {'month': Fmt.month(_month)}),
          builder: (ctx, d, _) {
            final list = d.list('employees');
            if (list.isEmpty) return EmptyState(t('no_employees'));
            return Column(children: [
              for (final x in list) Padding(padding: const EdgeInsets.only(bottom: 10), child: GlassCard(
                radius: 20,
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => GlassPage(title: x.obj('employee')!.s('full_name'), body: EmployeeKpiView(employeeId: x.obj('employee')!.s('id'))))),
                child: Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(x.obj('employee')!.s('full_name'), style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text([x.obj('employee')!.s('job_title'), x.obj('employee')!['team_name']?.toString() ?? ''].where((v) => v.isNotEmpty).join(' · '), style: const TextStyle(fontSize: 12)),
                  ])),
                  Text(x['weightedScore'] == null ? '—' : Fmt.num1(x['weightedScore']), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppColors.primary)),
                  const SizedBox(width: 10),
                  StatusPill(x['belowTarget'] == true ? 'below_target' : x.s('status')),
                ]),
              )),
            ]);
          },
        ),
      ]),
    );
  }
}
