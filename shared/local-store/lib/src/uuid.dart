import 'dart:math';

/// Cryptographically-seeded RNG used for all id generation. Shared so that a single
/// `Random.secure()` instance is reused (cheaper than constructing one per call).
final Random _rng = Random.secure();

/// Generates an RFC-4122 version-4 (random) UUID, lowercase, hyphenated.
///
/// Deliberately implemented in-package so the store carries no `uuid` dependency. The
/// version nibble is forced to `4` and the variant high bits to `10` per RFC 4122 §4.4.
String uuidV4() {
  final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));

  // Version 4: high nibble of byte 6 is 0100.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  // Variant 1 (RFC 4122): high bits of byte 8 are 10.
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
