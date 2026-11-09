import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../services/app_controller.dart';
import '../theme/app_colors.dart';
import '../widgets/app_background.dart';
import '../widgets/jph_form_ui.dart';
import '../widgets/payouts_widgets.dart';

/// صرف مالية — same look as "طلب سلفة / مصاريف": HR pays salary (القبض) / advances / commissions /
/// work expenses from the cash in hand; the manager / owner hands cash to HR (صرف أموال).
/// Every payout waits for the receiver's "تم الاستلام".
class DisbursementsPage extends StatefulWidget {
  /// true = shown as the "صرف" tab inside طلبات المالية (no own header / page)
  final bool embedded;
  const DisbursementsPage({super.key, this.embedded = false});

  @override
  State<DisbursementsPage> createState() => _DisbursementsPageState();
}

class _DisbursementsPageState extends State<DisbursementsPage> {
  static const _monthsAr = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
  static const _kinds = {
    'salary': ('القبض (الراتب)', Icons.payments_rounded, Colors.green),
    'advance': ('سلفة', Icons.account_balance_wallet_rounded, Colors.orange),
    'commission': ('عمولة', Icons.trending_up_rounded, Colors.purple),
    'work_expense': ('مستحقات مصاريف عمل', Icons.receipt_long_rounded, Colors.blue),
  };

  bool _loading = true;
  bool _saving = false;
  List<Map<String, dynamic>> _all = [];
  List<Map<String, dynamic>> _people = [];
  num? _balance;
  bool _canDisburse = false, _canFund = false;
  bool _fundMode = false; // false = صرف لموظف, true = صرف أموال للموارد البشرية
  String? _who;
  String _kind = 'salary';
  late DateTime _month;
  final _amount = TextEditingController();
  final _note = TextEditingController();
  Map<String, dynamic>? _pay; // the chosen employee's payroll for the chosen month (the salary note)
  bool _payLoading = false;
  String? _payErr;

  @override
  void initState() {
    super.initState();
    final n = DateTime.now();
    _month = DateTime(n.year, n.month);
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'payouts_list'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r['success'] == true) {
        _all = ((r['payouts'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
        _balance = r['balance'] as num?;
        _canDisburse = r['canDisburse'] == true;
        _canFund = r['canFund'] == true;
        if (!_canDisburse && _canFund) _fundMode = true;
      }
    });
    await _loadPeople();
  }

  Future<void> _loadPeople() async {
    List<Map<String, dynamic>> people;
    if (_fundMode) {
      final r = await ApiService.post({'action': 'payout_cashiers'});
      people = ((r['cashiers'] as List?) ?? const []).whereType<Map>()
          .map((m) => <String, dynamic>{'id': '${m['id']}', 'name': '${m['full_name']}', 'code': '${m['code'] ?? ''}'}).toList();
    } else {
      final r = await ApiService.post({'action': 'getActiveEmployees'});
      people = ((r['employees'] as List?) ?? const []).whereType<Map>()
          .map((m) => <String, dynamic>{'id': '${m['id']}', 'name': '${m['name']}', 'code': '${m['uid'] ?? ''}'}).toList();
    }
    if (!mounted) return;
    setState(() {
      _people = people;
      if (!_people.any((p) => p['id'] == _who)) _who = null;
    });
  }

  /// Salary note: when an employee is chosen for القبض / عمولة / سلفة, show his salary and what is due.
  Future<void> _loadPay() async {
    final who = _who;
    if (_fundMode || who == null || _kind == 'work_expense') {
      setState(() => _pay = null);
      return;
    }
    setState(() {
      _payLoading = true;
      _payErr = null;
    });
    final m = '${_month.year}-${_month.month.toString().padLeft(2, '0')}';
    final r = await ApiService.post({'action': 'cash_get', 'path': '/payroll/employee/$who', 'query': {'month': m}});
    if (!mounted || who != _who) return;
    setState(() {
      _payLoading = false;
      _pay = r['payroll'] is Map ? (r['payroll'] as Map).cast<String, dynamic>() : null;
      if (_pay == null) _payErr = '${r['message'] ?? 'مش قادر أجيب المرتب'}';
    });
  }

  Widget _payNote(bool isDark) {
    if (_fundMode || _who == null || _kind == 'work_expense') return const SizedBox.shrink();
    final c = Colors.indigo;
    Widget line(String k, Object? v, {bool strong = false}) => Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            Expanded(child: Text(k, style: TextStyle(fontSize: 13.5, color: isDark ? Colors.white70 : Colors.black87))),
            Text(egp(v), style: TextStyle(fontSize: strong ? 16 : 14, fontWeight: strong ? FontWeight.w900 : FontWeight.w700,
                color: strong ? (isDark ? Colors.indigo.shade200 : c.shade700) : (isDark ? Colors.white : Colors.black87))),
          ]),
        );
    final p = _pay;
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? c.shade900.withOpacity(0.3) : c.shade50,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isDark ? c.shade700 : c.shade200, width: 1.5),
      ),
      child: _payLoading
          ? const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator(strokeWidth: 2)))
          : p == null
              ? Text(_payErr ?? '', style: const TextStyle(color: Colors.red))
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Icon(Icons.sticky_note_2_rounded, color: isDark ? c.shade200 : c.shade700),
                    const SizedBox(width: 8),
                    Text('مرتب ${_monthsAr[_month.month - 1]} ${_month.year}',
                        style: TextStyle(fontWeight: FontWeight.w900, color: isDark ? c.shade200 : c.shade800)),
                  ]),
                  const SizedBox(height: 4),
                  line('الراتب الأساسي', p['baseSalary'], strong: _kind == 'advance'),
                  if (_kind == 'salary') ...[
                    line('إجمالي الخصومات', p['totalDeductions']),
                    line('السلف', p['advances']),
                    line('العمولات', p['commissions']),
                    line('الصافي المستحق', p['net']),
                    line('اتصرف منه', p['salaryPaid']),
                    line('الباقي له', p['remaining'], strong: true),
                  ],
                  if (_kind == 'commission') ...[
                    line('عمولات الشهر', p['commissions']),
                    line('اتصرف منها', p['commissionPaid']),
                    line('الباقي من العمولات',
                        ((p['commissions'] as num?) ?? 0) - ((p['commissionPaid'] as num?) ?? 0), strong: true),
                  ],
                  if (_kind == 'advance') line('سلف الشهر ده', p['advances']),
                ]),
    );
  }

  Future<void> _submit() async {
    final a = num.tryParse(_amount.text.trim());
    if (_who == null || a == null || a <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('اختار الشخص واكتب المبلغ'), backgroundColor: Colors.red));
      return;
    }
    setState(() => _saving = true);
    final r = await ApiService.post({
      'action': 'payout_create', 'employeeId': _who, 'kind': _fundMode ? 'fund' : _kind, 'amount': a,
      if (!_fundMode) 'month': '${_month.year}-${_month.month.toString().padLeft(2, '0')}',
      'note': _note.text.trim(),
    });
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Colors.green : Colors.red));
    if (r['success'] == true) {
      _amount.clear();
      _note.clear();
      await _load();
    }
  }

  // ---------------------------------------------------------------- the same building blocks as the request page
  BoxDecoration _box(bool isDark, {bool border = true}) => BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10)],
        border: border ? Border.all(color: isDark ? Colors.white.withOpacity(0.2) : Colors.grey.shade300, width: 1) : null,
      );

  Widget _pickerTile({required bool isDark, required IconData icon, required Color iconColor, required String label,
      required String value, required Color text, required Color sub, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: _box(isDark),
        child: Row(children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: iconColor.withOpacity(isDark ? 0.2 : 0.1)),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: sub)),
              const SizedBox(height: 4),
              Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: text)),
            ]),
          ),
          const SizedBox(width: 10),
          Icon(Icons.arrow_drop_down_rounded, color: AppColors.primary, size: 28),
        ]),
      ),
    );
  }

  Future<T?> _sheet<T>(bool isDark, String title, List<(T, String, IconData?)> options, {T? selected}) =>
      JphUi.sheet<T>(context, isDark, title, options, selected: selected);

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      final isRTL = app.isRTL;
      final primary = isDark ? AppColors.primaryLight : AppColors.primary;
      final text = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
      final sub = isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight;
      final whoName = _people.where((p) => p['id'] == _who).map((p) => '${p['name']}').firstOrNull;
      final kind = _kinds[_kind]!;

      final Widget content = _loading
                      ? const Center(child: CircularProgressIndicator())
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView(padding: const EdgeInsets.all(16), children: [
                            if (_canDisburse)
                              Container(
                                margin: const EdgeInsets.only(bottom: 16),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                decoration: BoxDecoration(
                                  color: isDark ? Colors.green.shade900.withOpacity(0.3) : Colors.green.shade50,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: isDark ? Colors.green.shade700 : Colors.green.shade200, width: 1.5),
                                ),
                                child: Row(children: [
                                  Container(
                                    width: 44, height: 44,
                                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: isDark ? Colors.green.shade800 : Colors.green.shade100),
                                    child: Icon(Icons.account_balance_wallet_rounded, color: isDark ? Colors.green.shade300 : Colors.green.shade800),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                      Text('الرصيد اللي معاك', style: TextStyle(fontSize: 13, color: isDark ? Colors.green.shade200 : Colors.green.shade700)),
                                      Text(egp(_balance), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: isDark ? Colors.green.shade300 : Colors.green.shade800)),
                                    ]),
                                  ),
                                ]),
                              ),

                            if (_canDisburse && _canFund) ...[
                              _pickerTile(
                                isDark: isDark, icon: _fundMode ? Icons.account_balance_rounded : Icons.person_rounded,
                                iconColor: primary, label: 'نوع العملية *',
                                value: _fundMode ? 'صرف أموال للموارد البشرية' : 'صرف لموظف', text: text, sub: sub,
                                onTap: () async {
                                  final v = await _sheet<bool>(isDark, 'نوع العملية', [
                                    (false, 'صرف لموظف', Icons.person_rounded),
                                    (true, 'صرف أموال للموارد البشرية', Icons.account_balance_rounded),
                                  ], selected: _fundMode);
                                  if (v != null && v != _fundMode) {
                                    setState(() => _fundMode = v);
                                    await _loadPeople();
                                    _loadPay();
                                  }
                                },
                              ),
                              const SizedBox(height: 16),
                            ],

                            if (_canDisburse || _canFund) ...[
                              _pickerTile(
                                isDark: isDark, icon: Icons.badge_rounded, iconColor: Colors.teal,
                                label: _fundMode ? 'يستلمها (الموارد البشرية) *' : 'الموظف *',
                                value: whoName ?? 'اختار', text: text, sub: sub,
                                onTap: () async {
                                  final v = await _sheet<String>(isDark, _fundMode ? 'اختار المستلم' : 'اختار الموظف',
                                      [for (final p in _people) ('${p['id']}', '${p['name']}', Icons.person_outline_rounded)], selected: _who);
                                  if (v != null) {
                                    setState(() => _who = v);
                                    _loadPay();
                                  }
                                },
                              ),
                              const SizedBox(height: 16),
                              if (!_fundMode) ...[
                                _pickerTile(
                                  isDark: isDark, icon: kind.$2, iconColor: kind.$3, label: 'نوع الصرف *', value: kind.$1, text: text, sub: sub,
                                  onTap: () async {
                                    final v = await _sheet<String>(isDark, 'نوع الصرف',
                                        [for (final e in _kinds.entries) (e.key, e.value.$1, e.value.$2)], selected: _kind);
                                    if (v != null) {
                                      setState(() => _kind = v);
                                      _loadPay();
                                    }
                                  },
                                ),
                                const SizedBox(height: 16),
                                _pickerTile(
                                  isDark: isDark, icon: Icons.calendar_month_rounded, iconColor: primary, label: 'الشهر *',
                                  value: '${_monthsAr[_month.month - 1]} ${_month.year}', text: text, sub: sub,
                                  onTap: () async {
                                    final now = DateTime.now();
                                    final months = [for (var i = -3; i <= 1; i++) DateTime(now.year, now.month + i)];
                                    final v = await _sheet<DateTime>(isDark, 'الشهر',
                                        [for (final m in months) (m, '${_monthsAr[m.month - 1]} ${m.year}', Icons.event_rounded)], selected: _month);
                                    if (v != null) {
                                      setState(() => _month = v);
                                      _loadPay();
                                    }
                                  },
                                ),
                                const SizedBox(height: 16),
                              ],

                              _payNote(isDark),

                              // المبلغ
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                decoration: _box(isDark),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                                  Text('المبلغ *', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: sub)),
                                  const SizedBox(height: 8),
                                  TextField(
                                    controller: _amount,
                                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                    decoration: InputDecoration(
                                      hintText: 'أدخل المبلغ بالجنيه',
                                      hintStyle: TextStyle(color: sub, fontSize: 16),
                                      border: InputBorder.none,
                                      prefixIcon: Icon(Icons.payments_outlined, color: primary, size: 22),
                                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                                    ),
                                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: text),
                                  ),
                                ]),
                              ),
                              const SizedBox(height: 16),

                              Text('ملاحظة (اختياري)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: text)),
                              const SizedBox(height: 8),
                              Container(
                                margin: const EdgeInsets.only(bottom: 16),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                decoration: _box(isDark, border: false),
                                child: TextField(
                                  controller: _note,
                                  maxLines: 4, minLines: 3,
                                  decoration: InputDecoration(
                                    hintText: 'اكتب ملاحظة توضيحية هنا...',
                                    hintStyle: TextStyle(color: sub, fontSize: 16),
                                    border: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                                  ),
                                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: text),
                                ),
                              ),

                              SizedBox(
                                height: 56,
                                child: ElevatedButton(
                                  onPressed: _saving ? null : _submit,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: primary,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                                  ),
                                  child: _saving
                                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                                      : Text(_fundMode ? 'صرف الأموال' : 'صرف', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                                ),
                              ),
                              const SizedBox(height: 24),
                            ],

                            Text('سجل الصرف', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: text)),
                            const SizedBox(height: 8),
                            PayoutsList(items: _all, reload: _load, showEmployee: true),
                          ]),
                        ),;
      if (widget.embedded) return content;

      return AppBackground(
        child: Directionality(
          textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                // Header — same as the request page
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(children: [
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        width: 46, height: 46,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          color: isDark ? Colors.white.withOpacity(0.15) : Colors.white.withOpacity(0.70),
                          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 14, offset: const Offset(0, 8))],
                        ),
                        child: Icon(isRTL ? Icons.arrow_forward_ios_rounded : Icons.arrow_back_ios_rounded, color: text, size: 22),
                      ),
                    ),
                    const Spacer(),
                    Text('صرف مالية', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: text)),
                    const Spacer(),
                    const SizedBox(width: 46),
                  ]),
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: content
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}
