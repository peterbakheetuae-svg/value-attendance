import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/side_sheet.dart';
import 'lead_page.dart';
import 'leads_api.dart';

/// المهام: mine, the ones I gave, my team's — each with its person, its time and its state.
class TasksPage extends StatefulWidget {
  const TasksPage({super.key});

  @override
  State<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends State<TasksPage> {
  String _view = 'mine', _status = 'open';
  bool _loading = true, _others = false;
  List<Map<String, dynamic>> _tasks = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await lget('/tasks', {'view': _view, 'status': _status});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _tasks = ll(r['tasks']);
      _others = r['canAssignOthers'] == true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final views = [('mine', tr('مهامي'), Icons.person_rounded), ('created', tr('اللي إديتها'), Icons.outbox_rounded), if (_others) ('team', tr('الفريق'), Icons.groups_rounded)];
    return LeadsShell(
      isDark: isDark,
      title: tr('المهام'),
      fab: FloatingActionButton.extended(
        onPressed: () async {
          if (await editTask(context, isDark)) _load();
        },
        backgroundColor: JphUi.primary(isDark),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_task_rounded),
        label: Text(tr('مهمة جديدة'), style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 6, 14, 100), children: [
          JphUi.tabs(isDark, [for (final v in views) (v.$2, v.$3)], views.indexWhere((v) => v.$1 == _view).clamp(0, views.length - 1), (i) {
            _view = views[i].$1;
            _load();
          }),
          const SizedBox(height: 8),
          Wrap(spacing: 6, children: [
            for (final s in [('open', tr('المفتوحة')), ('done', tr('اللي خلصت')), ('all', tr('الكل'))])
              ChoiceChip(selected: _status == s.$1, label: Text(s.$2), onSelected: (_) {
                _status = s.$1;
                _load();
              }),
          ]),
          const SizedBox(height: 10),
          if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
          if (!_loading && _tasks.isEmpty)
            Padding(padding: const EdgeInsets.all(30), child: Text(tr('مفيش مهام'), textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
          for (final t in _tasks) _card(isDark, t),
        ]),
      ),
    );
  }

  Widget _card(bool isDark, Map<String, dynamic> t) {
    final done = t['status'] == 'done', cancelled = t['status'] == 'cancelled';
    final color = done ? Ar.green : cancelled ? Ar.grey : t['late'] == true ? Ar.red : t['status'] == 'doing' ? Ar.amber : Ar.info;
    final can = lm(t['can']);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Checkbox(
            value: done,
            onChanged: can['status'] == true && !cancelled
                ? (v) async {
                    final r = await lpost('/tasks/${t['id']}', {'status': v == true ? 'done' : 'open'}, method: 'patch', ok: v == true ? tr('خلصت ✅') : tr('رجعت مفتوحة'));
                    if (mounted) JphUi.toast(context, r);
                    _load();
                  }
                : null,
          ),
          Expanded(
            child: Text('${t['title']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark),
                decoration: done ? TextDecoration.lineThrough : null)),
          ),
          JphUi.chip(done ? tr('خلصت') : cancelled ? tr('اتلغت') : t['late'] == true ? tr('متأخرة') : t['status'] == 'doing' ? tr('شغال فيها') : tr('مفتوحة'), color),
        ]),
        if ('${t['description'] ?? ''}'.isNotEmpty)
          Padding(padding: const EdgeInsets.only(right: 48, top: 4), child: Text('${t['description']}', style: TextStyle(color: JphUi.sub(isDark)))),
        Padding(
          padding: const EdgeInsets.only(right: 48, top: 6),
          child: Wrap(spacing: 12, runSpacing: 4, children: [
            Text('👤 ${lm(t['assignedTo'])['name']}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
            if (lm(t['createdBy'])['id'] != lm(t['assignedTo'])['id'])
              Text('من ${lm(t['createdBy'])['name']}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
            if (t['dueAt'] != null) Text('⏰ ${whenAr(t['dueAt'])}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
          ]),
        ),
        Row(children: [
          if (t['lead'] != null)
            TextButton.icon(
              onPressed: () => openLead(context, '${lm(t['lead'])['id']}'),
              icon: const Icon(Icons.person_search_rounded, size: 18),
              label: Text('${lm(t['lead'])['name']}'),
            ),
          const Spacer(),
          if (can['status'] == true && t['status'] == 'open')
            TextButton(
              onPressed: () async {
                await lpost('/tasks/${t['id']}', {'status': 'doing'}, method: 'patch');
                _load();
              },
              child: Text(tr('بدأت فيها')),
            ),
          if (can['edit'] == true)
            IconButton(
              onPressed: () async {
                if (await editTask(context, isDark, task: t)) _load();
              },
              icon: Icon(Icons.edit_rounded, color: JphUi.sub(isDark)),
            ),
        ]),
      ]),
    );
  }
}

/// مهمة جديدة / تعديل مهمة ([lead]: a task on that lead)
Future<bool> editTask(BuildContext context, bool isDark, {Map<String, dynamic>? task, Map<String, dynamic>? lead}) async {
  final r = await lget('/tasks', {'view': 'mine', 'status': 'open'});
  if (!context.mounted) return false;
  final people = ll(r['people']);
  final title = TextEditingController(text: '${task?['title'] ?? (lead == null ? '' : 'متابعة ${lead['fullName']}')}'),
      desc = TextEditingController(text: '${task?['description'] ?? ''}');
  String? to = task == null ? null : '${lm(task['assignedTo'])['id']}';
  DateTime? due = DateTime.tryParse('${task?['dueAt'] ?? ''}')?.toLocal();
  return leadForm(context, isDark, task == null ? tr('مهمة جديدة') : tr('تعديل المهمة'), (set) => [
        JphUi.input(isDark: isDark, label: tr('المهمة'), controller: title, icon: Icons.task_alt_rounded, big: false),
        JphUi.input(isDark: isDark, label: tr('التفاصيل'), controller: desc, icon: Icons.notes_rounded, big: false),
        if (r['canAssignOthers'] == true)
          refPicker(context, isDark, tr('لمين'), Icons.person_rounded, people, to, (v) => set(() => to = v), allowNone: false),
        WhenField(isDark: isDark, value: due, onPick: (v) => set(() => due = v), label: tr('المعاد')),
      ], () async {
    if (title.text.trim().length < 2) {
      JphUi.toast(context, {'success': false, 'message': tr('اكتب المهمة')});
      return false;
    }
    final b = {
      'title': title.text.trim(), 'description': desc.text.trim(), if (to != null) 'assignedTo': to,
      if (due != null) 'dueAt': isoUtc(due!), if (lead != null) 'leadId': lead['id'],
    };
    final res = task == null ? await lpost('/tasks', b, ok: tr('اتضافت المهمة ✅')) : await lpost('/tasks/${task['id']}', b, ok: tr('اتحفظ ✅'), method: 'patch');
    if (context.mounted) JphUi.toast(context, res);
    return res['success'] == true;
  });
}
