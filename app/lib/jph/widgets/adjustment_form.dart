import 'side_sheet.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_service.dart';
import 'jph_form_ui.dart';
import 'glass_ui.dart';

/// طلبات مالية ← علاوة / خصم: same look as "طلب".
///  • جزاء: comes off that month's salary (shows in "خصومات" in the monthly report).
///  • علاوة: added to that month's salary (shows in "علاوة إضافية").
///  • زيادة راتب: once approved it is added to the employee's "الزيادة" — monthly salary = starting salary + raises.
/// HR records it (with an optional photo); المدير / المالك approve or reject it.
class AdjustmentsTab extends StatefulWidget {
  final bool isDark;
  const AdjustmentsTab({super.key, required this.isDark});

  static bool get visible => ApiService.can('finance.manage') || ApiService.can('finance.approve');

  @override
  State<AdjustmentsTab> createState() => _AdjustmentsTabState();
}

const _kinds = {
  'deduction': ('جزاء', Icons.gavel_rounded, Ar.red),
  'raise': ('زيادة راتب', Icons.trending_up_rounded, Ar.green),
  'bonus': ('علاوة', Icons.card_giftcard_rounded, Ar.green),
};
const _monthsAr = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];

class _AdjustmentsTabState extends State<AdjustmentsTab> {
  List<Map<String, dynamic>> _employees = [];
  List<Map<String, dynamic>> _items = [];
  bool _loading = true, _saving = false;
  String? _empId, _empName;
  String _kind = 'deduction';
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);
  final _amount = TextEditingController(), _reason = TextEditingController();
  XFile? _image;

  bool get _canCreate => ApiService.can('finance.manage');

  @override
  void initState() {
    super.initState();
    _load();
    if (_canCreate) _loadEmployees();
  }

  Future<void> _loadEmployees() async {
    final r = await ApiService.post({'action': 'getActiveEmployees'});
    if (!mounted) return;
    setState(() => _employees = ((r['employees'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList());
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'cash_get', 'path': '/finance/adjustments'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = ((r['adjustments'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    });
  }

  Future<void> _pickImage() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 70, maxWidth: 1200);
    if (x != null) setState(() => _image = x);
  }

  Future<void> _submit() async {
    final amount = num.tryParse(_amount.text.trim());
    if (_empId == null || amount == null || amount <= 0) {
      JphUi.toast(context, {'success': false, 'message': 'اختار الموظف واكتب المبلغ'});
      return;
    }
    setState(() => _saving = true);
    String? img;
    if (_image != null) img = 'data:image/jpeg;base64,${base64Encode(await _image!.readAsBytes())}';
    final reason = _reason.text.trim().length >= 3 ? _reason.text.trim() : _kinds[_kind]!.$1;
    final r = await ApiService.post({
      'action': 'cash_post', 'path': '/finance/adjustments',
      'body': {
        'employeeId': _empId, 'kind': _kind, 'amountEgp': amount, 'reason': reason,
        'month': '${_month.year}-${_month.month.toString().padLeft(2, '0')}', if (img != null) 'attachment': img,
      },
      'ok': 'اتسجل — مستني موافقة المدير ✅',
    });
    if (!mounted) return;
    setState(() => _saving = false);
    JphUi.toast(context, r);
    if (r['success'] == true) {
      _amount.clear();
      _reason.clear();
      setState(() => _image = null);
      _load();
    }
  }

  Future<void> _decide(Map<String, dynamic> x, bool approve) async {
    String? comment;
    if (!approve) {
      final c = TextEditingController();
      final ok = await showAppSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: widget.isDark ? const Color(0xF2262624) : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              JphUi.input(isDark: widget.isDark, label: 'سبب الرفض', controller: c, big: false),
              const SizedBox(height: 12),
              SizedBox(width: double.infinity, child: FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('رفض'))),
            ]),
          ),
        ),
      );
      if (ok != true || c.text.trim().isEmpty) return;
      comment = c.text.trim();
    }
    final r = await ApiService.post({
      'action': 'cash_post', 'path': '/finance/adjustments/${x['id']}/decision',
      'body': {'decision': approve ? 'approve' : 'reject', if (comment != null) 'comment': comment},
      'ok': approve ? 'اتعتمد ✅' : 'اترفض',
    });
    if (!mounted) return;
    JphUi.toast(context, r);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final k = _kinds[_kind]!;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 120), children: [
        if (_canCreate) ...[
          Text('علاوة / خصم', textAlign: TextAlign.right, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
          const SizedBox(height: 12),
          JphUi.picker(
            isDark: isDark, icon: Icons.badge_rounded, iconColor: Ar.green, label: 'الموظف *',
            value: _empName ?? (_employees.isEmpty ? 'جاري التحميل...' : 'اختار الموظف'),
            onTap: _employees.isEmpty
                ? null
                : () async {
                    final v = await JphUi.sheet<String>(context, isDark, 'اختار الموظف',
                        [for (final e in _employees) ('${e['id']}', '${e['name'] ?? ''}', Icons.person_outline_rounded)],
                        selected: _empId, icon: Icons.badge_rounded, people: true);
                    if (v == null) return;
                    setState(() {
                      _empId = v;
                      _empName = '${_employees.firstWhere((e) => '${e['id']}' == v)['name']}';
                    });
                  },
          ),
          const SizedBox(height: 16),
          JphUi.picker(
            isDark: isDark, icon: k.$2, iconColor: k.$3, label: 'النوع *', value: k.$1,
            onTap: () async {
              final v = await JphUi.sheet<String>(context, isDark, 'النوع', [for (final e in _kinds.entries) (e.key, e.value.$1, e.value.$2)],
                  selected: _kind, icon: Icons.tune_rounded);
              if (v != null) setState(() => _kind = v);
            },
          ),
          const SizedBox(height: 16),
          JphUi.picker(
            isDark: isDark, icon: Icons.calendar_month_rounded, iconColor: Ar.accent,
            label: _kind == 'raise' ? 'من شهر *' : 'الشهر *', value: '${_monthsAr[_month.month - 1]} ${_month.year}',
            onTap: () async {
              final m = await JphUi.pickMonth(context, isDark, _month);
              if (m != null) setState(() => _month = m);
            },
          ),
          const SizedBox(height: 16),
          JphUi.input(isDark: isDark, label: 'المبلغ *', controller: _amount, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
          const SizedBox(height: 16),
          JphUi.input(isDark: isDark, label: 'السبب / ملاحظات', controller: _reason, icon: Icons.edit_note_rounded, big: false),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _pickImage,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: JphUi.box(isDark),
              child: Row(children: [
                JphUi.iconTile(isDark, Icons.add_photo_alternate_rounded, Ar.amber),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(_image == null ? 'إضافة صورة (اختياري)' : 'تم اختيار صورة ✅',
                      textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
                ),
                if (_image != null && !kIsWeb)
                  ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(File(_image!.path), width: 44, height: 44, fit: BoxFit.cover)),
              ]),
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 54,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _submit,
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded),
              label: const Text('إرسال', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              style: ElevatedButton.styleFrom(
                backgroundColor: JphUi.primary(isDark),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
        Text('آخر العلاوات والخصومات', textAlign: TextAlign.right, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
        const SizedBox(height: 10),
        if (_loading) const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _items.isEmpty)
          Padding(padding: const EdgeInsets.all(24), child: Text('مفيش لسه', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final x in _items) _card(isDark, x),
      ]),
    );
  }

  Widget _card(bool isDark, Map<String, dynamic> x) {
    final k = _kinds['${x['kind']}'] ?? ('${x['kind']}', Icons.tune_rounded, Ar.grey);
    final st = switch ('${x['status']}') {
      'approved' => ('معتمد', Ar.green),
      'rejected' => ('مرفوض', Ar.red),
      _ => ('مستني موافقة المدير', Ar.amber),
    };
    final period = '${x['period'] ?? ''}';
    final m = int.tryParse(period.length >= 7 ? period.substring(5, 7) : '') ?? 1;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          JphUi.iconTile(isDark, k.$2, k.$3),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${x['employee_name'] ?? ''} • ${k.$1}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
              Text('${_monthsAr[(m - 1).clamp(0, 11)]} ${period.length >= 4 ? period.substring(0, 4) : ''} • ${x['reason'] ?? ''}'
                  '${x['has_attachment'] == true ? ' • 📎' : ''}',
                  style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
              Text('سجّله ${x['created_by_name'] ?? ''}${x['decided_by_name'] != null ? ' • قرار ${x['decided_by_name']}' : ''}',
                  style: TextStyle(fontSize: 11, color: JphUi.sub(isDark))),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            CountUpText(JphUi.money(x['amount_egp']), style: TextStyle(fontWeight: FontWeight.w900, color: k.$3)),
            const SizedBox(height: 4),
            JphUi.chip(st.$1, st.$2),
          ]),
        ]),
        if (x['canDecide'] == true) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _decide(x, true),
                icon: const Icon(Icons.check_rounded, color: Ar.green),
                label: const Text('موافقة', style: TextStyle(color: Ar.green, fontWeight: FontWeight.w800)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _decide(x, false),
                icon: const Icon(Icons.close_rounded, color: Ar.red),
                label: const Text('رفض', style: TextStyle(color: Ar.red, fontWeight: FontWeight.w800)),
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}
