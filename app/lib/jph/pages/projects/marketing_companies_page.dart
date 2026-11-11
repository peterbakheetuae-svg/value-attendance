import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/jph_form_ui.dart';

/// شركات التسويق: one paid a fixed monthly fee (recorded as an office expense «شركة تسويق»), one paid a commission on
/// the sales it brings (picked on the reservation; its % comes out of the office share of that unit).
class MarketingCompaniesPage extends StatefulWidget {
  const MarketingCompaniesPage({super.key});

  @override
  State<MarketingCompaniesPage> createState() => _MarketingCompaniesPageState();
}

Map<String, dynamic> _m(Object? v) => (v as Map?)?.cast<String, dynamic>() ?? const {};
List<Map<String, dynamic>> _l(Object? v) => ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();

class _MarketingCompaniesPageState extends State<MarketingCompaniesPage> {
  bool _loading = true, _manage = false;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'cash_get', 'path': '/marketing-companies'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = _l(r['companies']);
      _manage = r['canManage'] == true;
    });
  }

  Future<void> _edit(bool isDark, [Map<String, dynamic>? c]) async {
    String kind = '${c?['kind'] ?? 'commission'}';
    String status = '${c?['status'] ?? 'active'}';
    final name = TextEditingController(text: '${c?['name'] ?? ''}'), phone = TextEditingController(text: '${c?['phone'] ?? ''}'),
        pct = TextEditingController(text: '${c?['defaultPct'] ?? ''}'), fee = TextEditingController(text: '${c?['monthlyFee'] ?? ''}');
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: StatefulBuilder(builder: (ctx, set) {
          return Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(color: isDark ? const Color(0xFF1E2230) : Colors.white, borderRadius: BorderRadius.circular(24)),
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(c == null ? 'شركة تسويق جديدة' : '${c['name']}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  const SizedBox(height: 12),
                  if (c == null)
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'commission', label: Text('عمولة على المبيعات')),
                        ButtonSegment(value: 'fixed', label: Text('راتب ثابت')),
                      ],
                      selected: {kind},
                      onSelectionChanged: (s) => set(() => kind = s.first),
                    ),
                  const SizedBox(height: 12),
                  JphUi.input(isDark: isDark, label: 'اسم الشركة', controller: name, icon: Icons.campaign_rounded),
                  const SizedBox(height: 10),
                  JphUi.input(isDark: isDark, label: 'التليفون', controller: phone, icon: Icons.phone_rounded, number: true),
                  const SizedBox(height: 10),
                  if (kind == 'commission')
                    JphUi.input(isDark: isDark, label: 'نسبتها ٪ من سعر الوحدة (بتتخصم من نصيب المكتب)', controller: pct, number: true, icon: Icons.percent_rounded)
                  else
                    JphUi.input(isDark: isDark, label: 'الراتب الشهري', controller: fee, number: true, suffix: 'جنيه', icon: Icons.payments_rounded),
                  if (c != null) ...[
                    const SizedBox(height: 10),
                    SwitchListTile(
                      value: status == 'active',
                      onChanged: (v) => set(() => status = v ? 'active' : 'inactive'),
                      title: const Text('شغالة معانا'),
                    ),
                  ],
                  const SizedBox(height: 14),
                  SizedBox(
                    height: 50,
                    child: FilledButton.icon(
                      onPressed: () async {
                        final body = {
                          'name': name.text.trim(), 'phone': phone.text.trim(), 'kind': kind,
                          if (kind == 'commission') 'defaultPct': num.tryParse(pct.text) ?? 0,
                          if (kind == 'fixed') 'monthlyFee': num.tryParse(fee.text.replaceAll(',', '')) ?? 0,
                          if (c != null) 'status': status,
                        };
                        final r = await ApiService.post({'action': 'cash_post', 'path': c == null ? '/marketing-companies' : '/marketing-companies/${c['id']}',
                          'body': body, 'ok': 'اتحفظ ✅', if (c != null) 'method': 'patch'});
                        if (ctx.mounted) JphUi.toast(ctx, r);
                        if (r['success'] == true && ctx.mounted) Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.check_rounded),
                      label: const Text('حفظ', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ]),
              ),
            ),
          );
        }),
      ),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final isDark = app.isDark;
    return AppBackground(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: isDark, isRTL: true, title: 'شركات التسويق'),
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
                        if (_manage)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: SizedBox(
                              height: 50,
                              child: ElevatedButton.icon(
                                onPressed: () => _edit(isDark),
                                icon: const Icon(Icons.add_rounded),
                                label: const Text('إضافة شركة تسويق', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                                style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                              ),
                            ),
                          ),
                        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
                        if (!_loading && _items.isEmpty)
                          Padding(padding: const EdgeInsets.all(30),
                              child: Text('لسه مفيش شركات تسويق', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
                        for (final c in _items) _card(isDark, c),
                      ]),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _card(bool isDark, Map<String, dynamic> c) {
    final t = _m(c['totals']);
    final commission = c['kind'] == 'commission';
    Widget kv(String k, Object? v, {Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(k, style: TextStyle(color: JphUi.sub(isDark)))),
            Text(JphUi.money(v), style: TextStyle(fontWeight: FontWeight.w800, color: color ?? JphUi.text(isDark))),
          ]),
        );
    return GestureDetector(
      onTap: _manage ? () => _edit(isDark, c) : null,
      child: Opacity(
        opacity: c['status'] == 'active' ? 1 : 0.55,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(16),
          decoration: JphUi.box(isDark),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              JphUi.iconTile(isDark, commission ? Icons.percent_rounded : Icons.payments_rounded, commission ? Colors.deepPurple : Colors.teal),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${c['name']}', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  Text(commission ? 'عمولة ${JphUi.pct(c['defaultPct'])} على المبيعات' : 'راتب ثابت ${JphUi.money(c['monthlyFee'])} في الشهر',
                      style: TextStyle(fontSize: 13, color: JphUi.sub(isDark))),
                ]),
              ),
              if (c['status'] != 'active') JphUi.chip('موقوفة', Colors.grey),
            ]),
            if (t.isNotEmpty) ...[
              const SizedBox(height: 8),
              if (commission) ...[
                kv('عمولتها على ${t['units']} وحدة', t['earned']),
                kv('اتصرفلها', t['paid'], color: Colors.green),
                kv('مستحق لها', t['due'], color: Colors.orange),
              ] else
                kv('اتصرفلها', t['paid'], color: Colors.green),
            ],
          ]),
        ),
      ),
    );
  }
}
