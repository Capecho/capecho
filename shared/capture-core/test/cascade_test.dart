import 'package:capecho_capture_core/capecho_capture_core.dart';
import 'package:test/test.dart';

OcrWordRun run(int start, int end, String text, double minX, double maxX, {int line = 0}) =>
    OcrWordRun(
      lineIndex: line,
      utf16Start: start,
      utf16End: end,
      text: text,
      box: NormRect(minX, 0.5, maxX - minX, 0.02),
    );

/// A single full-width line "alpha beta gamma" at y0.5; cursor on "beta".
/// Reuses the reconstructor's well-known targeting fixture so the OCR branch is
/// known-good and the tests isolate the *cascade* decision.
OcrSnapshot ocrSnap({
  required double confidence,
  ClipboardCandidate? clipboard,
  bool screenRecordingEnabled = true,
}) =>
    OcrSnapshot(
      lines: [
        OcrLine(
          'alpha beta gamma',
          const NormRect(0.0, 0.5, 1.0, 0.02),
          confidence: confidence,
          wordRuns: [
            run(0, 5, 'alpha', 0.00, 0.31),
            run(6, 10, 'beta', 0.38, 0.63),
            run(11, 16, 'gamma', 0.69, 1.00),
          ],
        ),
      ],
      cursor: const NormPoint(0.5, 0.51),
      clipboard: clipboard,
      screenRecordingEnabled: screenRecordingEnabled,
    );

/// No recognized lines — OCR found nothing (SR on) or SR-off direct mode.
OcrSnapshot emptyOcrSnap({
  ClipboardCandidate? clipboard,
  bool screenRecordingEnabled = true,
}) =>
    OcrSnapshot(
      lines: const [],
      cursor: const NormPoint(0.5, 0.5),
      clipboard: clipboard,
      screenRecordingEnabled: screenRecordingEnabled,
    );

void main() {
  const cascade = CaptureCascade();

  group('OCR-wins branch', () {
    test('usable OCR wins outright, ignoring a fresh clipboard', () {
      final r = cascade.resolve(ocrSnap(
        confidence: 0.95,
        clipboard: const ClipboardCandidate(text: 'serendipity', fresh: true),
      ));
      expect(r.word, 'beta');
      expect(r.contextSource, CaptureContextSource.ocr);
    });

    test('a usable-OCR snapshot with no clipboard matches reconstruct()', () {
      final snap = ocrSnap(confidence: 0.95);
      final viaCascade = cascade.resolve(snap);
      final viaReconstruct = const CaptureReconstructor().reconstruct(snap);
      expect(viaCascade.word, viaReconstruct.word);
      expect(viaCascade.context, viaReconstruct.context);
      expect(viaCascade.contextSource, viaReconstruct.contextSource);
    });
  });

  group('clipboard-fallback branch (SR on)', () {
    test('low-confidence OCR + FRESH clipboard → clipboard wins', () {
      final r = cascade.resolve(ocrSnap(
        confidence: 0.1,
        clipboard: const ClipboardCandidate(text: 'serendipity', fresh: true),
      ));
      expect(r.contextSource, CaptureContextSource.clipboard);
      expect(r.word, 'serendipity');
    });

    test('empty OCR + FRESH clipboard → clipboard wins', () {
      final r = cascade.resolve(emptyOcrSnap(
        clipboard: const ClipboardCandidate(text: 'serendipity', fresh: true),
      ));
      expect(r.contextSource, CaptureContextSource.clipboard);
      expect(r.word, 'serendipity');
    });

    test('a huge clipboard SENTENCE is clipped to maxContextLength (P1 — no multi-MB capture)', () {
      // A whole copied document must not flow verbatim into the overlay / fsync'd journal / explain
      // payload. Many words → routes to CONTEXT, clipped to the 600-rune cap (the OCR path's limit).
      final huge = 'word ' * 5000; // ~25k runes
      final r = cascade.resolve(emptyOcrSnap(
        clipboard: ClipboardCandidate(text: huge, fresh: true),
      ));
      expect(r.contextSource, CaptureContextSource.clipboard);
      expect(r.word, isNull); // sentence-shaped
      expect(r.context.runes.length, greaterThan(0));
      // Bounded by clip() (<= cap+1). This fixture lands AT the 600 cap — its 600th char is a space, so
      // trim drops it before the … is appended. The exact bound is pinned in sentence_context_test.dart.
      expect(r.context.runes.length, lessThanOrEqualTo(601));
    });

    test('a huge no-space clipboard blob (routes to the UNIT) is also clipped (P1)', () {
      // The worst footgun: a megabyte no-space paste is one "word" → routes to the UNIT. It must be
      // bounded too, or a multi-MB unit lands in the field + journal.
      final blob = 'x' * 10000;
      final r = cascade.resolve(emptyOcrSnap(
        clipboard: ClipboardCandidate(text: blob, fresh: true),
      ));
      expect(r.word, isNotNull);
      expect(r.word!.runes.length, lessThanOrEqualTo(601)); // bounded (600 + ellipsis), not 10k
    });

    test('low-confidence OCR + STALE clipboard → keep low-conf OCR', () {
      final r = cascade.resolve(ocrSnap(
        confidence: 0.1,
        clipboard: const ClipboardCandidate(text: 'serendipity', fresh: false),
      ));
      // A stale clipboard never overrides a usable OCR result; the low-conf OCR
      // is better than nothing.
      expect(r.contextSource, CaptureContextSource.ocr);
      expect(r.word, 'beta');
    });

    test('empty OCR + STALE clipboard → nothing found', () {
      final r = cascade.resolve(emptyOcrSnap(
        clipboard: const ClipboardCandidate(text: 'serendipity', fresh: false),
      ));
      expect(r.isEmpty, isTrue);
    });

    test('empty OCR + no clipboard → nothing found', () {
      final r = cascade.resolve(emptyOcrSnap());
      expect(r.isEmpty, isTrue);
    });
  });

  group('SR-off direct-clipboard mode', () {
    test('SR off + FRESH clipboard → used (the deliberate copy→capture)', () {
      final r = cascade.resolve(emptyOcrSnap(
        screenRecordingEnabled: false,
        clipboard: const ClipboardCandidate(text: 'serendipity', fresh: true),
      ));
      expect(r.contextSource, CaptureContextSource.clipboard);
      expect(r.word, 'serendipity');
    });

    test('SR off + STALE clipboard → NOT used → empty/editable (no confident stale capture, D4)',
        () {
      // An old, unrelated clipboard must not become a confident capture; it falls through to the empty
      // (now editable) overlay instead. SR-off gets a generous freshness window NATIVELY, so a real
      // copy→⌥E still reads fresh — only a genuinely-old clipboard lands here.
      final r = cascade.resolve(emptyOcrSnap(
        screenRecordingEnabled: false,
        clipboard: const ClipboardCandidate(text: 'serendipity', fresh: false),
      ));
      expect(r.isEmpty, isTrue);
    });

    test('SR off + empty clipboard → nothing found', () {
      final r = cascade.resolve(emptyOcrSnap(
        screenRecordingEnabled: false,
        clipboard: const ClipboardCandidate(text: '   ', fresh: false),
      ));
      expect(r.isEmpty, isTrue);
    });
  });

  group('clipboard shape routing (US-4.2)', () {
    test('a single word routes to the unit', () {
      final r = cascade.resolve(emptyOcrSnap(
        clipboard: const ClipboardCandidate(text: 'serendipity', fresh: true),
      ));
      expect(r.word, 'serendipity');
      expect(r.context, isEmpty);
    });

    test('a short phrase routes to the unit', () {
      final r = cascade.resolve(emptyOcrSnap(
        clipboard: const ClipboardCandidate(text: 'cognitive load', fresh: true),
      ));
      expect(r.word, 'cognitive load');
      expect(r.context, isEmpty);
    });

    test('a full sentence routes to the context, leaving the unit empty', () {
      final r = cascade.resolve(emptyOcrSnap(
        clipboard: const ClipboardCandidate(
            text: 'The quick brown fox jumped over the lazy dog.', fresh: true),
      ));
      expect(r.word, isNull);
      expect(r.context, 'The quick brown fox jumped over the lazy dog.');
      expect(r.contextSource, CaptureContextSource.clipboard);
    });

    test('a short clause with terminal punctuation routes to context', () {
      final r = cascade.resolve(emptyOcrSnap(
        clipboard: const ClipboardCandidate(text: 'Stop now.', fresh: true),
      ));
      expect(r.context, 'Stop now.');
      expect(r.word, isNull);
    });
  });

  group('confidence threshold boundary (>=, CR #16)', () {
    test('exactly at the threshold (0.30), OCR wins over a fresh clipboard', () {
      final r = cascade.resolve(ocrSnap(
        confidence: 0.30,
        clipboard: const ClipboardCandidate(text: 'serendipity', fresh: true),
      ));
      expect(r.contextSource, CaptureContextSource.ocr);
      expect(r.word, 'beta');
    });

    test('just below the threshold (0.29), a fresh clipboard wins', () {
      final r = cascade.resolve(ocrSnap(
        confidence: 0.29,
        clipboard: const ClipboardCandidate(text: 'serendipity', fresh: true),
      ));
      expect(r.contextSource, CaptureContextSource.clipboard);
      expect(r.word, 'serendipity');
    });
  });

  group('targeted-line confidence, not screen-wide max (CR #1)', () {
    // A blurry word UNDER THE CURSOR + a crisp headline ELSEWHERE on screen.
    // The cursor line is low-confidence, so the screen-wide max (0.98) must NOT
    // keep the blurry OCR — the gate is the targeted line's confidence (0.12).
    OcrSnapshot blurryCursorCrispHeadline({required bool clipboardFresh}) => OcrSnapshot(
          lines: [
            OcrLine(
              'blurryword',
              const NormRect(0.0, 0.5, 0.6, 0.02),
              confidence: 0.12,
              wordRuns: [run(0, 10, 'blurryword', 0.0, 0.6)],
            ),
            OcrLine(
              'CLEAN HEADLINE',
              const NormRect(0.0, 0.8, 1.0, 0.02),
              confidence: 0.98,
              wordRuns: [
                run(0, 5, 'CLEAN', 0.0, 0.45, line: 1),
                run(6, 14, 'HEADLINE', 0.55, 1.0, line: 1),
              ],
            ),
          ],
          cursor: const NormPoint(0.3, 0.51), // sits on the blurry line
          clipboard: ClipboardCandidate(text: 'correctword', fresh: clipboardFresh),
        );

    test(
        'a confident headline elsewhere does not vouch for the cursor word: '
        'fresh clipboard wins', () {
      final r = cascade.resolve(blurryCursorCrispHeadline(clipboardFresh: true));
      expect(r.contextSource, CaptureContextSource.clipboard);
      expect(r.word, 'correctword');
    });

    test(
        'with a stale clipboard, the low-confidence cursor word is kept (not '
        'the headline, not nothing-found)', () {
      final r = cascade.resolve(blurryCursorCrispHeadline(clipboardFresh: false));
      expect(r.contextSource, CaptureContextSource.ocr);
      expect(r.word, 'blurryword');
    });
  });
}
