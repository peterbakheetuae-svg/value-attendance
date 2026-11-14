import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/side_sheet.dart';
import '../exclusive/exclusive_projects_page.dart' show newUnit;
import 'leads_api.dart';
import 'leads_extra.dart';
import 'tasks_page.dart' show editTask;

/// One lead (a side panel on the computer): its data, «إضافة أكشن», the reservation from it, the comments and replies,
/// the reservations made from it and — for the managers — its log (who gave it, who opened it).
class LeadPage extends StatefulWidget {
  final String leadId;
  /// opened like a person of the directory: a floating panel (computer) / a tall bottom sheet (phone)
  final bool sheet;
  const LeadPage({super.key, required this.leadId, this.sheet = false});

  @override
  State<LeadPage> createState() => _LeadPageState();
}

class _LeadPageState extends State<LeadPage> {
  Map<String, dynamic>? _d;
  Map<String, dynamic> _meta = {};
  String _tab = 'comments';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await Future.wait([lget('/leads/${widget.leadId}'), LeadsMeta.load()]);
    if (!mounted) return;
    setState(() {
      _d = r[0]['success'] == true ? r[0] : {'error': r[0]['message'] ?? tr('الليد مش موجود')};
      _meta = r[1];
    });
  }

  Future<void> _after(bool ok) async {
    if (!ok) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final d = _d;
    if (widget.sheet) return _panel(isDark, d);
    return LeadsShell(
        isDark: isDark,
        title: d?['lead'] == null ? tr('العميل') : '${lm(d!['lead'])['fullName']}',
        child: d == null
            ? const Center(child: CircularProgressIndicator())
            : d['error'] != null
                ? Center(child: Text('${d['error']}', style: TextStyle(color: JphUi.sub(isDark))))
                : RefreshIndicator(onRefresh: _load, child: _body(isDark, d)),
    );
  }

  /// the floating panel: the grabber (phone), the name with its line and the X, then the body
  Widget _panel(bool isDark, Map<String, dynamic>? d) {
    final l = lm(d?['lead']);
    final wide = SideSheets.wide(context);
    return Directionality(
      textDirection: leadsDir,
      child: Material(
        color: isDark ? const Color(0xFF1E1D1B) : const Color(0xFFFBFAF8),
        borderRadius: wide ? BorderRadius.circular(18) : const BorderRadius.vertical(top: Radius.circular(26)),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          if (!wide)
            Container(margin: const EdgeInsets.only(top: 10), width: 42, height: 5,
                decoration: BoxDecoration(color: isDark ? Colors.white24 : Colors.black12, borderRadius: BorderRadius.circular(3))),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l['fullName'] == null ? tr('العميل') : '${l['fullName']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  if (l['fullName'] != null)
                    Text(['#${l['refNo']}', if (lm(l['project'])['name'] != null) '${lm(l['project'])['name']}'].join(' · '),
                        style: TextStyle(fontSize: 13, color: JphUi.sub(isDark))),
                ]),
              ),
              IconButton(tooltip: tr('قفل'), onPressed: () => Navigator.of(context).maybePop(), icon: const Icon(Icons.close_rounded)),
            ]),
          ),
          Divider(height: 1, color: isDark ? Colors.white10 : const Color(0xFFEDEBE8)),
          Expanded(
            child: d == null
                ? const Center(child: CircularProgressIndicator())
                : d['error'] != null
                    ? Center(child: Text('${d['error']}', style: TextStyle(color: JphUi.sub(isDark))))
                    : RefreshIndicator(onRefresh: _load, child: Padding(padding: const EdgeInsets.only(top: 16), child: _body(isDark, d))),
          ),
        ]),
      ),
    );
  }

  Widget _body(bool isDark, Map<String, dynamic> d) {
    final l = lm(d['lead']);
    final can = lm(d['can']);
    final phone = '${l['phone'] ?? ''}';
    final next = l['nextAt'];
    final open = !const ['cancelled', 'done_deal', 'reservation'].contains(l['stage']);
    final kind = l['kind'] == 'cold' ? tr('كولد كول') : tr('فريش');
    final rating = {'hot': (tr('ساخن 🔥'), Ar.red), 'warm': (tr('دافي'), Ar.amber), 'cold': (tr('بارد'), Ar.info)}[l['rating']];
    return ListView(padding: EdgeInsets.fromLTRB(widget.sheet ? 20 : 14, 6, widget.sheet ? 20 : 14, 40), children: [
      // ------------------------------------------------ the big avatar, its pills and the meta line
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        leadAvatar('${l['fullName']}', size: 72),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 6, runSpacing: 6, children: [
              pill('${stageNames[l['stage']] ?? l['stage']}', stageColor('${l['stage']}'), icon: stageIcon('${l['stage']}')),
              if (rating != null) pill(rating.$1, rating.$2),
              pill(kind, Ar.grey, dot: false),
            ]),
            const SizedBox(height: 8),
            SelectableText(phone, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
            const SizedBox(height: 2),
            Text([
              if (l['channel'] != null) '${lm(l['channel'])['name']}',
              '${lm(l['assignedTo'])['name'] ?? tr('مش متوزع')}',
              if (l['createdAt'] != null) 'اتضاف ${agoAr(l['createdAt'])}',
            ].join(' · '), style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
          ]),
        ),
      ]),
      const SizedBox(height: 16),
      // ------------------------------------------------ the actions row: one filled, the rest outlined
      Wrap(children: [
        if (can['act'] == true && l['stage'] != 'done_deal')
          dirBtn(isDark, tr('إضافة أكشن'), Icons.add_task_rounded, () async => _after(await addLeadAction(context, isDark, l, _meta)), primary: true),
        dirBtn(isDark, tr('اتصال'), Icons.call_rounded, () => callPhone(phone, leadId: l['id']), color: Ar.green),
        dirBtn(isDark, tr('واتساب'), Icons.chat_rounded, () => whatsAppWithTemplate(context, isDark, l), color: const Color(0xFF1FA855)),
        if (can['reserve'] == true) dirBtn(isDark, tr('حجز وحدة'), Icons.bookmark_add_rounded, () => _reserve(isDark, l)),
        if (can['edit'] == true)
          dirBtn(isDark, tr('تعديل'), Icons.edit_rounded, () async => _after(await editLead(context, isDark, _meta, lead: l, can: can))),
        if (can['assign'] == true)
          dirBtn(isDark, tr('توزيع'), Icons.switch_account_rounded, () async => _after(await assignLeads(context, isDark, _meta, [l['id']]))),
        if (can['refer'] == true) dirBtn(isDark, tr('مشاركة'), Icons.group_add_rounded, () async => _after(await _refer(isDark, l))),
        dirBtn(isDark, tr('مهمة'), Icons.task_alt_rounded, () async => _after(await editTask(context, isDark, lead: l))),
        if (can['act'] == true && const ['meeting', 'reschedule'].contains(l['stage']))
          dirBtn(isDark, tr('وصلت الميتنج'), Icons.where_to_vote_rounded, () async => _after(await leadCheckIn(context, isDark, l)), color: Ar.green),
      ]),
      if (l['pending'] == true || l['overdue'] == true) ...[
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Ar.red.withOpacity(0.10), borderRadius: BorderRadius.circular(14)),
          child: Text(l['pending'] == true ? tr('الليد اتوزع ولسه محدش عمل عليه أكشن') : 'معاد المتابعة عدّى: ${whenAr(next)}',
              style: const TextStyle(color: Ar.red, fontWeight: FontWeight.w800)),
        ),
      ] else if (next != null && open) ...[
        sectionLabel(tr('المتابعة الجاية'), isDark),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: Ar.accent.withOpacity(0.10), borderRadius: BorderRadius.circular(14)),
          child: Row(children: [
            Icon(Icons.event_rounded, color: Ar.accent.shade700, size: 20),
            const SizedBox(width: 8),
            Text(whenAr(next), style: TextStyle(fontWeight: FontWeight.w800, color: Ar.accent.shade700)),
          ]),
        ),
      ],
      if (can['act'] == true || can['edit'] == true) ...[
        sectionLabel(tr('تقييم العميل'), isDark),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 6, children: [
          for (final r in [('hot', tr('ساخن 🔥'), Ar.red), ('warm', tr('دافي'), Ar.amber), ('cold', tr('بارد'), Ar.info)])
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: ChoiceChip(
                selected: l['rating'] == r.$1,
                selectedColor: r.$3.withOpacity(0.3),
                label: Text(r.$2, style: const TextStyle(fontWeight: FontWeight.w800)),
                onSelected: (v) async {
                  final res = await lpost('/leads/${l['id']}', {'rating': v ? r.$1 : null}, method: 'patch', ok: tr('اتحفظ ✅'));
                  if (mounted) JphUi.toast(context, res);
                  _after(res['success'] == true);
                },
              ),
            ),
        ]),
      ],
      sectionLabel(tr('البيانات'), isDark),
      _info(isDark, l, d),
      sectionLabel(tr('المتابعة'), isDark),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final t in [
            ('comments', tr('التعليقات'), Icons.forum_rounded),
            ('request', tr('الطلب والوحدات'), Icons.manage_search_rounded),
            ('units', tr('الحجوزات'), Icons.home_work_rounded),
            ('files', tr('الملفات'), Icons.attach_file_rounded),
            ('checkins', tr('الميتنجات'), Icons.where_to_vote_rounded),
            if (can['log'] == true) ('log', tr('السجل'), Icons.history_rounded),
          ])
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: ChoiceChip(
                selected: _tab == t.$1,
                avatar: Icon(t.$3, size: 18),
                label: Text(t.$2, style: const TextStyle(fontWeight: FontWeight.w800)),
                onSelected: (_) => setState(() => _tab = t.$1),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 10),
      if (_tab == 'comments') ..._comments(isDark, ll(d['actions'])),
      if (_tab == 'units') ..._units(isDark, ll(d['units'])),
      if (_tab == 'log') ..._log(isDark, ll(d['logs'])),
      if (const ['request', 'files', 'checkins'].contains(_tab))
        LeadExtra(key: ValueKey('$_tab-${l['id']}-${l['lastActionAt']}'), isDark: isDark, lead: l, meta: _meta, canWork: can['act'] == true, part: _tab),
    ]);
  }

  Widget _info(bool isDark, Map<String, dynamic> l, Map<String, dynamic> d) {
    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(k, style: TextStyle(color: JphUi.sub(isDark))),
            const SizedBox(width: 12),
            Expanded(child: Text(v, textAlign: TextAlign.end, style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark)))),
          ]),
        );
    final refs = ll(d['referrals']);
    final extra = (l['extraPhones'] as List?)?.join(' — ') ?? '';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        kv(tr('رقم الليد'), '#${l['refNo']}'),
        kv(tr('المشروع'), '${lm(l['project'])['name'] ?? '—'}'),
        kv(tr('السيلز'), '${lm(l['assignedTo'])['name'] ?? 'لسه مش متوزع'}'),
        if (l['channel'] != null) kv(tr('القناة'), '${lm(l['channel'])['name']}'),
        if (l['campaign'] != null) kv(tr('الحملة'), '${lm(l['campaign'])['name']}'),
        kv(tr('النوع'), l['kind'] == 'cold' ? tr('كولد كول') : tr('فريش')),
        if (extra.isNotEmpty) kv(tr('أرقام تانية'), extra),
        if ('${l['email'] ?? ''}'.isNotEmpty) kv(tr('الإيميل'), '${l['email']}'),
        if (l['budget'] != null) kv(tr('الميزانية'), JphUi.money(l['budget'])),
        if (l['cancelReason'] != null) kv(tr('سبب الإلغاء'), '${lm(l['cancelReason'])['name']}'),
        if (l['duplicateOf'] != null) kv(tr('مكرر'), 'نفس رقم ${lm(l['duplicateOf'])['name']}'),
        if ((l['noAnswerCount'] ?? 0) > 0) kv(tr('مردّش'), '${l['noAnswerCount']} مرة'),
        if (refs.isNotEmpty) kv(tr('متشارك مع'), refs.map((r) => '${r['name']}').join(tr('، '))),
        if ('${l['notes'] ?? ''}'.isNotEmpty) kv(tr('ملاحظات'), '${l['notes']}'),
        kv(tr('اتضاف'), '${whenAr(l['createdAt'])}${l['createdByName'] == null ? '' : ' — ${l['createdByName']}'}'),
      ]),
    );
  }

  List<Widget> _comments(bool isDark, List<Map<String, dynamic>> actions) {
    if (actions.isEmpty) {
      return [Padding(padding: const EdgeInsets.all(24), child: Text(tr('لسه مفيش أكشن على العميل ده'), textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark))))];
    }
    return [
      for (final x in actions)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: JphUi.box(isDark),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(x['auto'] == true ? Icons.smart_toy_rounded : Icons.person_rounded, size: 18, color: JphUi.sub(isDark)),
              const SizedBox(width: 6),
              Expanded(child: Text('${x['byName']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
              Text(agoAr(x['at']), style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
            ]),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 6, children: [
              if (x['stage'] != null) stageChip('${x['stage']}'),
              if (x['answered'] != null)
                JphUi.chip(x['answered'] == true ? 'ردّ${(x['callSeconds'] ?? 0) > 0 ? ' — ${(x['callSeconds'] as num) ~/ 60}:${two((x['callSeconds'] as num).toInt() % 60)}' : ''}' : tr('مردّش'),
                    x['answered'] == true ? Ar.green : Ar.grey),
              if ('${x['meetingKind'] ?? ''}'.isNotEmpty) JphUi.chip('${x['meetingKind']}', Ar.accent),
              if ('${x['meetingPlace'] ?? ''}'.isNotEmpty) JphUi.chip('📍 ${x['meetingPlace']}', Ar.info),
              if (x['cancelReason'] != null) JphUi.chip('${x['cancelReason']}', Ar.red),
            ]),
            const SizedBox(height: 8),
            Text('${x['comment']}', style: TextStyle(fontSize: 15, color: JphUi.text(isDark))),
            if (x['nextAt'] != null) ...[
              const SizedBox(height: 6),
              Text('المتابعة الجاية: ${whenAr(x['nextAt'])}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Ar.accent.shade700)),
            ],
            Text(whenAr(x['at']), style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
            for (final rp in ll(x['replies']))
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: JphUi.primary(isDark).withOpacity(0.08), borderRadius: BorderRadius.circular(12)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text('${rp['byName']} — ${agoAr(rp['at'])}', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: JphUi.sub(isDark))),
                  const SizedBox(height: 3),
                  Text('${rp['comment']}', style: TextStyle(color: JphUi.text(isDark))),
                ]),
              ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(onPressed: () => _reply(isDark, x), icon: const Icon(Icons.reply_rounded, size: 18), label: Text(tr('رد'))),
            ),
          ]),
        ),
    ];
  }

  List<Widget> _units(bool isDark, List<Map<String, dynamic>> units) {
    if (units.isEmpty) {
      return [Padding(padding: const EdgeInsets.all(24), child: Text(tr('مفيش حجوزات من العميل ده'), textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark))))];
    }
    return [
      for (final u in units)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: JphUi.box(isDark),
          child: Row(children: [
            JphUi.iconTile(isDark, Icons.home_work_rounded, const Color(0xFF3FC1C9)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${u['projectName']} — وحدة ${u['unitNo']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                Text('${JphUi.money(u['price'])} — عربون ${JphUi.money(u['deposit'])}', style: TextStyle(color: JphUi.sub(isDark))),
              ]),
            ),
            JphUi.chip('${u['statusAr']}', u['status'] == 'contracted' || u['status'] == 'completed' ? Ar.green : u['status'] == 'cancelled' ? Ar.red : Ar.amber),
          ]),
        ),
    ];
  }

  List<Widget> _log(bool isDark, List<Map<String, dynamic>> logs) {
    String text(Map<String, dynamic> g) {
      final x = lm(g['data']);
      return switch ('${g['kind']}') {
        'create' => tr('ضاف الليد'),
        'import' => tr('ضاف الليد من ملف إكسيل'),
        'assign' => x['from'] == null
            ? 'وزّعه على ${x['toName'] ?? ''}${x['mode'] == 'duplicate' ? ' (عميله القديم)' : x['turn'] == true ? ' (بالدور)' : ''}'
            : 'نقله من ${x['fromName'] ?? ''} لـ ${x['toName'] ?? ''}${x['mode'] == 'cold' ? ' — كولد كول' : x['mode'] == 'fresh' ? ' — فريش' : ''}',
        'edit' => tr('عدّل البيانات'),
        'view' => tr('فتح صفحة العميل'),
        'duplicate' => 'الرقم ده موجود قبل كده (ليد #${x['ofRef'] ?? ''})',
        'referral' => 'شاركه مع ${x['toName'] ?? ''}',
        _ => '${g['kind']}',
      };
    }

    return [
      for (final g in logs)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Icon(g['kind'] == 'view' ? Icons.visibility_rounded : g['kind'] == 'assign' ? Icons.switch_account_rounded : Icons.history_rounded,
                size: 18, color: JphUi.sub(isDark)),
            const SizedBox(width: 8),
            Expanded(child: Text('${g['byName']}: ${text(g)}', style: TextStyle(color: JphUi.text(isDark)))),
            Text(whenAr(g['at'], withDay: false), style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
          ]),
        ),
    ];
  }

  Future<void> _reply(bool isDark, Map<String, dynamic> x) async {
    final c = TextEditingController();
    final ok = await leadForm(context, isDark, tr('رد على التعليق'), (set) => [
          Text('${x['comment']}', style: TextStyle(color: JphUi.sub(isDark))),
          JphUi.input(isDark: isDark, label: tr('الرد'), controller: c, icon: Icons.reply_rounded, big: false),
        ], () async {
      if (c.text.trim().isEmpty) return false;
      final r = await lpost('/leads/actions/${x['id']}/reply', {'comment': c.text.trim()}, ok: tr('اتبعت ✅'));
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    }, saveLabel: tr('ابعت'), saveIcon: Icons.send_rounded);
    await _after(ok);
  }

  Future<bool> _refer(bool isDark, Map<String, dynamic> l) async {
    final people = ll(_meta['assignees']).isNotEmpty ? ll(_meta['assignees']) : ll((await lget('/tasks'))['people']);
    if (!mounted) return false;
    final to = await pickPeople(context, isDark, tr('شارك العميل مع'), people.where((p) => p['id'] != lm(l['assignedTo'])['id']).toList());
    if (to == null || to.isEmpty) return false;
    final r = await lpost('/leads/${l['id']}/referral', {'to': to}, ok: tr('اتشارك ✅'));
    if (mounted) JphUi.toast(context, r);
    return r['success'] == true;
  }

  Future<void> _reserve(bool isDark, Map<String, dynamic> l) async {
    final r = await lget('/exclusive/projects', {'kind': 'all'});
    if (!mounted) return;
    if (r['success'] != true) {
      JphUi.toast(context, r);
      return;
    }
    await newUnit(context, isDark, ll(r['projects']), lead: l, then: () => _after(true));
  }
}

// ==================================================================== the sheets (used by the list too)

/// «إضافة أكشن»: the stage, answered or not, the next follow-up, the comment (+ the meeting / the cancel reason)
Future<bool> addLeadAction(BuildContext context, bool isDark, Map<String, dynamic> lead, Map<String, dynamic> meta) async {
  final stages = ll(meta['stages']).where((s) => s['action'] == true).toList();
  final reasons = ll(meta['cancelReasons']);
  String? stage;
  bool answered = true;
  DateTime? next;
  String? reason;
  final comment = TextEditingController(), place = TextEditingController(), mins = TextEditingController();
  String meetingKind = tr('معاينة');
  return leadForm(context, isDark, 'أكشن — ${lead['fullName']}', (set) {
    final noDate = stage == 'cancelled';
    final meeting = stage == 'meeting' || stage == 'reschedule';
    return [
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final s in stages)
          ChoiceChip(
            selected: stage == s['key'],
            avatar: Icon(stageIcon('${s['key']}'), size: 18, color: stageColor('${s['key']}')),
            label: Text('${s['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
            onSelected: (_) => set(() {
              stage = '${s['key']}';
              if (stage == 'no_answer') answered = false;
              if (stage != 'no_answer' && answered == false) answered = true;
            }),
          ),
      ]),
      SwitchListTile(
        value: answered,
        onChanged: (v) => set(() => answered = v),
        title: Text(answered ? tr('ردّ') : tr('مردّش'), style: const TextStyle(fontWeight: FontWeight.w800)),
        secondary: Icon(answered ? Icons.call_rounded : Icons.phone_missed_rounded, color: answered ? Ar.green : Ar.grey),
      ),
      if (answered) JphUi.input(isDark: isDark, label: tr('مدة المكالمة بالدقايق (اختياري)'), controller: mins, number: true, icon: Icons.timer_rounded, big: false),
      if (meeting) ...[
        Wrap(spacing: 6, children: [
          for (final k in [tr('معاينة'), tr('في المكتب'), tr('أونلاين'), tr('عند العميل')])
            ChoiceChip(selected: meetingKind == k, label: Text(k), onSelected: (_) => set(() => meetingKind = k)),
        ]),
        JphUi.input(isDark: isDark, label: tr('مكان الميتنج'), controller: place, icon: Icons.place_rounded, big: false),
      ],
      if (stage == 'cancelled') refPicker(context, isDark, tr('سبب الإلغاء'), Icons.cancel_rounded, reasons, reason, (v) => set(() => reason = v), allowNone: false),
      if (!noDate) WhenField(isDark: isDark, value: next, onPick: (v) => set(() => next = v), label: meeting ? tr('معاد الميتنج') : tr('معاد المتابعة الجاية')),
      JphUi.input(isDark: isDark, label: tr('التعليق'), controller: comment, icon: Icons.notes_rounded, big: false),
    ];
  }, () async {
    String? err;
    if (stage == null) err = tr('اختار المرحلة');
    else if (comment.text.trim().isEmpty) err = tr('اكتب التعليق');
    else if (stage == 'cancelled' && reason == null) err = tr('اختار سبب الإلغاء');
    else if (stage != 'cancelled' && next == null) err = tr('حدد المعاد الجاي');
    if (err != null) {
      JphUi.toast(context, {'success': false, 'message': err});
      return false;
    }
    final m = num.tryParse(mins.text.trim());
    final r = await lpost('/leads/${lead['id']}/actions', {
      'stage': stage, 'answered': answered, 'comment': comment.text.trim(),
      if (next != null && stage != 'cancelled') 'nextAt': isoUtc(next!),
      if (answered && m != null && m > 0) 'callSeconds': (m * 60).round(),
      if (stage == 'meeting' || stage == 'reschedule') ...{'meetingKind': meetingKind, 'meetingPlace': place.text.trim()},
      if (stage == 'cancelled') 'cancelReasonId': reason,
    }, ok: tr('اتسجل الأكشن ✅'));
    if (context.mounted) JphUi.toast(context, r);
    return r['success'] == true;
  }, saveLabel: tr('سجّل الأكشن'));
}

/// إضافة ليد / تعديل ليد. [can] (from the lead): who may change the number / the source.
Future<bool> editLead(BuildContext context, bool isDark, Map<String, dynamic> meta, {Map<String, dynamic>? lead, Map<String, dynamic>? can}) async {
  final isNew = lead == null;
  final mcan = lm(meta['can']);
  final name = TextEditingController(text: '${lead?['fullName'] ?? ''}'), phone = TextEditingController(text: '${lead?['phone'] ?? ''}'),
      phone2 = TextEditingController(text: ((lead?['extraPhones'] as List?) ?? const []).join(tr('، '))),
      email = TextEditingController(text: '${lead?['email'] ?? ''}'),
      budget = TextEditingController(text: lead?['budget'] == null ? '' : '${lead!['budget']}'),
      notes = TextEditingController(text: '${lead?['notes'] ?? ''}');
  String kind = '${lead?['kind'] ?? 'fresh'}';
  String? project = lm(lead?['project'])['id']?.toString(), channel = lm(lead?['channel'])['id']?.toString(),
      campaign = lm(lead?['campaign'])['id']?.toString();
  final projects = ll(meta['projects']);
  if (project == null && projects.length == 1) project = '${projects.first['id']}';
  List<String> assignees = [];
  final people = ll(meta['assignees']);
  final source = isNew || can?['editSource'] == true;
  final phoneOk = isNew || can?['editPhone'] == true;
  return leadForm(context, isDark, isNew ? tr('ليد جديد') : 'تعديل ${lead['fullName']}', (set) {
    final camps = ll(meta['campaigns']).where((c) => channel == null || c['channelId'] == null || c['channelId'] == channel).toList();
    return [
      JphUi.input(isDark: isDark, label: tr('اسم العميل'), controller: name, icon: Icons.person_rounded),
      if (phoneOk) JphUi.input(isDark: isDark, label: tr('الموبايل'), controller: phone, icon: Icons.phone_rounded, number: true),
      JphUi.input(isDark: isDark, label: tr('أرقام تانية (افصل بينهم بـ ،)'), controller: phone2, icon: Icons.phone_forwarded_rounded, big: false),
      refPicker(context, isDark, tr('المشروع'), Icons.apartment_rounded, projects, project, (v) => set(() => project = v), allowNone: false),
      if (source) ...[
        refPicker(context, isDark, tr('القناة'), Icons.campaign_rounded, ll(meta['channels']), channel, (v) => set(() {
              channel = v;
              campaign = null;
            })),
        if (camps.isNotEmpty) refPicker(context, isDark, tr('الحملة'), Icons.ads_click_rounded, camps, campaign, (v) => set(() => campaign = v)),
      ],
      SegmentedButton<String>(
        segments: [ButtonSegment(value: 'fresh', label: Text(tr('فريش'))), ButtonSegment(value: 'cold', label: Text(tr('كولد كول')))],
        selected: {kind},
        onSelectionChanged: (s) => set(() => kind = s.first),
      ),
      JphUi.input(isDark: isDark, label: tr('الميزانية (اختياري)'), controller: budget, number: true, suffix: tr('جنيه'), icon: Icons.payments_rounded, big: false),
      JphUi.input(isDark: isDark, label: tr('الإيميل (اختياري)'), controller: email, icon: Icons.email_rounded, big: false),
      JphUi.input(isDark: isDark, label: tr('ملاحظات'), controller: notes, icon: Icons.notes_rounded, big: false),
      if (isNew && people.isNotEmpty)
        JphUi.picker(
          isDark: isDark, icon: Icons.groups_rounded, iconColor: Ar.accent, label: tr('السيلز'),
          value: assignees.isEmpty
              ? (mcan['distribute'] == true ? tr('من غير (يفضل مش متوزع)') : tr('ليا أنا'))
              : assignees.length == 1
                  ? '${people.firstWhere((p) => p['id'] == assignees.first, orElse: () => const {'name': ''})['name']}'
                  : '${assignees.length} سيلز بالدور',
          onTap: () async {
            final v = await pickPeople(context, isDark, tr('السيلز'), people, selected: assignees);
            if (v != null) set(() => assignees = v);
          },
        ),
    ];
  }, () async {
    if (name.text.trim().length < 2 || (phoneOk && phone.text.trim().length < 7) || project == null) {
      JphUi.toast(context, {'success': false, 'message': project == null ? tr('اختار المشروع') : tr('اكتب الاسم والموبايل')});
      return false;
    }
    final extra = phone2.text.split(RegExp(r'[،,\n]')).map((x) => x.trim()).where((x) => x.length >= 7).toList();
    final b = <String, dynamic>{
      'fullName': name.text.trim(), 'extraPhones': extra, 'email': email.text.trim(), 'kind': kind, 'notes': notes.text.trim(),
      'budget': num.tryParse(budget.text.replaceAll(',', '')), 'projectId': project,
      if (phoneOk) 'phone': phone.text.trim(),
      if (source) ...{'channelId': channel, 'campaignId': campaign},
      if (isNew) 'assignees': assignees,
    };
    final r = isNew ? await lpost('/leads', b, ok: tr('اتضاف الليد ✅')) : await lpost('/leads/${lead['id']}', b, ok: tr('اتحفظ ✅'), method: 'patch');
    if (context.mounted) {
      JphUi.toast(context, r['duplicate'] == true ? {...r, 'message': tr('اتضاف — الرقم ده موجود قبل كده فراح لنفس السيلز')} : r);
    }
    return r['success'] == true;
  }, saveLabel: isNew ? tr('إضافة') : tr('حفظ'));
}

/// توزيع / إعادة توزيع: to one or more salesmen (in turn), as fresh / cold / the same stage
Future<bool> assignLeads(BuildContext context, bool isDark, Map<String, dynamic> meta, List<Object?> ids) async {
  final people = ll(meta['assignees']);
  List<String> to = [];
  String mode = 'fresh';
  return leadForm(context, isDark, ids.length == 1 ? tr('توزيع العميل') : 'توزيع ${ids.length} ليد', (set) => [
        JphUi.picker(
          isDark: isDark, icon: Icons.groups_rounded, iconColor: Ar.accent, label: tr('على مين'),
          value: to.isEmpty ? tr('اختار السيلز') : to.length == 1 ? '${people.firstWhere((p) => p['id'] == to.first, orElse: () => const {'name': ''})['name']}' : '${to.length} سيلز بالدور',
          onTap: () async {
            final v = await pickPeople(context, isDark, tr('وزّع على'), people, selected: to);
            if (v != null) set(() => to = v);
          },
        ),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'fresh', label: Text(tr('فريش'))),
            ButtonSegment(value: 'cold', label: Text(tr('كولد كول'))),
            ButtonSegment(value: 'same', label: Text(tr('نفس المرحلة'))),
          ],
          selected: {mode},
          onSelectionChanged: (s) => set(() => mode = s.first),
        ),
        Text(mode == 'same' ? tr('العميل بيروح بنفس مرحلته ومعاد متابعته') : tr('العميل بيبدأ من الأول عند السيلز الجديد (التعليقات القديمة بتفضل ظاهرة)'),
            style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
      ], () async {
    if (to.isEmpty) {
      JphUi.toast(context, {'success': false, 'message': tr('اختار السيلز')});
      return false;
    }
    final r = await lpost('/leads/assign', {'ids': ids, 'to': to, 'mode': mode}, ok: tr('اتوزع ✅'));
    if (context.mounted) JphUi.toast(context, r);
    return r['success'] == true;
  }, saveLabel: tr('وزّع'), saveIcon: Icons.switch_account_rounded);
}

/// تعديل جماعي: the project / fresh-cold / the rating (and, for the distributor, the channel / campaign) of several leads
Future<bool> bulkEditLeads(BuildContext context, bool isDark, Map<String, dynamic> meta, List<Object?> ids) async {
  String? project, kind, rating, channel, campaign;
  final dist = lm(meta['can'])['distribute'] == true;
  return leadForm(context, isDark, 'تعديل ${ids.length} ليد', (set) => [
        Text(tr('اللي هتسيبه فاضي مش هيتغيّر'), style: TextStyle(color: JphUi.sub(isDark))),
        refPicker(context, isDark, tr('المشروع'), Icons.apartment_rounded, ll(meta['projects']), project, (v) => set(() => project = v)),
        refPicker(context, isDark, tr('النوع'), Icons.ac_unit_rounded, [{'id': 'fresh', 'name': tr('فريش')}, {'id': 'cold', 'name': tr('كولد كول')}], kind,
            (v) => set(() => kind = v)),
        refPicker(context, isDark, tr('التقييم'), Icons.local_fire_department_rounded,
            [{'id': 'hot', 'name': tr('ساخن 🔥')}, {'id': 'warm', 'name': tr('دافي')}, {'id': 'cold', 'name': tr('بارد')}], rating, (v) => set(() => rating = v)),
        if (dist) ...[
          refPicker(context, isDark, tr('القناة'), Icons.campaign_rounded, ll(meta['channels']), channel, (v) => set(() => channel = v)),
          refPicker(context, isDark, tr('الحملة'), Icons.ads_click_rounded, ll(meta['campaigns']), campaign, (v) => set(() => campaign = v)),
        ],
      ], () async {
    final b = <String, dynamic>{
      'ids': ids, if (project != null) 'projectId': project, if (kind != null) 'kind': kind, if (rating != null) 'rating': rating,
      if (channel != null) 'channelId': channel, if (campaign != null) 'campaignId': campaign,
    };
    if (b.length == 1) {
      JphUi.toast(context, {'success': false, 'message': tr('اختار اللي عايز تغيّره')});
      return false;
    }
    final r = await lpost('/leads/bulk', b, ok: tr('اتعدّل ✅'));
    if (context.mounted) JphUi.toast(context, r);
    return r['success'] == true;
  }, saveLabel: tr('عدّل'));
}


/// open a lead the way the directory opens a person: a floating panel beside the list on the computer,
/// a tall bottom sheet with a grabber on the phone.
Future<void> openLead(BuildContext context, String id) {
  if (SideSheets.wide(context)) {
    return SideSheets.show<void>(context, width: 540, page: true, builder: (_) => LeadPage(leadId: id, sheet: true));
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => FractionallySizedBox(heightFactor: 0.94, child: LeadPage(leadId: id, sheet: true)),
  );
}
