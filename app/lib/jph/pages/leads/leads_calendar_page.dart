import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/side_sheet.dart';
import 'lead_page.dart';
import 'leads_api.dart';
import 'tasks_page.dart';

/// التقويم: the follow-ups / meetings of the leads and the tasks — a month grid with dots, and the chosen day's list.
class LeadsCalendarPage extends StatefulWidget {
  const LeadsCalendarPage({super.key});

  @override
  State<LeadsCalendarPage> createState() => _LeadsCalendarPageState();
}

class _LeadsCalendarPageState extends State<LeadsCalendarPage> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  late DateTime _day = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  String _view = 'me';
  String? _person;
  List<Map<String, dynamic>> _items = [];
  Map<String, dynamic> _meta = {};
  bool _loading = true;
  int _seq = 0;

  String _d(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

  @override
  void initState() {
    super.initState();
    LeadsMeta.load().then((m) {
      if (mounted) setState(() => _meta = m);
    });
    _load();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() => _loading = true);
    final last = DateTime(_month.year, _month.month + 1, 0);
    final r = await lget('/leads/calendar', {'from': _d(_month), 'to': _d(last), 'view': _view, 'employeeId': _person});
    if (!mounted || seq != _seq) return;
    setState(() {
      _loading = false;
      _items = ll(r['items']);
    });
  }

  List<Map<String, dynamic>> _of(DateTime d) => _items.where((x) {
        final t = DateTime.tryParse('${x['at']}')?.toLocal();
        return t != null && t.year == d.year && t.month == d.month && t.day == d.day;
      }).toList();

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final can = lm(_meta['can']);
    const months = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
    final first = DateTime(_month.year, _month.month, 1);
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final lead = (first.weekday + 1) % 7; // the week starts on Saturday
    final today = DateTime.now();
    final list = _of(_day);
    return LeadsShell(
      isDark: isDark,
      title: 'التقويم',
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 60), children: [
          if (can['assign'] == true)
            Wrap(spacing: 6, runSpacing: 6, children: [
              ChoiceChip(selected: _view == 'me', label: const Text('بتاعي'), onSelected: (_) {
                _view = 'me';
                _person = null;
                _load();
              }),
              ChoiceChip(selected: _view == 'team' && _person == null, label: const Text('الفريق كله'), onSelected: (_) {
                _view = 'team';
                _person = null;
                _load();
              }),
              ActionChip(
                avatar: const Icon(Icons.person_search_rounded, size: 18),
                label: Text(_person == null ? 'سيلز معيّن' : '${ll(_meta['assignees']).firstWhere((p) => p['id'] == _person, orElse: () => const {'name': ''})['name']}'),
                onPressed: () async {
                  final v = await pickPeople(context, isDark, 'تقويم مين', ll(_meta['assignees']), multi: false);
                  if (v == null || v.isEmpty) return;
                  _view = 'team';
                  _person = v.first;
                  _load();
                },
              ),
            ]),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: JphUi.box(isDark),
            child: Column(children: [
              Row(children: [
                IconButton(onPressed: () {
                  _month = DateTime(_month.year, _month.month - 1);
                  _load();
                }, icon: const Icon(Icons.chevron_right_rounded)),
                Expanded(child: Text('${months[_month.month - 1]} ${_month.year}', textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                IconButton(onPressed: () {
                  _month = DateTime(_month.year, _month.month + 1);
                  _load();
                }, icon: const Icon(Icons.chevron_left_rounded)),
              ]),
              Row(children: [
                for (final w in const ['سبت', 'حد', 'اتنين', 'تلات', 'أربع', 'خميس', 'جمعة'])
                  Expanded(child: Text(w, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: JphUi.sub(isDark)))),
              ]),
              const SizedBox(height: 4),
              for (var week = 0; week * 7 < lead + days; week++)
                Row(children: [
                  for (var c = 0; c < 7; c++)
                    Expanded(child: () {
                      final n = week * 7 + c - lead + 1;
                      if (n < 1 || n > days) return const SizedBox(height: 48);
                      final d = DateTime(_month.year, _month.month, n);
                      final items = _of(d);
                      final sel = d == _day;
                      final isToday = d.year == today.year && d.month == today.month && d.day == today.day;
                      final late = items.any((x) => x['overdue'] == true);
                      return GestureDetector(
                        onTap: () => setState(() => _day = d),
                        child: Container(
                          height: 48,
                          margin: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: sel ? JphUi.primary(isDark).withOpacity(0.25) : Colors.transparent,
                            borderRadius: BorderRadius.circular(10),
                            border: isToday ? Border.all(color: Ar.accent, width: 1.5) : null,
                          ),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text('$n', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                            if (items.isNotEmpty)
                              Container(
                                margin: const EdgeInsets.only(top: 2),
                                padding: const EdgeInsets.symmetric(horizontal: 5),
                                decoration: BoxDecoration(color: late ? Ar.red : Ar.accent, borderRadius: BorderRadius.circular(8)),
                                child: Text('${items.length}', style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w800)),
                              ),
                          ]),
                        ),
                      );
                    }()),
                ]),
            ]),
          ),
          const SizedBox(height: 12),
          Text('${_day.day} ${months[_day.month - 1]} — ${list.length} معاد', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
          const SizedBox(height: 6),
          if (_loading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
          if (!_loading && list.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text('مفيش مواعيد', style: TextStyle(color: JphUi.sub(isDark)))),
          for (final x in list)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: JphUi.box(isDark),
              child: ListTile(
                leading: Icon(x['kind'] == 'task' ? Icons.task_alt_rounded : stageIcon('${x['stage']}'),
                    color: x['kind'] == 'task' ? Ar.info : stageColor('${x['stage']}')),
                title: Text('${x['title']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                subtitle: Text([
                  whenAr(x['at']).split('— ').last,
                  x['kind'] == 'task' ? 'مهمة' : '${x['stageAr']}',
                  if (x['project'] != null) '${x['project']}',
                  if (_view != 'me' && x['who'] != null) '${x['who']}',
                ].join(' • '), style: TextStyle(color: x['overdue'] == true ? Ar.red : JphUi.sub(isDark))),
                trailing: x['kind'] == 'lead' ? IconButton(icon: const Icon(Icons.call_rounded, color: Ar.green), onPressed: () => callPhone('${x['phone']}')) : null,
                onTap: () async {
                  await pushSide(context, x['kind'] == 'task' ? const TasksPage() : LeadPage(leadId: '${x['id']}'));
                  _load();
                },
              ),
            ),
        ]),
      ),
    );
  }
}
