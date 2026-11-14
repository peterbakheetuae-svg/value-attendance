import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/side_sheet.dart';
import 'lead_page.dart';
import '../../widgets/app_nav.dart';
import '../../widgets/glass_bottom_nav.dart';
import 'leads_api.dart';
import 'leads_dashboard_cards.dart';
import 'leads_list_page.dart';
import 'leads_reports_page.dart';
import 'leads_calendar_page.dart';
import 'leads_settings_page.dart';
import 'leads_targets_page.dart';
import 'tasks_page.dart';

/// لوحة السيلز: the counts of every stage (tap → those leads), the follow-ups due, «مستني أكشن», the late ones,
/// the ranking, and the way to the leads, the tasks, the reports and the settings.
class LeadsDashboardPage extends StatefulWidget {
  /// opened as a tab of the phone's bottom bar (the bar stays under it)
  final bool tab;
  const LeadsDashboardPage({super.key, this.tab = false});

  @override
  State<LeadsDashboardPage> createState() => _LeadsDashboardPageState();
}

class _LeadsDashboardPageState extends State<LeadsDashboardPage> {
  Map<String, dynamic> _d = {}, _meta = {}, _target = {};
  bool _loading = true;
  bool _moreGo = false, _moreStats = false;
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
    await openLeadsPage(context, page);
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
      bottomBar: widget.tab
          ? GlassBottomNav(
              currentIndex: 6,
              onTap: (i) => AppNav.go(context, i, current: 6, uid: AppNav.uid ?? '', name: AppNav.name ?? '', role: AppNav.role ?? '',
                  photo: AppNav.photo ?? ''),
            )
          : null,
      title: tr('لوحة السيلز'),
      fab: can['create'] != true
          ? null
          : FloatingActionButton.extended(
              onPressed: () async {
                if (await editLead(context, isDark, _meta)) _load();
              },
              backgroundColor: JphUi.primary(isDark),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: Text(tr('ليد جديد'), style: TextStyle(fontWeight: FontWeight.w800)),
            ),
      child: denied
          ? Center(child: Text('${_d['message'] ?? ''}', style: TextStyle(color: JphUi.sub(isDark))))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 100), children: [
                // the way to everything: one row on the computer; 3 on the phone and the rest under «المزيد»
                LayoutBuilder(builder: (context, box) {
                  final wide = box.maxWidth > 700;
                  final go = [
                    _go(isDark, tr('الليدز'), Icons.people_alt_rounded, Ar.accent, () => _open(const LeadsListPage()), wide),
                    _go(isDark, 'المهام${(tasks['open'] ?? 0) > 0 ? ' (${tasks['open']})' : ''}', Icons.task_alt_rounded,
                        (tasks['late'] ?? 0) > 0 ? Ar.red : Ar.info, () => _open(const TasksPage()), wide),
                    _go(isDark, tr('التقويم'), Icons.calendar_month_rounded, Ar.amber, () => _open(const LeadsCalendarPage()), wide),
                    if (manager) _go(isDark, tr('التارجت'), Icons.flag_rounded, Ar.accent, () => _open(const LeadsTargetsPage()), wide),
                    if (can['reports'] == true) _go(isDark, tr('التقارير'), Icons.insights_rounded, Ar.green, () => _open(const LeadsReportsPage()), wide),
                    if (can['config'] == true)
                      _go(isDark, tr('الإعدادات'), Icons.tune_rounded, Ar.tan, () async {
                        await _open(const LeadsSettingsPage());
                        LeadsMeta.clear();
                      }, wide),
                  ];
                  return _grid(isDark, box.maxWidth, go, cols: wide ? go.length : 3, show: wide ? go.length : 3,
                      open: _moreGo, toggle: () => setState(() => _moreGo = !_moreGo));
                }),
                const SizedBox(height: 12),
                if (manager) _viewBar(isDark),
                if (_loading && c.isEmpty) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
                if (c.isNotEmpty) ...[
                  // every square together (the counts, then the stages — no title between them): 2 rows on the phone (6),
                  // 2 rows of 6 on the computer, the rest under «المزيد»
                  LayoutBuilder(builder: (context, box) {
                    final wide = box.maxWidth > 700;
                    final all = [
                      _stat(isDark, tr('كل العملاء'), c['total'], Icons.groups_rounded, Ar.info, 'all'),
                      _stat(isDark, tr('النهارده'), c['today'], Icons.today_rounded, Ar.accent, 'today'),
                      _stat(isDark, tr('متأخر'), c['delay'], Icons.alarm_rounded, Ar.red, 'delay'),
                      _stat(isDark, tr('مستني أكشن'), c['pending'], Icons.hourglass_top_rounded, Ar.amber, 'pending'),
                      _stat(isDark, tr('فريش'), c['fresh'], Icons.fiber_new_rounded, Ar.green, 'fresh'),
                      GestureDetector(
                        onTap: () => _open(const LeadsListPage(rating: 'hot')),
                        child: JphUi.stat(isDark, tr('عملاء ساخنين 🔥'), '${c['hot'] ?? 0}', Icons.local_fire_department_rounded, Ar.red),
                      ),
                      _stat(isDark, tr('كولد كول'), c['cold'], Icons.ac_unit_rounded, Ar.info, 'cold'),
                      if (manager) _stat(isDark, tr('مكرر'), c['duplicated'], Icons.copy_all_rounded, Ar.tan, 'duplicated'),
                      if (can['distribute'] == true) _stat(isDark, tr('مش متوزع'), c['unassigned'], Icons.person_off_rounded, Ar.grey, 'unassigned'),
                      for (final s in stageNames.entries)
                        GestureDetector(
                          onTap: () => _open(LeadsListPage(stage: s.key)),
                          child: JphUi.stat(isDark, s.value, '${stages[s.key] ?? 0}  •  ${_pct(stages[s.key], c['total'])}', stageIcon(s.key), stageColor(s.key)),
                        ),
                    ];
                    return _grid(isDark, box.maxWidth, all, cols: wide ? 6 : 3, show: wide ? 12 : 6,
                        open: _moreStats, toggle: () => setState(() => _moreStats = !_moreStats));
                  }),
                  if (_target['target'] != null) ...[
                    const SizedBox(height: 14),
                    targetCard(isDark, _target, mine: true),
                  ],
                  if (delay.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _title(isDark, tr('المتأخر حسب المرحلة')),
                    Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final e in delay.entries)
                        ActionChip(
                          avatar: Icon(stageIcon(e.key), size: 18, color: stageColor(e.key)),
                          label: Text('${stageNames[e.key] ?? e.key}: ${e.value}', style: const TextStyle(fontWeight: FontWeight.w800)),
                          onPressed: () => _open(LeadsListPage(tab: 'delay', stage: e.key)),
                        ),
                    ]),
                  ],
                  ...() {
                    final cards = DashboardCards(context, isDark, _d,
                        openLead: (id) async {
                          await openLead(context, id);
                          _load();
                        },
                        openTasks: () => _open(const TasksPage()));
                    return <Widget>[
                      const SizedBox(height: 14),
                      cards.kpis(),
                      const SizedBox(height: 12),
                      dashGrid([
                        cards.created7(),
                        cards.response7(),
                        cards.pipeline((s) => _open(LeadsListPage(stage: s))),
                        cards.delayList(),
                        _due(isDark),
                        _best(isDark),
                        cards.activity(),
                        cards.todo(),
                        cards.latest(),
                        cards.lastComments(),
                      ]),
                      cards.online(),
                    ];
                  }(),
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

  /// the computer: the icon beside the name; the phone (3 in a row): the icon over the name
  Widget _go(bool isDark, String label, IconData icon, Color color, VoidCallback onTap, bool wide) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: wide ? 70 : 92,
          padding: EdgeInsets.symmetric(horizontal: wide ? 12 : 6, vertical: wide ? 12 : 10),
          decoration: JphUi.box(isDark),
          child: wide
              ? Row(children: [
                  JphUi.iconTile(isDark, icon, color),
                  const SizedBox(width: 10),
                  Expanded(child: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                ])
              : Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  JphUi.iconTile(isDark, icon, color),
                  const SizedBox(height: 6),
                  Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                ]),
        ),
      );

  /// [cols] squares a row, the first [show] of them; the rest open with «المزيد»
  Widget _grid(bool isDark, double width, List<Widget> items, {required int cols, required int show, required bool open, required VoidCallback toggle}) {
    final c = cols < 1 ? 1 : cols;
    final w = (width - (c - 1) * 8) / c;
    final more = items.length > show;
    final shown = open || !more ? items : items.take(show).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [for (final b in shown) SizedBox(width: w, child: b)]),
      if (more)
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            onPressed: toggle,
            icon: Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded),
            label: Text(open ? tr('أقل') : '${tr('المزيد')} (${items.length - show})', style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
    ]);
  }

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
        ChoiceChip(selected: view == 'all' && _person == null, label: Text(tr('الكل')), onSelected: (_) {
          _view = 'all';
          _person = null;
          _load();
        }),
        ChoiceChip(selected: view == 'me', label: Text(tr('بتوعي')), onSelected: (_) {
          _view = 'me';
          _person = null;
          _load();
        }),
        if (people.isNotEmpty)
          ActionChip(
            avatar: const Icon(Icons.person_search_rounded, size: 18),
            label: Text(_person == null ? tr('سيلز معيّن') : '${people.firstWhere((p) => p['id'] == _person, orElse: () => const {'name': ''})['name']}'),
            onPressed: () async {
              final v = await pickPeople(context, isDark, tr('لوحة مين'), people, multi: false);
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
        _title(isDark, tr('المتابعات (المتأخر والنهارده)')),
        if (due.isEmpty) Text(tr('مفيش متابعات دلوقتي 👌'), style: TextStyle(color: JphUi.sub(isDark))),
        for (final l in due)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(stageIcon('${l['stage']}'), color: stageColor('${l['stage']}')),
            title: Text('${l['fullName']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
            subtitle: Text('${l['stageAr']} — ${whenAr(l['nextAt'])}${l['assignedTo'] != null && lm(_meta['can'])['assign'] == true ? ' — ${lm(l['assignedTo'])['name']}' : ''}',
                style: TextStyle(color: l['overdue'] == true ? Ar.red : JphUi.sub(isDark))),
            trailing: IconButton(icon: const Icon(Icons.call_rounded, color: Ar.green), onPressed: () => callPhone('${l['phone']}', leadId: l['id'])),
            onTap: () async {
              await openLead(context, '${l['id']}');
              _load();
            },
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
        _title(isDark, tr('الأحسن (عدد الأكشنات)')),
        Wrap(spacing: 6, children: [
          for (final p in [('today', tr('النهارده')), ('week', tr('الأسبوع')), ('month', tr('الشهر')), ('all', tr('الكل'))])
            ChoiceChip(selected: _period == p.$1, label: Text(p.$2), onSelected: (_) {
              _period = p.$1;
              _load();
            }),
        ]),
        const SizedBox(height: 8),
        if (best.isEmpty) Text(tr('لسه مفيش أكشنات'), style: TextStyle(color: JphUi.sub(isDark))),
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
