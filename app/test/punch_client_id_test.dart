import 'package:flutter_test/flutter_test.dart';
import 'package:jph_real_estate_hr/core/api.dart';

/// SEC-06: every punch carries one UUID v4 (the server dedupes retries / second sends by it).
void main() {
  test('newClientId is a random RFC 4122 version-4 UUID', () {
    final re = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$');
    final ids = List.generate(200, (_) => ApiClient.newClientId());
    for (final id in ids) {
      expect(re.hasMatch(id), isTrue, reason: id);
    }
    expect(ids.toSet().length, ids.length);
  });

  test('only the three punches get a client id', () {
    expect(ApiClient.isPunchPath('/attendance/check-in'), isTrue);
    expect(ApiClient.isPunchPath('/attendance/check-out'), isTrue);
    expect(ApiClient.isPunchPath('/outings/return'), isTrue);
    expect(ApiClient.isPunchPath('/requests'), isFalse);
    expect(ApiClient.isPunchPath('/tracking/ping'), isFalse);
  });
}
