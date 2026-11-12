import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../services/app_controller.dart';
import '../widgets/app_background.dart';
import '../widgets/jph_form_ui.dart';
import 'reservation_form_pdf.dart' show arabicWords, ReservationForm;

/// «إيصال صرف نقدية» of an expense (الإيجار، الأوفيس بوي، الفواتير …): printed, signed by whoever received the money,
/// then its photo is added to the expense.
class PaymentVoucher {
  static Future<Uint8List> build(Map<String, dynamic> x) async {
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
    final logo = pw.MemoryImage((await rootBundle.load('assets/forms/reservation/value_group_logo.png')).buffer.asUint8List());
    final amount = (x['amount'] as num?) ?? num.tryParse('${x['amount']}') ?? 0;
    final d = DateTime.tryParse('${x['occurredAt'] ?? ''}')?.toLocal() ?? DateTime.now();
    final day = '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    final box = x['cashbox'] == 'hr' ? 'خزنة المحاسب' : 'خزنة المكتب';
    final method = x['paymentMethod'] == 'bank' ? 'تحويل بنكي' : 'نقدًا';
    final t = pw.TextStyle(font: bold, fontSize: 13);
    final r = pw.TextStyle(font: regular, fontSize: 12.5);

    pw.Widget row(String k, String v) => pw.Container(
          padding: const pw.EdgeInsets.symmetric(vertical: 9, horizontal: 10),
          decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(width: 0.6, color: PdfColors.grey500))),
          child: pw.Row(children: [
            pw.SizedBox(width: 120, child: pw.Text(k, textDirection: pw.TextDirection.rtl, style: t)),
            pw.Expanded(child: pw.Text(v, textDirection: pw.TextDirection.rtl, style: r)),
          ]),
        );
    pw.Widget sign(String who) => pw.Expanded(
          child: pw.Column(children: [
            pw.Text(who, textDirection: pw.TextDirection.rtl, style: t),
            pw.SizedBox(height: 34),
            pw.Container(height: 0.8, color: PdfColors.black, margin: const pw.EdgeInsets.symmetric(horizontal: 14)),
            pw.SizedBox(height: 4),
            pw.Text('الاسم / التوقيع', textDirection: pw.TextDirection.rtl, style: pw.TextStyle(font: regular, fontSize: 10, color: PdfColors.grey700)),
          ]),
        );
    pw.Widget voucher() => pw.Container(
          padding: const pw.EdgeInsets.all(18),
          decoration: pw.BoxDecoration(border: pw.Border.all(width: 1.2)),
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: pw.BoxDecoration(border: pw.Border.all(width: 1)),
                child: pw.Text('إيصال صرف نقدية', textDirection: pw.TextDirection.rtl, style: pw.TextStyle(font: bold, fontSize: 16)),
              ),
              pw.Image(logo, width: 120),
            ]),
            pw.SizedBox(height: 10),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('رقم: ${x['refNo'] ?? ''}', textDirection: pw.TextDirection.rtl, style: t),
              pw.Text('التاريخ: $day', textDirection: pw.TextDirection.rtl, style: t),
            ]),
            pw.SizedBox(height: 8),
            row('صرفنا للسيد / ة', '${x['beneficiary'] ?? ''}'),
            row('مبلغ وقدره', '${_group(amount)} جنيه (${arabicWords(amount)} جنيهًا مصريًا فقط لا غير)'),
            row('وذلك عن', '${x['category'] ?? ''} — ${x['reason'] ?? ''}'),
            row('طريقة الصرف', '$method — من $box'),
            if ('${x['notes'] ?? ''}'.trim().isNotEmpty) row('ملاحظات', '${x['notes']}'),
            pw.SizedBox(height: 16),
            pw.Row(children: [sign('المستلم'), sign('المحاسب'), sign('المدير')]),
            pw.SizedBox(height: 8),
            pw.Text(ReservationForm.company, textAlign: pw.TextAlign.center, textDirection: pw.TextDirection.rtl,
                style: pw.TextStyle(font: regular, fontSize: 10, color: PdfColors.grey700)),
          ]),
        );

    final doc = pw.Document(title: 'إيصال صرف ${x['refNo'] ?? ''}', author: ReservationForm.company);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(36, 30, 36, 30),
      textDirection: pw.TextDirection.rtl,
      // two copies on one page: one for the beneficiary, one for the company
      build: (_) => pw.Column(children: [
        voucher(),
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 14),
          child: pw.Row(children: [
            pw.Expanded(child: pw.Divider(borderStyle: pw.BorderStyle.dashed)),
            pw.Padding(padding: const pw.EdgeInsets.symmetric(horizontal: 6),
                child: pw.Text('قص هنا', textDirection: pw.TextDirection.rtl, style: pw.TextStyle(font: regular, fontSize: 9, color: PdfColors.grey600))),
            pw.Expanded(child: pw.Divider(borderStyle: pw.BorderStyle.dashed)),
          ]),
        ),
        voucher(),
      ]),
    ));
    return doc.save();
  }
}

String _group(num v) {
  final i = v.round().abs().toString();
  final b = StringBuffer();
  for (var k = 0; k < i.length; k++) {
    if (k > 0 && (i.length - k) % 3 == 0) b.write(',');
    b.write(i[k]);
  }
  return b.toString();
}

class PaymentVoucherPage extends StatelessWidget {
  final Map<String, dynamic> expense;
  const PaymentVoucherPage({super.key, required this.expense});

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
              JphUi.header(context, isDark: isDark, isRTL: true, title: 'إيصال صرف'),
              Expanded(
                child: PdfPreview(
                  build: (_) => PaymentVoucher.build(expense),
                  initialPageFormat: PdfPageFormat.a4,
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  allowSharing: true,
                  allowPrinting: true,
                  pdfFileName: 'إيصال صرف ${expense['refNo'] ?? ''} - ${expense['beneficiary'] ?? ''}.pdf',
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
