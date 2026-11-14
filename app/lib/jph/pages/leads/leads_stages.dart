import 'package:flutter/material.dart';

import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import 'leads_api.dart';

/// الإعدادات / المراحل (like Elite): every stage with its type, «وقت التنبيه» (the salesman is reminded this long
/// before the follow-up time) and «مدة التأخير» (the lead counts as late only this long after it). New stages can be
/// added; the system's own stages can be renamed and tuned but never removed.
class LeadsStagesView extends StatefulWidget {
  final bool isDark;
  const LeadsStagesView({super.key, required this.isDark});

  @override
  State<LeadsStagesView> createState() => _LeadsStagesViewState();
}

String _kindAr(Object? k) => switch ('$k') {
      'new' => tr('بداية'),
      'lost' => tr('إلغاء'),
      'reserve' => tr('حجز'),
      'won' => tr('صفقة'),
      _ => tr('متابعة'),
    };

String _mins(Object? v) {
  final m = (v as num?)?.toInt() ?? 0;
  if (m == 0) return '—';
  if (m % 1440 == 0) return '${m ~/ 1440} ${tr('يوم')}';
  if (m % 60 == 0) return '${m ~/ 60} ${tr('ساعة')}';
  return '$m ${tr('دقيقة')}';
}

const _palette = ['#7FB4E8', '#F7A928', '#C99A76', '#FF6A3D', '#B28DFF', '#E38BC8', '#4FCF73', '#3FC1C9', '#FF7D6E', '#8F8B84'];

class _LeadsStagesViewState extends State<LeadsStagesView> {
  List<Map<String, dynamic>> _s = [];
  bool _loading = true;
  String? _err;

  bool get isDark => widget.isDark;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await lget('/leads/stages');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _err = r['success'] == false ? '${r['message']}' : null;
      _s = ll(r['stages']);
    });
    LeadsMeta.clear();
    LeadsMeta.load(fresh: true);
  }

  Future<void> _edit([Map<String, dynamic>? s]) async {
    final name = TextEditingController(text: '${s?['name'] ?? ''}');
    final alert = TextEditingController(text: '${s?['alertMinutes'] ?? 0}');
    final delay = TextEditingController(text: '${s?['delayMinutes'] ?? 0}');
    final sort = TextEditingController(text: '${s?['sort'] ?? ''}');
    var color = '${s?['color'] ?? _palette.first}';
    var needsDate = s?['needsDate'] != false;
    var active = s?['active'] != false;
    final builtin = s?['builtin'] == true;
    final kindAction = s == null || s['kind'] == 'action';
    final ok = await leadForm(context, isDark, s == null ? tr('مرحلة جديدة') : '${tr('المرحلة')}: ${s['name']}', (set) => [
          JphUi.input(isDark: isDark, label: tr('اسم المرحلة'), controller: name, icon: Icons.label_rounded, big: false),
          JphUi.input(isDark: isDark, label: tr('وقت التنبيه — قبل المعاد بكام دقيقة'), controller: alert, number: true, icon: Icons.notifications_active_rounded, big: false),
          JphUi.input(isDark: isDark, label: tr('مدة التأخير — يبقى متأخر بعد المعاد بكام دقيقة'), controller: delay, number: true, icon: Icons.alarm_rounded, big: false),
          JphUi.input(isDark: isDark, label: tr('الترتيب (الأصغر الأول)'), controller: sort, number: true, icon: Icons.sort_rounded, big: false),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final c in _palette)
              InkWell(
                onTap: () => set(() => color = c),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: Color(0xFF000000 | int.parse(c.substring(1), radix: 16)),
                    shape: BoxShape.circle,
                    border: Border.all(color: color == c ? JphUi.text(isDark) : Colors.transparent, width: 3),
                  ),
                ),
              ),
          ]),
          if (kindAction)
            SwitchListTile(
              value: needsDate,
              onChanged: (v) => set(() => needsDate = v),
              title: Text(tr('بتطلب معاد متابعة جاية'), style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          if (!builtin && s != null)
            SwitchListTile(
              value: active,
              onChanged: (v) => set(() => active = v),
              title: Text(active ? tr('شغالة') : tr('موقوفة'), style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
        ], () async {
      final body = {
        'name': name.text.trim(),
        'alertMinutes': int.tryParse(alert.text.trim()) ?? 0,
        'delayMinutes': int.tryParse(delay.text.trim()) ?? 0,
        if (int.tryParse(sort.text.trim()) != null) 'sort': int.parse(sort.text.trim()),
        'color': color,
        if (kindAction) 'needsDate': needsDate,
        if (!builtin && s != null) 'active': active,
      };
      final r = s == null
          ? await lpost('/leads/stages', body, ok: tr('اتضافت المرحلة ✅'))
          : await lpost('/leads/stages/${s['key']}', body, method: 'patch', ok: tr('اتحفظ ✅'));
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()));
    if (_err != null) return Text(_err!, style: TextStyle(color: JphUi.sub(isDark)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('المراحل'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            Text(tr('إدارة مراحل العملاء ومواعيد المتابعة.'), style: TextStyle(color: JphUi.sub(isDark))),
          ]),
        ),
        dirBtn(isDark, tr('مرحلة جديدة'), Icons.add_rounded, () => _edit(), primary: true),
      ]),
      const SizedBox(height: 10),
      Container(
        decoration: JphUi.box(isDark),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 22,
            columns: [
              DataColumn(label: Text(tr('المرحلة'), style: const TextStyle(fontWeight: FontWeight.w900))),
              DataColumn(label: Text(tr('النوع'), style: const TextStyle(fontWeight: FontWeight.w900))),
              DataColumn(label: Text(tr('وقت التنبيه'), style: const TextStyle(fontWeight: FontWeight.w900))),
              DataColumn(label: Text(tr('مدة التأخير'), style: const TextStyle(fontWeight: FontWeight.w900))),
              DataColumn(label: Text(tr('الحالة'), style: const TextStyle(fontWeight: FontWeight.w900))),
              const DataColumn(label: SizedBox()),
            ],
            rows: [
              for (final s in _s)
                DataRow(cells: [
                  DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 10, height: 10, decoration: BoxDecoration(color: stageColor('${s['key']}'), shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    Text('${s['name']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                    if (s['builtin'] == true) ...[const SizedBox(width: 6), Icon(Icons.lock_outline_rounded, size: 14, color: JphUi.sub(isDark))],
                  ])),
                  DataCell(Text(_kindAr(s['kind']))),
                  DataCell(Text(_mins(s['alertMinutes']))),
                  DataCell(Text(_mins(s['delayMinutes']))),
                  DataCell(pill(s['active'] == true ? tr('شغالة') : tr('موقوفة'), s['active'] == true ? Ar.green : Ar.grey)),
                  DataCell(IconButton(tooltip: tr('تعديل'), icon: const Icon(Icons.edit_rounded, size: 18), onPressed: () => _edit(s))),
                ]),
            ],
          ),
        ),
      ),
    ]);
  }
}
