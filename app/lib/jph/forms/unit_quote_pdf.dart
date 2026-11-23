import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart' show rootBundle;
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../services/app_controller.dart';
import '../widgets/app_background.dart';
import '../widgets/doc_logos.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/glass_ui.dart';
import '../widgets/jph_form_ui.dart';

/// «عرض سعر واستمارة حجز» of one unit of a project (the print button on each unit in «وحدات المشروع»):
/// the unit's own data is filled in (name, area, meter price, total), the payment plan is editable before printing
/// (المقدم ٪, a second payment after N months ٪, the years and how often an installment is due), and the figures follow.
class UnitQuote {
  String unitName, project;
  num area, meterPrice, total, downPct, secondPct, years;
  int secondMonths, everyMonths;
  String? developerId;
  Object? developerLogoAt;

  UnitQuote({required this.unitName, required this.project, required this.area, required this.meterPrice, required this.total,
      this.downPct = 10, this.secondPct = 10, this.secondMonths = 3, this.years = 3, this.everyMonths = 3, this.developerId, this.developerLogoAt});

  /// from a unit of the project's inventory (and the project it belongs to)
  factory UnitQuote.of(Map<String, dynamic> u, Map<String, dynamic> project) {
    num n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
    final area = n(u['areaM2']) > 0 ? n(u['areaM2']) : n(u['netAreaM2']);
    final meter = n(u['meterPrice']);
    final total = n(u['unitPrice']) > 0 ? n(u['unitPrice']) : (area > 0 && meter > 0 ? (area * meter).round() : 0);
    final floor = '${u['floor'] ?? ''}'.trim();
    final name = [
      '${u['unitType'] ?? ''}'.trim(),
      if (floor.isNotEmpty) (floor.startsWith('دور') ? floor : 'دور $floor'),
      '${u['unitNo'] ?? ''}'.trim(),
    ].where((x) => x.isNotEmpty).join(' ');
    return UnitQuote(unitName: name, project: '${project['name'] ?? ''}', area: area, meterPrice: meter, total: total,
        developerId: project['developerId']?.toString(), developerLogoAt: project['developerLogoAt']);
  }

  num get down => total * downPct / 100;
  num get second => total * secondPct / 100;
  num get remaining => total - down - second;
  int get count => everyMonths <= 0 ? 0 : (years * 12 / everyMonths).round();
  num get installment => count <= 0 ? 0 : remaining / count;
  num get monthly => everyMonths <= 0 ? 0 : installment / everyMonths;
}

/// 6739200 → «6,739,200»
String quoteGroup(num v) {
  final i = v.round().abs().toString();
  final b = StringBuffer();
  for (var k = 0; k < i.length; k++) {
    if (k > 0 && (i.length - k) % 3 == 0) b.write(',');
    b.write(i[k]);
  }
  return (v < 0 ? '-' : '') + b.toString();
}

/// the word the office writes after an amount: «مليون» from a million, «ألف» from a thousand
String quoteUnitWord(num v) => v.abs() >= 1000000 ? 'مليون' : v.abs() >= 1000 ? 'ألف' : 'جنيه';
String _pct(num v) => v == v.roundToDouble() ? '${v.toInt()}%' : '$v%';
String _num(num v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
String _everyAr(int m) => m == 1 ? 'كل شهر' : m == 2 ? 'كل شهرين' : m <= 10 ? 'كل $m شهور' : 'كل $m شهراً';
String _yearsAr(num y) => y == 1 ? 'سنة' : y == 2 ? 'سنتين' : y <= 10 ? '${_num(y)} سنوات' : '${_num(y)} سنة';

class UnitQuotePdf {
  static Future<Uint8List> build(UnitQuote q) async {
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
    final logoBytes = q.developerId == null ? null : await DocLogos.developer(q.developerId!, at: q.developerLogoAt);
    final logo = logoBytes == null ? null : pw.MemoryImage(logoBytes);

    const orange = PdfColor.fromInt(0xFFD97706), ink = PdfColor.fromInt(0xFF111827), muted = PdfColor.fromInt(0xFF6B7280);
    const line = PdfColor.fromInt(0xFFE5E7EB), soft = PdfColor.fromInt(0xFFF8FAFC), purple = PdfColor.fromInt(0xFF7E22CE);
    const purpleSoft = PdfColor.fromInt(0xFFFAF5FF), red = PdfColor.fromInt(0xFFDC2626), green = PdfColor.fromInt(0xFF16A34A);
    pw.TextStyle t(double size, {PdfColor color = ink, bool b = true}) => pw.TextStyle(font: b ? bold : regular, fontSize: size, color: color);
    pw.Widget txt(String s, pw.TextStyle st, {pw.TextAlign align = pw.TextAlign.right}) =>
        pw.Text(s, style: st, textDirection: pw.TextDirection.rtl, textAlign: align);
    pw.Widget amount(num v, {PdfColor color = ink, double size = 15}) => pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
          txt(quoteGroup(v), t(size, color: color)),
          pw.SizedBox(width: 4),
          txt(quoteUnitWord(v), t(size * 0.7, color: color)),
        ]);
    pw.Widget section(String title) => pw.Container(
          margin: const pw.EdgeInsets.only(top: 18, bottom: 8),
          child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.start, children: [
            pw.Container(width: 3, height: 16, color: orange),
            pw.SizedBox(width: 6),
            txt(title, t(12.5)),
          ]),
        );
    pw.Widget cell(String label, pw.Widget value) => pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
            txt(label, t(9, color: muted, b: false), align: pw.TextAlign.center),
            pw.SizedBox(height: 4),
            value,
          ]),
        );
    pw.TableRow row(String label, pw.Widget value, {bool head = false}) => pw.TableRow(
          decoration: head ? const pw.BoxDecoration(color: soft) : null,
          children: [
            pw.Padding(padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 9), child: pw.Align(alignment: pw.Alignment.centerLeft, child: value)),
            pw.Padding(padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 9), child: txt(label, t(11))),
          ],
        );

    final doc = pw.Document(title: 'عرض سعر ${q.unitName}', author: q.project);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 34, 36, 28),
      textDirection: pw.TextDirection.rtl,
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        // ---- header: the developer's logo · the title and the project · the unit
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          pw.SizedBox(width: 140, child: pw.Align(alignment: pw.Alignment.centerRight,
              child: logo == null ? txt(q.project, t(13, color: ink)) : pw.Image(logo, height: 34, fit: pw.BoxFit.contain))),
          pw.Expanded(
            child: pw.Column(children: [
              txt('عرض سعر واستمارة حجز', t(18), align: pw.TextAlign.center),
              if (q.project.isNotEmpty) txt(q.project, t(11.5, color: orange), align: pw.TextAlign.center),
            ]),
          ),
          pw.SizedBox(
            width: 140,
            child: pw.Align(
              alignment: pw.Alignment.centerLeft,
              child: pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: pw.BoxDecoration(color: const PdfColor.fromInt(0xFFFEF3C7), borderRadius: pw.BorderRadius.circular(12),
                    border: pw.Border.all(color: const PdfColor.fromInt(0xFFFCD34D))),
                child: txt(q.unitName, t(9.5, color: const PdfColor.fromInt(0xFFB45309)), align: pw.TextAlign.center),
              ),
            ),
          ),
        ]),
        pw.SizedBox(height: 10),
        pw.Container(height: 2.5, color: orange),
        pw.SizedBox(height: 16),
        // ---- the unit at a glance
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: pw.BoxDecoration(color: soft, borderRadius: pw.BorderRadius.circular(8), border: pw.Border.all(color: line)),
          child: pw.Row(children: [
            cell('بيان الوحدة', txt(q.unitName, t(12.5), align: pw.TextAlign.center)),
            cell('إجمالي المساحة', txt('${_num(q.area)} متر', t(14), align: pw.TextAlign.center)),
            cell('سعر المتر', amount(q.meterPrice, color: const PdfColor.fromInt(0xFFB45309), size: 14)),
            cell('إجمالي سعر الوحدة', amount(q.total, color: const PdfColor.fromInt(0xFFB45309), size: 14)),
          ]),
        ),
        // ---- the payments
        section('تفاصيل الدفعات والمقدم'),
        pw.Table(
          border: pw.TableBorder.all(color: line),
          columnWidths: const {0: pw.FlexColumnWidth(1), 1: pw.FlexColumnWidth(1)},
          children: [
            row('البيان', txt('القيمة المدفوعة', t(10, color: muted)), head: true),
            row('المقدم (${_pct(q.downPct)})', amount(q.down, size: 12.5)),
            if (q.secondPct > 0) row('بعد ${q.secondMonths} شهور (${_pct(q.secondPct)})', amount(q.second, size: 12.5)),
            row('المبلغ المتبقي', amount(q.remaining, color: red, size: 12.5)),
          ],
        ),
        // ---- the installments
        pw.SizedBox(height: 16),
        pw.Container(
          padding: const pw.EdgeInsets.all(12),
          decoration: pw.BoxDecoration(color: purpleSoft, borderRadius: pw.BorderRadius.circular(8),
              border: pw.Border.all(color: const PdfColor.fromInt(0xFFE9D5FF))),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
            txt('خطة الأقساط (على ${_yearsAr(q.years)} - عدد ${q.count} قسط)', t(12, color: purple)),
            pw.SizedBox(height: 8),
            pw.Row(children: [
              pw.Expanded(child: _box(txt, t, 'مدة التقسيط', txt(_yearsAr(q.years), t(13, color: purple)))),
              pw.SizedBox(width: 8),
              pw.Expanded(child: _box(txt, t, 'عدد الأقساط', txt('${q.count} قسط', t(13, color: purple)))),
            ]),
            pw.SizedBox(height: 8),
            _box(txt, t, 'القسط ${_everyAr(q.everyMonths)}${q.everyMonths == 3 ? ' (قسط ربع سنوي)' : ''}', amount(q.installment, color: purple, size: 17)),
          ]),
        ),
        // ---- monthly
        section('القسط الشهري'),
        pw.Table(
          border: pw.TableBorder.all(color: line),
          columnWidths: const {0: pw.FlexColumnWidth(1), 1: pw.FlexColumnWidth(1)},
          children: [row('كل شهر', amount(q.monthly, color: green, size: 14))],
        ),
        pw.Spacer(),
        pw.Container(height: 0.8, color: line),
        pw.SizedBox(height: 6),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          txt('${q.project.isEmpty ? '' : '${q.project} - '}عرض سعر ${q.unitName}', t(8.5, color: muted, b: false)),
          txt('صفحة 1 من 1', t(8.5, color: muted, b: false)),
        ]),
      ]),
    ));
    return doc.save();
  }

  static pw.Widget _box(pw.Widget Function(String, pw.TextStyle, {pw.TextAlign align}) txt, pw.TextStyle Function(double, {PdfColor color, bool b}) t,
          String label, pw.Widget value) =>
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: pw.BoxDecoration(color: PdfColors.white, borderRadius: pw.BorderRadius.circular(6),
            border: pw.Border.all(color: const PdfColor.fromInt(0xFFF3E8FF))),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          txt(label, t(9, color: const PdfColor.fromInt(0xFF7E22CE), b: false)),
          pw.SizedBox(height: 3),
          value,
        ]),
      );
}

/// the print button: the plan (filled from the unit, every figure editable) → the A4 preview (print / share)
Future<void> printUnitQuote(BuildContext context, bool isDark, Map<String, dynamic> unit, Map<String, dynamic> project) async {
  final q = UnitQuote.of(unit, project);
  String s(num v) => v == 0 ? '' : _num(v);
  final name = TextEditingController(text: q.unitName), area = TextEditingController(text: s(q.area)),
      meter = TextEditingController(text: s(q.meterPrice)), total = TextEditingController(text: s(q.total)),
      down = TextEditingController(text: s(q.downPct)), second = TextEditingController(text: s(q.secondPct)),
      secondM = TextEditingController(text: '${q.secondMonths}'), years = TextEditingController(text: s(q.years)),
      every = TextEditingController(text: '${q.everyMonths}');
  num n(TextEditingController c) => num.tryParse(c.text.trim().replaceAll(',', '')) ?? 0;
  void apply() {
    q
      ..unitName = name.text.trim()
      ..area = n(area)
      ..meterPrice = n(meter)
      ..total = n(total)
      ..downPct = n(down)
      ..secondPct = n(second)
      ..secondMonths = n(secondM).toInt()
      ..years = n(years)
      ..everyMonths = n(every).toInt();
  }

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      apply();
      void recalc() => set(() {
            // المساحة × سعر المتر = إجمالي السعر (it can still be typed in by hand)
            if (n(area) > 0 && n(meter) > 0) total.text = '${(n(area) * n(meter)).round()}';
          });
      Widget f(String label, TextEditingController c, {bool number = true, VoidCallback? onChange, String? suffix}) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: JphUi.input(isDark: isDark, label: label, controller: c, number: number, suffix: suffix, big: false,
                onChanged: (_) => onChange == null ? set(() {}) : onChange()),
          );
      Widget line(String k, num v, {Color? color}) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(child: Text(k, style: TextStyle(color: JphUi.sub(isDark)))),
              Text('${quoteGroup(v)} ${quoteUnitWord(v)}', style: TextStyle(fontWeight: FontWeight.w800, color: color ?? JphUi.text(isDark))),
            ]),
          );
      return GlassAlertDialog(
        icon: const Icon(Icons.print_rounded, color: Ar.accent, size: 32),
        title: const Text('عرض سعر الوحدة'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              f('اسم الوحدة', name, number: false),
              f('إجمالي المساحة', area, onChange: recalc, suffix: 'م'),
              f('سعر المتر', meter, onChange: recalc),
              f('إجمالي سعر الوحدة', total),
              Row(children: [
                Expanded(child: f('المقدم', down, suffix: '%')),
                const SizedBox(width: 8),
                Expanded(child: f('دفعة تانية', second, suffix: '%')),
                const SizedBox(width: 8),
                Expanded(child: f('بعد (شهور)', secondM)),
              ]),
              Row(children: [
                Expanded(child: f('مدة التقسيط (سنين)', years)),
                const SizedBox(width: 8),
                Expanded(child: f('قسط كل (شهور)', every)),
              ]),
              const Divider(),
              line('المقدم ${_pct(q.downPct)}', q.down),
              if (q.secondPct > 0) line('بعد ${q.secondMonths} شهور ${_pct(q.secondPct)}', q.second),
              line('المبلغ المتبقي', q.remaining, color: Ar.red),
              line('القسط ${_everyAr(q.everyMonths)} (${q.count} قسط)', q.installment),
              line('كل شهر', q.monthly, color: Ar.green),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton.icon(
            onPressed: q.total > 0 && q.count > 0 && q.remaining >= 0 ? () => Navigator.pop(ctx, true) : null,
            icon: const Icon(Icons.print_rounded),
            label: const Text('معاينة وطباعة'),
          ),
        ],
      );
    }),
  );
  if (ok != true || !context.mounted) return;
  apply();
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => UnitQuotePage(quote: q)));
}

class UnitQuotePage extends StatelessWidget {
  final UnitQuote quote;
  const UnitQuotePage({super.key, required this.quote});

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    return AppBackground(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: isDark, isRTL: true, title: 'عرض سعر واستمارة حجز'),
              Expanded(
                child: PdfPreview(
                  build: (_) => UnitQuotePdf.build(quote),
                  initialPageFormat: PdfPageFormat.a4,
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  allowSharing: true,
                  allowPrinting: true,
                  pdfFileName: 'عرض سعر ${quote.project} - ${quote.unitName}.pdf',
                  dynamicLayout: false,
                  actionBarTheme: PdfActionBarTheme(backgroundColor: JphUi.primary(isDark), iconColor: Colors.white),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
