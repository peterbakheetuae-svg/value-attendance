import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/side_sheet.dart';
import 'lead_page.dart';
import 'leads_api.dart';
import 'leads_extra.dart';
import 'leads_import.dart';

/// الليدز: the tabs (الكل / فريش / كولد / متأخر / مستني / مكرر / مش متوزع), the stages bar, the search and the filters;
/// a salesman sees his leads ordered by the nearest follow-up; the distributor / manager select several to give them out.
class LeadsListPage extends StatefulWidget {
  final String tab;
  final String? stage, rating;
  const LeadsListPage({super.key, this.tab = 'all', this.stage, this.rating});

  @override
  State<LeadsListPage> createState() => _LeadsListPageState();
}

class _LeadsListPageState extends State<LeadsListPage> {
  late String _tab = widget.tab;
  late String? _stage = widget.stage;
  String? _project, _channel, _person;
  late String? _rating = widget.rating;
  final _q = TextEditingController();
  Timer? _debounce;
  bool _loading = true;
  int _page = 1, _total = 0, _seq = 0;
  List<Map<String, dynamic>> _leads = [];
  Map<String, dynamic> _tabs = {}, _stages = {}, _meta = {};
  final Set<String> _picked = {};

  @override
  void initState() {
    super.initState();
    LeadsMeta.load().then((m) {
      if (mounted) setState(() => _meta = m);
    });
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _load({bool reset = true}) async {
    if (reset) _page = 1;
    final seq = ++_seq;
    setState(() => _loading = true);
    final r = await lget('/leads', {
      'tab': _tab, 'stage': _stage, 'projectId': _project, 'channelId': _channel, 'assignedTo': _person, 'rating': _rating,
      'q': _q.text.trim(), 'page': '$_page', 'size': '30',
    });
    if (!mounted || seq != _seq) return; // a late answer for an older filter
    setState(() {
      _loading = false;
      final rows = ll(r['leads']);
      _leads = reset ? rows : [..._leads, ...rows];
      _total = (r['total'] as num?)?.toInt() ?? 0;
      _tabs = lm(r['tabs']);
      _stages = lm(r['stages']);
      if (reset) _picked.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final can = lm(_meta['can']);
    final manager = can['assign'] == true;
    final tabs = <(String, String)>[
      ('all', tr('الكل')), if (manager) ('mine', tr('ليدز بتاعتي')), ('today', tr('النهارده')), ('fresh', tr('فريش')), ('cold', tr('كولد')),
      ('delay', tr('متأخر')), ('pending', tr('مستني أكشن')), if (manager) ('duplicated', tr('مكرر')), if (can['distribute'] == true) ('unassigned', tr('مش متوزع')),
      ('shared', tr('متشارك')),
    ];
    final delay = (_tabs['delay'] as num?) ?? 0;
    return LeadsShell(
      isDark: isDark,
      title: tr('الليدز'),
      fab: _picked.isNotEmpty && manager
          ? FloatingActionButton.extended(
              onPressed: () async {
                final what = await JphUi.sheet<String>(context, isDark, '${_picked.length} ليد', [
                  ('assign', tr('توزيع / نقل لسيلز'), Icons.switch_account_rounded),
                  ('bulk', tr('تعديل جماعي (المشروع / النوع / التقييم / القناة)'), Icons.edit_note_rounded),
                ]);
                if (!mounted || what == null) return;
                final done = what == 'assign'
                    ? await assignLeads(context, isDark, _meta, _picked.toList())
                    : await bulkEditLeads(context, isDark, _meta, _picked.toList());
                if (done) _load();
              },
              backgroundColor: Ar.accent.shade700,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.checklist_rounded),
              label: Text('${_picked.length} مختار', style: const TextStyle(fontWeight: FontWeight.w800)),
            )
          : null,
      child: RefreshIndicator(
        onRefresh: _load,
        child: NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels > n.metrics.maxScrollExtent - 300 && !_loading && _leads.length < _total) {
              _page++;
              _load(reset: false);
            }
            return false;
          },
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 110), children: [
            // ------------------------------------------------ the title, its line and the two buttons
            Text(tr('الليدز'), style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, color: JphUi.text(isDark), height: 1.1)),
            const SizedBox(height: 4),
            Text('${_tabs['all'] ?? _total} عميل${delay > 0 ? ' • $delay متأخر' : ''}', style: TextStyle(fontSize: 14, color: JphUi.sub(isDark))),
            const SizedBox(height: 14),
            Row(children: [
              if (manager)
                Expanded(child: dirBtn(isDark, tr('تصدير إكسيل'), Icons.file_download_outlined, () => _export())),
              if (can['import'] == true)
                Expanded(
                  child: dirBtn(isDark, tr('استورد'), Icons.upload_file_rounded, () async {
                    if (await importLeads(context, isDark, _meta)) _load();
                  }),
                ),
              Expanded(
                flex: 2,
                child: dirBtn(isDark, tr('ليد جديد'), Icons.person_add_alt_1_rounded, _meta.isEmpty
                    ? null
                    : () async {
                        if (await editLead(context, isDark, _meta)) _load();
                      }, primary: true),
              ),
            ]),
            const SizedBox(height: 10),
            // ------------------------------------------------ the directory card
            Container(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF242321) : Colors.white,
                borderRadius: BorderRadius.circular(22),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.3 : 0.05), blurRadius: 18, offset: const Offset(0, 6))],
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _q,
                      onChanged: (_) {
                        _debounce?.cancel();
                        _debounce = Timer(const Duration(milliseconds: 400), _load);
                      },
                      decoration: InputDecoration(
                        hintText: tr('دوّر بالاسم أو الرقم أو التعليق'),
                        prefixIcon: const Icon(Icons.search_rounded),
                        isDense: true,
                        filled: true,
                        fillColor: isDark ? Colors.white.withOpacity(0.06) : const Color(0xFFF4F3F1),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? Colors.white12 : const Color(0xFFE4E2DE))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: isDark ? Colors.white12 : const Color(0xFFE4E2DE))),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.outlined(tooltip: tr('فلتر'), onPressed: () => _filters(isDark), icon: const Icon(Icons.tune_rounded)),
                ]),
                const SizedBox(height: 10),
                Row(children: [
                  Text('${_leads.length} ${tr('من')} $_total', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                  const Spacer(),
                  if (manager && _leads.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(() {
                        if (_picked.length == _leads.length) {
                          _picked.clear();
                        } else {
                          _picked.addAll(_leads.map((l) => '${l['id']}'));
                        }
                      }),
                      child: Text(_picked.length == _leads.length ? tr('شيل التحديد') : tr('حدد الكل')),
                    ),
                ]),
                const SizedBox(height: 6),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final t in tabs)
                      dirChip(isDark, t.$2, _tab == t.$1, () {
                        _tab = t.$1;
                        _stage = null;
                        _load();
                      }, count: (_tabs[t.$1] as num?)?.toInt()),
                  ]),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final s in stageNames.entries)
                      dirChip(isDark, s.value, _stage == s.key, () {
                        _stage = _stage == s.key ? null : s.key;
                        _load();
                      }, count: (_stages[s.key] as num?)?.toInt() ?? 0, dot: stageColor(s.key)),
                  ]),
                ),
                if (_project != null || _channel != null || _person != null || _rating != null)
                  Wrap(spacing: 6, children: [
                    if (_project != null)
                      InputChip(label: Text(_name('projects', _project)), onDeleted: () {
                        _project = null;
                        _load();
                      }),
                    if (_channel != null)
                      InputChip(label: Text(_name('channels', _channel)), onDeleted: () {
                        _channel = null;
                        _load();
                      }),
                    if (_rating != null)
                      InputChip(label: Text({'hot': tr('ساخن 🔥'), 'warm': tr('دافي'), 'cold': tr('بارد')}[_rating] ?? ''), onDeleted: () {
                        _rating = null;
                        _load();
                      }),
                    if (_person != null)
                      InputChip(label: Text(_name('assignees', _person)), onDeleted: () {
                        _person = null;
                        _load();
                      }),
                  ]),
                const SizedBox(height: 6),
                if (_loading && _leads.isEmpty) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
                if (!_loading && _leads.isEmpty)
                  Padding(padding: const EdgeInsets.all(30), child: Text(tr('مفيش عملاء هنا'), textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
                LayoutBuilder(builder: (context, c) {
                  final wide = c.maxWidth >= 860;
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (wide && _leads.isNotEmpty) _headRow(isDark, manager),
                    for (final l in _leads) wide ? _row(isDark, l, manager) : _card(isDark, l, manager),
                  ]);
                }),
                if (_loading && _leads.isNotEmpty) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  String _name(String list, String? id) => '${ll(_meta[list]).firstWhere((x) => '${x['id']}' == id, orElse: () => const {'name': ''})['name']}';

  void _toggle(Map<String, dynamic> l) => setState(() {
        final id = '${l['id']}';
        if (!_picked.remove(id)) _picked.add(id);
      });

  Future<void> _open(Map<String, dynamic> l) async {
    if (_picked.isNotEmpty) {
      _toggle(l);
      return;
    }
    await openLead(context, '${l['id']}');
    _load(); // whatever changed on the lead shows in the list
  }

  /// the «when» of a lead: waiting / overdue / next follow-up / last action
  (String, bool) _when(Map<String, dynamic> l) {
    final late = l['overdue'] == true || l['pending'] == true;
    final t = l['pending'] == true
        ? 'مستني أول أكشن — ${agoAr(l['assignedAt'])}'
        : l['nextAt'] != null
            ? whenAr(l['nextAt'])
            : l['lastActionAt'] == null ? tr('لسه محدش كلّمه') : 'آخر أكشن ${agoAr(l['lastActionAt'])}';
    return (t, late);
  }

  TextStyle _head(bool isDark) => TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: JphUi.sub(isDark));

  Widget _headRow(bool isDark, bool manager) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: isDark ? Colors.white12 : const Color(0xFFEDEBE8)))),
        child: Row(children: [
          if (manager) const SizedBox(width: 36),
          Expanded(flex: 4, child: Text(tr('الاسم'), style: _head(isDark))),
          Expanded(flex: 3, child: Text(tr('المشروع'), style: _head(isDark))),
          Expanded(flex: 3, child: Text(tr('المرحلة'), style: _head(isDark))),
          if (manager) Expanded(flex: 3, child: Text(tr('السيلز'), style: _head(isDark))),
          Expanded(flex: 3, child: Text(tr('المتابعة الجاية'), style: _head(isDark))),
          Expanded(flex: 4, child: Text(tr('آخر تعليق'), style: _head(isDark))),
        ]),
      );

  /// the computer: one table row
  Widget _row(bool isDark, Map<String, dynamic> l, bool manager) {
    final picked = _picked.contains('${l['id']}');
    final (when, late) = _when(l);
    return InkWell(
      onTap: () => _open(l),
      onLongPress: manager ? () => _toggle(l) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: picked ? Ar.accent.withOpacity(0.08) : null,
          border: Border(bottom: BorderSide(color: isDark ? Colors.white10 : const Color(0xFFF1EFEC))),
        ),
        child: Row(children: [
          if (manager) SizedBox(width: 36, child: Checkbox(value: picked, onChanged: (_) => _toggle(l))),
          Expanded(
            flex: 4,
            child: Row(children: [
              leadAvatar('${l['fullName']}', size: 34),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${l['fullName']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                  Text('${l['phone']}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                ]),
              ),
            ]),
          ),
          Expanded(
            flex: 3,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: lm(l['project'])['name'] == null ? const SizedBox() : pill('${lm(l['project'])['name']}', Ar.info, icon: Icons.apartment_rounded),
            ),
          ),
          Expanded(flex: 3, child: Align(alignment: AlignmentDirectional.centerStart, child: pill('${stageNames[l['stage']] ?? l['stage']}', stageColor('${l['stage']}')))),
          if (manager)
            Expanded(
              flex: 3,
              child: Row(children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: l['assignedTo'] == null ? Ar.grey : Ar.accent, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Expanded(child: Text('${lm(l['assignedTo'])['name'] ?? tr('مش متوزع')}', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: JphUi.text(isDark)))),
              ]),
            ),
          Expanded(flex: 3, child: Text(when, maxLines: 2, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: late ? Ar.red.shade700 : JphUi.text(isDark)))),
          Expanded(flex: 4, child: Text('${l['lastComment'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark)))),
        ]),
      ),
    );
  }

  /// the phone: one row with its chips under the name
  Widget _card(bool isDark, Map<String, dynamic> l, bool manager) {
    final picked = _picked.contains('${l['id']}');
    final (when, late) = _when(l);
    return InkWell(
      onTap: () => _open(l),
      onLongPress: manager ? () => _toggle(l) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        decoration: BoxDecoration(
          color: picked ? Ar.accent.withOpacity(0.08) : null,
          border: Border(bottom: BorderSide(color: isDark ? Colors.white10 : const Color(0xFFF1EFEC))),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            if (manager && _picked.isNotEmpty) Checkbox(value: picked, onChanged: (_) => _toggle(l)),
            leadAvatar('${l['fullName']}', size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${l['fullName']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                Text([
                  '${l['phone']}',
                  if (manager && l['assignedTo'] != null) '${lm(l['assignedTo'])['name']}',
                ].join(' • '), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
              ]),
            ),
            IconButton(visualDensity: VisualDensity.compact, tooltip: tr('اتصال'), onPressed: () => callPhone('${l['phone']}'),
                icon: const Icon(Icons.call_rounded, color: Ar.green, size: 20)),
          ]),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 52),
            child: Row(children: [
              if (lm(l['project'])['name'] != null)
                Flexible(child: pill('${lm(l['project'])['name']}', Ar.info, icon: Icons.apartment_rounded)),
              const Spacer(),
              pill('${stageNames[l['stage']] ?? l['stage']}', stageColor('${l['stage']}')),
            ]),
          ),
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 52, top: 6),
            child: Text(when, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: late ? Ar.red.shade700 : JphUi.sub(isDark))),
          ),
        ]),
      ),
    );
  }

  Future<void> _filters(bool isDark) async {
    String? p = _project, ch = _channel, who = _person, rt = _rating;
    final ok = await leadForm(context, isDark, tr('فلتر'), (set) => [
          refPicker(context, isDark, tr('المشروع'), Icons.apartment_rounded, ll(_meta['projects']), p, (v) => set(() => p = v)),
          refPicker(context, isDark, tr('القناة'), Icons.campaign_rounded, ll(_meta['channels']), ch, (v) => set(() => ch = v)),
          if (ll(_meta['assignees']).isNotEmpty)
            refPicker(context, isDark, tr('السيلز'), Icons.person_rounded, ll(_meta['assignees']), who, (v) => set(() => who = v)),
          refPicker(context, isDark, tr('تقييم العميل'), Icons.local_fire_department_rounded,
              [{'id': 'hot', 'name': tr('ساخن 🔥')}, {'id': 'warm', 'name': tr('دافي')}, {'id': 'cold', 'name': tr('بارد')}], rt, (v) => set(() => rt = v)),
        ], () async => true, saveLabel: tr('طبّق'), saveIcon: Icons.filter_alt_rounded);
    if (!ok) return;
    _project = p;
    _channel = ch;
    _person = who;
    _rating = rt;
    _load();
  }

  /// all the leads of the current tab / filters (up to 5000) → Excel; the export is written in the log
  Future<void> _export() async {
    JphUi.toast(context, {'success': true, 'message': tr('بجهّز الملف…')});
    final rows = <List<Object?>>[];
    for (var page = 1; page <= 25; page++) {
      final r = await lget('/leads', {
        'tab': _tab, 'stage': _stage, 'projectId': _project, 'channelId': _channel, 'assignedTo': _person, 'rating': _rating,
        'q': _q.text.trim(), 'page': '$page', 'size': '200',
      });
      final got = ll(r['leads']);
      for (final l in got) {
        rows.add([
          l['refNo'], l['fullName'], l['phone'], ((l['extraPhones'] as List?) ?? const []).join(' / '), lm(l['project'])['name'], lm(l['channel'])['name'],
          lm(l['campaign'])['name'], l['kind'] == 'cold' ? tr('كولد') : tr('فريش'), l['stageAr'], {'hot': tr('ساخن'), 'warm': tr('دافي'), 'cold': tr('بارد')}[l['rating']],
          lm(l['assignedTo'])['name'], whenAr(l['nextAt']), l['lastComment'], lm(l['cancelReason'])['name'], l['budget'], whenAr(l['createdAt']),
        ]);
      }
      if (got.length < 200) break;
    }
    if (!mounted) return;
    await exportTable(context, 'leads', 'ليدز ${DateTime.now().day}-${DateTime.now().month}', [
      tr('رقم'), tr('الاسم'), tr('الموبايل'), tr('أرقام تانية'), tr('المشروع'), tr('القناة'), tr('الحملة'), tr('النوع'), tr('المرحلة'), tr('التقييم'), tr('السيلز'), tr('المتابعة الجاية'),
      tr('آخر تعليق'), tr('سبب الإلغاء'), tr('الميزانية'), tr('اتضاف'),
    ], rows, filters: {'tab': _tab, 'stage': _stage, 'projectId': _project, 'channelId': _channel, 'assignedTo': _person, 'rating': _rating});
  }
}
