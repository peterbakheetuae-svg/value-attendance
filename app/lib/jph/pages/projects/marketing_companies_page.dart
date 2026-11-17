import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/glass_ui.dart';
import 'marketing_company_form_page.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

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

  /// the company's file — like an employee's (marketing_company_form_page.dart)
  Future<void> _edit(bool isDark, [Map<String, dynamic>? c]) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => MarketingCompanyFormPage(id: c?['id']?.toString())));
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
            CountUpText(JphUi.money(v), style: TextStyle(fontWeight: FontWeight.w800, color: color ?? JphUi.text(isDark))),
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
              JphUi.iconTile(isDark, commission ? Icons.percent_rounded : Icons.payments_rounded, commission ? Ar.accent : Ar.green),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${c['name']}', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  Text(commission ? 'بالعمولة ${JphUi.pct(c['defaultPct'])} على المبيعات' : 'مبلغ ثابت ${JphUi.money(c['monthlyFee'])} في الشهر',
                      style: TextStyle(fontSize: 13, color: JphUi.sub(isDark))),
                ]),
              ),
              JphUi.chip(c['status'] == 'active' ? 'متعاقد' : 'تم فسخ التعاقد', c['status'] == 'active' ? Ar.green : Ar.grey),
            ]),
            if (t.isNotEmpty) ...[
              const SizedBox(height: 8),
              if (commission) ...[
                kv('عمولتها على ${t['units']} وحدة', t['earned']),
                kv('اتصرفلها', t['paid'], color: Ar.green),
                kv('مستحق لها', t['due'], color: Ar.amber),
              ] else
                kv('اتصرفلها', t['paid'], color: Ar.green),
            ],
          ]),
        ),
      ),
    );
  }
}
