import 'capture_result.dart';
import 'ocr_snapshot.dart';
import 'reconstructor.dart';
import 'sentence_context.dart';
import 'text_shape.dart';

/// Tunable knobs for the capture cascade (US-4.1, issue #12).
///
/// The freshness *window* itself lives natively — the adapter timestamps
/// clipboard changes and reports a `fresh` bool — so these are the Dart-side
/// thresholds only. Calibrate against real surfaces in M0a (ENG-8).
class CascadeOptions {
  /// Minimum OCR confidence [0,1] of the line UNDER THE CURSOR for OCR to win
  /// the cascade outright (CaptureResult.confidence, not a screen-wide max).
  /// Below it, a fresh clipboard may override. Vision's accurate-mode
  /// confidence is high for clean text and drops on ambiguous regions; 0.30 is
  /// a conservative "is this OCR garbage?" gate, not a precision tuner.
  final double ocrConfidenceThreshold;

  /// A clipboard selection with more than this many whitespace-separated words
  /// (or any sentence-terminal punctuation with >1 word) routes to the CONTEXT;
  /// otherwise it routes to the UNIT (word/short phrase). The overlay's inline
  /// edit is the safety net for a wrong guess (US-4.2), so this is deliberately
  /// simple, not a parser.
  final int phraseWordCeiling;

  const CascadeOptions({
    this.ocrConfidenceThreshold = 0.30,
    this.phraseWordCeiling = 4,
  });
}

/// Runs the OCR→clipboard capture cascade over a native [OcrSnapshot] and
/// returns a single [CaptureResult]. It composes the pure [CaptureReconstructor]
/// for the OCR branch, then applies the issue-#12 tiebreak:
///
/// 1. **OCR wins** when it reconstructs something AND its confidence ≥
///    [CascadeOptions.ocrConfidenceThreshold].
/// 2. Otherwise (empty/low-confidence OCR) a **clipboard** candidate is used
///    ONLY when it is *fresh* (a deliberate copy just before the hotkey). SR-off
///    direct mode gets a more generous freshness window natively (the clipboard
///    is its only input), but an old, unrelated clipboard never wins — it falls
///    through to the editable overlay (D4). Shape-routed to the unit or context.
/// 3. A non-empty but low-confidence OCR result is **kept over a stale
///    clipboard** (better than nothing).
/// 4. When nothing is usable, it returns an **empty** [CaptureResult]
///    (`isEmpty == true`) — the overlay's "Nothing found" state.
///
/// A usable-OCR snapshot with no clipboard resolves identically to a bare
/// `CaptureReconstructor.reconstruct`, so this is a safe drop-in for the
/// reconstruct-only path.
class CaptureCascade {
  const CaptureCascade({
    CaptureReconstructor reconstructor = const CaptureReconstructor(),
    this.options = const CascadeOptions(),
  }) : _reconstructor = reconstructor;

  final CaptureReconstructor _reconstructor;
  final CascadeOptions options;

  CaptureResult resolve(OcrSnapshot snapshot) {
    final ocr = _reconstructor.reconstruct(snapshot);
    // Gate on the confidence of the line under the cursor (CaptureResult.confidence
    // is the targeted line, not a screen-wide max) so a confident headline
    // elsewhere can't vouch for a blurry word at the cursor.
    final ocrUsable = !ocr.isEmpty && ocr.confidence >= options.ocrConfidenceThreshold;
    if (ocrUsable) return ocr;

    // OCR is empty or low-confidence — consider the clipboard. Clip to a bounded length first: a
    // multi-MB clipboard (a whole copied document) must not flow verbatim into the overlay, the fsync'd
    // journal, or the /explain payload (capture P1). The overlay's inline edit refines the rest.
    final clip = snapshot.clipboard;
    final clipText = LearningContextBuilder.clip((clip?.text ?? '').trim());
    if (clipText.isNotEmpty && clip!.fresh) {
      // Use the clipboard ONLY when it is FRESH — a deliberate copy just before the hotkey. (SR-off gets
      // a generous freshness window natively, since the clipboard is its only input; SR-on keeps the
      // tight window because there the clipboard merely OVERRIDES borderline OCR.) An old, unrelated
      // clipboard never becomes a confident capture (D4) — it falls through to the editable overlay.
      return _shapeRoute(clipText, snapshot);
    }

    // No usable/fresh clipboard. Keep a low-confidence OCR result if we have
    // one (better than nothing); otherwise the cascade found nothing.
    if (!ocr.isEmpty) return ocr;
    return CaptureResult(
      word: null,
      line: null,
      sentence: null,
      context: '',
      recognizedLineCount: snapshot.lines.length,
      screenName: snapshot.screenName,
      sourceApp: snapshot.sourceApp,
      sourceTitle: snapshot.sourceTitle,
      contextSource: CaptureContextSource.ocr,
    );
  }

  /// Routes a single copied selection to the unit or the context by shape
  /// (US-4.2): a word/short phrase fills the unit; a full sentence fills the
  /// context. The other field is left empty for the user. Source provenance
  /// (app/title/screen) still comes from the window under the cursor, even when
  /// the TEXT was shape-routed from the clipboard.
  CaptureResult _shapeRoute(String text, OcrSnapshot snapshot) {
    final isSentence = looksLikeSentence(text, phraseWordCeiling: options.phraseWordCeiling);
    return CaptureResult(
      word: isSentence ? null : text,
      line: null,
      sentence: isSentence ? text : null,
      context: isSentence ? text : '',
      recognizedLineCount: 0,
      screenName: snapshot.screenName,
      sourceApp: snapshot.sourceApp,
      sourceTitle: snapshot.sourceTitle,
      contextSource: CaptureContextSource.clipboard,
    );
  }
}
