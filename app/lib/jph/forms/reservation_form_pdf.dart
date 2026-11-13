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

/// «استمارة حجز وحدة» — always printed the same way (the company's approved form, A4): the logo and the boxed
/// «استمارة حجز» on top, the fixed wording, and the reservation's own figures written in (numbers + words).
class ReservationForm {
  static const company = 'فاليو جروب للتطوير العقاري';

  static Future<Uint8List> build(Map<String, dynamic> unit) async {
    final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Cairo-Bold.ttf'));
    final logo = pw.MemoryImage((await rootBundle.load('assets/forms/reservation/value_group_logo.png')).buffer.asUint8List());
    final f = ((unit['form'] as Map?) ?? const {}).cast<String, dynamic>();
    final contract = ((unit['contract'] as Map?) ?? const {}).cast<String, dynamic>();

    num n(Object? v) => v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
    String money(Object? v) => _group(n(v));
    String blank(Object? v, [String dots = '……………']) => '${v ?? ''}'.trim().isEmpty ? dots : '${v ?? ''}'.trim();
    String day(Object? iso) {
      final d = DateTime.tryParse('${iso ?? ''}');
      return d == null ? '……\\……\\……' : '${d.day.toString().padLeft(2, '0')}\\${d.month.toString().padLeft(2, '0')}\\${d.year}';
    }

    final price = n(unit['unitPrice']);
    final deposit = n(unit['depositAmount']);
    final area = n(f['areaM2']);
    // سعر المتر: as entered (× the loaded area = the price), else the price ÷ the loaded area
    final perM = n(f['meterPrice']) > 0 ? n(f['meterPrice']) : (area > 0 ? (price / area).round() : 0);
    final down = n(f['plannedDownPayment'] ?? contract['downPayment']);
    final downPct = price > 0 && down > 0 ? (down * 100 / price) : 0;
    final downRest = down > deposit ? down - deposit : 0;
    final afterDown = down > 0 ? price - down : 0;
    final installments = n(f['plannedInstallments'] ?? contract['installmentsCount']);
    final maintenance = n(f['maintenanceDeposit']);
    final method = '${unit['depositMethod'] ?? ''}';
    final cashOrBank = method.isEmpty ? 'نقدًا او بتحويل بنكي' : (method == 'cash' ? 'نقدًا' : 'بتحويل بنكي');

    final base = pw.TextStyle(font: bold, fontSize: 11.5, lineSpacing: 3);
    pw.Widget para(String text, {pw.TextAlign align = pw.TextAlign.right, double top = 7, pw.TextStyle? style}) => pw.Padding(
          padding: pw.EdgeInsets.only(top: top),
          child: pw.Text(text, textAlign: align, textDirection: pw.TextDirection.rtl, style: style ?? base),
        );

    final doc = pw.Document(title: 'استمارة حجز وحدة ${unit['unitNo'] ?? ''}', author: company);
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(56, 36, 56, 40),
      textDirection: pw.TextDirection.rtl,
      build: (_) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        // header: the boxed «استمارة حجز» (right) and the logo (left)
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, crossAxisAlignment: pw.CrossAxisAlignment.center, children: [
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: pw.BoxDecoration(border: pw.Border.all(width: 1)),
            child: pw.Text('استمارة حجز', textDirection: pw.TextDirection.rtl, style: pw.TextStyle(font: bold, fontSize: 16)),
          ),
          pw.Image(logo, width: 140),
        ]),
        pw.SizedBox(height: 14),
        pw.Center(
          child: pw.Text('استمارة حجز وحدة بمشروع "${unit['projectName'] ?? ''}"', textDirection: pw.TextDirection.rtl,
              style: pw.TextStyle(font: bold, fontSize: 14, decoration: pw.TextDecoration.underline)),
        ),
        pw.SizedBox(height: 6),
        para('السادة / $company'),
        para('برجاء قبول مبلغ وقدره: (${money(deposit)}) جنيه (${arabicWords(deposit)}) جنيهًا مصريًا فقط.'),
        para('والمسدد $cashOrBank بتاريخ : ${day(f['depositPaidOn'] ?? f['reservedOn'])} م'),
        para('كدفعة حجز للوحدة (${blank(f['unitType'], 'تجاري – اداري')}) - (${blank(f['floor'], 'ارضي – اول علوي – ثاني علوي')})'),
        para('رقم (${unit['unitNo'] ?? ''}) بإجمالي مساحة (${area > 0 ? _plain(area) : '……'} مترًا) تحت العجز والزيادة على أن تكون المساحة الفعلية '
            'وقت كتابة العقد في ${unit['projectName'] ?? ''} بنشاط (${blank(f['activity'], '                    ')})'),
        para('بإجمالي مبلغ قدره : (${money(price)} جنيه (${arabicWords(price)}) جنيه مصري فقط.'
            '${maintenance > 0 ? ' وذلك بخلاف وديعة الصيانة البالغة : (${money(maintenance)}) جنيه (${arabicWords(maintenance)}) جنيهًا مصريًا فقط' : ''}'),
        para('قيمة مقدم الوحدة ${down > 0 ? _plain(double.parse(downPct.toStringAsFixed(2))) : '……'}% من الإجمالي بقيمة (${down > 0 ? money(down) : '……'}) جنيه '
            '${down > 0 ? '(${arabicWords(down)}) ' : ''}جنيهًا مصريًا. ويتم استكمال الباقي من المقدم للوحدة وقدره: (${down > 0 ? money(downRest) : '……'}) جنيه مصري '
            '${down > 0 ? '(${arabicWords(downRest)}) ' : ''}وذلك في موعد أقصاه : ${day(f['downPaymentDue'])} م'),
        para('وتبقى بعد سداد المقدم من إجمالي ثمن الوحدة مبلغ وقدره: (${down > 0 ? money(afterDown) : '……'}) جنيه مصري '
            '${down > 0 ? '(${arabicWords(afterDown)}) ' : ''}جنيهًا مصريًا ويتم استكمال المتبقي على (${installments > 0 ? installments.toInt() : '……'}) قسط'),
        para('سعر المتر : (${perM > 0 ? money(perM) : '……'}) ${perM > 0 ? '(${arabicWords(perM)}) ' : ''}جنيه مصري فقط.'),
        para('وفي حالة عدم الوفاء بسداد باقي دفعة التعاقد في الموعد المحدد أعلاه يعتبر الحجز لاغيًا، ويحق للشركة رد قيمة دفعة الحجز بعد خصم 1% من '
            'إجمالي قيمة الوحدة مقابل مصاريف إدارية وإضرار حجب الوحدة عن البيع خلال فترة الحجز، وذلك دون حاجة لتنبيه أو إنذار أو حكم قضائي.', top: 2),
        para('وعلى هذا تم التوقيع والإقرار بما ورد أعلاه.', align: pw.TextAlign.center, top: 12),
        para('اسم العميل :  ${unit['clientName'] ?? ''}', top: 12),
        para('الرقم القومي: ${blank(f['clientNationalId'])}', top: 10),
        para('العنوان: ${blank(f['clientAddress'])}', top: 10),
        para('رقم التليفون : ${blank(unit['clientPhone'])}', top: 10),
        para('توقيع العميل :', top: 12, style: pw.TextStyle(font: bold, fontSize: 13)),
        para('بالشروط أعلاه', top: 12),
        para('يتم قبول دفعة الحجز من العميل \\\nلحين إتمام دفعة التعاقد واستلام العقد الابتدائي مع تطبيق شروط الإلغاء في حال عدم الوفاء في الموعد المحدد .', top: 12),
        pw.Spacer(),
        pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Expanded(child: para('شركة $company', top: 0)),
          pw.Expanded(
            child: para('تحريرًا في: ${day(f['reservedOn'])} وحررت هذه الاستمارة من نسختين مكونة من ورقة واحدة - نسخة تسلم ليد العميل ونسخة تسلم للشركة .',
                top: 0, style: pw.TextStyle(font: bold, fontSize: 10.5)),
          ),
        ]),
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
  return (v < 0 ? '-' : '') + b.toString();
}

String _plain(num v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

/// Egyptian amount in Arabic words: 1,328,032 → «مليون وثلاثمائة وثمانية وعشرون ألفًا واثنان وثلاثون».
String arabicWords(num value) {
  var x = value.round();
  if (x == 0) return 'صفر';
  const ones = ['', 'واحد', 'اثنان', 'ثلاثة', 'أربعة', 'خمسة', 'ستة', 'سبعة', 'ثمانية', 'تسعة', 'عشرة', 'أحد عشر', 'اثنا عشر', 'ثلاثة عشر',
    'أربعة عشر', 'خمسة عشر', 'ستة عشر', 'سبعة عشر', 'ثمانية عشر', 'تسعة عشر'];
  const tens = ['', '', 'عشرون', 'ثلاثون', 'أربعون', 'خمسون', 'ستون', 'سبعون', 'ثمانون', 'تسعون'];
  const hundreds = ['', 'مائة', 'مائتان', 'ثلاثمائة', 'أربعمائة', 'خمسمائة', 'ستمائة', 'سبعمائة', 'ثمانمائة', 'تسعمائة'];
  String below1000(int n) {
    final parts = <String>[];
    if (n >= 100) parts.add(hundreds[n ~/ 100]);
    final r = n % 100;
    if (r > 0) {
      if (r < 20) {
        parts.add(ones[r]);
      } else {
        final o = r % 10;
        parts.add(o > 0 ? '${ones[o]} و${tens[r ~/ 10]}' : tens[r ~/ 10]);
      }
    }
    return parts.join(' و');
  }

  // [one, two, 3-10 (plural), 11+ (accusative)]
  String scale(int n, List<String> w) {
    if (n == 1) return w[0];
    if (n == 2) return w[1];
    if (n >= 3 && n <= 10) return '${below1000(n)} ${w[2]}';
    return '${below1000(n)} ${w[3]}';
  }

  final parts = <String>[];
  final billions = x ~/ 1000000000;
  x %= 1000000000;
  final millions = x ~/ 1000000;
  x %= 1000000;
  final thousands = x ~/ 1000;
  final rest = x % 1000;
  if (billions > 0) parts.add(scale(billions, const ['مليار', 'ملياران', 'مليارات', 'مليارًا']));
  if (millions > 0) parts.add(scale(millions, const ['مليون', 'مليونان', 'ملايين', 'مليونًا']));
  if (thousands > 0) parts.add(scale(thousands, const ['ألف', 'ألفان', 'آلاف', 'ألفًا']));
  if (rest > 0) parts.add(below1000(rest));
  return parts.join(' و');
}

/// Preview + print / share of a unit's reservation form.
class ReservationFormPage extends StatelessWidget {
  final Map<String, dynamic> unit;
  const ReservationFormPage({super.key, required this.unit});

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final name = 'استمارة حجز ${unit['projectName'] ?? ''} - وحدة ${unit['unitNo'] ?? ''} - ${unit['clientName'] ?? ''}';
    return AppBackground(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: isDark, isRTL: true, title: 'استمارة حجز وحدة'),
              Expanded(
                child: PdfPreview(
                  build: (_) => ReservationForm.build(unit),
                  initialPageFormat: PdfPageFormat.a4,
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  allowSharing: true,
                  allowPrinting: true,
                  pdfFileName: '$name.pdf',
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
