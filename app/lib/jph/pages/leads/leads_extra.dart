import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/save_file.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import 'leads_api.dart';
import 'quote_pdf.dart';

/// نظام الليدز — المرحلة التانية: the lead's files, the client's request and the units that match it, «وصلت الميتنج»,
/// the WhatsApp templates, and the Excel export.

// ==================================================================== Excel (.xlsx) writer
/// A one-sheet .xlsx (right-to-left), numbers as numbers.
Uint8List writeXlsx(String sheet, List<String> head, List<List<Object?>> rows) {
  String esc(String v) => v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;')
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');
  String col(int i) {
    var s = '';
    for (var n = i + 1; n > 0; n = (n - 1) ~/ 26) {
      s = String.fromCharCode(65 + (n - 1) % 26) + s;
    }
    return s;
  }

  String cell(int r, int c, Object? v, {bool bold = false}) {
    final ref = '${col(c)}${r + 1}';
    if (v is num && v.isFinite) return '<c r="$ref"><v>$v</v></c>';
    return '<c r="$ref" t="inlineStr"${bold ? ' s="1"' : ''}><is><t xml:space="preserve">${esc('${v ?? ''}')}</t></is></c>';
  }

  final b = StringBuffer('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView rightToLeft="1" workbookViewId="0"/></sheetViews>'
      '<sheetData><row r="1">');
  for (var c = 0; c < head.length; c++) {
    b.write(cell(0, c, head[c], bold: true));
  }
  b.write('</row>');
  for (var r = 0; r < rows.length; r++) {
    b.write('<row r="${r + 2}">');
    for (var c = 0; c < rows[r].length; c++) {
      b.write(cell(r + 1, c, rows[r][c]));
    }
    b.write('</row>');
  }
  b.write('</sheetData></worksheet>');
  final name = esc(sheet.length > 30 ? sheet.substring(0, 30) : sheet);
  final files = <String, String>{
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    'xl/workbook.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="$name" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
    'xl/styles.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>'
        '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
        '<borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs>'
        '<cellXfs count="2"><xf fontId="0"/><xf fontId="1" applyFont="1"/></cellXfs></styleSheet>',
    'xl/worksheets/sheet1.xml': b.toString(),
  };
  final zip = Archive();
  files.forEach((path, text) {
    final bytes = utf8.encode(text);
    zip.addFile(ArchiveFile(path, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(zip));
}

/// save a table as Excel and write it in the export log (who exported what)
Future<void> exportTable(BuildContext context, String kind, String fileName, List<String> head, List<List<Object?>> rows,
    {Map<String, Object?> filters = const {}}) async {
  final log = await lpost('/leads/exports', {'kind': kind, 'rows': rows.length, 'filters': filters}, ok: '');
  if (log['success'] != true) {
    if (context.mounted) JphUi.toast(context, log);
    return;
  }
  await saveXlsx(fileName, writeXlsx(kind, head, rows));
  if (context.mounted) JphUi.toast(context, {'success': true, 'message': tr('اتحفظ ملف الإكسيل ✅')});
}

// ==================================================================== location (وصلت الميتنج)
Future<Position?> gpsNow() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
    return await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)));
  } catch (_) {
    return null;
  }
}

Future<bool> leadCheckIn(BuildContext context, bool isDark, Map<String, dynamic> lead) async {
  final note = TextEditingController();
  return leadForm(context, isDark, tr('وصلت الميتنج 📍'), (set) => [
        Text('هيتسجل مكانك ووقتك دلوقتي مع العميل ${lead['fullName']}، والعميل يتنقل لـ «متابعة بعد الميتنج».',
            style: TextStyle(color: JphUi.sub(isDark))),
        JphUi.input(isDark: isDark, label: tr('ملاحظة (اختياري)'), controller: note, icon: Icons.notes_rounded, big: false),
      ], () async {
    final p = await gpsNow();
    if (p == null) {
      if (context.mounted) JphUi.toast(context, {'success': false, 'message': tr('شغّل الموقع (GPS) واسمح للتطبيق بيه')});
      return false;
    }
    final r = await lpost('/leads/${lead['id']}/checkins', {'lat': p.latitude, 'lng': p.longitude, 'accuracy': p.accuracy, 'note': note.text.trim()},
        ok: tr('اتسجل وصولك ✅'));
    if (context.mounted) JphUi.toast(context, r);
    return r['success'] == true;
  }, saveLabel: tr('سجّل وصولي'), saveIcon: Icons.where_to_vote_rounded);
}

// ==================================================================== WhatsApp templates
/// pick a ready message, fill the client's name / project / salesman / company, open WhatsApp with it
Future<void> whatsAppWithTemplate(BuildContext context, bool isDark, Map<String, dynamic> lead) async {
  final r = await lget('/leads/templates');
  if (!context.mounted) return;
  final list = ll(r['templates']);
  final pick = await JphUi.sheet<String>(context, isDark, tr('رسالة واتساب'), [
    ('', tr('رسالة فاضية'), Icons.chat_bubble_outline_rounded),
    for (final t in list) ('${t['id']}', '${t['name']}', Icons.chat_rounded),
  ]);
  if (pick == null) return;
  var text = '';
  if (pick.isNotEmpty) {
    final t = list.firstWhere((x) => '${x['id']}' == pick, orElse: () => const {});
    text = '${t['body'] ?? ''}'
        .replaceAll('{الاسم}', '${lead['fullName'] ?? ''}')
        .replaceAll('{المشروع}', '${lm(lead['project'])['name'] ?? ''}')
        .replaceAll('{السيلز}', '${lm(lead['assignedTo'])['name'] ?? ''}')
        .replaceAll('{الشركة}', '${r['companyName'] ?? ''}');
  }
  await whatsApp('${lead['phone']}', text: text);
}

// ==================================================================== the lead's files / request / check-ins
class LeadExtra extends StatefulWidget {
  final bool isDark;
  final Map<String, dynamic> lead;
  final Map<String, dynamic> meta;
  final bool canWork;
  final String part; // files | request | checkins
  const LeadExtra({super.key, required this.isDark, required this.lead, required this.meta, required this.canWork, required this.part});

  @override
  State<LeadExtra> createState() => _LeadExtraState();
}

class _LeadExtraState extends State<LeadExtra> {
  Map<String, dynamic>? _x;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await lget('/leads/${widget.lead['id']}/extra');
    if (mounted) setState(() => _x = r);
  }

  bool get isDark => widget.isDark;

  @override
  Widget build(BuildContext context) {
    final x = _x;
    if (x == null) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
    if (x['success'] == false) return Text('${x['message']}', style: TextStyle(color: JphUi.sub(isDark)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: switch (widget.part) {
      'files' => _files(ll(x['attachments'])),
      'request' => _request(x['request'] == null ? null : lm(x['request']), ll(x['matches'])),
      _ => _checkins(ll(x['checkins'])),
    });
  }

  // ---------------------------------------------------------------- files
  List<Widget> _files(List<Map<String, dynamic>> files) => [
        if (widget.canWork)
          leadBtn(isDark, tr('ارفع ملف (صورة / PDF — لحد 3 ميجا)'), Icons.upload_file_rounded, _upload, outline: true),
        const SizedBox(height: 8),
        if (files.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('مفيش ملفات'), textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final f in files)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: JphUi.box(isDark),
            child: ListTile(
              leading: Icon('${f['mime']}'.startsWith('image/') ? Icons.image_rounded : '${f['mime']}'.contains('pdf') ? Icons.picture_as_pdf_rounded : Icons.insert_drive_file_rounded,
                  color: Ar.accent),
              title: Text('${f['fileName']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              subtitle: Text('${((f['size'] as num? ?? 0) / 1024).toStringAsFixed(0)} KB — ${f['byName'] ?? ''} — ${whenAr(f['at'])}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(tooltip: tr('تحميل'), icon: const Icon(Icons.download_rounded), onPressed: () => _download(f)),
                IconButton(tooltip: tr('مسح'), icon: const Icon(Icons.delete_outline_rounded, color: Ar.red), onPressed: () => _delete(f)),
              ]),
            ),
          ),
      ];

  Future<void> _upload() async {
    final f = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'pdf', 'doc', 'docx', 'xlsx'], withData: true);
    final x = f?.files.firstOrNull;
    if (x?.bytes == null) return;
    if (x!.bytes!.length > 3000000) {
      if (mounted) JphUi.toast(context, {'success': false, 'message': tr('الملف أكبر من 3 ميجا — صغّره وجرّب تاني')});
      return;
    }
    final ext = (x.extension ?? '').toLowerCase();
    final mime = switch (ext) {
      'jpg' || 'jpeg' => 'image/jpeg', 'png' => 'image/png', 'webp' => 'image/webp', 'pdf' => 'application/pdf',
      'doc' => 'application/msword', 'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', _ => 'application/octet-stream',
    };
    final r = await lpost('/leads/${widget.lead['id']}/attachments', {'fileName': x.name, 'mime': mime, 'data': base64Encode(x.bytes!)}, ok: tr('اترفع الملف ✅'));
    if (mounted) JphUi.toast(context, r);
    _load();
  }

  Future<void> _download(Map<String, dynamic> f) async {
    final r = await lget('/leads/attachments/${f['id']}');
    if (r['success'] != true) {
      if (mounted) JphUi.toast(context, r);
      return;
    }
    final name = '${r['fileName']}';
    final dot = name.lastIndexOf('.');
    await saveBytes(dot > 0 ? name.substring(0, dot) : name, dot > 0 ? name.substring(dot + 1) : 'bin', base64Decode('${r['data']}'));
    if (mounted) JphUi.toast(context, {'success': true, 'message': tr('اتحفظ الملف ✅')});
  }

  Future<void> _delete(Map<String, dynamic> f) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('تمسح الملف؟')),
        content: Text('${f['fileName']}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('لأ'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('امسح'), style: TextStyle(color: Ar.red))),
        ],
      ),
    );
    if (yes != true) return;
    final r = await lpost('/leads/attachments/${f['id']}/delete', {}, ok: tr('اتمسح'));
    if (mounted) JphUi.toast(context, r);
    _load();
  }

  // ---------------------------------------------------------------- request + matching units
  List<Widget> _request(Map<String, dynamic>? rq, List<Map<String, dynamic>> units) {
    String fmt(Object? v) => v == null ? '' : JphUi.money(v);
    final pay = {'any': tr('أي طريقة'), 'cash': tr('كاش'), 'installments': tr('تقسيط')}[rq?['payment']] ?? '';
    return [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: JphUi.box(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr('العميل عايز إيه'), style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: JphUi.text(isDark))),
          const SizedBox(height: 6),
          if (rq == null) Text(tr('لسه ماتسجلش طلب العميل'), style: TextStyle(color: JphUi.sub(isDark))),
          if (rq != null)
            Wrap(spacing: 6, runSpacing: 6, children: [
              if (rq['projectName'] != null) JphUi.chip('${rq['projectName']}', Ar.accent),
              if ('${rq['unitType'] ?? ''}'.isNotEmpty) JphUi.chip('${rq['unitType']}', Ar.info),
              if ('${rq['floor'] ?? ''}'.isNotEmpty) JphUi.chip('دور ${rq['floor']}', Ar.info),
              if (rq['minArea'] != null || rq['maxArea'] != null) JphUi.chip('${rq['minArea'] ?? '…'} - ${rq['maxArea'] ?? '…'} م²', Ar.tan),
              if (rq['maxPrice'] != null) JphUi.chip('لحد ${fmt(rq['maxPrice'])}', Ar.green),
              JphUi.chip(pay, Ar.amber),
            ]),
          if ('${rq?['notes'] ?? ''}'.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('${rq!['notes']}', style: TextStyle(color: JphUi.sub(isDark)))),
          if (widget.canWork) ...[
            const SizedBox(height: 10),
            leadBtn(isDark, rq == null ? tr('سجّل طلب العميل') : tr('عدّل الطلب'), Icons.manage_search_rounded, () => _editRequest(rq), outline: true),
          ],
        ]),
      ),
      const SizedBox(height: 12),
      if (rq != null) ...[
        Text('وحدات متاحة مناسبة (${units.length})', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: JphUi.text(isDark))),
        const SizedBox(height: 6),
        if (units.isEmpty) Text(tr('مفيش وحدة متاحة بالمواصفات دي دلوقتي'), style: TextStyle(color: JphUi.sub(isDark))),
        for (final u in units) unitCard(context, isDark, u, widget.lead),
      ],
    ];
  }

  Future<void> _editRequest(Map<String, dynamic>? rq) async {
    String? project = rq?['projectId']?.toString() ?? lm(widget.lead['project'])['id']?.toString();
    String payment = '${rq?['payment'] ?? 'any'}';
    final type = TextEditingController(text: '${rq?['unitType'] ?? ''}'), floor = TextEditingController(text: '${rq?['floor'] ?? ''}'),
        minA = TextEditingController(text: rq?['minArea'] == null ? '' : '${rq!['minArea']}'),
        maxA = TextEditingController(text: rq?['maxArea'] == null ? '' : '${rq!['maxArea']}'),
        price = TextEditingController(text: rq?['maxPrice'] == null ? '' : '${rq!['maxPrice']}'),
        notes = TextEditingController(text: '${rq?['notes'] ?? ''}');
    final ok = await leadForm(context, isDark, tr('طلب العميل'), (set) => [
          refPicker(context, isDark, tr('المشروع'), Icons.apartment_rounded, ll(widget.meta['projects']), project, (v) => set(() => project = v)),
          JphUi.input(isDark: isDark, label: tr('نوع الوحدة (محل / عيادة / شقة …)'), controller: type, icon: Icons.category_rounded, big: false),
          JphUi.input(isDark: isDark, label: tr('الدور (اختياري)'), controller: floor, icon: Icons.layers_rounded, big: false),
          Row(children: [
            Expanded(child: JphUi.input(isDark: isDark, label: tr('أقل مساحة'), controller: minA, number: true, suffix: tr('م²'), big: false)),
            const SizedBox(width: 8),
            Expanded(child: JphUi.input(isDark: isDark, label: tr('أقصى مساحة'), controller: maxA, number: true, suffix: tr('م²'), big: false)),
          ]),
          JphUi.input(isDark: isDark, label: tr('أقصى سعر'), controller: price, number: true, suffix: tr('جنيه'), icon: Icons.payments_rounded, big: false),
          SegmentedButton<String>(
            segments: [ButtonSegment(value: 'any', label: Text(tr('أي طريقة'))), ButtonSegment(value: 'cash', label: Text(tr('كاش'))),
              ButtonSegment(value: 'installments', label: Text(tr('تقسيط')))],
            selected: {payment},
            onSelectionChanged: (s) => set(() => payment = s.first),
          ),
          JphUi.input(isDark: isDark, label: tr('ملاحظات'), controller: notes, icon: Icons.notes_rounded, big: false),
        ], () async {
      num? n(TextEditingController c) => num.tryParse(c.text.replaceAll(',', '').trim());
      final r = await lpost('/leads/${widget.lead['id']}/request', {
        'projectId': project, 'unitType': type.text.trim(), 'floor': floor.text.trim(), 'minArea': n(minA), 'maxArea': n(maxA),
        'maxPrice': n(price), 'payment': payment, 'notes': notes.text.trim(),
      }, ok: tr('اتحفظ الطلب ✅'));
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  // ---------------------------------------------------------------- check-ins
  List<Widget> _checkins(List<Map<String, dynamic>> list) => [
        if (list.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('لسه محدش سجّل وصوله لميتنج مع العميل ده'), textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final c in list)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: JphUi.box(isDark),
            child: ListTile(
              leading: const Icon(Icons.where_to_vote_rounded, color: Ar.green),
              title: Text('${c['name']} — ${whenAr(c['at'])}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              subtitle: Text('${'${c['note'] ?? ''}'.isEmpty ? '' : '${c['note']} • '}دقة الموقع ${(c['accuracy'] as num?)?.round() ?? '?'} متر'),
              trailing: IconButton(
                tooltip: tr('افتح على الخريطة'),
                icon: const Icon(Icons.map_rounded),
                onPressed: () => openUrl('https://maps.google.com/?q=${c['lat']},${c['lng']}'),
              ),
            ),
          ),
      ];
}

/// an available unit: its data, and «عرض سعر» (a PDF with a payment plan, to send the client)
Widget unitCard(BuildContext context, bool isDark, Map<String, dynamic> u, Map<String, dynamic> lead) => Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: JphUi.box(isDark),
      child: Row(children: [
        JphUi.iconTile(isDark, Icons.storefront_rounded, Ar.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${u['projectName']} — وحدة ${u['unitNo']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            Text([
              if ('${u['unitType'] ?? ''}'.isNotEmpty) '${u['unitType']}',
              if ('${u['floor'] ?? ''}'.isNotEmpty) 'دور ${u['floor']}',
              if (u['area'] != null) '${u['area']} م²',
              if (u['price'] != null) JphUi.money(u['price']),
            ].join(' • '), style: TextStyle(color: JphUi.sub(isDark))),
          ]),
        ),
        TextButton.icon(
          onPressed: u['price'] == null ? null : () => showQuote(context, isDark, lead, u),
          icon: const Icon(Icons.request_quote_rounded, size: 18),
          label: Text(tr('عرض سعر')),
        ),
      ]),
    );
