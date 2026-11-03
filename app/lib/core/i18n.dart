import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart';

/// JSON-backed strings (same approach as the original app: `assets/l10n/<lang>.json`).
/// Arabic is primary. A missing key renders as the key itself so gaps are visible in QA;
/// test/i18n_test.dart fails the build if ar/en keys diverge.
class I18n {
  static final Map<String, Map<String, String>> _tables = {};
  static String lang = 'ar';

  static Future<void> load() async {
    for (final l in const ['ar', 'en']) {
      final raw = await rootBundle.loadString('assets/l10n/$l.json');
      _tables[l] = (json.decode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, v.toString()));
    }
  }

  /// For tests: inject tables directly.
  static void setTables(Map<String, Map<String, String>> t) {
    _tables
      ..clear()
      ..addAll(t);
  }

  static String t(String key, [Map<String, Object?> args = const {}]) {
    var s = _tables[lang]?[key] ?? _tables['ar']?[key] ?? key;
    args.forEach((k, v) => s = s.replaceAll('{$k}', '${v ?? ''}'));
    return s;
  }

  static bool get isRtl => lang == 'ar';
  static TextDirection get direction => isRtl ? TextDirection.rtl : TextDirection.ltr;
}

String t(String key, [Map<String, Object?> args = const {}]) => I18n.t(key, args);
