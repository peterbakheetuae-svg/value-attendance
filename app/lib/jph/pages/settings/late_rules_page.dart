import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';

/// Lateness deduction settings (same glass design as the rest of the app):
/// late more than N minutes → a fixed amount; late an hour or more → an amount per hour.
class LateRulesPage extends StatefulWidget {
  const LateRulesPage({super.key});

  @override
  State<LateRulesPage> createState() => _LateRulesPageState();
}

class _LateRulesPageState extends State<LateRulesPage> {
  final _after = TextEditingController(text: '30');
  final _fixed = TextEditingController(text: '0');
  final _hour = TextEditingController(text: '0');
  bool _enabled = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _num(Object? v, String d) {
    final n = num.tryParse('${v ?? ''}');
    if (n == null) return d;
    return n == n.roundToDouble() ? n.toInt().toString() : n.toString();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'get_settings'});
    if (!mounted) return;
    final s = ((r['settings'] as Map?) ?? {}).cast<String, dynamic>();
    setState(() {
      _loading = false;
      _enabled = s['payroll_auto_deductions'] == true && s['deduction_mode'] == 'hourly';
      _after.text = _num(s['late_fixed_after_minutes'], '30');
      _fixed.text = _num(s['late_fixed_amount'], '0');
      _hour.text = _num(s['late_hour_amount'], '0');
    });
  }

  Future<void> _save() async {
    final after = int.tryParse(_after.text.trim());
    final fixed = num.tryParse(_fixed.text.trim());
    final hour = num.tryParse(_hour.text.trim());
    if (after == null || after < 0 || after > 59 || fixed == null || fixed < 0 || hour == null || hour < 0) {
      setState(() => _error = 'اكتب الدقايق من 0 لـ 59، والمبالغ أرقام صفر أو أكتر');
      return;
    }
    setState(() { _saving = true; _error = null; });
    final r = await ApiService.post({'action': 'save_late_rules', 'enabled': _enabled, 'afterMinutes': after, 'fixedAmount': fixed, 'hourAmount': hour});
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${r['message'] ?? ''}'),
      backgroundColor: r['success'] == true ? Colors.green : Colors.red,
    ));
  }

  InputDecoration _input(String label, {String? suffix}) => InputDecoration(
        labelText: label,
        suffixText: suffix,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      );

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    final sub = TextStyle(fontSize: 13, height: 1.5, color: isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight);
    final after = _after.text.isEmpty ? '30' : _after.text;
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('خصم التأخير', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
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
                      subtitle: Text('لو مقفول، التأخير بيتحسب ويظهر في التقارير من غير خصم', style: sub),
                      onChanged: (v) => setState(() => _enabled = v),
                    ),
                  ),
                  const SizedBox(height: 14),
                  GlassCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const Row(children: [
                        Icon(Icons.schedule_rounded, color: AppColors.primary),
                        SizedBox(width: 8),
                        Text('تأخير أقل من ساعة', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      ]),
                      const SizedBox(height: 12),
                      TextField(controller: _after, keyboardType: TextInputType.number, onChanged: (_) => setState(() {}),
                          decoration: _input('لو اتأخر أكتر من', suffix: 'دقيقة')),
                      const SizedBox(height: 10),
                      TextField(controller: _fixed, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: _input('يتخصم من مرتبه', suffix: 'جنيه')),
                      const SizedBox(height: 8),
                      Text('مثال: اتأخر ${int.tryParse(after) != null ? int.parse(after) + 10 : 40} دقيقة → يتخصم ${_fixed.text} جنيه (مرة واحدة في اليوم)', style: sub),
                    ]),
                  ),
                  const SizedBox(height: 14),
                  GlassCard(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      const Row(children: [
                        Icon(Icons.more_time_rounded, color: AppColors.error),
                        SizedBox(width: 8),
                        Text('تأخير ساعة أو أكتر', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      ]),
                      const SizedBox(height: 12),
                      TextField(controller: _hour, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {}),
                          decoration: _input('خصم الساعة', suffix: 'جنيه / ساعة')),
                      const SizedBox(height: 8),
                      Text('بيتحسب بالتناسب: ساعة ونص تأخير → ${(num.tryParse(_hour.text) ?? 0) * 1.5} جنيه. '
                          'إذن الساعات والزيارة المتوافق عليهم مش بيتحسبوا تأخير.', style: sub),
                    ]),
                  ),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Colors.red))),
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
