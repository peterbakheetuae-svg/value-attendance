import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/side_sheet.dart';
import 'lead_page.dart';
import 'leads_api.dart';
import 'leads_extra.dart';

/// تقارير الليدز (of a period): every salesman's work, the channels, the campaigns (cost / CPL / CPA / ROI),
/// the cancel reasons, the funnel and who is late on which lead.
class LeadsReportsPage extends StatefulWidget {
  const LeadsReportsPage({super.key});

  @override
  State<LeadsReportsPage> createState() => _LeadsReportsPageState();
}

class _LeadsReportsPageState extends State<LeadsReportsPage> {
  late DateTime _from = DateTime(DateTime.now().year, DateTime.now().month, 1), _to = DateTime.now();
  Map<String, dynamic> _d = {}, _hourly = {}, _dist = {}, _yearly = {};
  String? _yearPerson;
  Map<String, dynamic> _meta = {};
  bool _loading = true;
  int _tab = 0, _seq = 0;

  String _day(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() => _loading = true);
    final q = {'from': _day(_from), 'to': _day(_to)};
    final r = await Future.wait([lget('/leads/reports', q), lget('/leads/reports/hourly', q), lget('/leads/reports/distribution', q), LeadsMeta.load()]);
    if (!mounted || seq != _seq) return;
    setState(() {
      _loading = false;
      _d = r[0];
      _hourly = r[1];
      _dist = r[2];
      _meta = r[3];
    });
    _loadYearly();
  }

  Future<void> _loadYearly() async {
    final r = await lget('/leads/reports/yearly', {'year': '${_to.year}', 'employeeId': _yearPerson});
    if (mounted) setState(() => _yearly = r);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    return LeadsShell(
      isDark: isDark,
      title: tr('تقارير السيلز'),
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 60), children: [
          JphUi.picker(
            isDark: isDark, icon: Icons.date_range_rounded, iconColor: Ar.accent, label: tr('الفترة'),
            value: '${_from.day}/${_from.month}/${_from.year}  ←  ${_to.day}/${_to.month}/${_to.year}',
            onTap: () async {
              final r = await JphUi.pickRange(context, isDark, _from, _to);
              if (r == null) return;
              _from = r.start;
              _to = r.end;
              _load();
            },
          ),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              for (final (i, t) in [tr('مندوب المبيعات'), tr('القنوات'), tr('الحملات'), tr('أسباب الإلغاء'), tr('المراحل'), tr('التأخير'), tr('الشغل ساعة بساعة'), tr('التوزيع'), tr('السنوي')].indexed)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 6),
                  child: ChoiceChip(selected: _tab == i, label: Text(t, style: const TextStyle(fontWeight: FontWeight.w800)), onSelected: (_) => setState(() => _tab = i)),
                ),
            ]),
          ),
          const SizedBox(height: 10),
          if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
          if (!_loading && _d['success'] == false) Text('${_d['message']}', style: TextStyle(color: JphUi.sub(isDark))),
          if (!_loading && _d['success'] != false) ...(switch (_tab) {
            0 => _sales(isDark),
            1 => _channels(isDark),
            2 => _campaigns(isDark),
            3 => _reasons(isDark),
            4 => _funnel(isDark),
            5 => _delays(isDark),
            6 => _hourlyTab(isDark),
            7 => _distTab(isDark),
            _ => _yearlyTab(isDark),
          }),
        ]),
      ),
    );
  }

  /// the tab's table → Excel (and the export log)
  List<Widget> _withExport(String kind, String name, List<String> head, List<List<String>> rows, Widget table) => [
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            onPressed: rows.isEmpty ? null : () => exportTable(context, kind, '$name ${_day(_from)} - ${_day(_to)}', head, rows,
                filters: {'from': _day(_from), 'to': _day(_to)}),
            icon: const Icon(Icons.file_download_rounded),
            label: Text(tr('تصدير')),
          ),
        ),
        table,
      ];

  List<Widget> _t(bool isDark, String kind, String name, List<String> head, List<List<String>> rows, {List<VoidCallback?>? taps}) =>
      _withExport(kind, name, head, rows, _table(isDark, head, rows, taps: taps));

  List<Widget> _hourlyTab(bool isDark) {
    final ppl = ll(_hourly['people']);
    if (ppl.isEmpty) return [Text(tr('مفيش أكشنات في الفترة دي'), style: TextStyle(color: JphUi.sub(isDark)))];
    final hours = [for (var h = 8; h <= 23; h++) h];
    final head = [tr('مندوب المبيعات'), for (final h in hours) '${h > 12 ? h - 12 : h}${h < 12 ? 'ص' : 'م'}', tr('المجموع')];
    final rows = [
      for (final p in ppl) ['${p['name']}', for (final h in hours) '${(p['hours'] as List)[h]}', '${p['total']}'],
    ];
    return _withExport('hourly', tr('الشغل ساعة بساعة'), head, rows, _table(isDark, head, rows));
  }

  List<Widget> _distTab(bool isDark) {
    final ppl = ll(_dist['people']);
    if (ppl.isEmpty) return [Text(tr('مفيش توزيع في الفترة دي'), style: TextStyle(color: JphUi.sub(isDark)))];
    final head = [tr('مندوب المبيعات'), tr('اتوزع عليه'), tr('بالدور'), tr('سحب أوتوماتيك'), tr('اتنقل من زميل'), tr('من مين')];
    final rows = [
      for (final p in ppl)
        ['${p['name']}', '${p['total']}', '${p['turn']}', '${p['auto']}', '${p['moved']}', ll(p['from']).map((f) => '${f['name']}: ${f['n']}').join(tr('، '))],
    ];
    return _withExport('distribution', tr('تقرير التوزيع'), head, rows, _table(isDark, head, rows));
  }

  List<Widget> _yearlyTab(bool isDark) {
    final months = ll(_yearly['months']);
    final people = ll(_meta['assignees']);
    final head = [tr('الشهر'), tr('اتوزع عليه'), tr('أكشنات'), tr('ميتنجات'), tr('وصل الميتنج'), tr('حجوزات'), tr('تعاقدات')];
    final names = [tr('يناير'), tr('فبراير'), tr('مارس'), tr('أبريل'), tr('مايو'), tr('يونيو'), tr('يوليو'), tr('أغسطس'), tr('سبتمبر'), tr('أكتوبر'), tr('نوفمبر'), tr('ديسمبر')];
    final rows = [
      for (final (i, m) in months.indexed)
        [names[i % 12], '${m['leads']}', '${m['calls']}', '${m['meetings']}', '${m['meetings_done']}', '${m['reservations']}', '${m['deals']}'],
    ];
    return [
      if (people.isNotEmpty)
        JphUi.picker(
          isDark: isDark, icon: Icons.person_rounded, iconColor: Ar.accent, label: tr('مندوب المبيعات'),
          value: '${lm(_yearly['employee'])['name'] ?? ''} — ${_yearly['year'] ?? ''}',
          onTap: () async {
            final v = await pickPeople(context, isDark, tr('الأداء السنوي لمين'), people, multi: false);
            if (v == null || v.isEmpty) return;
            _yearPerson = v.first;
            _loadYearly();
          },
        ),
      const SizedBox(height: 8),
      ..._withExport('yearly', 'الأداء السنوي ${lm(_yearly['employee'])['name'] ?? ''}', head, rows, _table(isDark, head, rows)),
    ];
  }

  Widget _table(bool isDark, List<String> head, List<List<String>> rows, {List<VoidCallback?>? taps}) => Container(
        decoration: JphUi.box(isDark),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingTextStyle: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark)),
            dataTextStyle: TextStyle(color: JphUi.text(isDark)),
            columnSpacing: 18,
            showCheckboxColumn: false,
            columns: [for (final h in head) DataColumn(label: Text(h))],
            rows: [
              for (final (i, r) in rows.indexed)
                DataRow(onSelectChanged: taps == null || taps[i] == null ? null : (_) => taps[i]!(), cells: [for (final c in r) DataCell(Text(c))]),
            ],
          ),
        ),
      );

  List<Widget> _sales(bool isDark) {
    final s = ll(_d['sales']);
    String n(Object? v) => '${v ?? 0}';
    return [
      ..._t(isDark, 'sales', tr('تقرير السيلز'), [tr('مندوب المبيعات'), tr('اتوزع عليه'), tr('أكشنات'), tr('ردّ'), tr('مردّش'), tr('اجتماع'), tr('إلغاء'), tr('حجوزات'), tr('تعاقدات'), tr('قيمة التعاقدات'), tr('مفتوح'), tr('متأخر'), tr('أول رد (دقيقة)')], [
        for (final x in s)
          [
            '${x['name']}', n(x['assigned']), n(x['actions']), n(x['answered']), n(x['noAnswer']), n(x['meetings']), n(x['cancelled']),
            n(x['reservations']), n(x['deals']), JphUi.money(x['dealsValue']), n(x['openLeads']), n(x['overdue']), x['firstResponseMin'] == null ? '—' : n(x['firstResponseMin']),
          ],
      ]),
      const SizedBox(height: 8),
      Text(tr('«أول رد»: متوسط الوقت من توزيع الليد لحد أول أكشن عليه.'), style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
    ];
  }

  List<Widget> _channels(bool isDark) {
    final ch = ll(_d['channels']);
    const keys = ['new', 'following', 'interested', 'meeting', 'cancelled', 'reservation', 'done_deal'];
    final total = ch.fold<num>(0, (a, b) => a + ((b['leads'] as num?) ?? 0));
    return [
      ..._t(isDark, 'channels', tr('تقرير القنوات'), [tr('القناة'), tr('ليدز'), '%', for (final k in keys) stageNames[k]!, tr('حجوزات')], [
        for (final x in ch)
          [
            '${x['name']}', '${x['leads']}', total == 0 ? '0%' : '${(((x['leads'] as num?) ?? 0) * 100 / total).toStringAsFixed(1)}%',
            for (final k in keys) '${lm(x['stages'])[k] ?? 0}', '${x['reservations'] ?? 0}',
          ],
      ]),
    ];
  }

  List<Widget> _campaigns(bool isDark) {
    final c = ll(_d['campaigns']);
    String opt(Object? v, {bool money = false, bool pct = false}) => v == null ? '—' : money ? JphUi.money(v) : pct ? '${v}%' : '$v';
    return [
      if (c.isEmpty) Text(tr('مفيش حملات في الفترة دي — ضيفها من الإعدادات'), style: TextStyle(color: JphUi.sub(isDark))),
      if (c.isNotEmpty)
        ..._t(isDark, 'campaigns', tr('تقرير الحملات'), [tr('الحملة'), tr('القناة'), tr('التكلفة'), tr('ليدز'), tr('تكلفة الليد'), tr('حجوزات'), tr('تعاقدات'), tr('تكلفة التعاقد'), tr('المبيعات'), tr('عمولتنا'), tr('العائد')], [
          for (final x in c)
            [
              '${x['name']}', '${x['channelName'] ?? '—'}', JphUi.money(x['cost']), '${x['leads']}', opt(x['cpl'], money: true), '${x['reservations']}',
              '${x['deals']}', opt(x['cpa'], money: true), JphUi.money(x['salesValue']), JphUi.money(x['commission']), opt(x['roi'], pct: true),
            ],
        ]),
      const SizedBox(height: 8),
      Text(tr('العائد = (عمولتنا من التعاقدات − تكلفة الحملة) ÷ التكلفة.'), style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
    ];
  }

  List<Widget> _reasons(bool isDark) {
    final r = ll(_d['cancelReasons']);
    final total = r.fold<num>(0, (a, b) => a + ((b['n'] as num?) ?? 0));
    if (r.isEmpty) return [Text(tr('مفيش إلغاءات في الفترة دي'), style: TextStyle(color: JphUi.sub(isDark)))];
    return [
      for (final x in r)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: JphUi.box(isDark),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text('${x['name']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
              Text('${x['n']}', style: const TextStyle(fontWeight: FontWeight.w900, color: Ar.red)),
            ]),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: total == 0 ? 0 : ((x['n'] as num?) ?? 0) / total, color: Ar.red, backgroundColor: Ar.red.withOpacity(0.12), minHeight: 8,
                borderRadius: BorderRadius.circular(8)),
          ]),
        ),
    ];
  }

  List<Widget> _funnel(bool isDark) {
    final f = lm(_d['funnel']);
    final total = f.values.fold<num>(0, (a, b) => a + ((b as num?) ?? 0));
    return [
      Text('العملاء اللي اتضافوا في الفترة: $total', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
      const SizedBox(height: 8),
      for (final s in stageNames.entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            SizedBox(width: 150, child: Text(s.value, style: TextStyle(color: JphUi.text(isDark)))),
            Expanded(
              child: LinearProgressIndicator(value: total == 0 ? 0 : ((f[s.key] as num?) ?? 0) / total, color: stageColor(s.key),
                  backgroundColor: stageColor(s.key).withOpacity(0.12), minHeight: 14, borderRadius: BorderRadius.circular(8)),
            ),
            SizedBox(width: 50, child: Text('  ${f[s.key] ?? 0}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
          ]),
        ),
    ];
  }

  List<Widget> _delays(bool isDark) {
    final d = ll(_d['delays']);
    if (d.isEmpty) return [Text(tr('مفيش متابعات متأخرة 👌'), style: TextStyle(color: JphUi.sub(isDark)))];
    return [
      ..._t(isDark, 'delays', tr('تقرير التأخير'), [tr('مندوب المبيعات'), tr('العميل'), tr('المرحلة'), tr('كان المفروض'), tr('متأخر')], [
        for (final x in d)
          ['${x['salesName']}', '${x['leadName']}', '${x['stageAr']}', whenAr(x['nextAt']),
            ((x['hours'] as num?) ?? 0) >= 24 ? '${((x['hours'] as num) / 24).floor()} يوم' : '${x['hours']} ساعة'],
      ], taps: [for (final x in d) () => openLead(context, '${x['leadId']}')]),
    ];
  }
}
