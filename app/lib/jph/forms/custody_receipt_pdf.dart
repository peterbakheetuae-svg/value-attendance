import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// استمارة استلام عهدة — the printed document.
///
/// The page is the approved original itself (drawn once from the original Word file at 300 dpi and kept with the app
/// as template version N), and only the entered data is written on its dotted lines / tick boxes. Nothing of the
/// original is redrawn, so the layout, wording, borders, logo and spacing stay exactly as approved.
/// Every saved receipt remembers its template version; all versions stay in the app, so an old receipt always
/// prints the way it was made even after the template is updated.
class CustodyReceiptTemplate {
  final int version;
  final Map<String, dynamic> spec;
  final Uint8List background;
  final pw.Font arabic;
  final pw.Font latin;
  CustodyReceiptTemplate._(this.version, this.spec, this.background, this.arabic, this.latin);

  /// Template versions shipped with the app, per form (موبايل / كمبيوتر محمول). Add a new folder (v2, …) for a new
  /// version; never edit an old one.
  static const templates = {
    'custody_receipt': {1: 'assets/forms/custody_receipt/v1/fields.json'},
    'laptop_receipt': {1: 'assets/forms/laptop_receipt/v1/fields.json'},
    'client_intro': {1: 'assets/forms/client_intro/v1/fields.json'},
  };
  static const versions = {1: 'assets/forms/custody_receipt/v1/fields.json'};
  static const latestVersion = 1;

  static final Map<String, CustodyReceiptTemplate> _cache = {};

  static Future<CustodyReceiptTemplate> load([int version = latestVersion, Future<ByteData> Function(String)? loader,
      String template = 'custody_receipt']) async {
    final key = '$template:$version';
    if (_cache[key] != null) return _cache[key]!;
    final ld = loader ?? rootBundle.load;
    final path = templates[template]?[version];
    if (path == null) throw StateError('Unknown form template $template v$version');
    final spec = jsonDecode(utf8.decode((await ld(path)).buffer.asUint8List())) as Map<String, dynamic>;
    final page = spec['page'] as Map<String, dynamic>;
    final font = spec['font'] as Map<String, dynamic>;
    final t = CustodyReceiptTemplate._(
      version,
      spec,
      (await ld(page['background'] as String)).buffer.asUint8List(),
      pw.Font.ttf(await ld(font['arabic'] as String)),
      pw.Font.ttf(await ld(font['latin'] as String)),
    );
    return _cache[key] = t;
  }

  double get width => ((spec['page'] as Map)['widthPt'] as num).toDouble();
  double get height => ((spec['page'] as Map)['heightPt'] as num).toDouble();
  double get fontSize => ((spec['font'] as Map)['sizePt'] as num).toDouble();
}

final _arabic = RegExp(r'[؀-ۿ]');

List<double> _box(Object? v) => (v as List).map((e) => (e as num).toDouble()).toList();

/// Builds the filled document. [data] holds exactly the fields of the original form.
Future<Uint8List> buildCustodyReceiptPdf(Map<String, dynamic> data, {int version = CustodyReceiptTemplate.latestVersion,
    Future<ByteData> Function(String)? loader, String template = 'custody_receipt'}) async {
  final t = await CustodyReceiptTemplate.load(version, loader, template);
  final style = pw.TextStyle(font: t.arabic, fontFallback: [t.latin], fontSize: t.fontSize, color: PdfColors.black);
  // values next to a label (no dotted line) start right after its colon
  final align = t.spec['align'] == 'right' ? pw.Alignment.bottomRight : pw.Alignment.bottomCenter;

  // a value written over its dotted line: centred on it, on the same baseline, shrunk only if it does not fit
  pw.Widget field(List<double> b, String value) {
    final v = value.trim();
    final w = b[1] - b[0];
    return pw.Positioned(
      left: b[0],
      top: b[3] - 13.6, // baseline just above the dots, like writing on the line
      child: pw.SizedBox(
        width: w,
        height: 11.5,
        child: pw.FittedBox(
          fit: pw.BoxFit.scaleDown,
          alignment: align,
          // Latin letters / digits are taller than the Arabic ones at the same size: one point smaller keeps the row even
          child: _arabic.hasMatch(v)
              ? pw.Text(v, style: style, textDirection: pw.TextDirection.rtl)
              : pw.Text(v, style: style.copyWith(fontSize: t.fontSize - 1), textDirection: pw.TextDirection.ltr),
        ),
      ),
    );
  }

  // a tick inside the original's check box
  pw.Widget tick(List<double> b) {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
        '<path d="M2.1 5.3 L4.2 7.6 L8.1 2.4" fill="none" stroke="#000" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    final s = (b[1] - b[0]).clamp(6.0, 9.0);
    return pw.Positioned(
      left: b[0] + ((b[1] - b[0]) - s) / 2,
      top: b[2] + ((b[3] - b[2]) - s) / 2 + 0.6,
      child: pw.SizedBox(width: s, height: s, child: pw.SvgImage(svg: svg)),
    );
  }

  final children = <pw.Widget>[
    pw.Positioned(left: 0, top: 0, child: pw.Image(pw.MemoryImage(t.background), width: t.width, height: t.height, fit: pw.BoxFit.fill)),
  ];
  final text = (t.spec['text'] as Map<String, dynamic>);
  final dateText = ((t.spec['dateText'] as Map?) ?? const {});
  for (final e in text.entries) {
    var v = '${data[e.key] ?? ''}';
    if (dateText.containsKey(e.key)) {
      final d = DateTime.tryParse(v);
      if (d != null) v = '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    }
    if (v.trim().isNotEmpty) children.add(field(_box(e.value), v));
  }
  final dates = ((t.spec['dates'] as Map?) ?? const {}).cast<String, dynamic>();
  for (final e in dates.entries) {
    final d = DateTime.tryParse('${data[e.key] ?? ''}');
    if (d == null) continue;
    final parts = e.value as Map<String, dynamic>;
    children
      ..add(field(_box(parts['day']), d.day.toString().padLeft(2, '0')))
      ..add(field(_box(parts['month']), d.month.toString().padLeft(2, '0')))
      ..add(field(_box(parts['year']), '${d.year}'));
  }
  final checks = (t.spec['checks'] as Map<String, dynamic>);
  final accessories = ((data['accessories'] as List?) ?? const []).map((e) => '$e').toSet();
  for (final e in checks.entries) {
    final k = e.key.split(':');
    // condition:x → data['condition'] == x; accessory:x → in data['accessories']; any other list field:x → in data[field]
    final v = k[0] == 'accessory' ? null : data[k[0]];
    final on = k[0] == 'accessory'
        ? accessories.contains(k[1])
        : v is List
            ? v.map((e) => '$e').contains(k[1])
            : '${v ?? ''}' == k[1];
    if (on) children.add(tick(_box(e.value)));
  }

  final doc = pw.Document(title: '${t.spec['title'] ?? 'استمارة استلام عهدة'}', creator: 'Value Attendance');
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat(t.width, t.height, marginAll: 0),
    margin: pw.EdgeInsets.zero,
    build: (_) => pw.SizedBox(width: t.width, height: t.height, child: pw.Stack(children: children)),
  ));
  return doc.save();
}
