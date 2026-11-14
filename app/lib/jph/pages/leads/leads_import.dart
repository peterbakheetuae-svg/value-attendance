import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import 'leads_api.dart';

/// استيراد ليدز من ملف إكسيل (.xlsx) أو CSV — up to 1000 a time. The first row is the headers:
/// الاسم | الموبايل | موبايل 2 | الإيميل | الميزانية | المشروع | القناة | ملاحظات (Arabic or English names).
/// The project / channel / campaign / fresh-cold / salesmen picked here go to every row that doesn't say its own.
Future<bool> importLeads(BuildContext context, bool isDark, Map<String, dynamic> meta) async {
  List<Map<String, dynamic>> rows = [];
  String file = '';
  String? project, channel, campaign;
  String kind = 'fresh';
  List<String> assignees = [];
  final people = ll(meta['assignees']);
  String result = '';
  return leadForm(context, isDark, tr('استيراد ليدز من إكسيل'), (set) {
    final camps = ll(meta['campaigns']).where((c) => channel == null || c['channelId'] == null || c['channelId'] == channel).toList();
    return [
      Text(tr('أول صف في الملف هو العناوين: الاسم، الموبايل، موبايل 2، الإيميل، الميزانية، المشروع، القناة، ملاحظات.\n') +
          tr('أقصى 1000 عميل في المرة. الرقم المكرر بيروح لنفس السيلز بتاعه.'),
          style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
      leadBtn(isDark, file.isEmpty ? tr('اختار الملف (xlsx / csv)') : '$file — ${rows.length} عميل', Icons.upload_file_rounded, () async {
        final f = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['xlsx', 'csv', 'txt'], withData: true);
        final x = f?.files.firstOrNull;
        if (x?.bytes == null) return;
        try {
          final table = x!.name.toLowerCase().endsWith('.xlsx') ? readXlsx(x.bytes!) : readCsv(x.bytes!);
          final parsed = tableToLeads(table);
          set(() {
            file = x.name;
            rows = parsed;
            result = parsed.isEmpty ? 'مش لاقي عمود الاسم والموبايل في أول صف' : '';
          });
        } catch (_) {
          set(() => result = tr('الملف ده مش مقروء — احفظه xlsx أو CSV وجرّب تاني'));
        }
      }, outline: true),
      if (rows.isNotEmpty)
        Text('أول عميل: ${rows.first['fullName']} — ${rows.first['phone']}', style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
      refPicker(context, isDark, tr('المشروع (للصفوف اللي من غير مشروع)'), Icons.apartment_rounded, ll(meta['projects']), project, (v) => set(() => project = v)),
      refPicker(context, isDark, tr('القناة'), Icons.campaign_rounded, ll(meta['channels']), channel, (v) => set(() {
            channel = v;
            campaign = null;
          })),
      if (camps.isNotEmpty) refPicker(context, isDark, tr('الحملة'), Icons.ads_click_rounded, camps, campaign, (v) => set(() => campaign = v)),
      SegmentedButton<String>(
        segments: [ButtonSegment(value: 'fresh', label: Text(tr('فريش'))), ButtonSegment(value: 'cold', label: Text(tr('كولد كول')))],
        selected: {kind},
        onSelectionChanged: (s) => set(() => kind = s.first),
      ),
      JphUi.picker(
        isDark: isDark, icon: Icons.groups_rounded, iconColor: Ar.accent, label: tr('وزّع على'),
        value: assignees.isEmpty ? tr('من غير (تفضل مش متوزعة)') : '${assignees.length} سيلز بالدور',
        onTap: () async {
          final v = await pickPeople(context, isDark, tr('وزّع على'), people, selected: assignees);
          if (v != null) set(() => assignees = v);
        },
      ),
      if (result.isNotEmpty) Text(result, style: TextStyle(fontWeight: FontWeight.w800, color: Ar.red.shade700)),
    ];
  }, () async {
    if (rows.isEmpty) {
      JphUi.toast(context, {'success': false, 'message': tr('اختار الملف الأول')});
      return false;
    }
    if (rows.length > 1000) {
      JphUi.toast(context, {'success': false, 'message': 'الملف فيه ${rows.length} — أقصى 1000 في المرة'});
      return false;
    }
    final r = await lpost('/leads/import', {
      'rows': rows, 'kind': kind, 'projectId': project, 'channelId': channel, 'campaignId': campaign, 'assignees': assignees,
    }, ok: tr('اتستورد ✅'));
    if (r['success'] != true) {
      if (context.mounted) JphUi.toast(context, r);
      return false;
    }
    final failed = ll(r['failed']);
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(tr('نتيجة الاستيراد')),
          content: SingleChildScrollView(
            child: Text('اتضاف ${r['created']} عميل${(r['duplicates'] ?? 0) > 0 ? ' (منهم ${r['duplicates']} مكرر راح لسيلزه)' : ''}.'
                '${failed.isEmpty ? '' : '\n\nماتضافش ${failed.length}:\n${failed.take(50).map((f) => 'صف ${(f['row'] as num) + 1}: ${f['error']}').join('\n')}'}'),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('تمام')))],
        ),
      );
    }
    return true;
  }, saveLabel: tr('استورد'), saveIcon: Icons.cloud_upload_rounded);
}

/// the headers we understand → the field
final _headers = <String, String>{
  'الاسم': 'fullName', 'اسم العميل': 'fullName', 'name': 'fullName', 'full name': 'fullName', 'client': 'fullName',
  'الموبايل': 'phone', 'الرقم': 'phone', 'رقم الموبايل': 'phone', 'التليفون': 'phone', 'mobile': 'phone', 'phone': 'phone',
  'موبايل 2': 'phone2', 'رقم تاني': 'phone2', 'mobile 2': 'phone2', 'phone 2': 'phone2',
  'الإيميل': 'email', 'الايميل': 'email', 'email': 'email',
  'الميزانية': 'budget', 'budget': 'budget',
  'المشروع': 'project', 'project': 'project',
  'القناة': 'channel', 'channel': 'channel',
  'ملاحظات': 'notes', 'notes': 'notes', 'comment': 'notes',
};

List<Map<String, dynamic>> tableToLeads(List<List<String>> t) {
  if (t.isEmpty) return [];
  final head = t.first.map((h) => _headers[h.trim().toLowerCase()] ?? _headers[h.trim()] ?? '').toList();
  if (!head.contains('fullName') || !head.contains('phone')) return [];
  final out = <Map<String, dynamic>>[];
  for (final row in t.skip(1)) {
    if (row.every((c) => c.trim().isEmpty)) continue;
    final m = <String, dynamic>{};
    for (var i = 0; i < head.length && i < row.length; i++) {
      if (head[i].isNotEmpty && row[i].trim().isNotEmpty) m[head[i]] = row[i].trim();
    }
    out.add(m);
  }
  return out;
}

/// CSV / tab-separated (pasted from Excel), UTF-8 (with or without BOM) — quotes handled
List<List<String>> readCsv(Uint8List bytes) {
  var s = utf8.decode(bytes, allowMalformed: true);
  if (s.startsWith('﻿')) s = s.substring(1);
  final sep = s.split('\n').first.contains('\t') ? '\t' : s.split('\n').first.contains(';') && !s.split('\n').first.contains(',') ? ';' : ',';
  final rows = <List<String>>[];
  var row = <String>[], cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (quoted) {
      if (ch == '"') {
        if (i + 1 < s.length && s[i + 1] == '"') {
          cell.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cell.write(ch);
      }
    } else if (ch == '"') {
      quoted = true;
    } else if (ch == sep) {
      row.add(cell.toString());
      cell = StringBuffer();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < s.length && s[i + 1] == '\n') i++;
      row.add(cell.toString());
      rows.add(row);
      row = <String>[];
      cell = StringBuffer();
    } else {
      cell.write(ch);
    }
  }
  if (cell.isNotEmpty || row.isNotEmpty) {
    row.add(cell.toString());
    rows.add(row);
  }
  return rows;
}

/// the first sheet of an .xlsx (a zip of XML): shared strings + inline strings + numbers
List<List<String>> readXlsx(Uint8List bytes) {
  final zip = ZipDecoder().decodeBytes(bytes);
  String? text(String name) {
    for (final f in zip.files) {
      if (f.name == name) return utf8.decode(f.content as List<int>, allowMalformed: true);
    }
    return null;
  }

  String unescape(String v) => v
      .replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&quot;', '"').replaceAll('&apos;', "'")
      .replaceAllMapped(RegExp(r'&#(x?[0-9a-fA-F]+);'), (m) {
        final c = m[1]!;
        return String.fromCharCode(c.startsWith('x') ? int.parse(c.substring(1), radix: 16) : int.parse(c));
      }).replaceAll('&amp;', '&');
  String joinT(String xml) => RegExp(r'<t(?:\s[^>]*)?>([\s\S]*?)</t>').allMatches(xml).map((m) => unescape(m[1]!)).join();

  final shared = <String>[];
  final ss = text('xl/sharedStrings.xml');
  if (ss != null) {
    for (final m in RegExp(r'<si>([\s\S]*?)</si>').allMatches(ss)) {
      shared.add(joinT(m[1]!));
    }
  }
  // the first sheet named in the workbook (usually sheet1.xml)
  var sheetPath = 'xl/worksheets/sheet1.xml';
  if (text(sheetPath) == null) {
    final any = zip.files.map((f) => f.name).where((n) => n.startsWith('xl/worksheets/sheet') && n.endsWith('.xml')).toList()..sort();
    if (any.isEmpty) return [];
    sheetPath = any.first;
  }
  final sheet = text(sheetPath)!;
  int col(String ref) {
    var n = 0;
    for (final c in ref.replaceAll(RegExp(r'\d'), '').codeUnits) {
      n = n * 26 + (c - 64);
    }
    return n - 1;
  }

  final rows = <List<String>>[];
  for (final r in RegExp(r'<row[^>]*>([\s\S]*?)</row>').allMatches(sheet)) {
    final row = <String>[];
    for (final c in RegExp(r'<c\s([^>]*?)(?:/>|>([\s\S]*?)</c>)').allMatches(r[1]!)) {
      final attrs = c[1]!, body = c[2] ?? '';
      final ref = RegExp(r'r="([A-Z]+)\d+"').firstMatch(attrs)?[1];
      final type = RegExp(r't="(\w+)"').firstMatch(attrs)?[1] ?? '';
      final v = RegExp(r'<v>([\s\S]*?)</v>').firstMatch(body)?[1];
      String value;
      if (type == 's') {
        final i = int.tryParse(v ?? '') ?? -1;
        value = i >= 0 && i < shared.length ? shared[i] : '';
      } else if (type == 'inlineStr') {
        value = joinT(body);
      } else {
        value = unescape(v ?? '');
        // numbers like 1.0123456789E9 (a phone saved as a number)
        final d = double.tryParse(value);
        if (d != null && value.contains(RegExp('[Ee.]')) && d == d.roundToDouble() && d.abs() < 1e15) value = d.toStringAsFixed(0);
      }
      final at = ref == null ? row.length : col(ref);
      while (row.length < at) {
        row.add('');
      }
      row.add(value);
    }
    rows.add(row);
  }
  return rows;
}
