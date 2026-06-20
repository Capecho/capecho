import 'package:capecho_local_store/capecho_local_store.dart' show kJournalSources;
import 'package:capture_native/capture_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The Dart facade (`capture_native.dart`) and the repository send
  // `result.contextSource.name` straight through as the journal's source tag,
  // so `CaptureContextSource` and `kJournalSources` are coupled by STRING
  // identity with no compile-time link. A rename of an enum value
  // (e.g. clipboard → pasteboard) would make the journal drain reject the
  // record and wedge every later capture. This guard makes that
  // drift fail loudly here instead of silently in production.
  //
  // Note: the native Swift `allowedSources` set is a third copy with no test
  // target of its own; this Dart guard is the feasible tripwire, and the drain
  // would reject a bad source regardless.
  test('CaptureContextSource names match the journal source allow-list', () {
    final enumNames = CaptureContextSource.values.map((e) => e.name).toSet();
    expect(enumNames, equals(kJournalSources));
  });
}
