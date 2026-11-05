import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_service.dart';
import '../services/app_controller.dart';
import '../theme/app_colors.dart';

const payoutKindsAr = {
  'salary': 'القبض',
  'advance': 'سلفة',
  'commission': 'عمولة',
  'work_expense': 'مصاريف عمل',
  'fund': 'صرف أموال',
};

String egp(Object? v) {
  final n = v is num ? v : num.tryParse('${v ?? ''}');
  if (n == null) return '--';
  return '${n == n.roundToDouble() ? n.round() : n.toStringAsFixed(2)} جنيه';
}

String _date(Object? iso) {
  final d = DateTime.tryParse('$iso')?.toLocal();
  return d == null ? '' : '${d.day}/${d.month}/${d.year}';
}

/// Home: money handed to me that I still have to confirm ("تم الاستلام"). Hidden when there is none.
class PendingPayoutsCard extends StatefulWidget {
  const PendingPayoutsCard({super.key});

  @override
  State<PendingPayoutsCard> createState() => _PendingPayoutsCardState();
}

class _PendingPayoutsCardState extends State<PendingPayoutsCard> {
  List<Map<String, dynamic>> _items = [];
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'payouts_list', 'scope': 'mine', 'status': 'pending'});
    if (!mounted || r['success'] != true) return;
    setState(() => _items = ((r['payouts'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList());
  }

  Future<void> _receive(Map<String, dynamic> p) async {
    setState(() => _busy.add('${p['id']}'));
    final r = await ApiService.post({'action': 'payout_receive', 'id': p['id']});
    if (!mounted) return;
    _busy.remove('${p['id']}');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Colors.green : Colors.red));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    final isDark = Provider.of<AppController>(context).isDark;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.4),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.green.withOpacity(0.6)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.payments_rounded, color: Colors.green),
            const SizedBox(width: 8),
            const Expanded(child: Text('فلوس اتصرفتلك — أكّد الاستلام', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 8),
          for (final p in _items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${payoutKindsAr[p['kind']] ?? p['kind']}: ${egp(p['amount_egp'])}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    Text('من ${p['created_by_name'] ?? ''}${(p['note'] ?? '').toString().isNotEmpty ? ' • ${p['note']}' : ''}',
                        style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Colors.black54)),
                  ]),
                ),
                ElevatedButton(
                  onPressed: _busy.contains('${p['id']}') ? null : () => _receive(p),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  child: const Text('تم الاستلام'),
                ),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// A list of payouts (mine, or all for HR / the manager), with confirm / cancel buttons where allowed.
class PayoutsList extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final Future<void> Function() reload;
  final bool showEmployee;
  const PayoutsList({super.key, required this.items, required this.reload, this.showEmployee = false});

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('مفيش مبالغ مصروفة لسه', textAlign: TextAlign.center, style: TextStyle(color: isDark ? Colors.white60 : Colors.black54)),
      );
    }
    Color statusColor(String s) => s == 'received' ? Colors.green : (s == 'cancelled' ? Colors.grey : Colors.orange);
    String statusAr(String s) => s == 'received' ? 'تم الاستلام' : (s == 'cancelled' ? 'ملغي' : 'مستني الاستلام');
    return Column(children: [
      for (final p in items)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withOpacity(0.08) : Colors.white.withOpacity(0.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(p['kind'] == 'fund' ? Icons.account_balance_rounded : Icons.payments_rounded, color: AppColors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${payoutKindsAr[p['kind']] ?? p['kind']} — ${egp(p['amount_egp'])}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
              Text(statusAr('${p['status']}'), style: TextStyle(color: statusColor('${p['status']}'), fontWeight: FontWeight.w700, fontSize: 12)),
            ]),
            const SizedBox(height: 4),
            Text(
              [
                if (showEmployee) 'لـ ${p['employee_name'] ?? ''}',
                'من ${p['created_by_name'] ?? ''}',
                _date(p['created_at']),
                if ((p['note'] ?? '').toString().isNotEmpty) '${p['note']}',
              ].join(' • '),
              style: TextStyle(fontSize: 12, color: isDark ? Colors.white60 : Colors.black54),
            ),
            if (p['canReceive'] == true || p['canCancel'] == true)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Wrap(spacing: 8, children: [
                  if (p['canCancel'] == true)
                    TextButton(
                      onPressed: () async {
                        final r = await ApiService.post({'action': 'payout_cancel', 'id': p['id']});
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['message'] ?? ''}')));
                        }
                        await reload();
                      },
                      child: const Text('إلغاء'),
                    ),
                  if (p['canReceive'] == true)
                    ElevatedButton(
                      onPressed: () async {
                        final r = await ApiService.post({'action': 'payout_receive', 'id': p['id']});
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Colors.green : Colors.red));
                        }
                        await reload();
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                      child: const Text('تم الاستلام'),
                    ),
                ]),
              ),
          ]),
        ),
    ]);
  }
}

/// "المبالغ المصروفة لي" inside the financial requests page (every employee).
class MyPayoutsSection extends StatefulWidget {
  const MyPayoutsSection({super.key});

  @override
  State<MyPayoutsSection> createState() => _MyPayoutsSectionState();
}

class _MyPayoutsSectionState extends State<MyPayoutsSection> {
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'payouts_list', 'scope': 'mine'});
    if (!mounted || r['success'] != true) return;
    setState(() => _items = ((r['payouts'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList());
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Padding(
        padding: EdgeInsets.only(bottom: 8),
        child: Text('المبالغ المصروفة ليك', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
      ),
      PayoutsList(items: _items, reload: _load),
      const SizedBox(height: 12),
    ]);
  }
}
