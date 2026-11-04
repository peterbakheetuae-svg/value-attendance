import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/async_view.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../design/app_colors.dart';
import '../design/glass.dart';
import 'common.dart';
import 'requests_page.dart';
import 'fingerprint_home.dart';

/// Role-shaped dashboard in the original layout: header (bell · name/date · avatar),
/// today card, then bold-titled sections of GlassMiniCards. All values come from /dashboard.
class DashboardPage extends StatefulWidget {
  final void Function(String tabKey) onOpenTab;
  const DashboardPage({super.key, required this.onOpenTab});
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Key _k = UniqueKey();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return AsyncView<Map<String, dynamic>>(
      key: _k,
      load: () => s.api.get('/dashboard'),
      builder: (ctx, d, reload) => RefreshIndicator(
        color: AppColors.primary,
        onRefresh: reload,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FingerprintHome(
              unreadNotifications: (d['unreadNotifications'] ?? 0) as int,
              onChanged: () => setState(() => _k = UniqueKey()),
            ),
            if (d['awaitingMyApproval'] != null) ...[
              const SizedBox(height: 12),
              GlassCard(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ApprovalsPage())),
                child: Row(children: [
                  const Icon(Icons.how_to_reg_rounded, color: AppColors.warning, size: 30),
                  const SizedBox(width: 12),
                  Expanded(child: Text(t('awaiting_my_approval'), style: const TextStyle(fontWeight: FontWeight.w700))),
                  Text('${d['awaitingMyApproval']}', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: AppColors.warning)),
                ]),
              ),
            ],
            ..._me(d.obj('me')!),
            if (d['team'] != null) ..._team(d.obj('team')!),
            if (d['kpiOverview'] != null) ..._kpi(d.obj('kpiOverview')!),
            if (d['evaluationProgress'] != null) ..._eval(d.obj('evaluationProgress')!),
            if (d['finance'] != null) ..._finance(d.obj('finance')!),
            const SizedBox(height: 100),
          ]),
        ),
      ),
    );
  }

  /// Personal extras (requests / KPI / evaluation). The attendance month itself is in FingerprintHome.
  List<Widget> _me(Map<String, dynamic> me) {
    final kpi = me.obj('kpi')!;
    final ev = me.obj('latestEvaluation');
    return [
      SectionTitle(t('my_kpi')),
      MiniCardGrid(children: [
        GlassMiniCard(title: t('pending_requests'), value: '${me['pendingRequests']}', icon: Icons.hourglass_top_rounded,
            onTap: () => widget.onOpenTab('requests')),
        GlassMiniCard(title: t('kpi_progress'),
            value: kpi['status'] == 'no_kpis' ? t('status_no_kpis') : kpi['weightedScore'] == null ? t('status_not_evaluated') : '${Fmt.num1(kpi['weightedScore'])} / 100',
            icon: Icons.insights_rounded, iconColor: AppColors.secondary),
        GlassMiniCard(title: t('latest_evaluation'), value: ev == null ? t('status_not_evaluated') : Fmt.percent(ev['overallPercent']),
            icon: Icons.star_rate_rounded, iconColor: AppColors.accent),
      ]),
    ];
  }

  List<Widget> _team(Map<String, dynamic> tm) {
    final today = tm.obj('today')!;
    final attention = tm.list('attentionNeeded');
    final abs = tm.obj('monthAbsence') ?? {};
    return [
      SectionTitle(tm['scope'] == 'company' ? t('company_today') : t('team_today')),
      if (today['holiday'] != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: StatusChip('${t('status_holiday')}: ${today['holiday']}', color: AppColors.primaryLight)),
      MiniCardGrid(children: [
        GlassMiniCard(title: t('active_employees'), value: '${tm['activeEmployees']}', icon: Icons.groups_rounded),
        GlassMiniCard(title: t('checked_in_today'), value: '${today['checkedIn']}', icon: Icons.login_rounded, iconColor: AppColors.success),
        GlassMiniCard(title: t('not_checked_in'), value: '${today['notCheckedIn']}', icon: Icons.person_off_rounded, iconColor: AppColors.error),
        GlassMiniCard(title: t('on_leave_today'), value: '${today['onApprovedLeave']}', icon: Icons.beach_access_rounded, iconColor: AppColors.secondary),
        GlassMiniCard(title: t('pending_requests'), value: '${tm['pendingRequests']}', icon: Icons.pending_actions_rounded, iconColor: AppColors.warning),
        GlassMiniCard(title: t('month_absence_days'), value: '${abs['days'] ?? 0}', icon: Icons.event_busy_rounded),
      ]),
      if (attention.isNotEmpty) ...[
        SectionTitle(t('needs_follow_up')),
        GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(children: [
            for (final a in attention)
              InfoTile(title: a.s('full_name'), value: t('missing_checkouts_n', {'n': a['missing_checkouts']})),
          ]),
        ),
      ],
    ];
  }

  List<Widget> _kpi(Map<String, dynamic> k) => [
        SectionTitle(t('kpi_overview')),
        MiniCardGrid(children: [
          GlassMiniCard(title: t('average_kpi_score'), value: k['averageWeightedScore'] == null ? '—' : Fmt.num1(k['averageWeightedScore']), icon: Icons.insights_rounded, iconColor: AppColors.secondary),
          GlassMiniCard(title: t('status_completed'), value: '${k['completed']}', icon: Icons.check_circle_rounded, iconColor: AppColors.success),
          GlassMiniCard(title: t('status_in_progress'), value: '${k['inProgress']}', icon: Icons.timelapse_rounded, iconColor: AppColors.warning),
          GlassMiniCard(title: t('status_not_evaluated'), value: '${k['notEvaluated']}', icon: Icons.help_outline_rounded),
          GlassMiniCard(title: t('status_below_target'), value: '${k['belowTarget']}', icon: Icons.trending_down_rounded, iconColor: AppColors.error),
          GlassMiniCard(title: t('status_no_kpis'), value: '${k['noKpis']}', icon: Icons.block_rounded),
        ]),
        if (k.list('top').isNotEmpty) ...[
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(children: [
              for (final x in k.list('top')) InfoTile(title: x.s('name'), value: Fmt.num1(x['score'])),
            ]),
          ),
        ],
      ];

  List<Widget> _eval(Map<String, dynamic> e) => [
        SectionTitle(t('evaluation_progress')),
        MiniCardGrid(children: [
          GlassMiniCard(title: t('evaluated_employees'), value: '${e['evaluated']} / ${e['employees']}', icon: Icons.fact_check_rounded),
          GlassMiniCard(title: t('draft_evaluations'), value: '${e['drafts']}', icon: Icons.edit_note_rounded, iconColor: AppColors.warning),
        ]),
      ];

  List<Widget> _finance(Map<String, dynamic> f) => [
        SectionTitle(t('monthly_financial_summary')),
        MiniCardGrid(children: [
          GlassMiniCard(title: t('approved_deductions'), value: Fmt.egp(f['approved_deductions']), icon: Icons.remove_circle_outline, iconColor: AppColors.error),
          GlassMiniCard(title: t('approved_bonuses'), value: Fmt.egp(f['approved_bonuses']), icon: Icons.add_circle_outline, iconColor: AppColors.success),
          GlassMiniCard(title: t('pending_adjustments'), value: '${f['pending_adjustments']}', icon: Icons.pending_rounded, iconColor: AppColors.warning),
          GlassMiniCard(title: t('approved_absence_requests'), value: '${f['approved_absence_requests']}', icon: Icons.event_busy_rounded),
          GlassMiniCard(title: t('unpaid_days'), value: '${f['unpaid_days']}', icon: Icons.money_off_rounded),
        ]),
      ];
}
