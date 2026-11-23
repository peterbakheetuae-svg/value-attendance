import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jph_real_estate_hr/jph/forms/unit_quote_pdf.dart';

/// «عرض سعر» of a unit / a resale / a rental: the owner's example (محل دور أرضي G - 19) gives exactly his figures.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the owner\'s example: 42.120 م × 160,000 = 6,739,200; 10% + 10% after 3 months; 3 years, every 3 months', () {
    final q = UnitQuote.of(
      {'unitType': 'محل', 'floor': 'أرضي', 'unitNo': 'G - 19', 'areaM2': 42.12, 'meterPrice': 160000},
      {'name': 'VALUE SQUARE'},
    );
    expect(q.unitName, 'محل دور أرضي G - 19');
    expect(q.total, 6739200);
    expect(q.down.round(), 673920);
    expect(q.second.round(), 673920);
    expect(q.remaining.round(), 5391360);
    expect(q.count, 12);
    expect(q.installment.round(), 449280);
    expect(q.monthly.round(), 149760);
    expect(quoteGroup(6739200), '6,739,200');
    expect(quoteUnitWord(6739200), 'مليون');
    expect(quoteUnitWord(673920), 'ألف');
  });

  test('the unit\'s own price wins over area × meter; the plan is editable', () {
    final q = UnitQuote.of({'unitType': 'شقة', 'floor': 'الثالث', 'unitNo': '305', 'areaM2': 100, 'meterPrice': 50000, 'unitPrice': 5200000}, {});
    expect(q.unitName, 'شقة دور الثالث 305');
    expect(q.total, 5200000);
    q
      ..downPct = 20
      ..secondPct = 0
      ..years = 5
      ..everyMonths = 1;
    expect(q.down, 1040000);
    expect(q.second, 0);
    expect(q.count, 60);
    expect(q.installment.round(), 69333);
    expect(q.monthly.round(), 69333);
  });

  test('the A4 PDF is built (Arabic fonts, no developer logo needed)', () async {
    final q = UnitQuote.of({'unitType': 'محل', 'floor': 'أرضي', 'unitNo': 'G - 19', 'areaM2': 42.12, 'meterPrice': 160000}, {'name': 'VALUE SQUARE'});
    final bytes = await UnitQuotePdf.build(q, loadLogos: false);
    expect(bytes.length, greaterThan(10000));
    expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
    final out = Platform.environment['QUOTE_PDF_OUT'];
    if (out != null) File(out).writeAsBytesSync(bytes);
  });

  test('a resale listing: cash by default (the whole price), a plan when chosen; meter price from price / area', () async {
    final q = UnitQuote.listing({'kind': 'resale', 'title': 'شقة', 'address': 'التجمع', 'area': 120, 'price': 2400000, 'finishingAr': 'سوبر لوكس'});
    expect([q.kind, q.cash, q.meterPrice, q.down, q.remaining, q.count, q.valid], ['resale', true, 20000, 2400000, 0, 0, true]);
    q.cash = false;
    expect([q.down, q.count > 0, q.valid], [240000, true, true]);
    final bytes = await UnitQuotePdf.build(q, loadLogos: false);
    expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
  });

  test('a rental listing: the rent paid every N months, the insurance, the first payment, the year', () async {
    final q = UnitQuote.listing({'kind': 'rental', 'title': 'محل', 'area': 60, 'price': 15000});
    q
      ..rentEveryMonths = 3
      ..insuranceMonths = 2;
    expect([q.rental, q.installments, q.rentPayment, q.insurance, q.firstRentPayment, q.yearlyRent, q.valid], [true, false, 45000, 30000, 75000, 180000, true]);
    final bytes = await UnitQuotePdf.build(q, loadLogos: false);
    expect(bytes.length, greaterThan(10000));
  });
}
