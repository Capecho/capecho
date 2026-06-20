import 'dart:convert';
import 'dart:io';

import 'package:capecho_api/capecho_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the QUEUE half of the widget cross-language contract: the Swift
/// `WidgetGradeEvent.jsonObject()` and the Dart `SyncEvent` wire are BOTH asserted against this one
/// committed fixture (mirroring the snapshot golden), so a key/type rename on either side is caught
/// rather than silently drifting. The Swift assertion lives in WidgetReviewKit's
/// `WidgetReviewSessionTests.testGradeEventMatchesTheCommittedGolden`.
Map<String, dynamic> _golden() =>
    jsonDecode(File('test/fixtures/widget_grade_event.golden.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  test('SyncEvent decodes the committed widget grade-event golden', () {
    final e = SyncEvent.fromJson(_golden());
    expect(e.wordId, 'w-ledger');
    expect(e.eventId, 'snap-fixture-1#0'); // the widget's deterministic "<snapshotId>#<cursor>" id
    expect(e.rating, Rating.good); // wire 3
    expect(e.clientReviewTs, 1733616000000);
    expect(e.source, 'widget');
  });

  test('the Dart SyncEvent encoder reproduces the golden exactly', () {
    const e = SyncEvent(
      wordId: 'w-ledger',
      eventId: 'snap-fixture-1#0',
      rating: Rating.good,
      clientReviewTs: 1733616000000,
      source: 'widget',
    );
    expect(e.toJson(), equals(_golden()));
  });
}
