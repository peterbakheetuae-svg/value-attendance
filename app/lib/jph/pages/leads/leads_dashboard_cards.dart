import 'package:flutter/material.dart';

import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import 'leads_api.dart';

/// The extra cards of «لوحة السيلز» (like the Elite / Engaz boards): the numbers strip (Phone Call, WhatsApp
/// Contacts, Created today, Avg Response Time), Lead creation · last 7 days, Avg Response Time / week,
/// Lead pipeline, Delay List, النشاط, To Do List, أحدث العملاء المحتملين, Last Comments, المستخدمون المتصلون.
class DashboardCards {
  final BuildContext context;
  final bool isDark;
  final Map<String, dynamic> d;
  final void Function(String id) openLead;
  final VoidCallback openTasks;
  DashboardCards(this.context, this.isDark, this.d, {required this.openLead, required this.openTasks});

  Map<String, dynamic> get _k => lm(d['kpis']);

  // ------------------------------------------------------------------ the numbers strip
  Widget kpis() {
    final k = _k;
    final avg = k['avgResponseMin'];
    final items = [
      (tr('مكالمات (Phone Call)'), '${k['callsToday'] ?? 0}', '${tr('الأسبوع')}: ${k['callsWeek'] ?? 0}', Icons.call_rounded, Ar.green),
      (tr('WhatsApp Contacts'), '${k['whatsappToday'] ?? 0}', '${tr('الأسبوع')}: ${k['whatsappWeek'] ?? 0}', Icons.chat_rounded, const Color(0xFF1FA855)),
      (tr('اتضاف النهارده'), '${k['createdToday'] ?? 0}', tr('Created today'), Icons.person_add_alt_1_rounded, Ar.info),
      (tr('ردّوا النهارده'), '${k['answeredToday'] ?? 0}', '${tr('مردّش')}: ${k['noAnswerToday'] ?? 0}', Icons.phone_callback_rounded, Ar.accent),
      (tr('متوسط وقت الرد'), avg == null ? '—' : _mins(avg), tr('آخر 7 أيام'), Icons.timer_rounded, Ar.amber),
    ];
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth > 900 ? 5 : (box.maxWidth > 560 ? 3 : 2);
      final w = (box.maxWidth - (cols - 1) * 8) / cols;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final x in items)
          SizedBox(
            width: w,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: JphUi.box(isDark),
              child: Row(children: [
                JphUi.iconTile(isDark, x.$4, x.$5),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(x.$1, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                    Text(x.$2, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text(x.$3, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: JphUi.sub(isDark))),
                  ]),
                ),
              ]),
            ),
          ),
      ]);
    });
  }

  String _mins(Object? v) {
    final m = (v as num?)?.toInt() ?? 0;
    if (m < 60) return '$m ${tr('د')}';
    return '${m ~/ 60}${tr('س')} ${m % 60}${tr('د')}';
  }

  // ------------------------------------------------------------------ the panels
  Widget panel(String title, IconData icon, Color color, List<Widget> children, {String? action, VoidCallback? onAction}) => Container(
        padding: const EdgeInsets.all(14),
        decoration: JphUi.box(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
            if (action != null) TextButton(onPressed: onAction, child: Text(action)),
          ]),
          const SizedBox(height: 8),
          ...children,
        ]),
      );

  Widget _empty(String t) => Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text(t, style: TextStyle(color: JphUi.sub(isDark))));

  Widget _row(String title, String sub, {Widget? lead, Widget? trail, VoidCallback? onTap, Color? subColor}) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(children: [
            if (lead != null) ...[lead, const SizedBox(width: 10)],
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                if (sub.isNotEmpty)
                  Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: subColor ?? JphUi.sub(isDark))),
              ]),
            ),
            if (trail != null) trail,
          ]),
        ),
      );

  /// Lead creation · last 7 days — a bar a day
  Widget created7() {
    final rows = ll(d['created7']);
    final max = rows.fold<int>(1, (m, x) => ((x['n'] as num?) ?? 0) > m ? (x['n'] as num).toInt() : m);
    return panel(tr('الليدز الجديدة · آخر 7 أيام'), Icons.bar_chart_rounded, Ar.info, [
      SizedBox(
        height: 130,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final x in rows)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Text('${x['n']}', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                  const SizedBox(height: 3),
                  Container(
                    height: 4 + 86 * (((x['n'] as num?) ?? 0) / max),
                    decoration: BoxDecoration(color: Ar.info.withOpacity(0.75), borderRadius: BorderRadius.circular(6)),
                  ),
                  const SizedBox(height: 4),
                  Text(_dayName('${x['day']}'), style: TextStyle(fontSize: 10.5, color: JphUi.sub(isDark))),
                ]),
              ),
            ),
        ]),
      ),
    ]);
  }

  /// Avg Response Time / week — minutes from giving the lead to the first action, a day at a time
  Widget response7() {
    final rows = ll(d['response7']);
    final max = rows.fold<int>(1, (m, x) => ((x['min'] as num?) ?? 0) > m ? (x['min'] as num).toInt() : m);
    return panel(tr('متوسط وقت الرد · الأسبوع'), Icons.timer_rounded, Ar.amber, [
      SizedBox(
        height: 130,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final x in rows)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  Text(x['min'] == null ? '—' : _mins(x['min']), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                  const SizedBox(height: 3),
                  Container(
                    height: 4 + 86 * (((x['min'] as num?) ?? 0) / max),
                    decoration: BoxDecoration(color: Ar.amber.withOpacity(0.8), borderRadius: BorderRadius.circular(6)),
                  ),
                  const SizedBox(height: 4),
                  Text(_dayName('${x['day']}'), style: TextStyle(fontSize: 10.5, color: JphUi.sub(isDark))),
                ]),
              ),
            ),
        ]),
      ),
    ]);
  }

  String _dayName(String ymd) {
    final t = DateTime.tryParse(ymd);
    if (t == null) return '';
    const n = ['الاتنين', 'التلات', 'الأربع', 'الخميس', 'الجمعة', 'السبت', 'الحد'];
    return tr(n[t.weekday - 1]);
  }

  /// Lead pipeline: every stage as a bar of its share
  Widget pipeline(void Function(String stage) openStage) {
    final st = lm(d['stages']);
    final total = st.values.fold<num>(0, (a, b) => a + ((b as num?) ?? 0));
    return panel(tr('مسار الليدز (Pipeline)'), Icons.filter_alt_rounded, Ar.accent, [
      for (final s in stageNames.entries)
        InkWell(
          onTap: () => openStage(s.key),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              SizedBox(width: 110, child: Text(s.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: JphUi.text(isDark)))),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    minHeight: 10,
                    value: total == 0 ? 0 : (((st[s.key] as num?) ?? 0) / total).toDouble(),
                    backgroundColor: isDark ? Colors.white10 : const Color(0xFFF0EEEB),
                    color: stageColor(s.key),
                  ),
                ),
              ),
              SizedBox(width: 36, child: Text('${st[s.key] ?? 0}', textAlign: TextAlign.end, style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
            ]),
          ),
        ),
    ]);
  }

  Widget delayList() {
    final rows = ll(d['delayList']);
    return panel(tr('قائمة التأخير'), Icons.alarm_rounded, Ar.red, [
      if (rows.isEmpty) _empty(tr('مفيش متأخرين 👌')),
      for (final l in rows)
        _row('${l['fullName']}', '${l['stageAr'] ?? stageNames[l['stage']] ?? ''} — ${whenAr(l['nextAt'])}${l['lastComment'] != null ? '\n${l['lastComment']}' : ''}',
            lead: leadAvatar('${l['fullName']}', size: 32), subColor: Ar.red.shade400,
            trail: IconButton(icon: const Icon(Icons.call_rounded, color: Ar.green, size: 20), onPressed: () => callPhone('${l['phone']}', leadId: l['id'])),
            onTap: () => openLead('${l['id']}')),
    ]);
  }

  Widget latest() {
    final rows = ll(d['latest']);
    return panel(tr('أحدث العملاء المحتملين'), Icons.fiber_new_rounded, Ar.green, [
      if (rows.isEmpty) _empty(tr('لسه مفيش ليدز')),
      for (final l in rows)
        _row('${l['fullName']}', [
          if (lm(l['project'])['name'] != null) '${lm(l['project'])['name']}',
          '${lm(l['assignedTo'])['name'] ?? tr('مش متوزع')}',
          agoAr(l['createdAt']),
        ].join(' · '), lead: leadAvatar('${l['fullName']}', size: 32), trail: pill('${stageNames[l['stage']] ?? l['stage']}', stageColor('${l['stage']}')),
            onTap: () => openLead('${l['id']}')),
    ]);
  }

  Widget lastComments() {
    final rows = ll(d['lastComments']);
    return panel(tr('آخر التعليقات'), Icons.forum_rounded, Ar.info, [
      if (rows.isEmpty) _empty(tr('لسه مفيش تعليقات')),
      for (final x in rows)
        _row('${lm(x['lead'])['name']} — ${x['by'] ?? ''}', '${x['comment']}\n${agoAr(x['at'])}',
            lead: Icon(x['answered'] == false ? Icons.phone_missed_rounded : Icons.chat_bubble_rounded, size: 20,
                color: x['answered'] == false ? Ar.red : Ar.info),
            onTap: () => openLead('${lm(x['lead'])['id']}')),
    ]);
  }

  Widget activity() {
    final rows = ll(d['activity']);
    String what(Map<String, dynamic> x) => switch ('${x['kind']}') {
          'action' => '${tr('أكشن')}: ${stageNames[x['what']] ?? x['what'] ?? ''}',
          'assign' => '${tr('اتوزع على')} ${x['what']}',
          'create' => tr('إنشاء عميل محتمل'),
          'import' => tr('اتستورد'),
          'form' => tr('من صفحة الهبوط'),
          'call' => tr('اتصال'),
          'whatsapp' => tr('واتساب'),
          'checkin' => tr('وصل الميتنج'),
          _ => '${x['kind']}',
        };
    IconData icon(String k) => switch (k) {
          'action' => Icons.add_task_rounded,
          'assign' => Icons.switch_account_rounded,
          'call' => Icons.call_rounded,
          'whatsapp' => Icons.chat_rounded,
          'checkin' => Icons.where_to_vote_rounded,
          _ => Icons.person_add_alt_1_rounded,
        };
    return panel(tr('المهام اليومية'), Icons.timeline_rounded, Ar.accent, [
      if (rows.isEmpty) _empty(tr('لسه مفيش نشاط')),
      for (final x in rows)
        _row('${x['by'] ?? tr('النظام')} · ${what(x)}', '${lm(x['lead'])['name']} — ${agoAr(x['at'])}',
            lead: Icon(icon('${x['kind']}'), size: 20, color: Ar.accent.shade700), onTap: () => openLead('${lm(x['lead'])['id']}')),
    ]);
  }

  Widget todo() {
    final rows = ll(d['todo']);
    final st = lm(d['todoStages']);
    var due = 0, done = 0;
    for (final v in st.values) {
      due += ((lm(v)['due'] as num?) ?? 0).toInt();
      done += ((lm(v)['done'] as num?) ?? 0).toInt();
    }
    Widget bar(String label, int dn, int du, Color c) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            SizedBox(width: 110, child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: JphUi.text(isDark)))),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(minHeight: 8, value: du == 0 ? 0 : dn / du,
                    backgroundColor: isDark ? Colors.white10 : const Color(0xFFF0EEEB), color: c),
              ),
            ),
            SizedBox(width: 92, child: Text('$dn ${tr('من')} $du · ${du == 0 ? 0 : (dn * 100 / du).round()}%', textAlign: TextAlign.end,
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: JphUi.sub(isDark)))),
          ]),
        );
    return panel(tr('قائمة الأعمال المطلوبة'), Icons.checklist_rounded, Ar.info, [
      Text(tr('متابعات النهارده: اتعمل منها كام'), style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
      for (final e in st.entries) bar('${stageNames[e.key] ?? e.key}', ((lm(e.value)['done'] as num?) ?? 0).toInt(), ((lm(e.value)['due'] as num?) ?? 0).toInt(), stageColor(e.key)),
      bar(tr('الإجمالي'), done, due, Ar.accent),
      const Divider(),
      if (rows.isEmpty) _empty(tr('مفيش مهام مفتوحة 👌')),
      for (final x in rows)
        _row('${x['title']}', [
          if (x['dueAt'] != null) whenAr(x['dueAt']),
          if (x['lead'] != null) '${lm(x['lead'])['name']}',
        ].join(' · '), subColor: x['late'] == true ? Ar.red : null,
            lead: Icon(x['status'] == 'doing' ? Icons.timelapse_rounded : Icons.radio_button_unchecked_rounded, size: 20,
                color: x['late'] == true ? Ar.red : Ar.info),
            onTap: x['lead'] != null ? () => openLead('${lm(x['lead'])['id']}') : openTasks),
    ], action: tr('كل المهام'), onAction: openTasks);
  }

  Widget online() {
    final rows = ll(d['online']);
    return panel('${tr('المستخدمون المتصلون')} ${rows.length}/${d['onlineOf'] ?? rows.length}', Icons.wifi_tethering_rounded, Ar.green, [
      if (rows.isEmpty) _empty(tr('محدش متصل دلوقتي')),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final x in rows)
          Container(
            padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
            decoration: BoxDecoration(color: Ar.green.withOpacity(0.10), borderRadius: BorderRadius.circular(20)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Stack(children: [
                leadAvatar('${x['name']}', size: 26),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(width: 8, height: 8, decoration: BoxDecoration(color: Ar.green, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 1.5))),
                ),
              ]),
              const SizedBox(width: 6),
              Text('${x['name']}${x['me'] == true ? ' (${tr('إنت')})' : ''}', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12.5, color: JphUi.text(isDark))),
            ]),
          ),
      ]),
    ]);
  }
}

/// two columns on the computer, one under the other on the phone
Widget dashGrid(List<Widget> panels) => LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < 820) {
        return Column(children: [for (final p in panels) Padding(padding: const EdgeInsets.only(bottom: 12), child: p)]);
      }
      final w = (box.maxWidth - 12) / 2;
      return Wrap(spacing: 12, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.start, children: [for (final p in panels) SizedBox(width: w, child: p)]);
    });
