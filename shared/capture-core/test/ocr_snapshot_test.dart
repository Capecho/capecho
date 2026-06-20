import 'package:capecho_capture_core/capecho_capture_core.dart';
import 'package:test/test.dart';

void main() {
  group('OcrLine.paragraphId serialization (native layout hint)', () {
    test('round-trips through toMap/fromMap; id 0 is a valid value', () {
      const line = OcrLine('hi', NormRect(0.1, 0.2, 0.3, 0.04), paragraphId: 0);
      final back = OcrLine.fromMap(line.toMap());
      expect(back.paragraphId, 0); // 0 must survive, not read as "absent"
      expect(back.text, 'hi');
    });

    test('omits the key when null and reads back null', () {
      const line = OcrLine('hi', NormRect(0.1, 0.2, 0.3, 0.04));
      expect(line.toMap().containsKey('paragraphId'), isFalse);
      expect(OcrLine.fromMap(line.toMap()).paragraphId, isNull);
    });

    test('tolerates a num (int OR double) from the method channel', () {
      Map<String, dynamic> mapWith(Object pid) => {
            'text': 'x',
            'box': const NormRect(0, 0, 1, 1).toMap(),
            'paragraphId': pid,
          };
      expect(OcrLine.fromMap(mapWith(3)).paragraphId, 3);
      expect(OcrLine.fromMap(mapWith(3.0)).paragraphId, 3);
    });
  });

  group('visual span serialization', () {
    test('fontRuns round-trip through OcrLine maps', () {
      const run = OcrVisualRun(
        lineIndex: 7,
        runIndex: 1,
        utf16Start: 3,
        utf16End: 9,
        text: 'visual',
        box: NormRect(0.2, 0.3, 0.4, 0.05),
        fontSizePx: 32,
        fontSizePt: 16,
      );
      const line = OcrLine(
        'one visual run',
        NormRect(0.1, 0.2, 0.8, 0.06),
        fontRuns: [run],
      );

      final restored = OcrLine.fromMap(line.toMap());

      expect(restored.fontRuns, hasLength(1));
      expect(restored.fontRuns.single.text, 'visual');
      expect(restored.fontRuns.single.lineIndex, 7);
      expect(restored.fontRuns.single.fontSizePt, 16);
    });

    test('wordRuns round-trip through OcrLine maps', () {
      const run = OcrWordRun(
        lineIndex: 3,
        utf16Start: 2,
        utf16End: 4,
        text: '学习',
        box: NormRect(0.2, 0.3, 0.15, 0.05),
      );
      const line = OcrLine(
        '我在学习中文',
        NormRect(0.1, 0.2, 0.8, 0.06),
        wordRuns: [run],
      );

      final restored = OcrLine.fromMap(line.toMap());

      expect(restored.wordRuns, hasLength(1));
      expect(restored.wordRuns.single.text, '学习');
      expect(restored.wordRuns.single.utf16Start, 2);
      expect(restored.wordRuns.single.utf16End, 4);
      expect(restored.wordRuns.single.lineIndex, 3);
    });

    test('cursorVisualSpan round-trips through OcrSnapshot maps', () {
      const segment = OcrVisualRun(
        lineIndex: 2,
        runIndex: 0,
        utf16Start: 0,
        utf16End: 9,
        text: 'Essential',
        box: NormRect(0.1, 0.5, 0.3, 0.04),
        fontSizePx: 34,
        fontSizePt: 17,
      );
      const span = CursorVisualSpan(
        text: 'Essential',
        lineIndices: [2],
        anchor: CursorVisualSpanAnchor(
          lineIndex: 2,
          runIndex: 0,
          position: 'whole',
          fontSizePx: 34,
          fontSizePt: 17,
          lineHeightPx: 34,
          lineHeightPt: 17,
        ),
        segments: [segment],
      );
      const snapshot = OcrSnapshot(
        lines: [OcrLine('Essential', NormRect(0.1, 0.5, 0.3, 0.04))],
        cursor: NormPoint(0.2, 0.52),
        cursorVisualSpan: span,
      );

      final restored = OcrSnapshot.fromMap(snapshot.toMap());

      expect(restored.cursorVisualSpan, isNotNull);
      expect(restored.cursorVisualSpan!.text, 'Essential');
      expect(restored.cursorVisualSpan!.anchor.lineIndex, 2);
      expect(restored.cursorVisualSpan!.segments.single.text, 'Essential');
    });

    test('sourceApp/sourceTitle round-trip through OcrSnapshot maps', () {
      const snapshot = OcrSnapshot(
        lines: [OcrLine('hi', NormRect(0, 0, 1, 1))],
        cursor: NormPoint(0.2, 0.5),
        sourceApp: 'Google Chrome',
        sourceTitle: 'Serendipity — Wikipedia',
      );
      final restored = OcrSnapshot.fromMap(snapshot.toMap());
      expect(restored.sourceApp, 'Google Chrome');
      expect(restored.sourceTitle, 'Serendipity — Wikipedia');
    });

    test('OcrSnapshot omits source keys when null and reads back null', () {
      const snapshot = OcrSnapshot(
        lines: [OcrLine('hi', NormRect(0, 0, 1, 1))],
        cursor: NormPoint(0.2, 0.5),
      );
      final map = snapshot.toMap();
      expect(map.containsKey('sourceApp'), isFalse);
      expect(map.containsKey('sourceTitle'), isFalse);
      final restored = OcrSnapshot.fromMap(map);
      expect(restored.sourceApp, isNull);
      expect(restored.sourceTitle, isNull);
    });
  });
}
