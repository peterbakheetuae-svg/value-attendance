import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../services/api_service.dart';
import '../../services/jph_bridge.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/swipe_tabs.dart';

/// KPI & performance evaluation — same glass layout and 3 tabs as the original screen:
/// 1) KPIs per job position, 2) employee performance (targets, actuals, achievement, trend),
/// 3) evaluations (manager / HR, comments, history).
/// Missing results are never shown as zero: they show as "لم يُقيَّم".
class KpiPage extends StatefulWidget {
  const KpiPage({super.key});

  @override
  State<KpiPage> createState() => _KpiPageState();
}

const _measure = {'count': 'عدد', 'percent': 'نسبة %', 'amount_egp': 'مبلغ (ج.م)', 'score': 'درجة'};
const _dims = {
  'discipline': 'الانضباط',
  'attendance': 'الحضور',
  'communication': 'التواصل',
  'followUp': 'المتابعة',
  'teamwork': 'العمل الجماعي',
  'salesPerformance': 'أداء المبيعات',
  'initiative': 'المبادرة',
  'professionalBehavior': 'السلوك المهني',
};
const _dimCols = {
  'discipline': 'discipline', 'attendance': 'attendance', 'communication': 'communication', 'followUp': 'follow_up',
  'teamwork': 'teamwork', 'salesPerformance': 'sales_performance', 'initiative': 'initiative', 'professionalBehavior': 'professional_behavior',
};

String _two(int v) => v.toString().padLeft(2, '0');
String _monthKey(DateTime d) => '${d.year}-${_two(d.month)}';
const _monthsAr = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
String _monthLabel(String period) {
  final d = DateTime.tryParse(period.length == 7 ? '$period-01' : period);
  return d == null ? period : '${_monthsAr[d.month - 1]} ${d.year}';
}
String _num(Object? v) {
  final n = num.tryParse('${v ?? ''}');
  if (n == null) return '—';
  return n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);
}

void _snack(BuildContext context, Map<String, dynamic> r) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('${r['message'] ?? ''}'),
    backgroundColor: r['success'] == true ? Colors.green : Colors.red,
  ));
}

Widget _sheet(BuildContext ctx, String title, List<Widget> children) {
  final isDark = Provider.of<AppController>(ctx, listen: false).isDark;
  return Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
    child: Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.9),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey.shade900.withOpacity(0.98) : Colors.white.withOpacity(0.98),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          ...children,
        ]),
      ),
    ),
  );
}

Widget _primaryButton(String label, VoidCallback onTap, {Color color = AppColors.primary}) => SizedBox(
      height: 52,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(backgroundColor: color, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        onPressed: onTap,
        child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
      ),
    );

/// Same picker + bottom-sheet list as every other list in the app.
Widget _pick(BuildContext ctx, String label, IconData icon, String? value, Map<String, String> options, ValueChanged<String> onChanged) {
  final isDark = Provider.of<AppController>(ctx, listen: false).isDark;
  return JphUi.picker(
    isDark: isDark,
    icon: icon,
    iconColor: Colors.indigo,
    label: label,
    value: options[value] ?? 'اختار',
    onTap: () async {
      final v = await JphUi.sheet<String>(ctx, isDark, label, [for (final e in options.entries) (e.key, e.value, icon)],
          selected: value, icon: icon);
      if (v != null) onChanged(v);
    },
  );
}

InputDecoration _input(String label) => InputDecoration(labelText: label, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)));

class _KpiPageState extends State<KpiPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _perfKey = GlobalKey<_PerformanceTabState>();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    // same header and bar as the attendance pages; swipe right / left between the tabs
    return AppBackground(
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: isDark, isRTL: true, title: 'مؤشرات الأداء والتقييم'),
              Expanded(
                child: SwipeTabs(
                  isDark: isDark,
                  tabs: const [
                    ('مؤشرات الوظائف', Icons.work_outline_rounded),
                    ('أداء الموظفين', Icons.insights_rounded),
                    ('التقييمات', Icons.star_rate_rounded),
                  ],
                  pages: [const _PositionsTab(), _PerformanceTab(key: _perfKey), const _EvaluationsTab()],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ============================================================ 1) KPIs per job position
class _PositionsTab extends StatefulWidget {
  const _PositionsTab();
  @override
  State<_PositionsTab> createState() => _PositionsTabState();
}

class _PositionsTabState extends State<_PositionsTab> {
  List<Map<String, dynamic>> _positions = [], _defs = [], _sets = [];
  bool _canConfig = false, _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  List<Map<String, dynamic>> _l(Object? v) => ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await ApiService.post({'action': 'kpi_setup'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = r['success'] == true ? '' : '${r['message'] ?? ''}';
      _positions = _l(r['positions']).where((p) => p['key'] != 'owner').toList();
      _defs = _l(r['definitions']);
      _sets = _l(r['sets']);
      _canConfig = r['canConfig'] == true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error.isNotEmpty) return Center(child: Text(_error));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_canConfig)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(onPressed: _newDefinition, icon: const Icon(Icons.add_chart_rounded), label: const Text('مؤشر جديد')),
            ),
          ..._positions.map((p) {
            final set = _sets.where((s) => s['position_key'] == p['key']).firstOrNull;
            final items = _l(set?['items']);
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GlassCard(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    const Icon(Icons.work_outline_rounded, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Expanded(child: Text('${p['name_ar']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                    if (_canConfig) IconButton(icon: const Icon(Icons.tune_rounded), tooltip: 'تحديد المؤشرات', onPressed: () => _editSet(p, items)),
                  ]),
                  if (set == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('لسه مفيش مؤشرات للوظيفة دي', style: TextStyle(color: AppColors.onSurfaceVariantLight)),
                    )
                  else ...[
                    Text('${set['name']} • نسخة ${set['version']}', style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariantLight)),
                    const SizedBox(height: 8),
                    ...items.map((i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(children: [
                            Expanded(child: Text('${i['nameAr']}')),
                            Text('الهدف ${_num(i['target'])} ${_measure[i['measurementType']] ?? ''}', style: const TextStyle(fontSize: 12)),
                            const SizedBox(width: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(color: AppColors.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(8)),
                              child: Text('${_num(i['weight'])}%', style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.primary)),
                            ),
                          ]),
                        )),
                  ],
                ]),
              ),
            );
          }),
        ],
      ),
    );
  }

  Future<void> _newDefinition() async {
    final name = TextEditingController();
    String type = 'count';
    bool higher = true;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) => _sheet(ctx, 'مؤشر أداء جديد', [
            TextField(controller: name, decoration: _input('اسم المؤشر *')),
            const SizedBox(height: 10),
            _pick(ctx, 'طريقة القياس', Icons.straighten_rounded, type, _measure, (v) => set(() => type = v)),
            SwitchListTile(contentPadding: EdgeInsets.zero, value: higher, title: const Text('كل ما الرقم يزيد يبقى أحسن'), onChanged: (v) => set(() => higher = v)),
            const SizedBox(height: 12),
            _primaryButton('حفظ', () async {
              if (name.text.trim().length < 2) return;
              final r = await ApiService.post({'action': 'kpi_add_definition', 'nameAr': name.text.trim(), 'measurementType': type, 'higherIsBetter': higher});
              if (ctx.mounted) {
                _snack(ctx, r);
                if (r['success'] == true) Navigator.pop(ctx);
              }
            }),
          ])),
    );
    _load();
  }

  Future<void> _editSet(Map<String, dynamic> pos, List<Map<String, dynamic>> current) async {
    final chosen = <String, (TextEditingController, TextEditingController)>{
      for (final i in current) '${i['kpiId']}': (TextEditingController(text: _num(i['weight'])), TextEditingController(text: _num(i['target']))),
    };
    String? error;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final total = chosen.values.fold<double>(0, (s, c) => s + (double.tryParse(c.$1.text) ?? 0));
        return _sheet(ctx, 'مؤشرات وظيفة ${pos['name_ar']}', [
          Text('اختار المؤشرات وحدد الوزن (المجموع 100%) والهدف الشهري', style: TextStyle(color: AppColors.onSurfaceVariantLight)),
          const SizedBox(height: 8),
          ..._defs.map((d) {
            final id = '${d['id']}';
            final on = chosen.containsKey(id);
            return Column(children: [
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: on,
                title: Text('${d['name_ar']}'),
                subtitle: Text(_measure[d['measurement_type']] ?? ''),
                onChanged: (v) => set(() => v == true
                    ? chosen[id] = (TextEditingController(), TextEditingController())
                    : chosen.remove(id)),
              ),
              if (on)
                Row(children: [
                  Expanded(child: TextField(controller: chosen[id]!.$1, keyboardType: TextInputType.number, decoration: _input('الوزن %'), onChanged: (_) => set(() {}))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: chosen[id]!.$2, keyboardType: TextInputType.number, decoration: _input('الهدف'))),
                ]),
              const SizedBox(height: 6),
            ]);
          }),
          Text('مجموع الأوزان: ${_num(total)}%', textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700, color: (total - 100).abs() < 0.01 ? Colors.green : Colors.orange)),
          if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Colors.red))),
          const SizedBox(height: 12),
          _primaryButton('حفظ المؤشرات', () async {
            final items = <Map<String, dynamic>>[];
            for (final e in chosen.entries) {
              final w = double.tryParse(e.value.$1.text), t = double.tryParse(e.value.$2.text);
              if (w == null || w <= 0 || t == null || t <= 0) {
                set(() => error = 'اكتب وزن وهدف أكبر من صفر لكل مؤشر');
                return;
              }
              items.add({'kpiId': e.key, 'weight': w, 'target': t});
            }
            if (items.isEmpty || (total - 100).abs() > 0.01) {
              set(() => error = 'لازم مؤشر واحد على الأقل ومجموع الأوزان 100%');
              return;
            }
            final r = await ApiService.post({'action': 'kpi_save_set', 'positionKey': pos['key'], 'name': 'مؤشرات ${pos['name_ar']}', 'items': items});
            if (ctx.mounted) {
              _snack(ctx, r);
              if (r['success'] == true) Navigator.pop(ctx);
            }
          }),
        ]);
      }),
    );
    _load();
  }
}

// ============================================================ 2) employee performance
class _PerformanceTab extends StatefulWidget {
  const _PerformanceTab({super.key});
  @override
  State<_PerformanceTab> createState() => _PerformanceTabState();
}

class _PerformanceTabState extends State<_PerformanceTab> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool get _canSeeOthers => JphBridge.session.has('kpi.read_all') || JphBridge.session.has('kpi.read_team');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_canSeeOthers) {
      setState(() => _loading = false);
      return;
    }
    setState(() => _loading = true);
    final r = await ApiService.post({'action': 'kpi_overview', 'month': _monthKey(_month)});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _rows = ((r['employees'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    });
  }

  Widget _monthBar() => GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(children: [
          IconButton(icon: const Icon(Icons.chevron_right), onPressed: () { setState(() => _month = DateTime(_month.year, _month.month - 1)); _load(); }),
          Expanded(child: Text(_monthLabel(_monthKey(_month)), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700))),
          IconButton(icon: const Icon(Icons.chevron_left), onPressed: () { setState(() => _month = DateTime(_month.year, _month.month + 1)); _load(); }),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (!_canSeeOthers) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        _monthBar(),
        const SizedBox(height: 12),
        _EmployeeKpiView(key: ValueKey(_monthKey(_month)), employeeId: JphBridge.myId, month: _monthKey(_month)),
      ]);
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _monthBar(),
          const SizedBox(height: 12),
          if (_loading) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          if (!_loading && _rows.isEmpty) Center(child: Text('مفيش موظفين للعرض', style: TextStyle(color: AppColors.onSurfaceVariantLight))),
          ..._rows.map((x) {
            final e = (x['employee'] as Map).cast<String, dynamic>();
            final score = x['weightedScore'];
            final color = score == null ? Colors.grey : (score as num) >= 100 ? Colors.green : score >= 70 ? Colors.orange : AppColors.error;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GestureDetector(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _EmployeeKpiPage(employee: e, month: _monthKey(_month)))).then((_) => _load()),
                child: GlassCard(
                  child: Row(children: [
                    CircleAvatar(backgroundColor: color.withOpacity(0.15), child: Icon(Icons.person, color: color)),
                    const SizedBox(width: 12),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${e['full_name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text('${e['position_name'] ?? e['job_title'] ?? ''}${e['team_name'] != null ? ' • ${e['team_name']}' : ''}',
                          style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariantLight)),
                    ])),
                    Text(x['kpiCount'] == 0 ? 'بدون مؤشرات' : score == null ? 'لم يُقيَّم' : '${_num(score)}%',
                        style: TextStyle(fontWeight: FontWeight.w800, color: color)),
                  ]),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

class _EmployeeKpiPage extends StatelessWidget {
  final Map<String, dynamic> employee;
  final String month;
  const _EmployeeKpiPage({required this.employee, required this.month});

  @override
  Widget build(BuildContext context) => AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: Text('${employee['full_name']}')),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            _EmployeeKpiView(employeeId: '${employee['id']}', month: month),
          ]),
        ),
      );
}

/// One employee, one month: KPI items, overall score, change vs. last month, 6-month trend chart.
class _EmployeeKpiView extends StatefulWidget {
  final String employeeId;
  final String month;
  const _EmployeeKpiView({super.key, required this.employeeId, required this.month});
  @override
  State<_EmployeeKpiView> createState() => _EmployeeKpiViewState();
}

class _EmployeeKpiViewState extends State<_EmployeeKpiView> {
  Map<String, dynamic>? _d;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'kpi_employee', 'id': widget.employeeId, 'month': widget.month});
    if (!mounted) return;
    setState(() {
      _d = r['success'] == true ? r : null;
      _error = r['success'] == true ? '' : '${r['message'] ?? ''}';
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error.isNotEmpty) return Center(child: Text(_error));
    if (_d == null) return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
    final cur = (_d!['current'] as Map).cast<String, dynamic>();
    final items = ((cur['items'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final trend = ((_d!['trend'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final canEnter = _d!['canEnter'] == true;
    final score = cur['weightedScore'];
    final change = _d!['change'];
    if (items.isEmpty) {
      return GlassCard(child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text('مفيش مؤشرات أداء محددة لوظيفة الموظف ده', textAlign: TextAlign.center, style: TextStyle(color: AppColors.onSurfaceVariantLight)),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      GlassCard(
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('الأداء العام', style: TextStyle(fontWeight: FontWeight.w600)),
            Text(score == null ? 'لم يُقيَّم بعد' : '${_num(score)}%',
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: AppColors.primary)),
          ])),
          if (change != null)
            Column(children: [
              Icon((change as num) >= 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded, color: change >= 0 ? Colors.green : AppColors.error),
              Text('${change >= 0 ? '+' : ''}${_num(change)}% عن الشهر اللي فات', style: const TextStyle(fontSize: 11)),
            ]),
        ]),
      ),
      const SizedBox(height: 12),
      GlassCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('آخر 6 شهور', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          SizedBox(
            height: 130,
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: trend.map((t) {
              final v = (t['weightedScore'] as num?)?.toDouble();
              final h = v == null ? 4.0 : (v.clamp(0, 120) / 120 * 96).toDouble().clamp(4.0, 96.0);
              return Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                Text(v == null ? '—' : _num(v), style: const TextStyle(fontSize: 10)),
                const SizedBox(height: 2),
                Container(
                  height: h, margin: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: v == null ? Colors.grey.withOpacity(0.3) : AppColors.primary.withOpacity(0.8),
                    borderRadius: BorderRadius.circular(6)),
                ),
                const SizedBox(height: 4),
                Text(_monthLabel('${t['period']}').split(' ').first, style: const TextStyle(fontSize: 9), overflow: TextOverflow.ellipsis),
              ]));
            }).toList()),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      ...items.map((i) {
        final ach = i['achievementPercent'];
        final state = '${i['state']}';
        final stateAr = {'not_evaluated': 'لم يُقيَّم', 'in_progress': 'جاري', 'completed': 'مكتمل', 'below_target': 'أقل من الهدف'}[state] ?? state;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GestureDetector(
            onTap: canEnter ? () => _enter(i) : null,
            child: GlassCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${i['nameAr']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                  Text('وزن ${_num(i['weight'])}%', style: const TextStyle(fontSize: 12)),
                  if (canEnter) const Padding(padding: EdgeInsetsDirectional.only(start: 6), child: Icon(Icons.edit_outlined, size: 16)),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: Text('الهدف: ${_num(i['target'])}')),
                  Expanded(child: Text('المحقق: ${i['actual'] == null ? '—' : _num(i['actual'])}')),
                  Text(ach == null ? stateAr : '${_num(ach)}%',
                      style: TextStyle(fontWeight: FontWeight.w800, color: ach == null ? Colors.grey : (ach as num) >= 100 ? Colors.green : Colors.orange)),
                ]),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    minHeight: 8,
                    value: ach == null ? 0 : ((ach as num) / 100).clamp(0, 1).toDouble(),
                    backgroundColor: Colors.grey.withOpacity(0.2),
                    color: ach != null && ach >= 100 ? Colors.green : AppColors.primary,
                  ),
                ),
              ]),
            ),
          ),
        );
      }),
    ]);
  }

  Future<void> _enter(Map<String, dynamic> i) async {
    final actual = TextEditingController(text: i['actual'] == null ? '' : _num(i['actual']));
    String state = i['state'] == 'below_target' ? 'completed' : '${i['state']}';
    if (state == 'not_evaluated') state = 'in_progress';
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) => _sheet(ctx, '${i['nameAr']}', [
            Text('الهدف: ${_num(i['target'])}', textAlign: TextAlign.center),
            const SizedBox(height: 10),
            TextField(controller: actual, keyboardType: TextInputType.number, decoration: _input('المحقق فعلياً')),
            const SizedBox(height: 10),
            _pick(ctx, 'الحالة', Icons.flag_rounded, state, const {
              'in_progress': 'جاري (الشهر لسه)',
              'completed': 'مكتمل',
              'not_evaluated': 'مسح النتيجة (لم يُقيَّم)',
            }, (v) => set(() => state = v)),
            const SizedBox(height: 14),
            _primaryButton('حفظ', () async {
              final v = double.tryParse(actual.text.trim());
              if (state != 'not_evaluated' && (v == null || v < 0)) return;
              final r = await ApiService.post({'action': 'kpi_enter', 'id': i['id'], 'state': state, 'actual': v});
              if (ctx.mounted) {
                _snack(ctx, r);
                if (r['success'] == true) Navigator.pop(ctx);
              }
            }),
          ])),
    );
    _load();
  }
}

// ============================================================ 3) evaluations
class _EvaluationsTab extends StatefulWidget {
  const _EvaluationsTab();
  @override
  State<_EvaluationsTab> createState() => _EvaluationsTabState();
}

class _EvaluationsTabState extends State<_EvaluationsTab> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  bool get _canWrite => JphBridge.session.has('evaluation.write_all') || JphBridge.session.has('evaluation.write_team');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await ApiService.post({'action': 'eval_list'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _rows = ((r['evaluations'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            if (_loading) const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
            if (!_loading && _rows.isEmpty) Center(child: Text('مفيش تقييمات لسه', style: TextStyle(color: AppColors.onSurfaceVariantLight))),
            ..._rows.map((e) {
              final pub = e['status'] == 'published';
              final kind = {'manager': 'المدير المباشر', 'hr': 'الموارد البشرية', 'owner': 'المالك'}[e['evaluator_kind']] ?? '';
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GestureDetector(
                  onTap: () => _show(e),
                  child: GlassCard(
                    child: Row(children: [
                      Icon(pub ? Icons.verified_rounded : Icons.edit_note_rounded, color: pub ? Colors.green : Colors.orange),
                      const SizedBox(width: 12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${e['employee_name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text('${_monthLabel('${e['period']}'.substring(0, 7))} • $kind: ${e['evaluator_name']}${pub ? '' : ' • مسودة'}',
                            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariantLight)),
                      ])),
                      Text(e['overallPercent'] == null ? '—' : '${_num(e['overallPercent'])}%',
                          style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.primary)),
                    ]),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
      if (_canWrite)
        PositionedDirectional(
          end: 16, bottom: 16,
          child: FloatingActionButton.extended(
            heroTag: 'eval_add',
            backgroundColor: AppColors.primary,
            onPressed: _newEvaluation,
            icon: const Icon(Icons.rate_review_outlined, color: Colors.white),
            label: const Text('تقييم جديد', style: TextStyle(color: Colors.white)),
          ),
        ),
    ]);
  }

  Future<void> _show(Map<String, dynamic> e) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _sheet(ctx, '${e['employee_name']} — ${_monthLabel('${e['period']}'.substring(0, 7))}', [
        ..._dims.entries.map((d) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(child: Text(d.value)),
                ...List.generate(5, (i) => Icon(i < ((e[_dimCols[d.key]] as num?) ?? 0) ? Icons.star_rounded : Icons.star_outline_rounded, color: Colors.amber, size: 20)),
              ]),
            )),
        if ('${e['feedback'] ?? ''}'.isNotEmpty) ...[const SizedBox(height: 10), const Text('التعليق', style: TextStyle(fontWeight: FontWeight.w700)), Text('${e['feedback']}')],
        if ('${e['improvement_plan'] ?? ''}'.isNotEmpty) ...[const SizedBox(height: 10), const Text('خطة التحسين', style: TextStyle(fontWeight: FontWeight.w700)), Text('${e['improvement_plan']}')],
        if (e['status'] != 'published' && e['evaluator_id'] == JphBridge.myId) ...[
          const SizedBox(height: 16),
          _primaryButton('نشر التقييم للموظف', () async {
            final r = await ApiService.post({'action': 'eval_publish', 'id': e['id']});
            if (ctx.mounted) {
              _snack(ctx, r);
              if (r['success'] == true) Navigator.pop(ctx);
            }
          }, color: Colors.green),
        ],
      ]),
    );
    _load();
  }

  Future<void> _newEvaluation() async {
    final now = DateTime.now();
    final ov = await ApiService.post({'action': 'kpi_overview', 'month': _monthKey(now)});
    if (!mounted) return;
    final emps = ((ov['employees'] as List?) ?? const []).whereType<Map>().map((m) => (m['employee'] as Map).cast<String, dynamic>()).toList();
    if (emps.isEmpty) {
      _snack(context, {'success': false, 'message': 'مفيش موظفين تقدر تقيّمهم'});
      return;
    }
    String empId = '${emps.first['id']}';
    String month = _monthKey(now);
    final scores = <String, int>{for (final k in _dims.keys) k: 3};
    final feedback = TextEditingController();
    final plan = TextEditingController();
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        Future<void> save(bool publish) async {
          final r = await ApiService.post({'action': 'eval_save', 'employeeId': empId, 'month': month, 'scores': scores,
            'feedback': feedback.text.trim(), 'improvementPlan': plan.text.trim(), 'publish': publish});
          if (ctx.mounted) {
            _snack(ctx, r);
            if (r['success'] == true) Navigator.pop(ctx);
          }
        }
        return _sheet(ctx, 'تقييم أداء', [
          _pick(ctx, 'الموظف', Icons.badge_rounded, empId, {for (final e in emps) '${e['id']}': '${e['full_name']}'},
              (v) => set(() => empId = v)),
          const SizedBox(height: 10),
          _pick(ctx, 'الشهر', Icons.calendar_month_rounded, month, {
            for (final m in List.generate(3, (i) => _monthKey(DateTime(now.year, now.month - i)))) m: _monthLabel(m),
          }, (v) => set(() => month = v)),
          const SizedBox(height: 8),
          ..._dims.entries.map((d) => Row(children: [
                Expanded(child: Text(d.value)),
                ...List.generate(5, (i) => GestureDetector(
                      onTap: () => set(() => scores[d.key] = i + 1),
                      child: Icon(i < scores[d.key]! ? Icons.star_rounded : Icons.star_outline_rounded, color: Colors.amber, size: 28),
                    )),
              ])),
          const SizedBox(height: 10),
          TextField(controller: feedback, maxLines: 3, decoration: _input('تعليق التقييم')),
          const SizedBox(height: 10),
          TextField(controller: plan, maxLines: 2, decoration: _input('خطة التحسين')),
          const SizedBox(height: 16),
          _primaryButton('حفظ ونشر للموظف', () => save(true)),
          const SizedBox(height: 8),
          SizedBox(height: 48, child: OutlinedButton(
            style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
            onPressed: () => save(false), child: const Text('حفظ كمسودة'))),
        ]);
      }),
    );
    _load();
  }
}
