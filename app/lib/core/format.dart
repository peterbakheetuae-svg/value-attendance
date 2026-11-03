import 'package:intl/intl.dart';
import 'i18n.dart';

/// Formatting helpers. Server timestamps are UTC ISO strings; we show device-local time.
class Fmt {
  static DateTime? parse(Object? v) => v == null ? null : DateTime.tryParse(v.toString())?.toLocal();

  static String time(Object? iso) {
    final d = parse(iso);
    return d == null ? '—' : DateFormat('HH:mm').format(d);
  }

  static String date(Object? v) {
    if (v == null) return '—';
    final d = DateTime.tryParse(v.toString());
    return d == null ? v.toString() : DateFormat('yyyy/MM/dd').format(d);
  }

  static String dateTime(Object? iso) {
    final d = parse(iso);
    return d == null ? '—' : DateFormat('yyyy/MM/dd HH:mm').format(d);
  }

  /// 'YYYY-MM' for API month params.
  static String month(DateTime d) => DateFormat('yyyy-MM').format(d);

  static String monthLabel(DateTime d) {
    final names = I18n.lang == 'ar'
        ? const ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر']
        : const ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
    return '${names[d.month - 1]} ${d.year}';
  }

  /// 135 → "2:15" hours:minutes
  static String minutes(Object? m) {
    final n = (m is num) ? m.round() : int.tryParse('$m') ?? 0;
    return '${n ~/ 60}:${(n % 60).toString().padLeft(2, '0')}';
  }

  static String num1(Object? v) {
    if (v == null) return '—';
    final n = v is num ? v : num.tryParse('$v');
    if (n == null) return '—';
    return n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(1);
  }

  static String percent(Object? v) => v == null ? '—' : '${num1(v)}%';

  /// All money in this product is EGP.
  static String egp(Object? v) {
    if (v == null) return '—';
    final n = v is num ? v : num.tryParse('$v') ?? 0;
    return '${NumberFormat('#,##0.00').format(n)} ${t('egp')}';
  }
}
