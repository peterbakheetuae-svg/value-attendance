import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Printable salary slip (بيان راتب) from the monthly attendance report:
/// a row of descriptions on top and the employee's numbers right under it.
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
    ['البدلات', money(monthly['allowance'])],
    ['المكافآت والعمولات', money(monthly['bonus'])],
  ];
  final deductions = <List<String>>[
    ['مصاريف العمل', money(monthly['workExpenses'])],
    ['خصم التأخير', money(monthly['lateAmount'])],
    ['خصم الغياب', money(monthly['absentDeduction'])],
    ['خصومات أخرى', money(monthly['deduction'])],
    ['السلف', money(monthly['advance'])],
    ['المستلم', money(monthly['received'])],
    ['المتأخرات', money(monthly['arrears'])],
    ['صافي الراتب المستحق', money(monthly['dueSalary'])],
  ];

  const head = PdfColor.fromInt(0xFF0F766E);
  const headBg = PdfColor.fromInt(0xFFE6F4F1);

  pw.Widget twoRows(List<List<String>> cols, {bool lastStrong = false}) => pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.8),
        defaultVerticalAlignment: pw.TableCellVerticalAlignment.middle,
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: headBg),
            children: [
              for (final c in cols)
                pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                  child: pw.Text(c[0], textAlign: pw.TextAlign.center, style: pw.TextStyle(font: bold, fontSize: 10, color: head)),
                ),
            ],
          ),
          pw.TableRow(children: [
            for (var i = 0; i < cols.length; i++)
              pw.Container(
                color: lastStrong && i == cols.length - 1 ? const PdfColor.fromInt(0xFFFFF7E6) : null,
                padding: const pw.EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                child: pw.Text(cols[i][1], textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(font: bold, fontSize: lastStrong && i == cols.length - 1 ? 13 : 12)),
              ),
          ]),
        ],
      );

  final doc = pw.Document(theme: pw.ThemeData.withFont(base: regular, bold: bold));
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(28),
    textDirection: pw.TextDirection.rtl,
    build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('بيان راتب', style: pw.TextStyle(font: bold, fontSize: 22, color: head)),
        pw.Text(companyName, style: pw.TextStyle(font: bold, fontSize: 14)),
      ]),
      pw.SizedBox(height: 6),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text('الموظف: $employeeName', style: const pw.TextStyle(fontSize: 13)),
        pw.Text('عن شهر: $monthLabel', style: const pw.TextStyle(fontSize: 13)),
      ]),
      pw.Divider(color: PdfColors.grey500),
      pw.SizedBox(height: 10),
      twoRows(earnings),
      pw.SizedBox(height: 16),
      twoRows(deductions, lastStrong: true),
      pw.SizedBox(height: 10),
      pw.Text('المبالغ بالجنيه المصري', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
      pw.Spacer(),
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceAround, children: [
        for (final s in ['توقيع الموظف', 'الموارد البشرية', 'الحسابات'])
          pw.Column(children: [
            pw.Container(width: 150, height: 0.8, color: PdfColors.grey700),
            pw.SizedBox(height: 4),
            pw.Text(s, style: const pw.TextStyle(fontSize: 11)),
          ]),
      ]),
    ]),
  ));

  await Printing.layoutPdf(name: 'بيان راتب - $employeeName - $monthLabel', onLayout: (_) async => doc.save());
}
