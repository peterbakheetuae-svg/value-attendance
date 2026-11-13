import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../services/app_controller.dart';
import '../theme/app_colors.dart';
import 'glass_ui_widgets.dart';
import 'glass_ui.dart';

/// One box with every KPI of the employee this month: target, actual, achievement and weight.
class EmployeeKpiBox extends StatefulWidget {
  final String employeeId; // empty = me
  const EmployeeKpiBox({super.key, this.employeeId = ''});

  @override
  State<EmployeeKpiBox> createState() => _EmployeeKpiBoxState();
}

class _EmployeeKpiBoxState extends State<EmployeeKpiBox> {
  Map<String, dynamic>? _cur;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant EmployeeKpiBox old) {
    super.didUpdateWidget(old);
    if (old.employeeId != widget.employeeId) _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'kpi_employee', if (widget.employeeId.isNotEmpty) 'id': widget.employeeId});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _cur = r['success'] == true ? (r['current'] as Map?)?.cast<String, dynamic>() : null;
    });
  }

  String _n(Object? v) {
    final n = v is num ? v : num.tryParse('${v ?? ''}');
    if (n == null) return '--';
    return n == n.roundToDouble() ? '${n.round()}' : n.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    final text = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final sub = isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight;
    final items = ((_cur?['items'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final score = _cur?['weightedScore'];

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('مؤشرات الأداء (KPIs) — الشهر ده', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: text))),
        if (score != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: AppColors.primary.withOpacity(0.15), borderRadius: BorderRadius.circular(999)),
            child: Text('${_n(score)}%', style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.primary)),
          ),
      ]),
      const SizedBox(height: 12),
      GlassCard(
        radius: 24,
        padding: const EdgeInsets.all(16),
        child: _loading
            ? const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)))
            : items.isEmpty
                ? Text('لسه مفيش مؤشرات أداء متحددة للوظيفة دي', style: TextStyle(color: sub))
                : Column(children: [
                    for (final (i, k) in items.indexed) ...[
                      if (i > 0) Divider(color: sub.withOpacity(0.2), height: 18),
                      Row(children: [
                        Expanded(child: Text('${k['nameAr'] ?? ''}', style: TextStyle(fontWeight: FontWeight.w700, color: text))),
                        Text('${_n(k['weight'])}%', style: TextStyle(fontSize: 12, color: sub)),
                      ]),
                      const SizedBox(height: 6),
                      Row(children: [
                        Expanded(child: Text('المستهدف: ${_n(k['target'])}   •   المحقق: ${_n(k['actual'])}', style: TextStyle(fontSize: 13, color: sub))),
                        Text(k['achievementPercent'] == null ? 'لم يُقيَّم' : '${_n(k['achievementPercent'])}%',
                            style: TextStyle(fontWeight: FontWeight.w700,
                                color: k['achievementPercent'] == null ? sub : ((k['achievementPercent'] as num) >= 100 ? Ar.green : Ar.amber))),
                      ]),
                      if (k['achievementPercent'] is num) ...[
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: GrowTo(value: ((k['achievementPercent'] as num) / 100).clamp(0.0, 1.0).toDouble(), builder: (v) => LinearProgressIndicator(
                            value: v,
                            minHeight: 6,
                            backgroundColor: sub.withOpacity(0.15),
                            color: (k['achievementPercent'] as num) >= 100 ? Ar.green : AppColors.primary,
                          )),
                        ),
                      ],
                    ],
                  ]),
      ),
    ]);
  }
}
