import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../services/jph_bridge.dart';
import '../../widgets/app_background.dart';
import '../../widgets/jph_form_ui.dart';
import 'project_form_page.dart';
import '../../widgets/glass_dialog.dart';

/// One project: its split, the totals and the sold units (approved deals only). Company figures arrive from the
/// API only for the owner / المدير; the sales manager gets only his team's units.
class CommissionProjectPage extends StatefulWidget {
  final String projectId;
  const CommissionProjectPage({super.key, required this.projectId});

  @override
  State<CommissionProjectPage> createState() => _CommissionProjectPageState();
}

class _CommissionProjectPageState extends State<CommissionProjectPage> {
  bool _loading = true;
  Map<String, dynamic>? _p;
  List<Map<String, dynamic>> _units = [];
  final _q = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'commission_project', 'id': widget.projectId});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _p = (r['project'] as Map?)?.cast<String, dynamic>();
      _units = ((r['units'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    });
    if (r['success'] != true && mounted) JphUi.toast(context, r);
  }

  Future<void> _void(Map<String, dynamic> u) async {
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: GlassAlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          title: const Text('إلغاء عمولة معتمدة', style: TextStyle(fontWeight: FontWeight.w900)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('السجل هيفضل محفوظ بقيمه الأصلية، بس العمولة هتتشال من المرتب.'),
            const SizedBox(height: 10),
            TextField(controller: reason, maxLines: 2, decoration: const InputDecoration(hintText: 'السبب (إجباري)')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('رجوع')),
            ElevatedButton(
              onPressed: () => Navigator.pop(c, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
              child: const Text('إلغاء العمولة'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final r = await ApiService.post({'action': 'commission_void', 'id': u['id'], 'reason': reason.text.trim()});
    if (!mounted) return;
    JphUi.toast(context, r);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      final isRTL = app.isRTL;
      final p = _p;
      final manage = ApiService.can('commission.project_manage');
      final q = _q.text.trim().toLowerCase();
      final shown = q.isEmpty ? _units : _units.where((u) =>
          '${u['unitNo']} ${u['employeeName']} ${u['salesManagerName'] ?? ''}'.toLowerCase().contains(q)).toList();
      return AppBackground(
        child: Directionality(
          textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                JphUi.header(context, isDark: isDark, isRTL: isRTL, title: p == null ? 'المشروع' : '${p['name']}',
                    action: manage && p != null
                        ? IconButton(
                            icon: Icon(Icons.edit_rounded, color: JphUi.primary(isDark)),
                            tooltip: 'تعديل المشروع',
                            onPressed: () async {
                              final saved = await Navigator.push(context, MaterialPageRoute(builder: (_) => ProjectFormPage(project: p)));
                              if (saved == true) _load();
                            },
                          )
                        : null),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : p == null
                          ? Center(child: Text('المشروع مش موجود', style: TextStyle(color: JphUi.sub(isDark))))
                          : RefreshIndicator(
                              onRefresh: _load,
                              child: Center(
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 1100),
                                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 60), children: [
                                    _split(isDark, p),
                                    const SizedBox(height: 12),
                                    _stats(isDark, p),
                                    const SizedBox(height: 18),
                                    Row(children: [
                                      Text('الوحدات المباعة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                                      const Spacer(),
                                      Text('${shown.length} وحدة', style: TextStyle(color: JphUi.sub(isDark), fontWeight: FontWeight.w700)),
                                    ]),
                                    const SizedBox(height: 8),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12),
                                      decoration: JphUi.box(isDark),
                                      child: TextField(
                                        controller: _q,
                                        onChanged: (_) => setState(() {}),
                                        decoration: InputDecoration(hintText: 'ابحث برقم الوحدة أو اسم البائع', border: InputBorder.none,
                                            prefixIcon: Icon(Icons.search_rounded, color: JphUi.primary(isDark))),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    if (shown.isEmpty)
                                      Padding(padding: const EdgeInsets.all(30), child: Text('مفيش وحدات معتمدة', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark))))
                                    else
                                      LayoutBuilder(builder: (context, c) => c.maxWidth >= 760 ? _table(isDark, shown) : Column(children: [for (final u in shown) _unitCard(isDark, u)])),
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
    });
  }

  Widget _split(bool isDark, Map<String, dynamic> p) {
    final parts = <(String, Object?, Color)>[
      ('البائع', p['salesPct'], Colors.teal),
      if (p['managerPct'] != null) ('مدير المبيعات', p['managerPct'], Colors.purple),
      if (p['companyPct'] != null) ('الشركة', p['companyPct'], Colors.green),
    ];
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          JphUi.iconTile(isDark, Icons.pie_chart_rounded, Colors.indigo),
          const SizedBox(width: 12),
          Expanded(child: Text('توزيع العمولة', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
          if (p['totalPct'] != null) JphUi.chip('الإجمالي ${JphUi.pct(p['totalPct'])}', Colors.blueGrey),
        ]),
        const SizedBox(height: 12),
        if (p['totalPct'] != null && (p['totalPct'] as num) > 0)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Row(children: [
              for (final x in parts)
                if (((x.$2 as num?) ?? 0) > 0)
                  Expanded(flex: (((x.$2 as num) * 10000).round()), child: Container(height: 12, color: x.$3)),
            ]),
          ),
        const SizedBox(height: 10),
        Wrap(spacing: 16, runSpacing: 6, children: [
          for (final x in parts)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: x.$3, shape: BoxShape.circle)),
              const SizedBox(width: 6),
              Text('${x.$1}: ${JphUi.pct(x.$2)}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
            ]),
        ]),
      ]),
    );
  }

  Widget _stats(bool isDark, Map<String, dynamic> p) {
    final company = p['companyCommission'] != null;
    final cards = [
      JphUi.stat(isDark, 'الوحدات المعتمدة', '${p['units'] ?? 0}', Icons.home_work_rounded, Colors.indigo),
      JphUi.stat(isDark, 'إجمالي المبيعات', JphUi.money(p['salesValue']), Icons.trending_up_rounded, Colors.blue),
      if (company) JphUi.stat(isDark, 'إجمالي العمولة', JphUi.money(p['totalCommission']), Icons.payments_rounded, Colors.teal)
      else JphUi.stat(isDark, 'عمولات البائعين', JphUi.money(p['salesCommission']), Icons.person_rounded, Colors.teal),
      if (company) JphUi.stat(isDark, 'أرباح الشركة', JphUi.money(p['companyCommission']), Icons.account_balance_rounded, Colors.green)
      else JphUi.stat(isDark, 'عمولات مدير المبيعات', JphUi.money(p['managerCommission']), Icons.groups_rounded, Colors.purple),
    ];
    return LayoutBuilder(builder: (context, c) {
      final cols = c.maxWidth > 700 ? 4 : 2;
      return GridView.count(crossAxisCount: cols, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: cols == 4 ? 2.1 : 1.75, children: cards);
    });
  }

  bool get _canVoid => JphBridge.session.isOwner;

  Widget _table(bool isDark, List<Map<String, dynamic>> units) {
    final company = units.any((u) => u['companyAmount'] != null);
    final manager = units.any((u) => u['managerAmount'] != null);
    TextStyle h = TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark), fontSize: 13);
    return Container(
      decoration: JphUi.box(isDark),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 46,
          columnSpacing: 22,
          columns: [
            DataColumn(label: Text('الوحدة', style: h)),
            DataColumn(label: Text('البائع', style: h)),
            DataColumn(label: Text('مدير المبيعات', style: h)),
            DataColumn(label: Text('سعر المتر', style: h), numeric: true),
            DataColumn(label: Text('المساحة', style: h), numeric: true),
            DataColumn(label: Text('قيمة الوحدة', style: h), numeric: true),
            DataColumn(label: Text('عمولة البائع', style: h), numeric: true),
            if (manager) DataColumn(label: Text('عمولة المدير', style: h), numeric: true),
            if (company) DataColumn(label: Text('عمولة الشركة', style: h), numeric: true),
            DataColumn(label: Text('الاعتماد', style: h)),
            DataColumn(label: Text('شهر المرتب', style: h)),
            DataColumn(label: Text('الحالة', style: h)),
            if (_canVoid) DataColumn(label: Text('', style: h)),
          ],
          rows: [
            for (final u in units)
              DataRow(cells: [
                DataCell(Text('${u['unitNo']}', style: const TextStyle(fontWeight: FontWeight.w800))),
                DataCell(Text('${u['employeeName']}')),
                DataCell(Text('${u['salesManagerName'] ?? '—'}')),
                DataCell(Text(JphUi.money(u['pricePerM2']))),
                DataCell(Text('${u['areaM2']} م²')),
                DataCell(Text(JphUi.money(u['unitValue']), style: const TextStyle(fontWeight: FontWeight.w800))),
                DataCell(Text('${JphUi.money(u['salesAmount'])}\n${JphUi.pct(u['salesPct'])}')),
                if (manager) DataCell(Text(u['managerAmount'] == null ? '—' : '${JphUi.money(u['managerAmount'])}\n${JphUi.pct(u['managerPct'])}')),
                if (company) DataCell(Text(u['companyAmount'] == null ? '—' : '${JphUi.money(u['companyAmount'])}\n${JphUi.pct(u['companyPct'])}')),
                DataCell(Text(JphUi.date(u['decidedAt']))),
                DataCell(Text(JphUi.monthAr('${u['period']}'))),
                DataCell(_payChips(u)),
                if (_canVoid) DataCell(IconButton(icon: const Icon(Icons.block_rounded, color: Colors.red), tooltip: 'إلغاء', onPressed: () => _void(u))),
              ]),
          ],
        ),
      ),
    );
  }

  Widget _payChips(Map<String, dynamic> u) {
    final pay = ((u['payroll'] as List?) ?? const []).whereType<Map>().toList();
    if (pay.isEmpty) return JphUi.chip(commissionStatus('${u['status']}').$1, commissionStatus('${u['status']}').$2);
    final allPaid = pay.every((x) => x['payment'] == 'paid');
    final s = allPaid ? 'paid' : pay.any((x) => x['payment'] == 'handed') ? 'handed' : 'unpaid';
    return JphUi.chip(paymentStatus(s).$1, paymentStatus(s).$2);
  }

  Widget _unitCard(bool isDark, Map<String, dynamic> u) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          JphUi.iconTile(isDark, Icons.home_work_rounded, Colors.indigo),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('وحدة ${u['unitNo']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
              Text('${u['employeeName']}${u['salesManagerName'] != null ? ' • مدير: ${u['salesManagerName']}' : ''}',
                  style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
            ]),
          ),
          _payChips(u),
        ]),
        const SizedBox(height: 10),
        Wrap(spacing: 14, runSpacing: 6, children: [
          Text('${u['areaM2']} م² × ${JphUi.money(u['pricePerM2'])}', style: TextStyle(color: JphUi.sub(isDark))),
          Text('القيمة: ${JphUi.money(u['unitValue'])}', style: const TextStyle(fontWeight: FontWeight.w800)),
          Text('البائع: ${JphUi.money(u['salesAmount'])}', style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.teal)),
          if (u['managerAmount'] != null) Text('المدير: ${JphUi.money(u['managerAmount'])}', style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.purple)),
          if (u['companyAmount'] != null) Text('الشركة: ${JphUi.money(u['companyAmount'])}', style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.green)),
          Text('اعتماد ${JphUi.date(u['decidedAt'])} • مرتب ${JphUi.monthAr('${u['period']}')}', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
        ]),
        if (_canVoid)
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(onPressed: () => _void(u), icon: const Icon(Icons.block_rounded, color: Colors.red),
                label: const Text('إلغاء العمولة', style: TextStyle(color: Colors.red))),
          ),
      ]),
    );
  }
}
