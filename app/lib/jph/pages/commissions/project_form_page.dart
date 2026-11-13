import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/glass_ui.dart';

/// Add / edit a project. The three shares must add up to the total exactly (checked live here and again by
/// the server). Changing the split later never touches commissions that were already approved.
class ProjectFormPage extends StatefulWidget {
  final Map<String, dynamic>? project;
  const ProjectFormPage({super.key, this.project});

  @override
  State<ProjectFormPage> createState() => _ProjectFormPageState();
}

class _ProjectFormPageState extends State<ProjectFormPage> {
  final _name = TextEditingController();
  final _total = TextEditingController();
  final _sales = TextEditingController();
  final _manager = TextEditingController();
  final _company = TextEditingController();
  String _status = 'active';
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final p = widget.project;
    String f(Object? v) => v == null ? '' : JphUi.pct(v).replaceAll('%', '');
    if (p != null) {
      _name.text = '${p['name'] ?? ''}';
      _total.text = f(p['totalPct']);
      _sales.text = f(p['salesPct']);
      _manager.text = f(p['managerPct']);
      _company.text = f(p['companyPct']);
      _status = '${p['status'] ?? 'active'}';
    }
  }

  num? _n(TextEditingController c) => num.tryParse(c.text.trim());
  // compare in ten-thousandths so 0.3 + 0.4 + 0.8 is exactly 1.5
  int? _u(TextEditingController c) => _n(c) == null ? null : (_n(c)! * 10000).round();

  String? get _problem {
    final t = _u(_total), s = _u(_sales), m = _u(_manager), c = _u(_company);
    if (_name.text.trim().length < 2) return 'اكتب اسم المشروع';
    if (t == null || s == null || m == null || c == null) return 'اكتب كل النسب (اكتب 0 لو مفيش)';
    if (t <= 0) return 'إجمالي العمولة لازم يكون أكبر من صفر';
    if (s < 0 || m < 0 || c < 0) return 'مفيش نسبة بالسالب';
    if (s + m + c != t) return 'المجموع ${JphUi.pct((s + m + c) / 10000)} لازم يساوي الإجمالي ${JphUi.pct(t / 10000)}';
    return null;
  }

  Future<void> _save() async {
    final err = _problem;
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err), backgroundColor: Ar.red));
      return;
    }
    setState(() => _saving = true);
    final r = await ApiService.post({
      'action': 'commission_project_save', 'id': widget.project?['id'], 'name': _name.text.trim(),
      'totalPct': _n(_total), 'salesPct': _n(_sales), 'managerPct': _n(_manager), 'companyPct': _n(_company), 'status': _status,
    });
    if (!mounted) return;
    setState(() => _saving = false);
    JphUi.toast(context, r);
    if (r['success'] == true) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      final isRTL = app.isRTL;
      final primary = JphUi.primary(isDark);
      final problem = _problem;
      final t = _n(_total) ?? 0;
      return AppBackground(
        child: Directionality(
          textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                JphUi.header(context, isDark: isDark, isRTL: isRTL, title: widget.project == null ? 'مشروع جديد' : 'تعديل المشروع'),
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: ListView(padding: const EdgeInsets.fromLTRB(16, 10, 16, 40), children: [
                        JphUi.input(isDark: isDark, label: 'اسم المشروع *', controller: _name, hint: 'مثال: Kayan',
                            icon: Icons.apartment_rounded, big: false, onChanged: (_) => setState(() {})),
                        const SizedBox(height: 16),
                        JphUi.input(isDark: isDark, label: 'إجمالي عمولة العقد % *', controller: _total, hint: '1.50', number: true,
                            icon: Icons.percent_rounded, suffix: '%', onChanged: (_) => setState(() {})),
                        const SizedBox(height: 16),
                        Text('التوزيع', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                        const SizedBox(height: 8),
                        JphUi.input(isDark: isDark, label: 'نسبة البائع % *', controller: _sales, hint: '0.30', number: true,
                            icon: Icons.person_rounded, suffix: '%', onChanged: (_) => setState(() {})),
                        const SizedBox(height: 12),
                        JphUi.input(isDark: isDark, label: 'نسبة مدير المبيعات % *', controller: _manager, hint: '0.40', number: true,
                            icon: Icons.groups_rounded, suffix: '%', onChanged: (_) => setState(() {})),
                        const SizedBox(height: 12),
                        JphUi.input(isDark: isDark, label: 'نسبة الشركة % *', controller: _company, hint: '0.80', number: true,
                            icon: Icons.account_balance_rounded, suffix: '%', onChanged: (_) => setState(() {})),
                        const SizedBox(height: 12),
                        // live check
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: (problem == null ? Ar.green : Ar.amber).withOpacity(isDark ? 0.18 : 0.08),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: (problem == null ? Ar.green : Ar.amber).withOpacity(0.5), width: 1.4),
                          ),
                          child: Row(children: [
                            Icon(problem == null ? Icons.check_circle_rounded : Icons.info_rounded,
                                color: problem == null ? Ar.green : Ar.amber),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                problem ?? 'التوزيع سليم ✔  مثال: وحدة 4,500,000 جنيه → إجمالي ${JphUi.money((4500000 * t / 100))}',
                                style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark)),
                              ),
                            ),
                          ]),
                        ),
                        const SizedBox(height: 16),
                        JphUi.picker(
                          isDark: isDark, icon: Icons.toggle_on_rounded, iconColor: Ar.green, label: 'حالة المشروع',
                          value: switch (_status) { 'paused' => 'متوقف مؤقتاً', 'closed' => 'مقفول', _ => 'شغال (بيستقبل صفقات)' },
                          onTap: () async {
                            final v = await JphUi.sheet<String>(context, isDark, 'حالة المشروع', [
                              ('active', 'شغال (بيستقبل صفقات)', Icons.play_circle_rounded),
                              ('paused', 'متوقف مؤقتاً', Icons.pause_circle_rounded),
                              ('closed', 'مقفول', Icons.lock_rounded),
                            ]);
                            if (v != null) setState(() => _status = v);
                          },
                        ),
                        if (widget.project != null) ...[
                          const SizedBox(height: 12),
                          Text('تعديل النسب بيسري على الصفقات الجديدة بس — العمولات المعتمدة قبل كده مش بتتغير.',
                              style: TextStyle(color: JphUi.sub(isDark), fontWeight: FontWeight.w600)),
                        ],
                        const SizedBox(height: 20),
                        ElevatedButton(
                          onPressed: _saving ? null : _save,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: primary, foregroundColor: Colors.white,
                            minimumSize: const Size(double.infinity, 58),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          ),
                          child: _saving
                              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Text('حفظ المشروع', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                        ),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}
