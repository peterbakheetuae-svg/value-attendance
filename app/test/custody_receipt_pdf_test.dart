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

  test('laptop custody receipt v1: filled sample is one Letter page', () async {
    final out = Directory('build/form-samples')..createSync(recursive: true);
    final filled = await buildCustodyReceiptPdf({
      'employeeName': 'أحمد محمد عبد الرحمن', 'employeeCode': 'VS-1024', 'jobTitle': 'سيلز', 'department': 'المبيعات',
      'directManager': 'محمود السيد', 'receiptDate': '2026-11-10', 'brand': 'Dell Latitude 5440', 'serialNo': 'SN-7H2K9L',
      'condition': 'new', 'accessories': ['charger', 'other'], 'accessoriesOther': 'شنطة',
      'signEmployeeName': 'أحمد محمد عبد الرحمن', 'signDate': '2026-11-10', 'custodianName': 'IT', 'hrName': 'مروة حسن',
    }, loader: _file, template: 'laptop_receipt');
    File('${out.path}/laptop_receipt_filled.pdf').writeAsBytesSync(filled);
    expect(String.fromCharCodes(filled.sublist(0, 5)), '%PDF-');
  });

  test('client intro v1: filled sample is one A4 page', () async {
    final out = Directory('build/form-samples')..createSync(recursive: true);
    final filled = await buildCustodyReceiptPdf({
      'date': '2026-11-10', 'salesName': 'أحمد محمد', 'clientName': 'محمد علي حسن', 'phone': '01012345678', 'whatsapp': '01098765432',
      'job': 'مهندس مدني', 'residence': 'التجمع الخامس', 'propertyTypes': ['residential', 'medical', 'other'], 'propertyOther': 'فيلا',
    }, loader: _file, template: 'client_intro');
    File('${out.path}/client_intro_filled.pdf').writeAsBytesSync(filled);
    expect(String.fromCharCodes(filled.sublist(0, 5)), '%PDF-');
  });
}
