import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/side_sheet.dart';
import 'lead_page.dart';
import 'leads_api.dart';
import 'leads_list_page.dart';
import 'leads_reports_page.dart';
import 'leads_calendar_page.dart';
import 'leads_settings_page.dart';
import 'leads_targets_page.dart';
import 'tasks_page.dart';

/// لوحة السيلز: the counts of every stage (tap → those leads), the follow-ups due, «مستني أكشن», the late ones,
/// the ranking, and the way to the leads, the tasks, the reports and the settings.
class LeadsDashboardPage extends StatefulWidget {
  const LeadsDashboardPage({super.key});

  @override
  State<LeadsDashboardPage> createState() => _LeadsDashboardPageState();
}

class _LeadsDashboardPageState extends State<LeadsDashboardPage> {
  Map<String, dynamic> _d = {}, _meta = {}, _target = {};
  bool _loading = true;
  String _period = 'month';
  String? _view, _person;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() => _loading = true);
    final r = await Future.wait([
      lget('/leads/dashboard', {'period': _period, 'view': _view, 'employeeId': _person}),
      LeadsMeta.load(fresh: _meta.isEmpty),
      lget('/leads/targets/me'),
    ]);
    if (!mounted || seq != _seq) return;
    setState(() {
      _loading = false;
      _d = r[0];
      _meta = r[1];
      _target = lm(r[2]['me']);
    });
  }

  Future<void> _open(Widget page) async {
    await pushSide(context, page, width: 900);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final can = lm(_meta['can']);
    final c = lm(_d['counts']);
    final stages = lm(_d['stages']);
    final delay = lm(_d['delayByStage']);
    final tasks = lm(_d['tasks']);
    final manager = can['all'] == true || can['team'] == true;
    final denied = _d['success'] == false;
    return LeadsShell(
      isDark: isDark,
      title: 'لوحة السيلز',
      fab: can.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () async {
                if (await editLead(context, isDark, _meta)) _load();
              },
              backgroundColor: JphUi.primary(isDark),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('ليد جديد', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
      child: denied
          ? Center(child: Text('${_d['message'] ?? ''}', style: TextStyle(color: JphUi.sub(isDark))))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 100), children: [
                // the way to everything
                Wrap(spacing: 8, runSpacing: 8, children: [
                  _go(isDark, 'الليدز', Icons.people_alt_rounded, Ar.accent, () => _open(const LeadsListPage())),
                  _go(isDark, 'المهام${(tasks['open'] ?? 0) > 0 ? ' (${tasks['open']})' : ''}', Icons.task_alt_rounded,
                      (tasks['late'] ?? 0) > 0 ? Ar.red : Ar.info, () => _open(const TasksPage())),
                  _go(isDark, 'التقويم', Icons.calendar_month_rounded, Ar.amber, () => _open(const LeadsCalendarPage())),
                  if (manager) _go(isDark, 'التارجت', Icons.flag_rounded, Ar.accent, () => _open(const LeadsTargetsPage())),
                  if (can['reports'] == true) _go(isDark, 'التقارير', Icons.insights_rounded, Ar.green, () => _open(const LeadsReportsPage())),
                  if (can['config'] == true) _go(isDark, 'الإعدادات', Icons.tune_rounded, Ar.tan, () async {
                        await _open(const LeadsSettingsPage());
                        LeadsMeta.clear();
                      }),
                ]),
                const SizedBox(height: 12),
                if (manager) _viewBar(isDark),
                if (_loading && c.isEmpty) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
                if (c.isNotEmpty) ...[
                  JphUi.statGrid([
                    _stat(isDark, 'كل العملاء', c['total'], Icons.groups_rounded, Ar.info, 'all'),
                    _stat(isDark, 'النهارده', c['today'], Icons.today_rounded, Ar.accent, 'today'),
                    _stat(isDark, 'متأخر', c['delay'], Icons.alarm_rounded, Ar.red, 'delay'),
                    _stat(isDark, 'مستني أكشن', c['pending'], Icons.hourglass_top_rounded, Ar.amber, 'pending'),
                    _stat(isDark, 'فريش', c['fresh'], Icons.fiber_new_rounded, Ar.green, 'fresh'),
                    GestureDetector(
                      onTap: () => _open(const LeadsListPage(rating: 'hot')),
                      child: JphUi.stat(isDark, 'عملاء ساخنين 🔥', '${c['hot'] ?? 0}', Icons.local_fire_department_rounded, Ar.red),
                    ),
                    _stat(isDark, 'كولد كول', c['cold'], Icons.ac_unit_rounded, Ar.info, 'cold'),
                    if (manager) _stat(isDark, 'مكرر', c['duplicated'], Icons.copy_all_rounded, Ar.tan, 'duplicated'),
                    if (can['distribute'] == true) _stat(isDark, 'مش متوزع', c['unassigned'], Icons.person_off_rounded, Ar.grey, 'unassigned'),
                  ], phone: 2),
                  if (_target['target'] != null) ...[
                    const SizedBox(height: 14),
                    targetCard(isDark, _target, mine: true),
                  ],
                  const SizedBox(height: 14),
                  _title(isDark, 'المراحل'),
                  JphUi.statGrid([
                    for (final s in stageNames.entries)
                      GestureDetector(
                        onTap: () => _open(LeadsListPage(stage: s.key)),
                        child: JphUi.stat(isDark, s.value, '${stages[s.key] ?? 0}  •  ${_pct(stages[s.key], c['total'])}', stageIcon(s.key), stageColor(s.key)),
                      ),
                  ], phone: 2),
                  if (delay.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _title(isDark, 'المتأخر حسب المرحلة'),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final e in delay.entries)
                        ActionChip(
                          avatar: Icon(stageIcon(e.key), size: 18, color: stageColor(e.key)),
                          label: Text('${stageNames[e.key] ?? e.key}: ${e.value}', style: const TextStyle(fontWeight: FontWeight.w800)),
                          onPressed: () => _open(LeadsListPage(tab: 'delay', stage: e.key)),
                        ),
                    ]),
                  ],
                  const SizedBox(height: 14),
                  LayoutBuilder(builder: (context, box) {
                    final wide = box.maxWidth > 820;
                    final due = _due(isDark), best = _best(isDark);
                    return wide
                        ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(flex: 3, child: due), const SizedBox(width: 12), Expanded(flex: 2, child: best)])
                        : Column(children: [due, const SizedBox(height: 12), best]);
                  }),
                ],
              ]),
            ),
    );
  }

  String _pct(Object? v, Object? total) {
    final t = (total as num?) ?? 0;
    if (t == 0) return '0%';
    return '${(((v as num?) ?? 0) * 100 / t).toStringAsFixed(0)}%';
  }

  Widget _title(bool isDark, String t) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(t, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      );

  Widget _go(bool isDark, String label, IconData icon, Color color, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 170,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: JphUi.box(isDark),
          child: Row(children: [
            JphUi.iconTile(isDark, icon, color),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
          ]),
        ),
      );

  Widget _stat(bool isDark, String label, Object? v, IconData icon, Color color, String tab) => GestureDetector(
        onTap: () => _open(LeadsListPage(tab: tab)),
        child: JphUi.stat(isDark, label, '${v ?? 0}', icon, color),
      );

  Widget _viewBar(bool isDark) {
    final people = ll(_meta['assignees']);
    final view = _view ?? '${_d['view'] ?? 'all'}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        ChoiceChip(selected: view == 'all' && _person == null, label: const Text('الكل'), onSelected: (_) {
          _view = 'all';
          _person = null;
          _load();
        }),
        ChoiceChip(selected: view == 'me', label: const Text('بتوعي'), onSelected: (_) {
          _view = 'me';
          _person = null;
          _load();
        }),
        if (people.isNotEmpty)
          ActionChip(
            avatar: const Icon(Icons.person_search_rounded, size: 18),
            label: Text(_person == null ? 'سيلز معيّن' : '${people.firstWhere((p) => p['id'] == _person, orElse: () => const {'name': ''})['name']}'),
            onPressed: () async {
              final v = await pickPeople(context, isDark, 'لوحة مين', people, multi: false);
              if (v == null || v.isEmpty) return;
              _view = 'all';
              _person = v.first;
              _load();
            },
          ),
      ]),
    );
  }

  Widget _due(bool isDark) {
    final due = ll(_d['due']);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title(isDark, 'المتابعات (المتأخر والنهارده)'),
        if (due.isEmpty) Text('مفيش متابعات دلوقتي 👌', style: TextStyle(color: JphUi.sub(isDark))),
        for (final l in due)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(stageIcon('${l['stage']}'), color: stageColor('${l['stage']}')),
            title: Text('${l['fullName']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
            subtitle: Text('${l['stageAr']} — ${whenAr(l['nextAt'])}${l['assignedTo'] != null && lm(_meta['can'])['assign'] == true ? ' — ${lm(l['assignedTo'])['name']}' : ''}',
                style: TextStyle(color: l['overdue'] == true ? Ar.red : JphUi.sub(isDark))),
            trailing: IconButton(icon: const Icon(Icons.call_rounded, color: Ar.green), onPressed: () => callPhone('${l['phone']}')),
            onTap: () => _open(LeadPage(leadId: '${l['id']}')),
          ),
      ]),
    );
  }

  Widget _best(bool isDark) {
    final best = ll(_d['best']);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title(isDark, 'الأحسن (عدد الأكشنات)'),
        Wrap(spacing: 6, children: [
          for (final p in const [('today', 'النهارده'), ('week', 'الأسبوع'), ('month', 'الشهر'), ('all', 'الكل')])
            ChoiceChip(selected: _period == p.$1, label: Text(p.$2), onSelected: (_) {
              _period = p.$1;
              _load();
            }),
        ]),
        const SizedBox(height: 8),
        if (best.isEmpty) Text('لسه مفيش أكشنات', style: TextStyle(color: JphUi.sub(isDark))),
        for (final b in best)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: b['me'] == true ? Ar.accent.withOpacity(0.14) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              SizedBox(
                width: 30,
                child: Text(switch (b['rank']) { 1 => '🥇', 2 => '🥈', 3 => '🥉', _ => '${b['rank']}' }, style: const TextStyle(fontSize: 18)),
              ),
              Expanded(child: Text('${b['name']}${b['me'] == true ? ' (إنت)' : ''}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
              Text('${b['actions']}', style: TextStyle(fontWeight: FontWeight.w900, color: Ar.accent.shade700)),
            ]),
          ),
      ]),
    );
  }
}
