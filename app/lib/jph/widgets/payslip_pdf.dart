import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Printable salary slip (بيان راتب) from the monthly attendance report:
/// a row of descriptions on top and the employee's numbers right under it — twice on one A4 page:
/// the signed copy, a cut line, and the employee's copy for the salary envelope.
Future<void> printPayslip({
  required Map<String, dynamic> monthly,
  required String employeeName,
  required String monthLabel,
  String companyName = 'Value',
}) async {
  final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));

  String money(Object? v) {
    final n = num.tryParse('${v ?? ''}'.replaceAll(',', ''));
    if (n == null) return '0';
    return n == n.roundToDouble() ? n.round().toString() : n.toStringAsFixed(2);
  }

  String txt(Object? v) => (v == null || '$v'.isEmpty) ? '0' : '$v';

  // descriptions (top) → values (bottom); two blocks so each cell stays readable on A4 landscape
  final earnings = <List<String>>[
    ['أيام الحضور', txt(monthly['workDays'])],
    ['الغياب', txt(monthly['absent'])],
    ['إجازات', txt(monthly['holidays'])],
    ['مرضي', txt(monthly['sick'])],
    ['ساعات التأخير', txt(monthly['lateHours'])],
    ['راتب الحضور', money(monthly['attendSalary'])],
    ['عمولة المبيعات', money(monthly['commissions'])],
    ['علاوة إضافية', money(monthly['bonus'])],
  ];
  final deductions = <List<String>>[
    ['مصاريف العمل', money(monthly['workExpenses'])],
    ['خصم التأخير', money(monthly['lateAmount'])],
    ['خصم الغياب', money(monthly['absentDeduction'])],
    ['خصومات', money(monthly['deduction'])],
    ['السلف', money(monthly['advance'])],
    ['المستلم', money(monthly['received'])],
    ['المتأخرات', money(monthly['arrears'])],
    ['صافي الراتب المستحق', money(monthly['dueSalary'])],
  ];

  const head = PdfColor.fromInt(0xFF0F766E);
  const headBg = PdfColor.fromInt(0xFFE6F4F1);

  pw.Widget twoRows(List<List<String>> cols, {bool lastStrong = false, double scale = 1}) => pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.8),
        defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: headBg),
            children: [
              for (final c in cols)
                pw.Padding(
                  padding: pw.EdgeInsets.symmetric(vertical: 6 * scale, horizontal: 2),
                  child: pw.Text(c[0], textAlign: pw.TextAlign.center, style: pw.TextStyle(font: bold, fontSize: 8.5 * scale, color: head)),
                ),
            ],
          ),
          pw.TableRow(children: [
            for (var i = 0; i < cols.length; i++)
              pw.Container(
                color: lastStrong && i == cols.length - 1 ? const PdfColor.fromInt(0xFFFFF7E6) : null,
                padding: pw.EdgeInsets.symmetric(vertical: 7 * scale, horizontal: 2),
                child: pw.Text(cols[i][1], textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(font: bold, fontSize: (lastStrong && i == cols.length - 1 ? 11 : 10) * scale)),
              ),
          ]),
        ],
      );

  // one copy of the slip: the company keeps the top one (signed), the bottom one is cut off and goes in the salary envelope
  pw.Widget slip({required String title, required bool signatures}) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text(title, style: pw.TextStyle(font: bold, fontSize: 18, color: head)),
          pw.Text(companyName, style: pw.TextStyle(font: bold, fontSize: 13)),
        ]),
        pw.SizedBox(height: 4),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('الموظف: $employeeName', style: const pw.TextStyle(fontSize: 11)),
          pw.Text('عن شهر: $monthLabel', style: const pw.TextStyle(fontSize: 11)),
        ]),
        pw.Divider(color: PdfColors.grey500),
        pw.SizedBox(height: 6),
        twoRows(earnings),
        pw.SizedBox(height: 10),
        twoRows(deductions, lastStrong: true),
        pw.SizedBox(height: 6),
        pw.Text('المبالغ بالجنيه المصري', style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        if (signatures) ...[
          pw.SizedBox(height: 34),
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceAround, children: [
            for (final s in ['توقيع الموظف', 'الموارد البشرية', 'الحسابات'])
              pw.Column(children: [
                pw.Container(width: 120, height: 0.8, color: PdfColors.grey700),
                pw.SizedBox(height: 4),
                pw.Text(s, style: const pw.TextStyle(fontSize: 10)),
              ]),
          ]),
        ],
      ]);

  // dashed cut line between the two copies
  pw.Widget cutLine() => pw.Row(children: [
        pw.Expanded(child: pw.Container(height: 1, decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: PdfColors.grey600, width: 1, style: pw.BorderStyle.dashed))))),
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6),
          child: pw.Text('قص هنا — الجزء ده يتحط في ظرف الراتب', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        ),
        pw.Expanded(child: pw.Container(height: 1, decoration: const pw.BoxDecoration(
            border: pw.Border(top: pw.BorderSide(color: PdfColors.grey600, width: 1, style: pw.BorderStyle.dashed))))),
      ]);

  final doc = pw.Document(theme: pw.ThemeData.withFont(base: regular, bold: bold));
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(24, 24, 24, 24),
    textDirection: pw.TextDirection.rtl,
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      slip(title: 'بيان راتب', signatures: true),
      pw.Spacer(),
      cutLine(),
      pw.Spacer(),
      slip(title: 'بيان راتب — نسخة الموظف', signatures: false),
      pw.Spacer(),
    ]),
  ));

  await Printing.layoutPdf(name: 'بيان راتب - $employeeName - $monthLabel', onLayout: (_) async => doc.save());
}
