import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/side_sheet.dart';
import 'lead_page.dart';
import 'leads_api.dart';
import 'leads_import.dart';

/// الليدز: the tabs (الكل / فريش / كولد / متأخر / مستني / مكرر / مش متوزع), the stages bar, the search and the filters;
/// a salesman sees his leads ordered by the nearest follow-up; the distributor / manager select several to give them out.
class LeadsListPage extends StatefulWidget {
  final String tab;
  final String? stage;
  const LeadsListPage({super.key, this.tab = 'all', this.stage});

  @override
  State<LeadsListPage> createState() => _LeadsListPageState();
}

class _LeadsListPageState extends State<LeadsListPage> {
  late String _tab = widget.tab;
  late String? _stage = widget.stage;
  String? _project, _channel, _person;
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
      'tab': _tab, 'stage': _stage, 'projectId': _project, 'channelId': _channel, 'assignedTo': _person,
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
      ('all', 'الكل'), if (manager) ('mine', 'ليدز بتاعتي'), ('today', 'النهارده'), ('fresh', 'فريش'), ('cold', 'كولد'),
      ('delay', 'متأخر'), ('pending', 'مستني أكشن'), if (manager) ('duplicated', 'مكرر'), if (can['distribute'] == true) ('unassigned', 'مش متوزع'),
      ('shared', 'متشارك'),
    ];
    return LeadsShell(
      isDark: isDark,
      title: 'الليدز',
      action: can['import'] == true
          ? IconButton(
              tooltip: 'استيراد من إكسيل',
              onPressed: () async {
                if (await importLeads(context, isDark, _meta)) _load();
              },
              icon: Icon(Icons.upload_file_rounded, color: JphUi.text(isDark)),
            )
          : null,
      fab: _picked.isNotEmpty && manager
          ? FloatingActionButton.extended(
              onPressed: () async {
                if (await assignLeads(context, isDark, _meta, _picked.toList())) _load();
              },
              backgroundColor: Ar.accent.shade700,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.switch_account_rounded),
              label: Text('وزّع ${_picked.length}', style: const TextStyle(fontWeight: FontWeight.w800)),
            )
          : FloatingActionButton.extended(
              onPressed: _meta.isEmpty
                  ? null
                  : () async {
                      if (await editLead(context, isDark, _meta)) _load();
                    },
              backgroundColor: JphUi.primary(isDark),
              foregroundColor: Colors.white,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('ليد جديد', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
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
          child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 100), children: [
            TextField(
              controller: _q,
              onChanged: (_) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 400), _load);
              },
              decoration: InputDecoration(
                hintText: 'دوّر بالاسم أو الرقم أو التعليق',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: IconButton(icon: const Icon(Icons.tune_rounded), tooltip: 'فلتر', onPressed: () => _filters(isDark)),
                filled: true,
                fillColor: isDark ? Colors.white.withOpacity(0.06) : Colors.white.withOpacity(0.8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final t in tabs)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: ChoiceChip(
                      selected: _tab == t.$1,
                      label: Text('${t.$2} ${_tabs[t.$1] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      selectedColor: (t.$1 == 'delay' || t.$1 == 'pending' ? Ar.red : JphUi.primary(isDark)).withOpacity(0.25),
                      onSelected: (_) {
                        _tab = t.$1;
                        _stage = null;
                        _load();
                      },
                    ),
                  ),
              ]),
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final s in stageNames.entries)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: FilterChip(
                      selected: _stage == s.key,
                      avatar: Icon(stageIcon(s.key), size: 16, color: stageColor(s.key)),
                      label: Text('${s.value} ${_stages[s.key] ?? 0}'),
                      onSelected: (v) {
                        _stage = v ? s.key : null;
                        _load();
                      },
                    ),
                  ),
              ]),
            ),
            if (_project != null || _channel != null || _person != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(spacing: 6, children: [
                  if (_project != null) InputChip(label: Text(_name('projects', _project)), onDeleted: () {
                    _project = null;
                    _load();
                  }),
                  if (_channel != null) InputChip(label: Text(_name('channels', _channel)), onDeleted: () { _channel = null; _load(); }),
                  if (_person != null) InputChip(label: Text(_name('assignees', _person)), onDeleted: () { _person = null; _load(); }),
                ]),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Text('$_total عميل', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.sub(isDark))),
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
                    child: Text(_picked.length == _leads.length ? 'شيل التحديد' : 'حدد الكل'),
                  ),
              ]),
            ),
            if (_loading && _leads.isEmpty) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
            if (!_loading && _leads.isEmpty)
              Padding(padding: const EdgeInsets.all(30), child: Text('مفيش عملاء هنا', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
            LayoutBuilder(builder: (context, c) {
              final cols = c.maxWidth > 900 ? 3 : c.maxWidth > 600 ? 2 : 1;
              final w = (c.maxWidth - (cols - 1) * 10) / cols;
              return Wrap(spacing: 10, runSpacing: 10, children: [for (final l in _leads) SizedBox(width: w, child: _card(isDark, l, manager))]);
            }),
            if (_loading && _leads.isNotEmpty) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
          ]),
        ),
      ),
    );
  }

  String _name(String list, String? id) => '${ll(_meta[list]).firstWhere((x) => '${x['id']}' == id, orElse: () => const {'name': ''})['name']}';

  Widget _card(bool isDark, Map<String, dynamic> l, bool manager) {
    final picked = _picked.contains('${l['id']}');
    final late = l['overdue'] == true || l['pending'] == true;
    return GestureDetector(
      onTap: () async {
        if (_picked.isNotEmpty) {
          setState(() => picked ? _picked.remove('${l['id']}') : _picked.add('${l['id']}'));
          return;
        }
        await pushSide<void>(context, LeadPage(leadId: '${l['id']}'));
        _load(); // whatever changed on the lead shows in the list
      },
      onLongPress: manager ? () => setState(() => picked ? _picked.remove('${l['id']}') : _picked.add('${l['id']}')) : null,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: JphUi.box(isDark).copyWith(
          border: Border.all(color: picked ? Ar.accent : late ? Ar.red.withOpacity(0.6) : Colors.transparent, width: picked ? 2 : 1.2),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            if (manager)
              SizedBox(
                width: 28,
                child: Checkbox(value: picked, onChanged: (v) => setState(() => v == true ? _picked.add('${l['id']}') : _picked.remove('${l['id']}'))),
              ),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${l['fullName']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                Text('${l['phone']} • ${lm(l['project'])['name'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
              ]),
            ),
            stageChip('${l['stage']}'),
          ]),
          const SizedBox(height: 6),
          if ('${l['lastComment'] ?? ''}'.isNotEmpty)
            Text('${l['lastComment']}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: JphUi.text(isDark))),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: Text(
                l['pending'] == true
                    ? 'مستني أول أكشن — اتوزع ${agoAr(l['assignedAt'])}'
                    : l['nextAt'] != null
                        ? '${l['overdue'] == true ? 'متأخر: ' : 'المتابعة: '}${whenAr(l['nextAt'])}'
                        : l['lastActionAt'] == null ? 'لسه محدش كلّمه' : 'آخر أكشن ${agoAr(l['lastActionAt'])}',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: late ? Ar.red : JphUi.sub(isDark)),
              ),
            ),
            if (manager && l['assignedTo'] != null)
              Text('${lm(l['assignedTo'])['name']}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Ar.accent.shade700)),
          ]),
          Row(children: [
            IconButton(visualDensity: VisualDensity.compact, tooltip: 'اتصال', onPressed: () => callPhone('${l['phone']}'),
                icon: const Icon(Icons.call_rounded, color: Ar.green)),
            IconButton(visualDensity: VisualDensity.compact, tooltip: 'واتساب', onPressed: () => whatsApp('${l['phone']}'),
                icon: const Icon(Icons.chat_rounded, color: Color(0xFF25D366))),
            if (l['kind'] == 'cold') JphUi.chip('كولد', Ar.info),
            if (l['duplicateOf'] != null) Padding(padding: const EdgeInsets.only(right: 4), child: JphUi.chip('مكرر', Ar.amber)),
            const Spacer(),
            if (!const ['done_deal'].contains(l['stage']))
              TextButton.icon(
                onPressed: () async {
                  if (await addLeadAction(context, isDark, l, _meta)) _load();
                },
                icon: const Icon(Icons.add_task_rounded, size: 18),
                label: const Text('أكشن', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
          ]),
        ]),
      ),
    );
  }

  Future<void> _filters(bool isDark) async {
    String? p = _project, ch = _channel, who = _person;
    final ok = await leadForm(context, isDark, 'فلتر', (set) => [
          refPicker(context, isDark, 'المشروع', Icons.apartment_rounded, ll(_meta['projects']), p, (v) => set(() => p = v)),
          refPicker(context, isDark, 'القناة', Icons.campaign_rounded, ll(_meta['channels']), ch, (v) => set(() => ch = v)),
          if (ll(_meta['assignees']).isNotEmpty)
            refPicker(context, isDark, 'السيلز', Icons.person_rounded, ll(_meta['assignees']), who, (v) => set(() => who = v)),
        ], () async => true, saveLabel: 'طبّق', saveIcon: Icons.filter_alt_rounded);
    if (!ok) return;
    _project = p;
    _channel = ch;
    _person = who;
    _load();
  }
}
