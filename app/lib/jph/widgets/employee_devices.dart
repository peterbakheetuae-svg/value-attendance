import 'package:flutter/material.dart' hide Text;
import '../../core/api.dart';
import '../services/jph_bridge.dart';
import 'glass_ui.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

/// ربط الحساب بأكتر من جهاز: the phones linked to one account. The first phone is linked by itself; any other
/// phone waits here until the general manager / administrative officer (or the owner) approves it. Only approved
/// phones can sign in. Shows nothing when the viewer may not see this employee's phones.
class EmployeeDevicesBox extends StatefulWidget {
  final String employeeId;
  final bool isDark;
  final VoidCallback? onChanged;
  /// HR (employee.manage) may unlink a phone too, but only the approvers approve / refuse
  final bool canManage;
  const EmployeeDevicesBox({super.key, required this.employeeId, required this.isDark, this.onChanged, this.canManage = false});

  @override
  State<EmployeeDevicesBox> createState() => _EmployeeDevicesBoxState();
}

class _EmployeeDevicesBoxState extends State<EmployeeDevicesBox> {
  List<Map<String, dynamic>>? _devices;
  bool _canApprove = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.employeeId.isEmpty) return;
    try {
      final r = await JphBridge.api.get('/employees/${widget.employeeId}/devices');
      if (!mounted) return;
      setState(() {
        _devices = ((r['devices'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
        _canApprove = r['canApprove'] == true;
      });
    } catch (_) {
      if (mounted) setState(() => _devices = null);
    }
  }

  Future<void> _act(Map<String, dynamic> d, String what) async {
    if (what == 'remove') {
      final sure = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('فك ربط الجهاز؟'),
          content: Text('«${d['label']}» هيخرج من الحساب ومش هيقدر يدخل تاني غير بموافقة جديدة.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('لأ')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('فك الربط', style: TextStyle(color: Ar.red))),
          ],
        ),
      );
      if (sure != true) return;
    }
    setState(() => _busy = true);
    String msg;
    bool ok = false;
    try {
      await JphBridge.api.post('/employees/${widget.employeeId}/devices/${d['id']}/$what', {});
      ok = true;
      msg = what == 'approve' ? 'اتوافق على الجهاز ✅' : what == 'reject' ? 'اترفض الجهاز' : 'اتفك ربط الجهاز';
    } on ApiException catch (e) {
      msg = e.status == 403 ? 'الموافقة للمدير العام أو المسؤول الإداري بس' : e.message;
    } catch (_) {
      msg = 'حصل خطأ، جرّب تاني';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: ok ? Ar.green : Ar.red));
    if (ok) {
      await _load();
      widget.onChanged?.call();
    }
  }

  static String _when(Object? iso) {
    final t = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (t == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}/${two(t.month)}/${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final list = _devices;
    if (list == null) return const SizedBox.shrink();
    final dark = widget.isDark;
    final fg = dark ? Colors.white : Colors.black87;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: Glass.tile(dark, r: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.devices_rounded, color: Ar.info.shade700),
          const SizedBox(width: 8),
          Expanded(child: Text('الأجهزة المربوطة بالحساب', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: fg))),
          IconButton(onPressed: _busy ? null : _load, icon: const Icon(Icons.refresh_rounded), tooltip: txs('تحديث')),
        ]),
        Text('أول جهاز بيتربط لوحده. أي جهاز تاني بيستنى موافقة المدير العام أو المسؤول الإداري، والحساب يدخل من الأجهزة الموافق عليها بس.',
            style: TextStyle(fontSize: 12.5, color: fg.withValues(alpha: 0.7))),
        const SizedBox(height: 8),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text('مفيش أجهزة لسه — أول جهاز يسجّل منه هيتربط تلقائي', style: TextStyle(color: fg.withValues(alpha: 0.7))),
          ),
        for (final d in list) _row(d, fg),
      ]),
    );
  }

  Widget _row(Map<String, dynamic> d, Color fg) {
    final st = '${d['status']}';
    final (color, text, icon) = switch (st) {
      'approved' => (Ar.green, 'موافق عليه', Icons.verified_rounded),
      'pending' => (Ar.amber, 'مستني الموافقة', Icons.hourglass_top_rounded),
      _ => (Ar.red, 'مرفوض', Icons.block_rounded),
    };
    final sub = <String>[
      text,
      if (st == 'pending') 'طلب ${_when(d['requestedAt'])}',
      if (st != 'pending' && d['decidedBy'] != null) 'بواسطة ${d['decidedBy']}',
      if (d['lastLoginAt'] != null) 'آخر دخول ${_when(d['lastLoginAt'])}',
    ].join(' • ');
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(10), border: Border.all(color: color.withValues(alpha: 0.35))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text('${d['label'] ?? 'جهاز'}', style: TextStyle(fontWeight: FontWeight.w600, color: fg))),
        ]),
        Padding(padding: const EdgeInsets.only(top: 2, right: 28), child: Text(sub, style: TextStyle(fontSize: 12, color: fg.withValues(alpha: 0.7)))),
        if (_canApprove || widget.canManage)
          Wrap(alignment: WrapAlignment.end, spacing: 4, children: [
            if (_canApprove && st != 'approved')
              TextButton.icon(onPressed: _busy ? null : () => _act(d, 'approve'),
                  icon: const Icon(Icons.check_circle_rounded, color: Ar.green), label: const Text('موافقة')),
            if (_canApprove && st == 'pending')
              TextButton.icon(onPressed: _busy ? null : () => _act(d, 'reject'),
                  icon: const Icon(Icons.cancel_rounded, color: Ar.red), label: const Text('رفض')),
            if (st == 'approved' || st == 'rejected')
              TextButton.icon(onPressed: _busy ? null : () => _act(d, 'remove'),
                  icon: Icon(Icons.phonelink_erase_rounded, color: Ar.grey.shade600), label: const Text('فك الربط')),
          ]),
      ]),
    );
  }
}
