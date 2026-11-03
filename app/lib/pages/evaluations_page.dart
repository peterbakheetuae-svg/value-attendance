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

const evalDimensions = ['discipline', 'attendance', 'communication', 'follow_up', 'teamwork', 'sales_performance', 'initiative', 'professional_behavior'];
const _camel = {
  'discipline': 'discipline', 'attendance': 'attendance', 'communication': 'communication', 'follow_up': 'followUp',
  'teamwork': 'teamwork', 'sales_performance': 'salesPerformance', 'initiative': 'initiative', 'professional_behavior': 'professionalBehavior',
};

/// Evaluation history for one employee. Employees see only published evaluations (server-enforced).
class EvaluationsView extends StatefulWidget {
  final String employeeId;
  final String employeeName;
  const EvaluationsView({super.key, required this.employeeId, required this.employeeName});
  @override
  State<EvaluationsView> createState() => _EvaluationsViewState();
}

class _EvaluationsViewState extends State<EvaluationsView> {
  Key _k = UniqueKey();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    final canWrite = widget.employeeId != s.id && (s.has('evaluation.write_all') || s.has('evaluation.write_team'));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle(t('evaluations'), trailing: canWrite ? TextButton.icon(icon: const Icon(Icons.add), label: Text(t('new_evaluation')), onPressed: () async {
        final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => EvaluationFormPage(employeeId: widget.employeeId, employeeName: widget.employeeName)));
        if (ok == true) setState(() => _k = UniqueKey());
      }) : null),
      AsyncView<Map<String, dynamic>>(
        key: _k,
        load: () => s.api.get('/evaluations', {'employeeId': widget.employeeId}),
        builder: (ctx, d, reload) {
          final list = d.list('evaluations');
          if (list.isEmpty) return EmptyState(t('no_evaluations'), icon: Icons.star_outline_rounded);
          return Column(children: [
            for (final e in list) Padding(padding: const EdgeInsets.only(bottom: 10), child: GlassCard(
              radius: 20,
              onTap: (e['status'] == 'draft' && e['evaluator_id'] == s.id) ? () async {
                final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => EvaluationFormPage(employeeId: widget.employeeId, employeeName: widget.employeeName, existing: e)));
                if (ok == true) await reload();
              } : null,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text('${Fmt.monthLabel(DateTime.parse(e.s('period')))} · ${t('evaluator_${e.s('evaluator_kind')}')}', style: const TextStyle(fontWeight: FontWeight.w800))),
                  StatusPill(e.s('status')),
                ]),
                Text('${e.s('evaluator_name')} · ${t('overall')}: ${Fmt.percent(e['overallPercent'])}', style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  for (final dim in evalDimensions) if (e[dim] != null) StatusChip('${t('dim_$dim')}: ${e[dim]}/5', color: AppColors.primary),
                ]),
                if (e.s('strengths').isNotEmpty) InfoTile(title: t('strengths'), value: e.s('strengths')),
                if (e.s('improvements').isNotEmpty) InfoTile(title: t('areas_for_improvement'), value: e.s('improvements')),
                if (e.s('improvement_plan').isNotEmpty) InfoTile(title: t('improvement_plan'), value: e.s('improvement_plan')),
                if (e.s('feedback').isNotEmpty) InfoTile(title: t('feedback'), value: e.s('feedback')),
              ]),
            )),
          ]);
        },
      ),
    ]);
  }
}

class EvaluationFormPage extends StatefulWidget {
  final String employeeId;
  final String employeeName;
  final Map<String, dynamic>? existing;
  const EvaluationFormPage({super.key, required this.employeeId, required this.employeeName, this.existing});
  @override
  State<EvaluationFormPage> createState() => _EvaluationFormPageState();
}

class _EvaluationFormPageState extends State<EvaluationFormPage> {
  late DateTime _month;
  final Map<String, int?> _scores = {};
  late final TextEditingController _feedback, _strengths, _improve, _plan;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    final now = DateTime.now();
    _month = e['period'] != null ? DateTime.parse(e['period'].toString()) : DateTime(now.year, now.month);
    for (final d in evalDimensions) { _scores[d] = e[d] as int?; }
    _feedback = TextEditingController(text: e['feedback']?.toString() ?? '');
    _strengths = TextEditingController(text: e['strengths']?.toString() ?? '');
    _improve = TextEditingController(text: e['improvements']?.toString() ?? '');
    _plan = TextEditingController(text: e['improvement_plan']?.toString() ?? '');
  }

  @override
  void dispose() { _feedback.dispose(); _strengths.dispose(); _improve.dispose(); _plan.dispose(); super.dispose(); }

  Map<String, dynamic> get _body => {
        for (final d in evalDimensions) _camel[d]!: _scores[d],
        'feedback': _feedback.text.trim(), 'strengths': _strengths.text.trim(),
        'improvements': _improve.text.trim(), 'improvementPlan': _plan.text.trim(),
      };

  Future<void> _save({required bool publish}) async {
    final api = context.read<Session>().api;
    if (publish && _scores.values.any((v) => v == null)) { showSnack(context, t('score_all_dimensions'), error: true); return; }
    if (publish) {
      final ok = await confirmDialog(context, title: t('publish'), message: t('publish_confirm'), ok: t('publish'), cancel: t('cancel'));
      if (!ok || !mounted) return;
    }
    setState(() => _busy = true);
    try {
      String id;
      if (widget.existing == null) {
        final r = await api.post('/evaluations', {'employeeId': widget.employeeId, 'month': Fmt.month(_month), ..._body});
        id = r.obj('evaluation')!.s('id');
      } else {
        id = widget.existing!.s('id');
        await api.patch('/evaluations/$id', _body);
      }
      if (publish) await api.post('/evaluations/$id/publish');
      if (mounted) { showSnack(context, publish ? t('evaluation_published') : t('draft_saved')); Navigator.pop(context, true); }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      title: '${t('evaluation')} — ${widget.employeeName}',
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.existing == null) Align(alignment: AlignmentDirectional.centerStart, child: MonthPicker(month: _month, onChanged: (m) => setState(() => _month = m))),
        const SizedBox(height: 10),
        GlassCard(radius: 20, child: Column(children: [
          for (final d in evalDimensions) Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Expanded(child: Text(t('dim_$d'), style: const TextStyle(fontWeight: FontWeight.w700))),
              for (var v = 1; v <= 5; v++)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '$v',
                  icon: Icon((_scores[d] ?? 0) >= v ? Icons.star_rounded : Icons.star_outline_rounded, color: AppColors.accent),
                  onPressed: () => setState(() => _scores[d] = v),
                ),
            ]),
          ),
        ])),
        const SizedBox(height: 12),
        GlassCard(radius: 20, child: Material(type: MaterialType.transparency, child: Column(children: [
          TextField(controller: _strengths, maxLines: 2, decoration: glassInput(context, t('strengths'))),
          const SizedBox(height: 10),
          TextField(controller: _improve, maxLines: 2, decoration: glassInput(context, t('areas_for_improvement'))),
          const SizedBox(height: 10),
          TextField(controller: _plan, maxLines: 3, decoration: glassInput(context, t('improvement_plan'))),
          const SizedBox(height: 10),
          TextField(controller: _feedback, maxLines: 3, decoration: glassInput(context, t('feedback'))),
        ]))),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: PrimaryButton(label: t('save_draft'), color: AppColors.primaryLight, loading: _busy, onTap: () => _save(publish: false))),
          const SizedBox(width: 12),
          Expanded(child: PrimaryButton(label: t('publish'), loading: _busy, onTap: () => _save(publish: true))),
        ]),
        const SizedBox(height: 8),
        Text(t('publish_is_final'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
      ]),
    );
  }
}
