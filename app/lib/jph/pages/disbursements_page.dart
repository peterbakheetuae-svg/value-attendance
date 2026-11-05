import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../services/app_controller.dart';
import '../theme/app_colors.dart';
import '../widgets/app_background.dart';
import '../widgets/glass_ui_widgets.dart';
import '../widgets/payouts_widgets.dart';

/// صرف مالية — HR pays salary (القبض) / advances / commissions / work expenses from the cash in hand;
/// the manager / owner hands cash to HR (صرف أموال). Every payout waits for "تم الاستلام".
class DisbursementsPage extends StatefulWidget {
  const DisbursementsPage({super.key});

  @override
  State<DisbursementsPage> createState() => _DisbursementsPageState();
}

class _DisbursementsPageState extends State<DisbursementsPage> {
  bool _loading = true;
  List<Map<String, dynamic>> _all = [];
  num? _balance;
  bool _canDisburse = false, _canFund = false;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
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
      }
    });
  }

  List<Map<String, dynamic>> get _shown => switch (_filter) {
        'pending' => _all.where((p) => p['status'] == 'pending').toList(),
        'received' => _all.where((p) => p['status'] == 'received').toList(),
        'fund' => _all.where((p) => p['kind'] == 'fund').toList(),
        _ => _all,
      };

  Future<void> _create({required bool fund}) async {
    // people to pay: employees (HR payout) or cashiers (cash to HR)
    List<Map<String, dynamic>> people;
    if (fund) {
      final r = await ApiService.post({'action': 'payout_cashiers'});
      people = ((r['cashiers'] as List?) ?? const []).whereType<Map>()
          .map((m) => {'id': '${m['id']}', 'name': '${m['full_name']}'}).toList();
    } else {
      final r = await ApiService.post({'action': 'getActiveEmployees'});
      people = ((r['employees'] as List?) ?? const []).whereType<Map>()
          .map((m) => {'id': '${m['id']}', 'name': '${m['name']}'}).toList();
    }
    if (!mounted) return;
    final now = DateTime.now();
    final month = TextEditingController(text: '${now.year}-${now.month.toString().padLeft(2, '0')}');
    final amount = TextEditingController();
    final note = TextEditingController();
    String? who;
    String kind = fund ? 'fund' : 'salary';
    String? err;
    final done = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        InputDecoration dec(String l) => InputDecoration(labelText: l, border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)));
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Text(fund ? 'صرف أموال للموارد البشرية' : 'صرف لموظف'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: who,
                isExpanded: true,
                decoration: dec(fund ? 'يستلمها' : 'الموظف'),
                items: [for (final p in people) DropdownMenuItem(value: p['id'] as String, child: Text('${p['name']}'))],
                onChanged: (v) => set(() => who = v),
              ),
              if (!fund) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: kind,
                  decoration: dec('نوع الصرف'),
                  items: const [
                    DropdownMenuItem(value: 'salary', child: Text('القبض (الراتب)')),
                    DropdownMenuItem(value: 'advance', child: Text('سلفة')),
                    DropdownMenuItem(value: 'commission', child: Text('عمولة')),
                    DropdownMenuItem(value: 'work_expense', child: Text('مستحقات مصاريف عمل')),
                  ],
                  onChanged: (v) => set(() => kind = v ?? 'salary'),
                ),
              ],
              const SizedBox(height: 12),
              TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: dec('المبلغ (جنيه)')),
              if (!fund) ...[
                const SizedBox(height: 12),
                TextField(controller: month, decoration: dec('عن شهر (YYYY-MM)')),
              ],
              const SizedBox(height: 12),
              TextField(controller: note, maxLines: 2, decoration: dec('ملاحظة')),
              if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Colors.red))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white),
              onPressed: () async {
                final a = num.tryParse(amount.text.trim());
                if (who == null || a == null || a <= 0) {
                  set(() => err = 'اختار الشخص واكتب المبلغ');
                  return;
                }
                final r = await ApiService.post({'action': 'payout_create', 'employeeId': who, 'kind': kind, 'amount': a,
                  if (!fund) 'month': month.text.trim(), 'note': note.text.trim()});
                if (r['success'] == true) {
                  if (ctx.mounted) Navigator.pop(ctx, true);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['message']}'), backgroundColor: Colors.green));
                  }
                } else {
                  set(() => err = '${r['message'] ?? 'حصل خطأ'}');
                }
              },
              child: const Text('صرف'),
            ),
          ],
        );
      }),
    );
    if (done == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    final text = isDark ? Colors.white : Colors.black;
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: const Text('صرف مالية')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 40), children: [
                  if (_canDisburse)
                    GlassCard(
                      radius: 22,
                      child: Row(children: [
                        const Icon(Icons.account_balance_wallet_rounded, size: 36, color: AppColors.primary),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('الرصيد اللي معاك', style: TextStyle(color: isDark ? Colors.white70 : Colors.black54)),
                            Text(egp(_balance), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: text)),
                          ]),
                        ),
                      ]),
                    ),
                  const SizedBox(height: 12),
                  Row(children: [
                    if (_canDisburse)
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => _create(fund: false),
                          icon: const Icon(Icons.payments_rounded),
                          label: const Text('صرف لموظف'),
                          style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                        ),
                      ),
                    if (_canDisburse && _canFund) const SizedBox(width: 10),
                    if (_canFund)
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => _create(fund: true),
                          icon: const Icon(Icons.account_balance_rounded),
                          label: const Text('صرف أموال'),
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                        ),
                      ),
                  ]),
                  const SizedBox(height: 14),
                  Wrap(spacing: 8, children: [
                    for (final f in const [('all', 'الكل'), ('pending', 'مستني الاستلام'), ('received', 'تم الاستلام'), ('fund', 'صرف أموال')])
                      ChoiceChip(label: Text(f.$2), selected: _filter == f.$1, onSelected: (_) => setState(() => _filter = f.$1)),
                  ]),
                  const SizedBox(height: 12),
                  PayoutsList(items: _shown, reload: _load, showEmployee: true),
                ]),
              ),
      ),
    );
  }
}
