import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/doc_logos.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/side_sheet.dart';
import 'leads_api.dart';

/// «عرض سعر» for a lead on an available unit: the price, the discount, the down payment, the installments
/// (every 1 / 3 / 6 months for N years) and their schedule — a PDF to print or share with the client.
Future<void> showQuote(BuildContext context, bool isDark, Map<String, dynamic> lead, Map<String, dynamic> unit) async {
  final price = (unit['price'] as num?) ?? 0;
  final discount = TextEditingController(text: '0'), down = TextEditingController(text: '10'), years = TextEditingController(text: '3');
  int every = 3;
  final ok = await leadForm(context, isDark, 'عرض سعر — وحدة ${unit['unitNo']}', (set) => [
        Text('سعر الوحدة: ${JphUi.money(price)}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
        JphUi.input(isDark: isDark, label: 'خصم %', controller: discount, number: true, suffix: '%', icon: Icons.discount_rounded, big: false),
        JphUi.input(isDark: isDark, label: 'المقدم %', controller: down, number: true, suffix: '%', icon: Icons.payments_rounded, big: false),
        JphUi.input(isDark: isDark, label: 'عدد السنين', controller: years, number: true, suffix: 'سنة', icon: Icons.date_range_rounded, big: false),
        Wrap(spacing: 6, children: [
          for (final e in const [(1, 'شهري'), (3, 'كل 3 شهور'), (6, 'كل 6 شهور'), (12, 'سنوي')])
            ChoiceChip(selected: every == e.$1, label: Text(e.$2), onSelected: (_) => set(() => every = e.$1)),
        ]),
      ], () async => true, saveLabel: 'اعمل العرض', saveIcon: Icons.picture_as_pdf_rounded);
  if (!ok || !context.mounted) return;
  final q = Quote(
    lead: lead, unit: unit, price: price.toDouble(),
    discountPct: (double.tryParse(discount.text.trim()) ?? 0).clamp(0, 50).toDouble(),
    downPct: (double.tryParse(down.text.trim()) ?? 0).clamp(0, 100).toDouble(),
    years: (int.tryParse(years.text.trim()) ?? 0).clamp(0, 15), every: every,
  );
  await pushSide(context, QuotePage(quote: q));
}

class Quote {
  final Map<String, dynamic> lead, unit;
  final double price, discountPct, downPct;
  final int years, every;
  Quote({required this.lead, required this.unit, required this.price, required this.discountPct, required this.downPct, required this.years, required this.every});

  double get net => (price * (100 - discountPct) / 100).roundToDouble();
  double get downAmount => (net * downPct / 100).roundToDouble();
  int get count => years * 12 ~/ every;
  double get installment => count == 0 ? 0 : ((net - downAmount) / count).roundToDouble();

  List<(DateTime, double)> schedule() {
    final now = DateTime.now();
    final out = <(DateTime, double)>[];
    var left = net - downAmount;
    for (var i = 1; i <= count; i++) {
      final amount = i == count ? left : installment;
      left -= amount;
      out.add((DateTime(now.year, now.month + i * every, 1), amount));
    }
    return out;
  }
}

class QuotePage extends StatelessWidget {
  final Quote quote;
  const QuotePage({super.key, required this.quote});

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
              JphUi.header(context, isDark: isDark, isRTL: true, title: 'عرض سعر — ${quote.lead['fullName']}'),
              Expanded(
                child: PdfPreview(
                  build: (_) => buildQuotePdf(quote),
                  initialPageFormat: PdfPageFormat.a4,
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  pdfFileName: 'عرض سعر - ${quote.lead['fullName']} - ${quote.unit['unitNo']}.pdf',
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

String _group(num v) {
  final s = v.round().abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

Future<Uint8List> buildQuotePdf(Quote q) async {
  final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
  final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
  final logoBytes = await DocLogos.company();
  final logo = logoBytes == null ? null : pw.MemoryImage(logoBytes);
  final company = await DocLogos.companyName();
  final t = pw.TextStyle(font: bold, fontSize: 12);
  final r = pw.TextStyle(font: regular, fontSize: 11);
  final orange = PdfColor.fromHex('#F26A1B');
  final now = DateTime.now();
  pw.Widget row(String k, String v) => pw.Container(
        padding: const pw.EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(width: 0.5, color: PdfColors.grey400))),
        child: pw.Row(children: [
          pw.SizedBox(width: 150, child: pw.Text(k, textDirection: pw.TextDirection.rtl, style: t)),
          pw.Expanded(child: pw.Text(v, textDirection: pw.TextDirection.rtl, style: r)),
        ]),
      );
  final u = q.unit;
  final sched = q.schedule();
  final everyAr = {1: 'شهري', 3: 'كل 3 شهور', 6: 'كل 6 شهور', 12: 'سنوي'}[q.every] ?? '';
  final doc = pw.Document(title: 'عرض سعر', author: company);
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(32, 28, 32, 28),
    textDirection: pw.TextDirection.rtl,
    header: (_) => pw.Column(children: [
      pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('عرض سعر', textDirection: pw.TextDirection.rtl, style: pw.TextStyle(font: bold, fontSize: 20, color: orange)),
          pw.Text('${now.day}/${now.month}/${now.year}', style: r),
        ]),
        if (logo != null) pw.Image(logo, width: 110, height: 52, fit: pw.BoxFit.contain),
      ]),
      pw.Divider(color: orange, thickness: 1.2),
    ]),
    footer: (c) => pw.Text('$company — العرض ده استرشادي وبيتأكد عند الحجز — صفحة ${c.pageNumber}',
        textDirection: pw.TextDirection.rtl, style: pw.TextStyle(font: regular, fontSize: 8.5, color: PdfColors.grey600)),
    build: (_) => [
      row('السيد / ة', '${q.lead['fullName']}'),
      row('المشروع', '${u['projectName']}'),
      row('الوحدة', [
        '${u['unitNo']}',
        if ('${u['unitType'] ?? ''}'.isNotEmpty) '${u['unitType']}',
        if ('${u['floor'] ?? ''}'.isNotEmpty) 'دور ${u['floor']}',
        if (u['area'] != null) '${u['area']} م²',
      ].join(' — ')),
      row('سعر الوحدة', '${_group(q.price)} جنيه'),
      if (q.discountPct > 0) row('الخصم', '${q.discountPct}% — السعر بعد الخصم ${_group(q.net)} جنيه'),
      row('المقدم', '${q.downPct}% = ${_group(q.downAmount)} جنيه'),
      if (q.count > 0) row('الأقساط', '${q.count} قسط $everyAr — القسط ${_group(q.installment)} جنيه على ${q.years} سنين'),
      pw.SizedBox(height: 14),
      if (sched.isNotEmpty)
        pw.TableHelper.fromTextArray(
          cellAlignment: pw.Alignment.center,
          headerStyle: pw.TextStyle(font: bold, fontSize: 10, color: PdfColors.white),
          headerDecoration: pw.BoxDecoration(color: orange),
          cellStyle: pw.TextStyle(font: regular, fontSize: 10),
          headers: ['المبلغ', 'التاريخ', 'القسط'],
          data: [
            ['${_group(q.downAmount)}', 'عند الحجز', 'المقدم'],
            for (var i = 0; i < sched.length; i++) ['${_group(sched[i].$2)}', '${sched[i].$1.month}/${sched[i].$1.year}', '${i + 1}'],
          ],
        ),
      pw.SizedBox(height: 16),
      pw.Text('السيلز: ${lm(q.lead['assignedTo'])['name'] ?? ''}', textDirection: pw.TextDirection.rtl, style: t),
    ],
  ));
  return doc.save();
}
