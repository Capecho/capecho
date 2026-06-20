import 'package:capecho/backend/distribution.dart';
import 'package:flutter_test/flutter_test.dart';

/// The distribution gate decides the Pro upgrade's payment rail (Stripe for direct, Apple IAP for the
/// Mac App Store). These pin the SAFE DEFAULT: a plain build — dev, `flutter run`, the test runner, and
/// the Developer ID direct release — must resolve to `direct` (Stripe) and NEVER accidentally to the IAP
/// rail. The `mas` value is only ever set by `--dart-define=CAPECHO_DIST=mas` (build_mas.sh) or the
/// runtime receipt backstop, neither of which is present here.
void main() {
  test('kCapechoDist defaults to "direct" with no --dart-define', () {
    expect(kCapechoDist, 'direct');
  });

  test('no Mac App Store receipt under the test runner (it is not a store install)', () {
    // The test runner binary has no `Contents/_MASReceipt/receipt` beside it.
    expect(hasMacAppStoreReceipt(), isFalse);
  });

  test('isMacAppStoreBuild() is false for a default (direct) build', () {
    // Neither signal present (flag is "direct", no receipt) → the Stripe rail. This is the guard against
    // a non-MAS build ever showing the IAP paywall.
    expect(isMacAppStoreBuild(), isFalse);
  });
}
