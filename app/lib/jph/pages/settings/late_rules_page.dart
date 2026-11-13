import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/glass_ui.dart';

/// Late arrival / early leave deduction (same glass design as the rest of the app).
/// Approved policy: fixed-amount tiers by minutes — up to the first tier nothing is deducted; past a tier the
/// amount of the highest tier passed is deducted once per day. Early leave uses the same tiers.
/// Default: more than 15 min → 25, more than 30 → 50, more than 60 → 100 (EGP).
class LateRulesPage extends StatefulWidget {
  const LateRulesPage({super.key});

  @override
  State<LateRulesPage> createState() => _LateRulesPageState();
}

class _Tier {
  final TextEditingController minutes;
  final TextEditingController amount;
  _Tier(String m, String a)
      : minutes = TextEditingController(text: m),
        amount = TextEditingController(text: a);
}

class _LateRulesPageState extends State<LateRulesPage> {
  final List<_Tier> _tiers = [];
  bool _enabled = false;
  /// خصم الانصراف بدري (off → counted and shown, not deducted)
  bool _early = true;
  /// قاعدة الإجازة الأسبوعية: غياب الخميس والسبت معاً ← الجمعة غياب
  bool _weekendRule = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  static const _defaults = [(15, 25), (30, 50), (60, 100)];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final t in _tiers) {
      t.minutes.dispose();
      t.amount.dispose();
    }
    super.dispose();
  }

  String _num(Object? v) {
    final n = num.tryParse('${v ?? ''}');
    if (n == null) return '';
    return n == n.roundToDouble() ? n.toInt().toString() : n.toString();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'get_settings'});
    if (!mounted) return;
    final s = ((r['settings'] as Map?) ?? {}).cast<String, dynamic>();
    final saved = ((s['late_tiers'] as List?) ?? const []).whereType<Map>().toList();
    setState(() {
      _loading = false;
      _enabled = s['payroll_auto_deductions'] == true && s['deduction_mode'] == 'tiers';
      _early = s['early_deduction'] != false;
      _weekendRule = s['weekend_absence_rule'] == true;
      _tiers.clear();
      if (saved.isEmpty) {
        for (final d in _defaults) {
          _tiers.add(_Tier('${d.$1}', '${d.$2}'));
        }
      } else {
        for (final t in saved) {
          _tiers.add(_Tier(_num(t['afterMinutes']), _num(t['amount'])));
        }
      }
    });
  }

  Future<void> _save() async {
    final list = <Map<String, num>>[];
    for (final t in _tiers) {
      final m = int.tryParse(t.minutes.text.trim());
      final a = num.tryParse(t.amount.text.trim());
      if (m == null || m < 1 || m > 600 || a == null || a <= 0) {
        setState(() => _error = 'كل شريحة: دقايق من 1 لـ 600، ومبلغ أكبر من صفر');
        return;
      }
      list.add({'afterMinutes': m, 'amount': a});
    }
    if (list.isEmpty) {
      setState(() => _error = 'ضيف شريحة واحدة على الأقل');
      return;
    }
    if (list.map((e) => e['afterMinutes']).toSet().length != list.length) {
      setState(() => _error = 'كل شريحة لازم يبقى لها عدد دقايق مختلف');
      return;
    }
    list.sort((x, y) => x['afterMinutes']!.compareTo(y['afterMinutes']!));
    setState(() {
      _saving = true;
      _error = null;
    });
    final r = await ApiService.post({'action': 'save_late_rules', 'enabled': _enabled, 'tiers': list, 'earlyDeduction': _early,
      'weekendAbsenceRule': _weekendRule});
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${r['message'] ?? ''}'),
      backgroundColor: r['success'] == true ? Ar.green : Ar.red,
    ));
  }

  InputDecoration _input(String label, {String? suffix}) => InputDecoration(
        labelText: label,
        suffixText: suffix,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      );

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    final sub = TextStyle(fontSize: 13, height: 1.5, color: isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight);
    final first = _tiers.isEmpty ? null : int.tryParse(_tiers.first.minutes.text);
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('خصم التأخير والانصراف بدري', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  GlassCard(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _enabled,
                      activeColor: AppColors.primary,
                      title: const Text('تفعيل الخصم من المرتب', style: TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('لو مقفول، التأخير والانصراف بدري بيتحسبوا ويظهروا في التقارير من غير خصم', style: sub),
                      onChanged: (v) => setState(() => _enabled = v),
                    ),
                  ),
                  const SizedBox(height: 14),
                  GlassCard(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _early,
                      activeColor: AppColors.primary,
                      title: const Text('تفعيل خصم الانصراف بدري', style: TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('لو مقفول، الانصراف بدري بيتحسب ويظهر في التقارير من غير ما يتخصم — التأخير بس اللي بيتخصم', style: sub),
                      onChanged: (v) => setState(() => _early = v),
                    ),
                  ),
                  const SizedBox(height: 14),
                  GlassCard(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _weekendRule,
                      activeColor: AppColors.primary,
                      title: const Text('قاعدة الإجازة الأسبوعية (الجمعة)', style: TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('• غياب الخميس والسبت معاً ← الجمعة تتحسب غياب.\n'
                          '• غياب يوم واحد بس منهم ← الجمعة تفضل راحة أسبوعية.\n'
                          '• حضور اليومين ← الجمعة راحة أسبوعية.\n'
                          'الغياب هنا هو الغياب من غير إذن — الإجازة المتوافق عليها مش بتتحسب.', style: sub),
                      onChanged: (v) => setState(() => _weekendRule = v),
                    ),
                  ),
                  const SizedBox(height: 14),
                  GlassCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const Row(children: [
                        Icon(Icons.stairs_rounded, color: AppColors.primary),
                        SizedBox(width: 8),
                        Expanded(child: Text('شرايح الخصم (مبلغ ثابت)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
                      ]),
                      const SizedBox(height: 6),
                      Text('${first != null ? 'لحد $first دقيقة مفيش خصم. ' : ''}'
                          'لو عدّى شريحة، يتخصم مبلغ أعلى شريحة عدّاها — مرة واحدة في اليوم. '
                          'الانصراف بدري بيتخصم بنفس الشرايح.', style: sub),
                      const SizedBox(height: 12),
                      for (var i = 0; i < _tiers.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(children: [
                            Expanded(
                              child: TextField(controller: _tiers[i].minutes, keyboardType: TextInputType.number,
                                  onChanged: (_) => setState(() {}), decoration: _input('أكتر من', suffix: 'دقيقة')),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(controller: _tiers[i].amount, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  onChanged: (_) => setState(() {}), decoration: _input('يتخصم', suffix: 'جنيه')),
                            ),
                            IconButton(
                              tooltip: 'حذف الشريحة',
                              icon: const Icon(Icons.remove_circle_outline, color: AppColors.error),
                              onPressed: _tiers.length <= 1 ? null : () => setState(() => _tiers.removeAt(i)),
                            ),
                          ]),
                        ),
                      if (_tiers.length < 6)
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton.icon(
                            onPressed: () => setState(() => _tiers.add(_Tier('', ''))),
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('إضافة شريحة'),
                          ),
                        ),
                      const SizedBox(height: 4),
                      Text('إذن الساعات والزيارة المتوافق عليهم مش بيتحسبوا تأخير ولا انصراف بدري.', style: sub),
                    ]),
                  ),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Ar.red))),
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                      onPressed: _saving ? null : _save,
                      child: Text(_saving ? 'جاري الحفظ...' : 'حفظ', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
