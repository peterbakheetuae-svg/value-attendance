import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/app_controller.dart';
import '../services/jph_bridge.dart';
import '../theme/app_colors.dart';
import 'app_background.dart';
import 'glass_ui_widgets.dart';
import 'glass_dialog.dart';

/// Employee documents (acknowledgment PDF, job description PDF, ID image) and custody sections —
/// same glass cards as the rest of the profile. Files are fetched with the session token only.

const docTitles = {
  'acknowledgment': 'إقرار وتعهد الموظف (PDF)',
  'job_description': 'الوصف الوظيفي (PDF)',
  'national_id': 'صورة إثبات الشخصية',
};
const _maxBytes = 4 * 1024 * 1024;

class PickedDoc {
  final String fileName;
  final String mime;
  final Uint8List bytes;
  PickedDoc(this.fileName, this.mime, this.bytes);
  String get base64 => base64Encode(bytes);
}

String _mimeOf(String name) {
  final n = name.toLowerCase();
  if (n.endsWith('.pdf')) return 'application/pdf';
  if (n.endsWith('.png')) return 'image/png';
  if (n.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
}

/// Pick a PDF (acknowledgment / job description) or an image (national ID). Returns null + shows why.
Future<PickedDoc?> pickDocument(BuildContext context, String kind) async {
  final pdf = kind != 'national_id';
  final res = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: pdf ? ['pdf'] : ['jpg', 'jpeg', 'png', 'webp'],
    withData: true,
  );
  final f = res?.files.firstOrNull;
  if (f == null || f.bytes == null) return null;
  String? err;
  if (f.bytes!.length > _maxBytes) err = 'حجم الملف أكبر من 4 ميجا';
  final mime = _mimeOf(f.name);
  if (pdf && mime != 'application/pdf') err = 'لازم يكون ملف PDF';
  if (!pdf && !mime.startsWith('image/')) err = 'لازم تكون صورة';
  if (err != null) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err), backgroundColor: Colors.red));
    return null;
  }
  return PickedDoc(f.name, mime, f.bytes!);
}

/// Open a private document: images in a dialog, PDFs in a preview page (print / share / save).
Future<void> openDocument(BuildContext context, {required String id, required String mime, required String name}) async {
  try {
    final bytes = await JphBridge.api.bytes('/documents/$id');
    if (!context.mounted) return;
    if (mime.startsWith('image/')) {
      await showDialog<void>(
        context: context,
        builder: (d) => GlassDialogPanel(
          insetPadding: const EdgeInsets.all(12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.all(12), child: Text(name, style: const TextStyle(fontWeight: FontWeight.w700))),
            Flexible(child: InteractiveViewer(child: Image.memory(bytes))),
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('إغلاق')),
          ]),
        ),
      );
    } else {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, title: Text(name)),
          body: PdfPreview(build: (_) async => bytes, pdfFileName: name, canChangePageFormat: false, canChangeOrientation: false, canDebug: false),
        ),
      )));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('مش قادر أفتح الملف — ممكن مش عندك صلاحية'), backgroundColor: Colors.red));
    }
  }
}

String _date(Object? iso) {
  final d = DateTime.tryParse('$iso')?.toLocal();
  if (d == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

Widget _sectionTitle(String t, IconData icon) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 10),
      child: Row(children: [Icon(icon, color: AppColors.primary), const SizedBox(width: 8),
        Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))]),
    );

// ============================================================ documents
class EmployeeDocumentsSection extends StatefulWidget {
  final String employeeId;
  const EmployeeDocumentsSection({super.key, required this.employeeId});
  @override
  State<EmployeeDocumentsSection> createState() => _EmployeeDocumentsSectionState();
}

class _EmployeeDocumentsSectionState extends State<EmployeeDocumentsSection> {
  Map<String, dynamic>? _d;
  bool _hidden = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'employee_documents', 'id': widget.employeeId});
    if (!mounted) return;
    setState(() {
      _hidden = r['success'] != true; // no permission → the section is not shown
      _d = r['success'] == true ? r : null;
    });
  }

  Future<void> _replace(String kind) async {
    final f = await pickDocument(context, kind);
    if (f == null) return;
    setState(() => _busy = true);
    final r = await ApiService.post({'action': 'upload_document', 'id': widget.employeeId, 'kind': kind, 'fileName': f.fileName, 'mime': f.mime, 'data': f.base64});
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Colors.green : Colors.red));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    final isDark = Provider.of<AppController>(context).isDark;
    final sub = TextStyle(fontSize: 12, color: isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight);
    if (_d == null) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
    final req = ((_d!['required'] as Map?) ?? {}).cast<String, dynamic>();
    final all = ((_d!['documents'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    final canManage = _d!['canManage'] == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _sectionTitle('المستندات', Icons.folder_shared_outlined),
      GlassCard(
        child: Column(children: [
          for (final k in docTitles.keys) ...[
            Builder(builder: (_) {
              final cur = (req[k] as Map?)?.cast<String, dynamic>();
              final history = all.where((d) => d['kind'] == k && d['replaced_at'] != null).toList();
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Icon(cur == null ? Icons.error_outline : (k == 'national_id' ? Icons.badge_outlined : Icons.picture_as_pdf_outlined),
                      color: cur == null ? Colors.orange : AppColors.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(docTitles[k]!, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(cur == null ? 'مش مرفوع' : '${_date(cur['created_at'])} • ${cur['uploaded_by_name'] ?? ''}', style: sub),
                  ])),
                  if (cur != null)
                    IconButton(icon: const Icon(Icons.visibility_outlined), tooltip: 'عرض',
                        onPressed: () => openDocument(context, id: '${cur['id']}', mime: '${cur['mime']}', name: docTitles[k]!)),
                  if (canManage)
                    IconButton(icon: Icon(cur == null ? Icons.upload_file_rounded : Icons.sync_rounded), tooltip: cur == null ? 'رفع' : 'استبدال',
                        onPressed: _busy ? null : () => _replace(k)),
                ]),
                if (history.isNotEmpty)
                  Theme(
                    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: Text('نسخ سابقة (${history.length})', style: sub),
                      children: history.map((h) => ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text('${h['file_name']}'),
                            subtitle: Text('رُفع ${_date(h['created_at'])} • اتغيّر ${_date(h['replaced_at'])}'),
                            trailing: IconButton(icon: const Icon(Icons.visibility_outlined),
                                onPressed: () => openDocument(context, id: '${h['id']}', mime: '${h['mime']}', name: '${h['file_name']}')),
                          )).toList(),
                    ),
                  ),
                const Divider(height: 18),
              ]);
            }),
          ],
          if (_busy) const LinearProgressIndicator(),
        ]),
      ),
    ]);
  }
}

// ============================================================ custody
const custodyTypes = {'laptop': 'لابتوب', 'mobile': 'موبايل', 'sim': 'شريحة', 'keys': 'مفاتيح', 'equipment': 'معدات', 'car': 'عربية', 'other': 'أخرى'};
const _conditions = {'new': 'جديد', 'good': 'كويس', 'fair': 'مقبول', 'damaged': 'تالف'};

class EmployeeCustodySection extends StatefulWidget {
  final String employeeId;
  const EmployeeCustodySection({super.key, required this.employeeId});
  @override
  State<EmployeeCustodySection> createState() => _EmployeeCustodySectionState();
}

class _EmployeeCustodySectionState extends State<EmployeeCustodySection> {
  List<Map<String, dynamic>>? _items;
  bool _canManage = false;
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'employee_custody', 'id': widget.employeeId});
    if (!mounted) return;
    setState(() {
      _hidden = r['success'] != true;
      _items = ((r['items'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
      _canManage = r['canManage'] == true;
    });
  }

  void _snack(Map<String, dynamic> r) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Colors.green : Colors.red));

  InputDecoration _input(String l) => InputDecoration(labelText: l, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)));

  Widget _sheet(BuildContext ctx, String title, List<Widget> children) {
    final isDark = Provider.of<AppController>(ctx, listen: false).isDark;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? Colors.grey.shade900.withOpacity(0.98) : Colors.white.withOpacity(0.98),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2)))),
          const SizedBox(height: 14),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          ...children,
        ])),
      ),
    );
  }

  Widget _save(VoidCallback onTap, [String label = 'حفظ', Color color = AppColors.primary]) => SizedBox(
        height: 52,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: color, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
        ),
      );

  /// تسليم عهدة: pick one of the items added in Settings → العهدة that is not with anyone.
  Future<void> _assign() async {
    final r0 = await ApiService.post({'action': 'cash_get', 'path': '/custody/assets', 'query': {'available': '1'}});
    if (!mounted) return;
    final assets = ((r0['assets'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    if (assets.isEmpty) {
      _snack({'success': false, 'message': r0['success'] == true ? 'مفيش عهدة متاحة — ضيفها الأول من الإعدادات ← العهدة' : '${r0['message'] ?? ''}'});
      return;
    }
    final notes = TextEditingController();
    String cond = 'good';
    String? assetId;
    await showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) => _sheet(ctx, 'تسليم عهدة', [
            DropdownButtonFormField<String>(value: assetId, isExpanded: true, decoration: _input('العهدة *'),
                items: [
                  for (final a in assets)
                    DropdownMenuItem(value: '${a['id']}',
                        child: Text('${a['typeAr'] ?? ''}: ${a['name']}${'${a['serialNo'] ?? ''}'.isEmpty ? '' : ' — ${a['serialNo']}'}',
                            overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => set(() => assetId = v)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(value: cond, decoration: _input('الحالة وقت التسليم'),
                items: _conditions.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(), onChanged: (v) => set(() => cond = v ?? cond)),
            const SizedBox(height: 10),
            TextField(controller: notes, decoration: _input('ملاحظات')),
            const SizedBox(height: 16),
            _save(() async {
              if (assetId == null) return;
              final r = await ApiService.post({'action': 'custody_assign', 'id': widget.employeeId, 'assetId': assetId, 'condition': cond,
                'notes': notes.text.trim()});
              if (ctx.mounted) Navigator.pop(ctx);
              _snack(r);
            }),
          ])),
    );
    _load();
  }

  Future<void> _close(Map<String, dynamic> it) async {
    String outcome = 'returned', cond = 'good';
    final notes = TextEditingController();
    await showModalBottomSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) => _sheet(ctx, 'استلام العهدة: ${it['asset_name']}', [
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'returned', label: Text('رجعت')), ButtonSegment(value: 'lost', label: Text('مفقودة'))],
              selected: {outcome},
              onSelectionChanged: (s) => set(() => outcome = s.first),
            ),
            const SizedBox(height: 10),
            if (outcome == 'returned')
              DropdownButtonFormField<String>(value: cond, decoration: _input('الحالة وقت الاستلام'),
                  items: _conditions.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(), onChanged: (v) => set(() => cond = v ?? cond)),
            const SizedBox(height: 10),
            TextField(controller: notes, decoration: _input('ملاحظات')),
            const SizedBox(height: 16),
            _save(() async {
              final r = await ApiService.post({'action': 'custody_close', 'itemId': it['id'], 'outcome': outcome,
                if (outcome == 'returned') 'condition': cond, 'notes': notes.text.trim()});
              if (ctx.mounted) Navigator.pop(ctx);
              _snack(r);
            }, 'تأكيد', outcome == 'lost' ? AppColors.error : AppColors.success),
          ])),
    );
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    final isDark = Provider.of<AppController>(context).isDark;
    final sub = TextStyle(fontSize: 12, color: isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight);
    final items = _items;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: _sectionTitle('العُهد', Icons.inventory_2_outlined)),
        if (_canManage) TextButton.icon(onPressed: _assign, icon: const Icon(Icons.add), label: const Text('تسليم عهدة')),
      ]),
      if (items == null) const Center(child: CircularProgressIndicator())
      else if (items.isEmpty) GlassCard(child: Text('مفيش عُهد مسجلة', textAlign: TextAlign.center, style: sub))
      else ...items.map((it) {
        final open = it['status'] == 'assigned';
        final status = {'assigned': 'مع الموظف', 'returned': 'رجعت', 'lost': 'مفقودة'}[it['status']] ?? '';
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GlassCard(
            child: Row(children: [
              Icon(open ? Icons.inventory_2_rounded : Icons.history_rounded, color: open ? AppColors.primary : Colors.grey),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${custodyTypes[it['asset_type']] ?? ''}: ${it['asset_name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                if ('${it['serial_no'] ?? ''}'.isNotEmpty) Text('S/N ${it['serial_no']}', style: sub),
                Text('اتسلمت ${it['assigned_on']} من ${it['assigned_by_name']} • ${_conditions[it['condition_out']] ?? ''}', style: sub),
                if (!open) Text('$status ${it['returned_on'] ?? ''}${it['received_by_name'] != null ? ' • ${it['received_by_name']}' : ''}', style: sub),
                if ('${it['notes'] ?? ''}'.isNotEmpty) Text('${it['notes']}', style: sub),
              ])),
              if (open && _canManage)
                TextButton(onPressed: () => _close(it), child: const Text('استلام'))
              else
                Text(status, style: TextStyle(fontWeight: FontWeight.w700, color: open ? AppColors.primary : (it['status'] == 'lost' ? AppColors.error : Colors.green))),
            ]),
          ),
        );
      }),
    ]);
  }
}
