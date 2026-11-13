import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'jph_form_ui.dart';
import 'glass_ui.dart';

/// "عمولة صفقة" inside the financial request page: project → unit → price/m² × area. The total value, the
/// salesperson percentage and the expected commission are computed (locked); the server recomputes them anyway
/// and always files the request under the signed-in employee.
class DealCommissionForm extends StatefulWidget {
  final bool isDark;
  const DealCommissionForm({super.key, required this.isDark});

  @override
  State<DealCommissionForm> createState() => _DealCommissionFormState();
}

class _DealCommissionFormState extends State<DealCommissionForm> {
  List<Map<String, dynamic>> _projects = [];
  Map<String, dynamic>? _project;
  bool _loading = true, _saving = false;
  final _unit = TextEditingController();
  final _price = TextEditingController();
  final _area = TextEditingController();
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _unit.dispose();
    _price.dispose();
    _area.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'commission_projects', 'status': 'active'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _projects = ((r['projects'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>())
          .where((p) => p['status'] == 'active').toList();
    });
  }

  num? get _priceN => num.tryParse(_price.text.trim().replaceAll(',', ''));
  num? get _areaN => num.tryParse(_area.text.trim().replaceAll(',', ''));
  num? get _value => (_priceN != null && _areaN != null) ? ((_priceN! * _areaN!) * 100).round() / 100 : null;
  num? get _pct => _project?['salesPct'] as num?;
  num? get _commission => (_value != null && _pct != null) ? ((_value! * _pct! / 100) * 100).round() / 100 : null;

  Future<void> _submit() async {
    String? err;
    if (_project == null) {
      err = 'اختار المشروع';
    } else if (_unit.text.trim().isEmpty) {
      err = 'اكتب رقم الوحدة';
    } else if ((_priceN ?? 0) <= 0) {
      err = 'اكتب سعر المتر';
    } else if ((_areaN ?? 0) <= 0) {
      err = 'اكتب مساحة الوحدة';
    }
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err), backgroundColor: Ar.red));
      return;
    }
    setState(() => _saving = true);
    final r = await ApiService.post({
      'action': 'commission_request_create', 'projectId': _project!['id'], 'unitNo': _unit.text.trim(),
      'pricePerM2': _priceN, 'areaM2': _areaN, 'note': _note.text.trim(),
    });
    if (!mounted) return;
    setState(() => _saving = false);
    JphUi.toast(context, r);
    if (r['success'] == true) {
      _unit.clear();
      _price.clear();
      _area.clear();
      _note.clear();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final primary = JphUi.primary(isDark);
    if (_loading) return const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      JphUi.picker(
        isDark: isDark, icon: Icons.apartment_rounded, iconColor: Ar.accent, label: 'المشروع *',
        value: _project == null ? (_projects.isEmpty ? 'مفيش مشاريع متاحة' : 'اختار المشروع') : '${_project!['name']}',
        onTap: () async {
          final v = await JphUi.sheet<Map<String, dynamic>>(context, isDark, 'اختار المشروع',
              [for (final p in _projects) (p, '${p['name']}  •  ${JphUi.pct(p['salesPct'])}', Icons.apartment_rounded)]);
          if (v != null) setState(() => _project = v);
        },
      ),
      const SizedBox(height: 16),
      JphUi.input(isDark: isDark, label: 'رقم الوحدة *', controller: _unit, hint: 'مثال: A-101', icon: Icons.tag_rounded, big: false),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: JphUi.input(isDark: isDark, label: 'المساحة (م²) *', controller: _area, hint: '150', number: true,
            icon: Icons.square_foot_rounded, onChanged: (_) => setState(() {}))),
        const SizedBox(width: 12),
        Expanded(child: JphUi.input(isDark: isDark, label: 'سعر المتر *', controller: _price, hint: '30000', number: true,
            icon: Icons.sell_rounded, onChanged: (_) => setState(() {}))),
      ]),
      const SizedBox(height: 16),
      JphUi.readOnly(isDark: isDark, label: 'إجمالي قيمة الوحدة (سعر المتر × المساحة)', value: JphUi.money(_value),
          icon: Icons.home_work_rounded, color: Ar.info),
      const SizedBox(height: 12),
      JphUi.readOnly(isDark: isDark, label: 'نسبة عمولتك (من إعدادات المشروع)', value: JphUi.pct(_pct),
          icon: Icons.percent_rounded, color: Ar.accent),
      const SizedBox(height: 12),
      JphUi.readOnly(isDark: isDark, label: 'العمولة المتوقعة', value: JphUi.money(_commission),
          icon: Icons.payments_rounded, color: Ar.green),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: JphUi.box(isDark, border: false),
        child: TextField(
          controller: _note,
          maxLines: 3, minLines: 2,
          decoration: InputDecoration(
            hintText: 'ملاحظة (اختياري): اسم العميل، رقم العقد...',
            hintStyle: TextStyle(color: JphUi.sub(isDark), fontSize: 15),
            border: InputBorder.none,
          ),
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: JphUi.text(isDark)),
        ),
      ),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? Ar.amber.shade900.withOpacity(0.25) : Ar.amber.shade50,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: isDark ? Ar.amber.shade700 : Ar.amber.shade200, width: 1.5),
        ),
        child: Row(children: [
          Icon(Icons.info_outline_rounded, color: isDark ? Ar.amber.shade300 : Ar.amber.shade800),
          const SizedBox(width: 10),
          Expanded(
            child: Text('الطلب بيروح للمدير العام يراجعه ويحدد شهر نزول العمولة في المرتب. النسبة والمبلغ بيتحسبوا من إعدادات المشروع.',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: isDark ? Ar.amber.shade200 : Ar.amber.shade900)),
          ),
        ]),
      ),
      const SizedBox(height: 16),
      Container(
        margin: const EdgeInsets.only(bottom: 30),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: primary.withOpacity(0.4), blurRadius: 20, spreadRadius: 2)],
        ),
        child: ElevatedButton(
          onPressed: _saving ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: primary, foregroundColor: Colors.white,
            minimumSize: const Size(double.infinity, 58),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), elevation: 0,
          ),
          child: _saving
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.send_rounded, size: 22),
                  SizedBox(width: 10),
                  Text('إرسال طلب العمولة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                ]),
        ),
      ),
    ]);
  }
}
