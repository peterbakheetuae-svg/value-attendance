import 'dart:math';

/// Cryptographically secure random source. `Random.secure()` is backed by the
/// platform CSPRNG, which is what an idempotency token needs.
final Random _secureRandom = Random.secure();

/// Generates a canonical UUID version 4 (random) string.
///
/// Implemented locally instead of adding the `uuid` package: the whole surface
/// is 16 random bytes plus two bit twiddles, and adding a dependency would also
/// modify the tracked `pubspec.lock`.
///
/// Layout (RFC 4122 §4.4):
///   bytes[6] high nibble = 0100  → version 4
///   bytes[8] high bits   = 10    → variant RFC 4122
String uuidV4() {
  final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));

  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx

  final hex = StringBuffer();
  for (final b in bytes) {
    hex.write(b.toRadixString(16).padLeft(2, '0'));
  }
  final h = hex.toString();

  return '${h.substring(0, 8)}-'
      '${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-'
      '${h.substring(20, 32)}';
}
