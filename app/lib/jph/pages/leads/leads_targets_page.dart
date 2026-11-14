import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import 'leads_api.dart';
import 'leads_extra.dart';

/// التارجت الشهري: every salesman's target (calls / meetings / reservations / contracts / their value) and how far he got.
class LeadsTargetsPage extends StatefulWidget {
  const LeadsTargetsPage({super.key});

  @override
  State<LeadsTargetsPage> createState() => _LeadsTargetsPageState();
}

class _LeadsTargetsPageState extends State<LeadsTargetsPage> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  List<Map<String, dynamic>> _people = [];
  bool _loading = true, _canEdit = false;
  int _seq = 0;

  String get _m => '${_month.year}-${two(_month.month)}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() => _loading = true);
    final r = await lget('/leads/targets', {'month': _m});
    if (!mounted || seq != _seq) return;
    setState(() {
      _loading = false;
      _people = ll(r['people']);
      _canEdit = r['canEdit'] == true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    const months = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
    return LeadsShell(
      isDark: isDark,
      title: 'التارجت الشهري',
      action: IconButton(
        tooltip: 'تصدير إكسيل',
        icon: Icon(Icons.file_download_rounded, color: JphUi.text(isDark)),
        onPressed: () => exportTable(context, 'targets', 'تارجت $_m', [
          'السيلز', 'مكالمات', 'تارجت', 'ميتنجات', 'تارجت', 'حجوزات', 'تارجت', 'تعاقدات', 'تارجت', 'قيمة التعاقدات', 'تارجت',
        ], [
          for (final p in _people)
            [
              p['name'], lm(p['actual'])['calls'], lm(p['target'])['calls'], lm(p['actual'])['meetings'], lm(p['target'])['meetings'],
              lm(p['actual'])['reservations'], lm(p['target'])['reservations'], lm(p['actual'])['deals'], lm(p['target'])['deals'],
              lm(p['actual'])['dealsValue'], lm(p['target'])['dealsValue'],
            ],
        ], filters: {'month': _m}),
      ),
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 4, 14, 60), children: [
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
          if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
          for (final p in _people) targetCard(isDark, p, onEdit: _canEdit ? () => _edit(isDark, p) : null),
        ]),
      ),
    );
  }

  Future<void> _edit(bool isDark, Map<String, dynamic> p) async {
    final t = lm(p['target']);
    final c = {
      for (final k in const ['calls', 'meetings', 'reservations', 'deals', 'dealsValue']) k: TextEditingController(text: t[k] == null ? '' : '${t[k]}'),
    };
    const labels = {'calls': 'مكالمات (أكشنات)', 'meetings': 'ميتنجات', 'reservations': 'حجوزات', 'deals': 'تعاقدات', 'dealsValue': 'قيمة التعاقدات'};
    final ok = await leadForm(context, isDark, 'تارجت ${p['name']} — $_m', (set) => [
          for (final e in c.entries)
            JphUi.input(isDark: isDark, label: labels[e.key]!, controller: e.value, number: true, suffix: e.key == 'dealsValue' ? 'جنيه' : null, big: false),
        ], () async {
      final r = await lpost('/leads/targets', {
        'month': _m,
        'items': [
          {'employeeId': p['id'], for (final e in c.entries) e.key: num.tryParse(e.value.text.replaceAll(',', '').trim()) ?? 0},
        ],
      }, ok: 'اتحفظ التارجت ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }
}

/// one salesman's month: each target with its bar
Widget targetCard(bool isDark, Map<String, dynamic> p, {VoidCallback? onEdit, bool mine = false}) {
  final a = lm(p['actual']), t = lm(p['target']);
  const rows = [('calls', 'مكالمات'), ('meetings', 'ميتنجات'), ('reservations', 'حجوزات'), ('deals', 'تعاقدات'), ('dealsValue', 'قيمة التعاقدات')];
  return Container(
    margin: const EdgeInsets.only(bottom: 10),
    padding: const EdgeInsets.all(14),
    decoration: JphUi.box(isDark),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: Text(mine ? 'التارجت بتاعك الشهر ده' : '${p['name']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
        if (onEdit != null) IconButton(onPressed: onEdit, icon: Icon(Icons.edit_rounded, color: JphUi.sub(isDark))),
      ]),
      if (p['target'] == null) Text('مفيش تارجت للشهر ده', style: TextStyle(color: JphUi.sub(isDark))),
      for (final r in rows)
        if (p['target'] != null && ((t[r.$1] as num?) ?? 0) > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: [
              SizedBox(width: 110, child: Text(r.$2, style: TextStyle(color: JphUi.text(isDark)))),
              Expanded(
                child: LinearProgressIndicator(
                  value: (((a[r.$1] as num?) ?? 0) / ((t[r.$1] as num?) ?? 1)).clamp(0, 1).toDouble(),
                  minHeight: 10,
                  borderRadius: BorderRadius.circular(8),
                  color: ((a[r.$1] as num?) ?? 0) >= ((t[r.$1] as num?) ?? 1) ? Ar.green : Ar.accent,
                  backgroundColor: Ar.accent.withOpacity(0.12),
                ),
              ),
              SizedBox(
                width: 120,
                child: Text(
                  r.$1 == 'dealsValue' ? '  ${JphUi.money(a[r.$1])}' : '  ${a[r.$1] ?? 0} / ${t[r.$1]}',
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: 12.5, color: JphUi.text(isDark)),
                ),
              ),
            ]),
          ),
    ]),
  );
}
