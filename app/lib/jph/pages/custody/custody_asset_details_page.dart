import '../../widgets/side_sheet.dart';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/custody_asset_card.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/glass_ui.dart';

/// العهدة ← one item: its card, «تسليم العهدة إلى» (or «استلام العهدة» while it is with someone) and its history —
/// who had it, from when, when it came back and who received it.
class CustodyAssetDetailsPage extends StatefulWidget {
  final String assetId;
  const CustodyAssetDetailsPage({super.key, required this.assetId});

  @override
  State<CustodyAssetDetailsPage> createState() => _CustodyAssetDetailsPageState();
}

class _CustodyAssetDetailsPageState extends State<CustodyAssetDetailsPage> {
  Map<String, dynamic>? _asset;
  List<Map<String, dynamic>> _history = [];
  bool _canManage = false;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'cash_get', 'path': '/custody/assets/${widget.assetId}'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = r['success'] == true ? null : '${r['message'] ?? 'مش قادر أحمّل العهدة'}';
      _asset = (r['asset'] as Map?)?.cast<String, dynamic>();
      _canManage = r['canManage'] == true;
      _history = ((r['history'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    });
  }

  InputDecoration _input(bool isDark, String label) => InputDecoration(
        labelText: label,
        filled: true,
        fillColor: isDark ? Colors.white.withOpacity(0.06) : Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
      );

  Future<void> _sheet(bool isDark, String title, List<Widget> Function(StateSetter set) body) => showAppSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => Directionality(
          textDirection: ui.TextDirection.rtl,
          child: StatefulBuilder(
            builder: (ctx, set) => Padding(
              padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
              child: Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(16),
                decoration: Glass.sheet(isDark, r: 24),
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [
                    Expanded(child: Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                    IconButton(onPressed: () => Navigator.pop(ctx), icon: Icon(Icons.close_rounded, color: JphUi.sub(isDark))),
                  ]),
                  const SizedBox(height: 8),
                  ...body(set),
                ]),
              ),
            ),
          ),
        ),
      );

  Widget _button(bool isDark, String label, Color color, Future<void> Function() onTap) => SizedBox(
        height: 52,
        child: ElevatedButton(
          onPressed: onTap,
          style: ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          child: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        ),
      );

  /// تسليم العهدة إلى: pick the employee, condition and notes.
  Future<void> _handOver(bool isDark) async {
    final r0 = await ApiService.post({'action': 'getActiveEmployees'});
    if (!mounted) return;
    final emps = ((r0['employees'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    String? empId, empName;
    String cond = 'good';
    final notes = TextEditingController();
    await _sheet(isDark, 'تسليم العهدة إلى', (set) => [
          JphUi.picker(
            isDark: isDark, icon: Icons.person_rounded, iconColor: Ar.green, label: 'الموظف *',
            value: empName ?? (emps.isEmpty ? 'جاري التحميل...' : 'اختار الموظف'),
            onTap: emps.isEmpty
                ? null
                : () async {
                    final v = await JphUi.sheet<String>(context, isDark, 'الموظف',
                        [for (final e in emps) ('${e['id']}', '${e['name'] ?? ''}', Icons.person_outline_rounded)], selected: empId);
                    if (v != null) set(() { empId = v; empName = '${emps.firstWhere((e) => '${e['id']}' == v)['name']}'; });
                  },
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            value: cond, decoration: _input(isDark, 'الحالة وقت التسليم'),
            items: custodyCondAr.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
            onChanged: (v) => set(() => cond = v ?? cond),
          ),
          const SizedBox(height: 10),
          TextField(controller: notes, decoration: _input(isDark, 'ملاحظات')),
          const SizedBox(height: 16),
          _button(isDark, 'تسليم', JphUi.primary(isDark), () async {
            if (empId == null) {
              JphUi.toast(context, {'success': false, 'message': 'اختار الموظف'});
              return;
            }
            final r = await ApiService.post({'action': 'custody_assign', 'id': empId, 'assetId': widget.assetId, 'condition': cond, 'notes': notes.text.trim()});
            if (!mounted) return;
            Navigator.pop(context);
            JphUi.toast(context, r);
            _load();
          }),
        ]);
  }

  /// استلام العهدة: back (with its condition) or lost.
  Future<void> _receive(bool isDark) async {
    final holder = (_asset?['holder'] as Map?) ?? const {};
    String outcome = 'returned', cond = 'good';
    final notes = TextEditingController();
    await _sheet(isDark, 'استلام العهدة من ${holder['name'] ?? ''}', (set) => [
          SegmentedButton<String>(
            segments: const [ButtonSegment(value: 'returned', label: Text('رجعت')), ButtonSegment(value: 'lost', label: Text('مفقودة'))],
            selected: {outcome},
            onSelectionChanged: (s) => set(() => outcome = s.first),
          ),
          const SizedBox(height: 10),
          if (outcome == 'returned')
            DropdownButtonFormField<String>(
              value: cond, decoration: _input(isDark, 'الحالة وقت الاستلام'),
              items: custodyCondAr.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) => set(() => cond = v ?? cond),
            ),
          const SizedBox(height: 10),
          TextField(controller: notes, decoration: _input(isDark, 'ملاحظات')),
          const SizedBox(height: 16),
          _button(isDark, 'تأكيد', outcome == 'lost' ? Ar.red : Ar.green, () async {
            final r = await ApiService.post({'action': 'custody_close', 'itemId': holder['custodyId'], 'outcome': outcome,
              if (outcome == 'returned') 'condition': cond, 'notes': notes.text.trim()});
            if (!mounted) return;
            Navigator.pop(context);
            JphUi.toast(context, r);
            _load();
          }),
        ]);
  }

  Widget _historyRow(bool isDark, Map<String, dynamic> h) {
    final st = '${h['status']}';
    final color = st == 'assigned' ? Ar.green : st == 'lost' ? Ar.red : Ar.accent;
    final lines = <String>[
      'استلمها: ${custodyDay(h['assignedOn'])}${'${h['assignedByName'] ?? ''}'.isEmpty ? '' : ' — سلّمها ${h['assignedByName']}'}'
          '${custodyCondAr[h['conditionOut']] == null ? '' : ' (${custodyCondAr[h['conditionOut']]})'}',
      if (st == 'returned')
        'رجّعها: ${custodyDay(h['returnedOn'])}${'${h['receivedByName'] ?? ''}'.isEmpty ? '' : ' — استلمها ${h['receivedByName']}'}'
            '${custodyCondAr[h['conditionIn']] == null ? '' : ' (${custodyCondAr[h['conditionIn']]})'}',
      if (st == 'lost') 'اتسجلت مفقودة: ${custodyDay(h['closedAt'])}${'${h['receivedByName'] ?? ''}'.isEmpty ? '' : ' — سجّلها ${h['receivedByName']}'}',
      if ('${h['notes'] ?? ''}'.trim().isNotEmpty) 'ملاحظات: ${'${h['notes']}'.trim()}',
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        JphUi.iconTile(isDark, st == 'assigned' ? Icons.person_rounded : st == 'lost' ? Icons.report_rounded : Icons.assignment_return_rounded, color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('${h['employeeName'] ?? ''}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
              Text(st == 'assigned' ? 'معاه دلوقتي' : st == 'lost' ? 'مفقودة' : 'رجعت',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: color)),
            ]),
            const SizedBox(height: 4),
            for (final l in lines) Text(l, style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
          ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final a = _asset;
    final held = a?['holder'] != null;
    return AppBackground(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: isDark, isRTL: true, title: a == null ? 'العهدة' : '${a['name']}'),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 60), children: [
                    if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
                    if (!_loading && _error != null) Padding(padding: const EdgeInsets.all(30), child: Text(_error!, textAlign: TextAlign.center)),
                    if (a != null) ...[
                      CustodyAssetCard(asset: a, isDark: isDark),
                      if (_canManage && a['status'] == 'active') ...[
                        const SizedBox(height: 4),
                        held
                            ? _button(isDark, 'استلام العهدة', Ar.green, () => _receive(isDark))
                            : _button(isDark, 'تسليم العهدة إلى', JphUi.primary(isDark), () => _handOver(isDark)),
                      ],
                      const SizedBox(height: 18),
                      Text('سجل العهدة', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                      const SizedBox(height: 10),
                      if (_history.isEmpty)
                        Padding(padding: const EdgeInsets.all(20), child: Text('لسه متسلمتش لحد', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
                      for (final h in _history) _historyRow(isDark, h),
                    ],
                  ]),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
