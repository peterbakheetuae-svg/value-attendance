import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Arabic is primary and English must be complete: both tables have identical keys,
/// and every literal key used in lib/ exists.
void main() {
  final ar = (json.decode(File('assets/l10n/ar.json').readAsStringSync()) as Map).keys.toSet();
  final en = (json.decode(File('assets/l10n/en.json').readAsStringSync()) as Map).keys.toSet();

  test('ar and en have exactly the same keys', () {
    expect(ar.difference(en), isEmpty);
    expect(en.difference(ar), isEmpty);
  });

  test('every t(\'key\') used in lib/ exists', () {
    final used = <String>{};
    final re = RegExp(r"\bt\('([a-z0-9_]+)'");
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      used.addAll(re.allMatches(f.readAsStringSync()).map((m) => m.group(1)!));
    }
    expect(used.difference(ar), isEmpty);
  });

  test('dynamic status/type keys returned by the API are translated', () {
    const statuses = ['present', 'absent', 'weekend', 'holiday', 'approved_absence', 'unpaid_absence', 'mission', 'before_joining',
      'pending_manager', 'pending_hr', 'approved', 'rejected', 'cancelled', 'not_evaluated', 'in_progress', 'completed',
      'below_target', 'no_kpis', 'good', 'needs_attention', 'poor', 'published', 'draft', 'pending'];
    for (final s in statuses) { expect(ar, contains('status_$s')); }
    for (final s in ['hourly_permission', 'short_leave', 'full_day_absence', 'emergency_permission', 'attendance_correction']) {
      expect(ar, contains('type_$s'));
    }
  });
}
