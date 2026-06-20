/// Capecho platform-neutral capture reconstruction core.
///
/// See `pubspec.yaml` for the architecture summary. Public surface:
/// - [OcrSnapshot] / [OcrLine] — the platform-neutral input from a native adapter.
/// - [NormRect] / [NormPoint] — normalized geometry (bottom-left origin; see
///   `src/geometry.dart` for the coordinate convention every adapter must match).
/// - [CaptureResult] / [CaptureContextSource] — the reconstructed output.
/// - [CaptureReconstructor] — the shared reconstruction pipeline.
/// - [CaptureCascade] — the OCR→clipboard cascade over a snapshot (US-4.1).
library;

export 'src/capture_cascade.dart';
export 'src/capture_result.dart';
export 'src/geometry.dart';
export 'src/gibberish_filter.dart' show isLikelyGibberish;
export 'src/junk_filter.dart' show isLikelyJunk;
export 'src/ocr_snapshot.dart';
export 'src/paragraph.dart' show ParagraphReconstructor, OcrLineSpan, FlowText;
export 'src/reconstructor.dart';
export 'src/sentence_context.dart' show LearningContextBuilder, LearningContext;
export 'src/surface_unit.dart' show surfaceUnit;
export 'src/tokenizer.dart' show OcrToken, Tokenizer;
export 'src/unit_language.dart'
    show
        UnitScript,
        dominantScript,
        scriptsOfLanguage,
        effectiveTargetLanguage,
        suggestedTargetLanguage,
        supportedTargetLanguages,
        suggestedTargetConfidenceGate,
        scriptCertainLanguage;
