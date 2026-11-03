import 'package:flutter_test/flutter_test.dart';
import 'package:jph_real_estate_hr/core/format.dart';
import 'package:jph_real_estate_hr/core/i18n.dart';

void main() {
  setUp(() => I18n.setTables({'ar': {'egp': 'ج.م'}, 'en': {'egp': 'EGP'}}));

  test('minutes → h:mm', () {
    expect(Fmt.minutes(0), '0:00');
    expect(Fmt.minutes(135), '2:15');
    expect(Fmt.minutes(410), '6:50');
  });
  test('null is never shown as zero', () {
    expect(Fmt.percent(null), '—');
    expect(Fmt.num1(null), '—');
    expect(Fmt.egp(null), '—');
  });
  test('money is EGP', () {
    I18n.lang = 'en';
    expect(Fmt.egp(12000), '12,000.00 EGP');
    I18n.lang = 'ar';
  });
  test('month param', () => expect(Fmt.month(DateTime(2026, 3, 9)), '2026-03'));
}
