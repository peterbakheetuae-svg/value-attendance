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

/// KPI section of an employee profile: target · actual · achievement · weighted score,
/// previous-period comparison and a 6-month trend. Missing data shows as "not evaluated".
class EmployeeKpiView extends StatefulWidget {
  final String employeeId;
  const EmployeeKpiView({super.key, required this.employeeId});
  @override
  State<EmployeeKpiView> createState() => _EmployeeKpiViewState();
}

class _EmployeeKpiViewState extends State<EmployeeKpiView> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  Key _k = UniqueKey();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle(t('kpi'), trailing: MonthPicker(month: _month, onChanged: (m) => setState(() { _month = m; _k = UniqueKey(); }))),
      AsyncView<Map<String, dynamic>>(
        key: _k,
        load: () => s.api.get('/kpi/employees/${widget.employeeId}', {'month': Fmt.month(_month)}),
        builder: (ctx, d, reload) {
          final cur = d.obj('current')!;
          final items = cur.list('items');
          final canEnter = d['canEnter'] == true;
          if (items.isEmpty) return EmptyState(t('no_kpis_assigned'), icon: Icons.insights_rounded);
          final change = d['change'];
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            MiniCardGrid(children: [
              GlassMiniCard(title: t('weighted_score'), value: cur['weightedScore'] == null ? t('status_not_evaluated') : '${Fmt.num1(cur['weightedScore'])} / 100',
                  icon: Icons.insights_rounded, iconColor: AppColors.secondary),
              GlassMiniCard(title: t('kpi_status'), value: t('status_${cur['status']}'), icon: Icons.flag_rounded, iconColor: statusColor(cur.s('status'))),
              GlassMiniCard(title: t('previous_period'), value: d.obj('previous')!['weightedScore'] == null ? '—' : Fmt.num1(d.obj('previous')!['weightedScore']), icon: Icons.history_rounded),
              GlassMiniCard(title: t('change_vs_previous'), value: change == null ? '—' : '${(change as num) >= 0 ? '+' : ''}${Fmt.num1(change)}',
                  icon: change == null ? Icons.remove : (change as num) >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                  iconColor: change == null ? null : (change as num) >= 0 ? AppColors.success : AppColors.error),
            ]),
            const SizedBox(height: 12),
            for (final it in items) Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GlassCard(radius: 20, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text(I18n.lang == 'ar' ? it.s('nameAr') : (it.s('nameEn').isEmpty ? it.s('nameAr') : it.s('nameEn')), style: const TextStyle(fontWeight: FontWeight.w800))),
                  StatusPill(it.s('state')),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _metric(t('weight'), '${Fmt.num1(it['weight'])}%')),
                  Expanded(child: _metric(t('target'), _val(it['target'], it.s('measurementType')))),
                  Expanded(child: _metric(t('actual'), it['actual'] == null ? '—' : _val(it['actual'], it.s('measurementType')))),
                  Expanded(child: _metric(t('achievement'), Fmt.percent(it['achievementPercent']))),
                ]),
                const SizedBox(height: 8),
                ClipRRect(borderRadius: BorderRadius.circular(6), child: LinearProgressIndicator(
                  minHeight: 8,
                  value: it['achievementPercent'] == null ? 0 : ((it['achievementPercent'] as num) / 100).clamp(0, 1).toDouble(),
                  backgroundColor: Colors.grey.withValues(alpha: 0.2),
                  color: statusColor(it.s('state')),
                )),
                if (canEnter) Align(alignment: AlignmentDirectional.centerEnd, child: TextButton.icon(
                  icon: const Icon(Icons.edit_rounded), label: Text(t('enter_actual')),
                  onPressed: () async { if (await _enter(context, it) == true) await reload(); },
                )),
              ])),
            ),
            SectionTitle(t('monthly_trend')),
            GlassCard(child: _Trend(points: d.list('trend'))),
          ]);
        },
      ),
    ]);
  }

  String _val(Object? v, String type) => type == 'amount_egp' ? Fmt.egp(v) : type == 'percent' ? Fmt.percent(v) : Fmt.num1(v);

  Widget _metric(String label, String value) => Column(children: [
        Text(label, style: const TextStyle(fontSize: 11)),
        const SizedBox(height: 2),
        Text(value, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800)),
      ]);

  Future<bool?> _enter(BuildContext context, Map<String, dynamic> it) {
    final c = TextEditingController(text: it['actual']?.toString() ?? '');
    String state = it['state'] == 'below_target' ? 'completed' : it.s('state');
    if (state == 'not_evaluated') state = 'in_progress';
    return showGlassSheet<bool>(context, title: '${t('enter_actual')} — ${it.s('nameAr')}', child: StatefulBuilder(builder: (ctx, set) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: glassInput(ctx, '${t('actual')} (${t('target')}: ${Fmt.num1(it['target'])})')),
        const SizedBox(height: 12),
        FilterChips<String>(options: [('in_progress', t('status_in_progress')), ('completed', t('status_completed')), ('not_evaluated', t('clear_value'))],
            value: state, onChanged: (v) => set(() => state = v)),
        const SizedBox(height: 16),
        PrimaryButton(label: t('save'), onTap: () async {
          final v = double.tryParse(c.text.trim());
          if (state != 'not_evaluated' && (v == null || v < 0)) { showSnack(ctx, t('invalid_amount'), error: true); return; }
          try {
            await context.read<Session>().api.put('/kpi/results/${it['id']}', {'state': state, if (state != 'not_evaluated') 'actual': v});
            if (ctx.mounted) Navigator.pop(ctx, true);
          } catch (e) { if (ctx.mounted) showSnack(ctx, errorText(e), error: true); }
        }),
      ],
    )));
  }
}

/// Six-month bar trend; months without data are drawn hollow (never as zero).
class _Trend extends StatelessWidget {
  final List<Map<String, dynamic>> points;
  const _Trend({required this.points});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 150,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final p in points) Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
              Text(p['weightedScore'] == null ? '—' : Fmt.num1(p['weightedScore']), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Container(
                height: p['weightedScore'] == null ? 12 : (90 * ((p['weightedScore'] as num) / 100)).clamp(4, 90).toDouble(),
                decoration: BoxDecoration(
                  color: p['weightedScore'] == null ? Colors.transparent : AppColors.primary.withValues(alpha: 0.85),
                  border: p['weightedScore'] == null ? Border.all(color: Colors.grey.withValues(alpha: 0.6)) : null,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(height: 4),
              Text('${p['period']}'.substring(5, 7), style: const TextStyle(fontSize: 11)),
            ]),
          ),
        ),
      ]),
    );
  }
}

/// HR / owner: KPI definitions and versioned KPI sets (weights must total 100%).
class KpiConfigPage extends StatefulWidget {
  const KpiConfigPage({super.key});
  @override
  State<KpiConfigPage> createState() => _KpiConfigPageState();
}

class _KpiConfigPageState extends State<KpiConfigPage> {
  Key _k = UniqueKey();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return GlassPage(
      title: t('kpi_settings'),
      body: AsyncView<List<Map<String, dynamic>>>(
        key: _k,
        load: () => Future.wait([s.api.get('/kpi/definitions'), s.api.get('/kpi/sets')]),
        builder: (ctx, d, reload) {
          final defs = d[0].list('definitions');
          final sets = d[1].list('sets');
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SectionTitle(t('kpi_sets'), trailing: TextButton.icon(icon: const Icon(Icons.add), label: Text(t('new_kpi_set')),
                onPressed: () async { if (await _editSet(context, defs.where((x) => x['active'] == true).toList()) == true) setState(() => _k = UniqueKey()); })),
            if (sets.isEmpty) EmptyState(t('no_kpi_sets')),
            for (final st in sets) Padding(padding: const EdgeInsets.only(bottom: 10), child: GlassCard(radius: 20, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text('${st.s('name')}  ·  v${st['version']}', style: const TextStyle(fontWeight: FontWeight.w800))),
                StatusChip(st['scope_type'] == 'job_title' ? '${t('job_title')}: ${st.s('job_title')}' : '${t('employee')}: ${st.s('employee_name')}', color: AppColors.primary),
              ]),
              const SizedBox(height: 8),
              for (final it in st.list('items')) InfoTile(title: it.s('nameAr'), value: '${Fmt.num1(it['weight'])}% · ${t('target')} ${Fmt.num1(it['target'])}'),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton.icon(icon: const Icon(Icons.copy_all_rounded), label: Text(t('new_version')),
                    onPressed: () async { if (await _editSet(context, defs.where((x) => x['active'] == true).toList(), base: st) == true) setState(() => _k = UniqueKey()); }),
                TextButton.icon(icon: const Icon(Icons.archive_outlined, color: AppColors.error), label: Text(t('retire'), style: const TextStyle(color: AppColors.error)),
                    onPressed: () async {
                      final ok = await confirmDialog(context, title: t('retire'), message: t('retire_set_confirm'), ok: t('yes'), cancel: t('no'));
                      if (!ok || !context.mounted) return;
                      try { await s.api.post('/kpi/sets/${st['id']}/retire'); setState(() => _k = UniqueKey()); } catch (e) { if (context.mounted) showSnack(context, errorText(e), error: true); }
                    }),
              ]),
            ]))),
            SectionTitle(t('kpi_definitions'), trailing: TextButton.icon(icon: const Icon(Icons.add), label: Text(t('new_kpi')),
                onPressed: () async { if (await _newDefinition(context) == true) setState(() => _k = UniqueKey()); })),
            Text(t('kpi_templates_note'), style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            GlassCard(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Column(children: [
              for (final df in defs) SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: df['active'] == true,
                title: Text(df.s('name_ar'), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${df.s('key')} · ${t('measure_${df.s('measurement_type')}')}'),
                onChanged: (v) async {
                  try { await s.api.patch('/kpi/definitions/${df['id']}', {'active': v}); setState(() => _k = UniqueKey()); }
                  catch (e) { if (context.mounted) showSnack(context, errorText(e), error: true); }
                },
              ),
            ])),
          ]);
        },
      ),
    );
  }

  Future<bool?> _newDefinition(BuildContext context) {
    final key = TextEditingController(), ar = TextEditingController(), en = TextEditingController();
    String type = 'count';
    bool higher = true;
    return showGlassSheet<bool>(context, title: t('new_kpi'), child: StatefulBuilder(builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: ar, decoration: glassInput(ctx, t('name_ar'))),
      const SizedBox(height: 10),
      TextField(controller: en, decoration: glassInput(ctx, t('name_en'))),
      const SizedBox(height: 10),
      TextField(controller: key, decoration: glassInput(ctx, t('kpi_key'), hint: 'e.g. new_listings')),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(value: type, decoration: glassInput(ctx, t('measurement_type')),
          items: [for (final m in ['count', 'percent', 'amount_egp', 'score']) DropdownMenuItem(value: m, child: Text(t('measure_$m')))],
          onChanged: (v) => set(() => type = v ?? type)),
      SwitchListTile(contentPadding: EdgeInsets.zero, value: higher, title: Text(t('higher_is_better')), onChanged: (v) => set(() => higher = v)),
      const SizedBox(height: 8),
      PrimaryButton(label: t('save'), onTap: () async {
        try {
          await context.read<Session>().api.post('/kpi/definitions', {'key': key.text.trim(), 'nameAr': ar.text.trim(), 'nameEn': en.text.trim(), 'measurementType': type, 'higherIsBetter': higher});
          if (ctx.mounted) Navigator.pop(ctx, true);
        } catch (e) { if (ctx.mounted) showSnack(ctx, errorText(e), error: true); }
      }),
    ])));
  }

  Future<bool?> _editSet(BuildContext context, List<Map<String, dynamic>> defs, {Map<String, dynamic>? base}) {
    final name = TextEditingController(text: base?.s('name') ?? '');
    final jobTitle = TextEditingController(text: base?['job_title']?.toString() ?? '');
    final rows = <({String? kpiId, TextEditingController weight, TextEditingController target})>[
      for (final it in base?.list('items') ?? <Map<String, dynamic>>[])
        (kpiId: it.s('kpiId'), weight: TextEditingController(text: Fmt.num1(it['weight'])), target: TextEditingController(text: Fmt.num1(it['target']))),
    ];
    if (rows.isEmpty) rows.add((kpiId: null, weight: TextEditingController(), target: TextEditingController()));
    final scopeEmployee = base?['scope_type'] == 'employee';
    return showGlassSheet<bool>(context, title: base == null ? t('new_kpi_set') : t('new_version'), child: StatefulBuilder(builder: (ctx, set) {
      final total = rows.fold<double>(0, (s, r) => s + (double.tryParse(r.weight.text) ?? 0));
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(controller: name, decoration: glassInput(ctx, t('set_name'))),
        const SizedBox(height: 10),
        if (!scopeEmployee) TextField(controller: jobTitle, decoration: glassInput(ctx, t('applies_to_job_title'))),
        if (scopeEmployee) Text('${t('employee')}: ${base?.s('employee_name')}'),
        const SizedBox(height: 12),
        for (var i = 0; i < rows.length; i++) Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(children: [
          Expanded(flex: 5, child: DropdownButtonFormField<String>(
            value: defs.any((d) => d['id'] == rows[i].kpiId) ? rows[i].kpiId : null,
            isExpanded: true,
            decoration: glassInput(ctx, t('kpi')),
            items: [for (final d in defs) DropdownMenuItem(value: d.s('id'), child: Text(d.s('name_ar'), overflow: TextOverflow.ellipsis))],
            onChanged: (v) => set(() => rows[i] = (kpiId: v, weight: rows[i].weight, target: rows[i].target)),
          )),
          const SizedBox(width: 6),
          Expanded(flex: 2, child: TextField(controller: rows[i].weight, keyboardType: TextInputType.number, decoration: glassInput(ctx, '%'), onChanged: (_) => set(() {}))),
          const SizedBox(width: 6),
          Expanded(flex: 3, child: TextField(controller: rows[i].target, keyboardType: TextInputType.number, decoration: glassInput(ctx, t('target')))),
          IconButton(icon: const Icon(Icons.remove_circle_outline, color: AppColors.error), onPressed: rows.length == 1 ? null : () => set(() => rows.removeAt(i))),
        ])),
        TextButton.icon(icon: const Icon(Icons.add), label: Text(t('add_kpi')), onPressed: () => set(() => rows.add((kpiId: null, weight: TextEditingController(), target: TextEditingController())))),
        Text(t('weights_total', {'n': Fmt.num1(total)}), style: TextStyle(fontWeight: FontWeight.w800, color: total == 100 ? AppColors.success : AppColors.error)),
        const SizedBox(height: 12),
        PrimaryButton(label: t('save'), onTap: () async {
          if (total != 100) { showSnack(ctx, t('weights_must_be_100'), error: true); return; }
          if (rows.any((r) => r.kpiId == null || double.tryParse(r.target.text) == null)) { showSnack(ctx, t('fill_required'), error: true); return; }
          try {
            await context.read<Session>().api.post('/kpi/sets', {
              'name': name.text.trim(),
              'scopeType': scopeEmployee ? 'employee' : 'job_title',
              if (!scopeEmployee) 'jobTitle': jobTitle.text.trim(),
              if (scopeEmployee) 'employeeId': base?['employee_id'],
              'items': [for (final r in rows) {'kpiId': r.kpiId, 'weight': double.parse(r.weight.text), 'target': double.parse(r.target.text)}],
            });
            if (ctx.mounted) Navigator.pop(ctx, true);
          } catch (e) { if (ctx.mounted) showSnack(ctx, errorText(e), error: true); }
        }),
      ]);
    }));
  }
}
