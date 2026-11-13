import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../exclusive/exclusive_projects_page.dart' show newUnit;
import 'leads_api.dart';
import 'tasks_page.dart' show editTask;

/// One lead (a side panel on the computer): its data, «إضافة أكشن», the reservation from it, the comments and replies,
/// the reservations made from it and — for the managers — its log (who gave it, who opened it).
class LeadPage extends StatefulWidget {
  final String leadId;
  const LeadPage({super.key, required this.leadId});

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
      _d = r[0]['success'] == true ? r[0] : {'error': r[0]['message'] ?? 'الليد مش موجود'};
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
    return LeadsShell(
        isDark: isDark,
        title: d?['lead'] == null ? 'العميل' : '${lm(d!['lead'])['fullName']}',
        child: d == null
            ? const Center(child: CircularProgressIndicator())
            : d['error'] != null
                ? Center(child: Text('${d['error']}', style: TextStyle(color: JphUi.sub(isDark))))
                : RefreshIndicator(onRefresh: _load, child: _body(isDark, d)),
    );
  }

  Widget _body(bool isDark, Map<String, dynamic> d) {
    final l = lm(d['lead']);
    final can = lm(d['can']);
    final phone = '${l['phone'] ?? ''}';
    final next = l['nextAt'];
    final open = !const ['cancelled', 'done_deal', 'reservation'].contains(l['stage']);
    return ListView(padding: const EdgeInsets.fromLTRB(14, 6, 14, 40), children: [
      Container(
        padding: const EdgeInsets.all(16),
        decoration: JphUi.box(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            JphUi.iconTile(isDark, stageIcon('${l['stage']}'), stageColor('${l['stage']}')),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${l['fullName']}', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                const SizedBox(height: 2),
                SelectableText(phone, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: JphUi.sub(isDark))),
              ]),
            ),
            stageChip('${l['stage']}'),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: leadBtn(isDark, 'اتصال', Icons.call_rounded, () => callPhone(phone), color: Ar.green)),
            const SizedBox(width: 8),
            Expanded(child: leadBtn(isDark, 'واتساب', Icons.chat_rounded, () => whatsApp(phone), color: const Color(0xFF25D366))),
          ]),
          if (l['pending'] == true || l['overdue'] == true) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Ar.red.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
              child: Text(l['pending'] == true ? 'الليد اتوزع ولسه محدش عمل عليه أكشن' : 'معاد المتابعة عدّى: ${whenAr(next)}',
                  style: const TextStyle(color: Ar.red, fontWeight: FontWeight.w800)),
            ),
          ] else if (next != null && open) ...[
            const SizedBox(height: 10),
            Text('المتابعة الجاية: ${whenAr(next)}', style: TextStyle(fontWeight: FontWeight.w800, color: Ar.accent.shade700)),
          ],
        ]),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (can['act'] == true && l['stage'] != 'done_deal')
          SizedBox(width: 170, child: leadBtn(isDark, 'إضافة أكشن', Icons.add_task_rounded, () async => _after(await addLeadAction(context, isDark, l, _meta)))),
        if (can['reserve'] == true)
          SizedBox(width: 150, child: leadBtn(isDark, 'حجز وحدة', Icons.bookmark_add_rounded, () => _reserve(isDark, l), color: const Color(0xFF3FC1C9))),
        if (can['edit'] == true)
          SizedBox(width: 120, child: leadBtn(isDark, 'تعديل', Icons.edit_rounded, () async => _after(await editLead(context, isDark, _meta, lead: l, can: can)), outline: true)),
        if (can['assign'] == true)
          SizedBox(width: 130, child: leadBtn(isDark, 'توزيع', Icons.switch_account_rounded, () async => _after(await assignLeads(context, isDark, _meta, [l['id']])), outline: true)),
        if (can['refer'] == true)
          SizedBox(width: 130, child: leadBtn(isDark, 'مشاركة', Icons.group_add_rounded, () async => _after(await _refer(isDark, l)), outline: true)),
        SizedBox(width: 120, child: leadBtn(isDark, 'مهمة', Icons.task_alt_rounded, () async => _after(await editTask(context, isDark, lead: l)), outline: true)),
      ]),
      const SizedBox(height: 12),
      _info(isDark, l, d),
      const SizedBox(height: 12),
      JphUi.tabs(isDark, [
        ('التعليقات', Icons.forum_rounded),
        ('الحجوزات', Icons.home_work_rounded),
        if (can['log'] == true) ('السجل', Icons.history_rounded),
      ], _tab == 'comments' ? 0 : _tab == 'units' ? 1 : 2, (i) => setState(() => _tab = ['comments', 'units', 'log'][i])),
      const SizedBox(height: 10),
      if (_tab == 'comments') ..._comments(isDark, ll(d['actions'])),
      if (_tab == 'units') ..._units(isDark, ll(d['units'])),
      if (_tab == 'log') ..._log(isDark, ll(d['logs'])),
    ]);
  }

  Widget _info(bool isDark, Map<String, dynamic> l, Map<String, dynamic> d) {
    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 130, child: Text(k, style: TextStyle(color: JphUi.sub(isDark)))),
            Expanded(child: Text(v, style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark)))),
          ]),
        );
    final refs = ll(d['referrals']);
    final extra = (l['extraPhones'] as List?)?.join(' — ') ?? '';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        kv('رقم الليد', '#${l['refNo']}'),
        kv('المشروع', '${lm(l['project'])['name'] ?? '—'}'),
        kv('السيلز', '${lm(l['assignedTo'])['name'] ?? 'لسه مش متوزع'}'),
        if (l['channel'] != null) kv('القناة', '${lm(l['channel'])['name']}'),
        if (l['campaign'] != null) kv('الحملة', '${lm(l['campaign'])['name']}'),
        kv('النوع', l['kind'] == 'cold' ? 'كولد كول' : 'فريش'),
        if (extra.isNotEmpty) kv('أرقام تانية', extra),
        if ('${l['email'] ?? ''}'.isNotEmpty) kv('الإيميل', '${l['email']}'),
        if (l['budget'] != null) kv('الميزانية', JphUi.money(l['budget'])),
        if (l['cancelReason'] != null) kv('سبب الإلغاء', '${lm(l['cancelReason'])['name']}'),
        if (l['duplicateOf'] != null) kv('مكرر', 'نفس رقم ${lm(l['duplicateOf'])['name']}'),
        if ((l['noAnswerCount'] ?? 0) > 0) kv('مردّش', '${l['noAnswerCount']} مرة'),
        if (refs.isNotEmpty) kv('متشارك مع', refs.map((r) => '${r['name']}').join('، ')),
        if ('${l['notes'] ?? ''}'.isNotEmpty) kv('ملاحظات', '${l['notes']}'),
        kv('اتضاف', '${whenAr(l['createdAt'])}${l['createdByName'] == null ? '' : ' — ${l['createdByName']}'}'),
      ]),
    );
  }

  List<Widget> _comments(bool isDark, List<Map<String, dynamic>> actions) {
    if (actions.isEmpty) {
      return [Padding(padding: const EdgeInsets.all(24), child: Text('لسه مفيش أكشن على العميل ده', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark))))];
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
                JphUi.chip(x['answered'] == true ? 'ردّ${(x['callSeconds'] ?? 0) > 0 ? ' — ${(x['callSeconds'] as num) ~/ 60}:${two((x['callSeconds'] as num).toInt() % 60)}' : ''}' : 'مردّش',
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
              child: TextButton.icon(onPressed: () => _reply(isDark, x), icon: const Icon(Icons.reply_rounded, size: 18), label: const Text('رد')),
            ),
          ]),
        ),
    ];
  }

  List<Widget> _units(bool isDark, List<Map<String, dynamic>> units) {
    if (units.isEmpty) {
      return [Padding(padding: const EdgeInsets.all(24), child: Text('مفيش حجوزات من العميل ده', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark))))];
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
        'create' => 'ضاف الليد',
        'import' => 'ضاف الليد من ملف إكسيل',
        'assign' => x['from'] == null
            ? 'وزّعه على ${x['toName'] ?? ''}${x['mode'] == 'duplicate' ? ' (عميله القديم)' : x['turn'] == true ? ' (بالدور)' : ''}'
            : 'نقله من ${x['fromName'] ?? ''} لـ ${x['toName'] ?? ''}${x['mode'] == 'cold' ? ' — كولد كول' : x['mode'] == 'fresh' ? ' — فريش' : ''}',
        'edit' => 'عدّل البيانات',
        'view' => 'فتح صفحة العميل',
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
    final ok = await leadForm(context, isDark, 'رد على التعليق', (set) => [
          Text('${x['comment']}', style: TextStyle(color: JphUi.sub(isDark))),
          JphUi.input(isDark: isDark, label: 'الرد', controller: c, icon: Icons.reply_rounded, big: false),
        ], () async {
      if (c.text.trim().isEmpty) return false;
      final r = await lpost('/leads/actions/${x['id']}/reply', {'comment': c.text.trim()}, ok: 'اتبعت ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    }, saveLabel: 'ابعت', saveIcon: Icons.send_rounded);
    await _after(ok);
  }

  Future<bool> _refer(bool isDark, Map<String, dynamic> l) async {
    final people = ll(_meta['assignees']).isNotEmpty ? ll(_meta['assignees']) : ll((await lget('/tasks'))['people']);
    if (!mounted) return false;
    final to = await pickPeople(context, isDark, 'شارك العميل مع', people.where((p) => p['id'] != lm(l['assignedTo'])['id']).toList());
    if (to == null || to.isEmpty) return false;
    final r = await lpost('/leads/${l['id']}/referral', {'to': to}, ok: 'اتشارك ✅');
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
  String meetingKind = 'معاينة';
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
        title: Text(answered ? 'ردّ' : 'مردّش', style: const TextStyle(fontWeight: FontWeight.w800)),
        secondary: Icon(answered ? Icons.call_rounded : Icons.phone_missed_rounded, color: answered ? Ar.green : Ar.grey),
      ),
      if (answered) JphUi.input(isDark: isDark, label: 'مدة المكالمة بالدقايق (اختياري)', controller: mins, number: true, icon: Icons.timer_rounded, big: false),
      if (meeting) ...[
        Wrap(spacing: 6, children: [
          for (final k in const ['معاينة', 'في المكتب', 'أونلاين', 'عند العميل'])
            ChoiceChip(selected: meetingKind == k, label: Text(k), onSelected: (_) => set(() => meetingKind = k)),
        ]),
        JphUi.input(isDark: isDark, label: 'مكان الميتنج', controller: place, icon: Icons.place_rounded, big: false),
      ],
      if (stage == 'cancelled') refPicker(context, isDark, 'سبب الإلغاء', Icons.cancel_rounded, reasons, reason, (v) => set(() => reason = v), allowNone: false),
      if (!noDate) WhenField(isDark: isDark, value: next, onPick: (v) => set(() => next = v), label: meeting ? 'معاد الميتنج' : 'معاد المتابعة الجاية'),
      JphUi.input(isDark: isDark, label: 'التعليق', controller: comment, icon: Icons.notes_rounded, big: false),
    ];
  }, () async {
    String? err;
    if (stage == null) err = 'اختار المرحلة';
    else if (comment.text.trim().isEmpty) err = 'اكتب التعليق';
    else if (stage == 'cancelled' && reason == null) err = 'اختار سبب الإلغاء';
    else if (stage != 'cancelled' && next == null) err = 'حدد المعاد الجاي';
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
    }, ok: 'اتسجل الأكشن ✅');
    if (context.mounted) JphUi.toast(context, r);
    return r['success'] == true;
  }, saveLabel: 'سجّل الأكشن');
}

/// إضافة ليد / تعديل ليد. [can] (from the lead): who may change the number / the source.
Future<bool> editLead(BuildContext context, bool isDark, Map<String, dynamic> meta, {Map<String, dynamic>? lead, Map<String, dynamic>? can}) async {
  final isNew = lead == null;
  final mcan = lm(meta['can']);
  final name = TextEditingController(text: '${lead?['fullName'] ?? ''}'), phone = TextEditingController(text: '${lead?['phone'] ?? ''}'),
      phone2 = TextEditingController(text: ((lead?['extraPhones'] as List?) ?? const []).join('، ')),
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
  return leadForm(context, isDark, isNew ? 'ليد جديد' : 'تعديل ${lead['fullName']}', (set) {
    final camps = ll(meta['campaigns']).where((c) => channel == null || c['channelId'] == null || c['channelId'] == channel).toList();
    return [
      JphUi.input(isDark: isDark, label: 'اسم العميل', controller: name, icon: Icons.person_rounded),
      if (phoneOk) JphUi.input(isDark: isDark, label: 'الموبايل', controller: phone, icon: Icons.phone_rounded, number: true),
      JphUi.input(isDark: isDark, label: 'أرقام تانية (افصل بينهم بـ ،)', controller: phone2, icon: Icons.phone_forwarded_rounded, big: false),
      refPicker(context, isDark, 'المشروع', Icons.apartment_rounded, projects, project, (v) => set(() => project = v), allowNone: false),
      if (source) ...[
        refPicker(context, isDark, 'القناة', Icons.campaign_rounded, ll(meta['channels']), channel, (v) => set(() {
              channel = v;
              campaign = null;
            })),
        if (camps.isNotEmpty) refPicker(context, isDark, 'الحملة', Icons.ads_click_rounded, camps, campaign, (v) => set(() => campaign = v)),
      ],
      SegmentedButton<String>(
        segments: const [ButtonSegment(value: 'fresh', label: Text('فريش')), ButtonSegment(value: 'cold', label: Text('كولد كول'))],
        selected: {kind},
        onSelectionChanged: (s) => set(() => kind = s.first),
      ),
      JphUi.input(isDark: isDark, label: 'الميزانية (اختياري)', controller: budget, number: true, suffix: 'جنيه', icon: Icons.payments_rounded, big: false),
      JphUi.input(isDark: isDark, label: 'الإيميل (اختياري)', controller: email, icon: Icons.email_rounded, big: false),
      JphUi.input(isDark: isDark, label: 'ملاحظات', controller: notes, icon: Icons.notes_rounded, big: false),
      if (isNew && people.isNotEmpty)
        JphUi.picker(
          isDark: isDark, icon: Icons.groups_rounded, iconColor: Ar.accent, label: 'السيلز',
          value: assignees.isEmpty
              ? (mcan['distribute'] == true ? 'من غير (يفضل مش متوزع)' : 'ليا أنا')
              : assignees.length == 1
                  ? '${people.firstWhere((p) => p['id'] == assignees.first, orElse: () => const {'name': ''})['name']}'
                  : '${assignees.length} سيلز بالدور',
          onTap: () async {
            final v = await pickPeople(context, isDark, 'السيلز', people, selected: assignees);
            if (v != null) set(() => assignees = v);
          },
        ),
    ];
  }, () async {
    if (name.text.trim().length < 2 || (phoneOk && phone.text.trim().length < 7) || project == null) {
      JphUi.toast(context, {'success': false, 'message': project == null ? 'اختار المشروع' : 'اكتب الاسم والموبايل'});
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
    final r = isNew ? await lpost('/leads', b, ok: 'اتضاف الليد ✅') : await lpost('/leads/${lead['id']}', b, ok: 'اتحفظ ✅', method: 'patch');
    if (context.mounted) {
      JphUi.toast(context, r['duplicate'] == true ? {...r, 'message': 'اتضاف — الرقم ده موجود قبل كده فراح لنفس السيلز'} : r);
    }
    return r['success'] == true;
  }, saveLabel: isNew ? 'إضافة' : 'حفظ');
}

/// توزيع / إعادة توزيع: to one or more salesmen (in turn), as fresh / cold / the same stage
Future<bool> assignLeads(BuildContext context, bool isDark, Map<String, dynamic> meta, List<Object?> ids) async {
  final people = ll(meta['assignees']);
  List<String> to = [];
  String mode = 'fresh';
  return leadForm(context, isDark, ids.length == 1 ? 'توزيع العميل' : 'توزيع ${ids.length} ليد', (set) => [
        JphUi.picker(
          isDark: isDark, icon: Icons.groups_rounded, iconColor: Ar.accent, label: 'على مين',
          value: to.isEmpty ? 'اختار السيلز' : to.length == 1 ? '${people.firstWhere((p) => p['id'] == to.first, orElse: () => const {'name': ''})['name']}' : '${to.length} سيلز بالدور',
          onTap: () async {
            final v = await pickPeople(context, isDark, 'وزّع على', people, selected: to);
            if (v != null) set(() => to = v);
          },
        ),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'fresh', label: Text('فريش')),
            ButtonSegment(value: 'cold', label: Text('كولد كول')),
            ButtonSegment(value: 'same', label: Text('نفس المرحلة')),
          ],
          selected: {mode},
          onSelectionChanged: (s) => set(() => mode = s.first),
        ),
        Text(mode == 'same' ? 'العميل بيروح بنفس مرحلته ومعاد متابعته' : 'العميل بيبدأ من الأول عند السيلز الجديد (التعليقات القديمة بتفضل ظاهرة)',
            style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
      ], () async {
    if (to.isEmpty) {
      JphUi.toast(context, {'success': false, 'message': 'اختار السيلز'});
      return false;
    }
    final r = await lpost('/leads/assign', {'ids': ids, 'to': to, 'mode': mode}, ok: 'اتوزع ✅');
    if (context.mounted) JphUi.toast(context, r);
    return r['success'] == true;
  }, saveLabel: 'وزّع', saveIcon: Icons.switch_account_rounded);
}
