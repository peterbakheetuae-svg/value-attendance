import 'package:flutter_test/flutter_test.dart';
import 'package:jph_real_estate_hr/jph/pages/exclusive/exclusive_projects_page.dart' show unitsFromTable;

void main() {
  test('a units sheet: Arabic / English headers, numbers with commas, empty rows skipped', () {
    final rows = unitsFromTable([
      ['رقم الوحدة', 'النوع', 'الدور', 'المساحة', 'سعر المتر', 'Price', 'عمود غريب'],
      ['A-1', 'سكني', '1', '120', '20,000', '', 'x'],
      ['', '', '', '', '', '', ''],
      ['A-2', 'إداري', '2', '80 م2', '', '1,500,000', ''],
    ]);
    expect(rows.length, 2);
    expect(rows[0], {'unitNo': 'A-1', 'unitType': 'سكني', 'floor': '1', 'areaM2': 120, 'meterPrice': 20000});
    expect(rows[1]['areaM2'], 80);
    expect(rows[1]['unitPrice'], 1500000);
  });
  test('no «رقم الوحدة» column → nothing', () {
    expect(unitsFromTable([['الاسم', 'السعر'], ['x', '1']]), isEmpty);
  });
}
