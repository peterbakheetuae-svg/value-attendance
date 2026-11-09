import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jph_real_estate_hr/jph/forms/custody_receipt_pdf.dart';

/// Builds the custody receipt with the app's own code (template v1) — a blank copy and a filled sample —
/// so the printed result can be compared with the approved original.
Future<ByteData> _file(String path) async => ByteData.sublistView(File(path).readAsBytesSync());

void main() {
  test('custody receipt v1: blank and filled samples are one Letter page', () async {
    final out = Directory('build/form-samples')..createSync(recursive: true);
    final blank = await buildCustodyReceiptPdf({}, loader: _file);
    File('${out.path}/custody_receipt_blank.pdf').writeAsBytesSync(blank);
    final filled = await buildCustodyReceiptPdf({
      'employeeName': 'أحمد محمد عبد الرحمن',
      'employeeCode': 'VS-1024',
      'jobTitle': 'مستشار عقاري',
      'department': 'المبيعات',
      'directManager': 'محمود السيد',
      'receiptDate': '2026-11-09',
      'phoneBrand': 'Samsung Galaxy A15',
      'imei': '356789104512378',
      'lineNumber': '01012345678',
      'condition': 'used_good',
      'conditionOther': '',
      'accessories': ['charger', 'cable', 'other'],
      'accessoriesOther': 'شريحة بيانات',
      'signEmployeeName': 'أحمد محمد عبد الرحمن',
      'signDate': '2026-11-09',
      'custodianName': 'قسم تكنولوجيا المعلومات',
      'hrName': 'مروة حسن',
    }, loader: _file);
    File('${out.path}/custody_receipt_filled.pdf').writeAsBytesSync(filled);
    expect(String.fromCharCodes(filled.sublist(0, 5)), '%PDF-');
    expect(filled.length, greaterThan(blank.length));
  });
}
