import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/save_file.dart';
import '../../services/api_service.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';

/// مستندات وحدة في مشروع تسويق: «استمارة الحجز» و«عقد التعاقد» — صورة أو PDF (لحد 3 ميجا للملف).
/// In the reservation / contract forms the files are only picked; they are uploaded once the unit is saved.

const unitFileKinds = {'reservation_form': 'استمارة الحجز', 'contract': 'عقد التعاقد'};
const _maxBytes = 3000000;

class PickedUnitFile {
  final String name;
  final String mime;
  final Uint8List bytes;
  const PickedUnitFile(this.name, this.mime, this.bytes);
  bool get isPdf => mime == 'application/pdf';
}

String _size(int b) => b >= 1000000 ? '${(b / 1000000).toStringAsFixed(1)} ميجا' : '${(b / 1000).ceil()} كيلو';

/// كاميرا / صورة من الموبايل / ملف PDF → the file, or null (too big → a message).
Future<PickedUnitFile?> pickUnitFile(BuildContext context, bool isDark) async {
  final how = await JphUi.sheet<String>(context, isDark, 'رفع صورة أو PDF', [
    if (!kIsWeb) ('camera', 'صوّر بالكاميرا', Icons.photo_camera_rounded),
    ('gallery', 'صورة من الموبايل', Icons.photo_library_rounded),
    ('pdf', 'ملف PDF', Icons.picture_as_pdf_rounded),
  ]);
  if (how == null) return null;
  PickedUnitFile? f;
  try {
    if (how == 'pdf') {
      final r = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf'], withData: true);
      final x = r?.files.firstOrNull;
      if (x?.bytes != null) f = PickedUnitFile(x!.name, 'application/pdf', x.bytes!);
    } else {
      // photos are made smaller on the phone (a page stays readable)
      final x = await ImagePicker().pickImage(
          source: how == 'camera' ? ImageSource.camera : ImageSource.gallery, imageQuality: 75, maxWidth: 2000, maxHeight: 2000);
      if (x != null) {
        final bytes = await x.readAsBytes();
        final png = bytes.length > 3 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47;
        final name = x.name.isEmpty ? 'صورة.jpg' : x.name;
        f = PickedUnitFile(name, png ? 'image/png' : 'image/jpeg', bytes);
      }
    }
  } catch (_) {
    if (context.mounted) JphUi.toast(context, {'success': false, 'message': 'مقدرناش نفتح الملف'});
    return null;
  }
  if (f == null) return null;
  if (f.bytes.length > _maxBytes) {
    if (context.mounted) JphUi.toast(context, {'success': false, 'message': 'الملف أكبر من 3 ميجا — صغّره وجرّب تاني'});
    return null;
  }
  return f;
}

/// The field inside a form: «رفع استمارة الحجز» + the picked files (each can be removed before saving).
Widget unitFilesField(BuildContext context, bool isDark, StateSetter set, String label, List<PickedUnitFile> files) {
  return Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: Ar.accent.withValues(alpha: 0.45)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Icon(Icons.upload_file_rounded, color: Ar.accent),
        const SizedBox(width: 8),
        Expanded(child: Text(label, style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
        TextButton.icon(
          onPressed: files.length >= 10
              ? null
              : () async {
                  final f = await pickUnitFile(context, isDark);
                  if (f != null) set(() => files.add(f));
                },
          icon: const Icon(Icons.add_rounded),
          label: Text(files.isEmpty ? 'اختار' : 'ملف تاني'),
        ),
      ]),
      Text('صورة أو PDF (لحد 3 ميجا للملف)', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
      for (final f in files)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(children: [
            Icon(f.isPdf ? Icons.picture_as_pdf_rounded : Icons.image_rounded, color: f.isPdf ? Ar.red : Ar.info, size: 20),
            const SizedBox(width: 6),
            Expanded(child: Text(f.name, overflow: TextOverflow.ellipsis, style: TextStyle(color: JphUi.text(isDark)))),
            Text(_size(f.bytes.length), style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
            IconButton(
              tooltip: 'شيله',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => set(() => files.remove(f)),
            ),
          ]),
        ),
    ]),
  );
}

Future<Map<String, dynamic>> _call(String action, String path, [Map<String, dynamic>? body]) =>
    ApiService.post({'action': action, 'path': path, if (body != null) 'body': body, 'ok': 'تم ✅'});

/// Uploads the picked files of a saved unit; returns how many failed.
Future<int> uploadUnitFiles(String unitId, String kind, List<PickedUnitFile> files) async {
  var failed = 0;
  for (final f in files) {
    final r = await _call('cash_post', '/exclusive/units/$unitId/files', {'kind': kind, 'fileName': f.name, 'data': base64Encode(f.bytes)});
    if (r['success'] != true) failed++;
  }
  return failed;
}

/// The unit page's «المستندات»: the uploaded papers (open / delete) and an upload button per kind.
class UnitFilesSection extends StatefulWidget {
  final String unitId;
  final bool isDark;
  final List<Map<String, dynamic>> files;
  final bool canUpload;
  final bool contracted;
  final VoidCallback onChanged;
  const UnitFilesSection({super.key, required this.unitId, required this.isDark, required this.files, required this.canUpload,
      required this.contracted, required this.onChanged});

  @override
  State<UnitFilesSection> createState() => _UnitFilesSectionState();
}

class _UnitFilesSectionState extends State<UnitFilesSection> {
  bool _busy = false;

  bool get isDark => widget.isDark;

  Future<void> _add(String kind) async {
    final f = await pickUnitFile(context, isDark);
    if (f == null || !mounted) return;
    setState(() => _busy = true);
    final failed = await uploadUnitFiles(widget.unitId, kind, [f]);
    if (!mounted) return;
    setState(() => _busy = false);
    JphUi.toast(context, failed == 0 ? {'success': true, 'message': 'اترفع ✅'} : {'success': false, 'message': 'الرفع ماتمّش — جرّب تاني'});
    widget.onChanged();
  }

  Future<void> _open(Map<String, dynamic> f) async {
    final r = await _call('cash_get', '/exclusive/units/${widget.unitId}/files/${f['id']}');
    if (r['success'] != true) {
      if (mounted) JphUi.toast(context, r);
      return;
    }
    final bytes = base64Decode('${r['data']}');
    if (!mounted) return;
    if ('${r['mime']}'.startsWith('image/')) {
      await showDialog<void>(
        context: context,
        builder: (c) => Dialog(
          insetPadding: const EdgeInsets.all(12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Flexible(child: InteractiveViewer(maxScale: 5, child: Image.memory(bytes, fit: BoxFit.contain))),
            OverflowBar(alignment: MainAxisAlignment.end, children: [
              TextButton.icon(onPressed: () => _save(r, bytes), icon: const Icon(Icons.download_rounded), label: const Text('حفظ')),
              TextButton(onPressed: () => Navigator.pop(c), child: const Text('قفل')),
            ]),
          ]),
        ),
      );
    } else {
      await _save(r, bytes);
    }
  }

  Future<void> _save(Map<String, dynamic> r, Uint8List bytes) async {
    final name = '${r['fileName']}';
    final dot = name.lastIndexOf('.');
    await saveBytes(dot > 0 ? name.substring(0, dot) : name, dot > 0 ? name.substring(dot + 1) : ('${r['mime']}' == 'application/pdf' ? 'pdf' : 'jpg'), bytes);
    if (mounted) JphUi.toast(context, {'success': true, 'message': 'اتحفظ الملف ✅'});
  }

  Future<void> _delete(Map<String, dynamic> f) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('تمسح الملف؟'),
        content: Text('${f['fileName']}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('لأ')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('امسح', style: TextStyle(color: Ar.red))),
        ],
      ),
    );
    if (yes != true) return;
    final r = await _call('cash_post', '/exclusive/units/${widget.unitId}/files/${f['id']}/delete', {});
    if (mounted) JphUi.toast(context, r['success'] == true ? {'success': true, 'message': 'اتمسح'} : r);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final kinds = ['reservation_form', if (widget.contracted || widget.files.any((f) => f['kind'] == 'contract')) 'contract'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final k in kinds) ...[
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text(unitFileKinds[k]!, style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
        ),
        for (final f in widget.files.where((f) => f['kind'] == k))
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(f['mime'] == 'application/pdf' ? Icons.picture_as_pdf_rounded : Icons.image_rounded,
                color: f['mime'] == 'application/pdf' ? Ar.red : Ar.info),
            title: Text('${f['fileName']}', overflow: TextOverflow.ellipsis, style: TextStyle(color: JphUi.text(isDark))),
            subtitle: Text([if (f['byName'] != null) '${f['byName']}', _size(int.tryParse('${f['size']}') ?? 0)].join(' · ')),
            onTap: f['canOpen'] == false ? null : () => _open(f),
            trailing: f['canDelete'] == true
                ? IconButton(tooltip: 'مسح', icon: const Icon(Icons.delete_outline_rounded, color: Ar.red), onPressed: () => _delete(f))
                : const Icon(Icons.open_in_new_rounded, size: 18),
          ),
        if (!widget.files.any((f) => f['kind'] == k))
          Text('لسه مترفعش', style: TextStyle(color: JphUi.sub(isDark))),
        if (widget.canUpload)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _busy ? null : () => _add(k),
              icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.upload_file_rounded),
              label: Text('رفع ${unitFileKinds[k]}'),
            ),
          ),
      ],
    ]);
  }
}
