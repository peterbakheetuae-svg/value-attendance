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
import 'reservation_form_pdf.dart' show arabicWords;
import '../widgets/doc_logos.dart';

/// «إيصال صرف نقدية» of an expense (الإيجار، الأوفيس بوي، الفواتير …): printed, signed by whoever received the money,
/// then its photo is added to the expense. The same voucher prints a transfer between the boxes or a payout (سلفة / قبض …)
/// when [x] carries its own 'voucherTitle', 'rows' [[label, value]…] and 'signers'. Every voucher has the company's logo and name.
class PaymentVoucher {
  /// a transfer between خزنة المكتب and خزنة المحاسب
  static Map<String, dynamic> transfer(Map<String, dynamic> t) {
    final toHr = t['direction'] == 'office_to_hr';
    final amount = t['amountExecuted'] ?? t['amountRequested'] ?? t['amount'];
    return {
      'voucherTitle': 'إيصال تحويل نقدية', 'refNo': t['refNo'], 'occurredAt': t['executedAt'] ?? t['receivedAt'] ?? t['requestedAt'] ?? t['at'],
      'amount': (amount is num ? amount : num.tryParse('$amount') ?? 0).abs(),
      'rows': [
        ['من', toHr ? 'خزنة المكتب' : 'خزنة المحاسب'],
        ['إلى', toHr ? 'خزنة المحاسب' : 'خزنة المكتب'],
        ['__amount', ''],
        ['وذلك عن', '${t['reason'] ?? t['label'] ?? ''}'],
        if (t['executedByName'] != null) ['سلّمها', '${t['executedByName']}'],
        if (t['receivedByName'] != null) ['استلمها', '${t['receivedByName']}'],
      ],
      'signers': ['المسلِّم', 'المستلم', 'المدير'],
      'fileName': 'إيصال تحويل ${t['refNo'] ?? ''}',
    };
  }

  /// a payout out of خزنة المحاسب: سلفة / قبض / عمولة / مصاريف عمل
  static Map<String, dynamic> payout(Map<String, dynamic> e) {
    const kinds = {'advance': 'سلفة', 'salary': 'قبض مرتب', 'commission': 'عمولة', 'work_expense': 'مصاريف عمل'};
    final kind = kinds['${e['payoutKind'] ?? ''}'] ?? 'صرف';
    final amount = e['amount'] is num ? e['amount'] as num : num.tryParse('${e['amount']}') ?? 0;
    final period = '${e['period'] ?? ''}';
    return {
      'voucherTitle': 'إيصال صرف $kind', 'refNo': e['refNo'], 'occurredAt': e['at'], 'amount': amount.abs(),
      'rows': [
        ['صرفنا للسيد / ة', '${e['toName'] ?? ''}'],
        ['__amount', ''],
        ['وذلك عن', '$kind${period.length >= 7 ? ' — شهر ${period.substring(0, 7)}' : ''}${'${e['label'] ?? ''}'.trim().isEmpty ? '' : ' — ${e['label']}'}'],
        ['طريقة الصرف', 'نقداً — من خزنة المحاسب'],
      ],
      'signers': ['المستلم', 'المحاسب', 'المدير'],
      'fileName': 'إيصال صرف $kind - ${e['toName'] ?? ''}',
    };
  }

  static Future<Uint8List> build(Map<String, dynamic> x) async {
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
    final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Regular.ttf'));
    // the company's logo (company settings), else the built-in one
    final logo = pw.MemoryImage(await DocLogos.company() ?? (await rootBundle.load('assets/forms/reservation/value_group_logo.png')).buffer.asUint8List());
    final companyName = await DocLogos.companyName();
    final title = '${x['voucherTitle'] ?? 'إيصال صرف نقدية'}';
    final rows = (x['rows'] as List?)?.map((r) => (r as List).map((v) => '$v').toList()).toList();
    final signers = ((x['signers'] as List?) ?? const ['المستلم', 'المحاسب', 'المدير']).map((v) => '$v').toList();
    final amount = (x['amount'] as num?) ?? num.tryParse('${x['amount']}') ?? 0;
    final d = DateTime.tryParse('${x['occurredAt'] ?? ''}')?.toLocal() ?? DateTime.now();
    final day = '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    final box = x['cashbox'] == 'hr' ? 'خزنة المحاسب' : 'خزنة المكتب';
    final method = x['paymentMethod'] == 'bank' ? 'تحويل بنكي' : 'نقداً';
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
                child: pw.Text(title, textDirection: pw.TextDirection.rtl, style: pw.TextStyle(font: bold, fontSize: 16)),
              ),
              pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
                pw.Image(logo, width: 120, height: 56, fit: pw.BoxFit.contain),
                pw.SizedBox(height: 2),
                pw.Text(companyName, textDirection: pw.TextDirection.rtl, style: pw.TextStyle(font: bold, fontSize: 10.5)),
              ]),
            ]),
            pw.SizedBox(height: 10),
            pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
              pw.Text('رقم: ${x['refNo'] ?? ''}', textDirection: pw.TextDirection.rtl, style: t),
              pw.Text('التاريخ: $day', textDirection: pw.TextDirection.rtl, style: t),
            ]),
            pw.SizedBox(height: 8),
            if (rows != null)
              for (final r0 in rows)
                r0[0] == '__amount' ? row('مبلغ وقدره', '${_group(amount)} جنيه (${arabicWords(amount)} جنيهاً مصرياً فقط لا غير)') : row(r0[0], r0[1])
            else ...[
              row('صرفنا للسيد / ة', '${x['beneficiary'] ?? ''}'),
              row('مبلغ وقدره', '${_group(amount)} جنيه (${arabicWords(amount)} جنيهاً مصرياً فقط لا غير)'),
              row('وذلك عن', '${x['category'] ?? ''} — ${x['reason'] ?? ''}'),
              row('طريقة الصرف', '$method — من $box'),
              if ('${x['notes'] ?? ''}'.trim().isNotEmpty) row('ملاحظات', '${x['notes']}'),
            ],
            pw.SizedBox(height: 16),
            pw.Row(children: [for (final w in signers) sign(w)]),
            pw.SizedBox(height: 8),
            pw.Text(companyName, textAlign: pw.TextAlign.center, textDirection: pw.TextDirection.rtl,
                style: pw.TextStyle(font: regular, fontSize: 10, color: PdfColors.grey700)),
          ]),
        );

    final doc = pw.Document(title: '$title ${x['refNo'] ?? ''}', author: companyName);
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
              JphUi.header(context, isDark: isDark, isRTL: true, title: '${expense['voucherTitle'] ?? 'إيصال صرف'}'),
              Expanded(
                child: PdfPreview(
                  build: (_) => PaymentVoucher.build(expense),
                  initialPageFormat: PdfPageFormat.a4,
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  allowSharing: true,
                  allowPrinting: true,
                  pdfFileName: '${expense['fileName'] ?? 'إيصال صرف ${expense['refNo'] ?? ''} - ${expense['beneficiary'] ?? ''}'}.pdf',
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
