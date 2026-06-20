/// Where the sentence/context came from.
enum CaptureContextSource {
  /// Reconstructed from the OCR'd paragraph around the cursor.
  ocr,

  /// Taken from the user's explicit on-screen selection (highlight).
  selection,

  /// Shape-routed from a single copied clipboard selection — the cascade's
  /// fallback when OCR is empty/low-confidence, and the SR-off direct mode
  /// (US-4.2). The unit OR the context is filled by shape, the other is left
  /// for the user.
  clipboard,
}

/// The reconstructed capture: the unit the user targeted plus the sentence and
/// wider context around it. This is the output of the shared reconstruction
/// core and the payload the native plugin surfaces to the Flutter app.
///
/// NOTE: this is the *capture* shape, not the persisted/deduped unit. The
/// `target_language` choice and the deterministic, no-lemmatization dedup key
/// (provisional client-side, authoritative server-side via `backend/src/dedup-key.ts`)
/// happen later, in the overlay/save path.
class CaptureResult {
  /// The token under (or nearest) the cursor. Null when OCR found no word.
  final String? word;

  /// The full OCR line that contained [word]. Null when none.
  final String? line;

  /// The sentence [word] belongs to, reconstructed across line wraps, or the
  /// user's selected text when [contextSource] is [CaptureContextSource.selection].
  final String? sentence;

  /// The wider context window (the sentence plus neighbouring sentences).
  final String context;

  /// Total number of OCR lines recognized on screen (diagnostic).
  final int recognizedLineCount;

  /// The display name of the screen the capture came from (diagnostic).
  final String screenName;

  /// The capture SOURCE application's name (e.g. "Google Chrome", "Books"), or
  /// null when unresolved — provenance metadata ("where I met this word"). Carried
  /// from [OcrSnapshot.sourceApp] through to the overlay's Save. Plaintext end to end.
  final String? sourceApp;

  /// The capture source WINDOW's title (the page/document title), or null when the
  /// window exposes none. Carried from [OcrSnapshot.sourceTitle]; plaintext on-device,
  /// encrypted at rest once synced.
  final String? sourceTitle;

  /// Whether [sentence]/[context] came from OCR reconstruction or a selection.
  final CaptureContextSource contextSource;

  /// OCR confidence [0,1] of the content this result was built from — the
  /// *targeted* line under the cursor (OCR branch) or the most-confident line
  /// inside the user's selection (selection branch). The cascade gates on THIS,
  /// not a screen-wide max, so a confident headline elsewhere can't prop up a
  /// blurry word at the cursor. Defaults to 1.0 for results that did not come
  /// from OCR targeting (clipboard-routed / fully-trusted), so they are never
  /// gated out.
  final double confidence;

  /// The dominant language of the captured SPAN (the sentence/context around the
  /// cursor), detected natively (`NLLanguageRecognizer`), or null when undetected.
  /// A recognition HINT for the overlay's target-language suggestion — see
  /// `suggestedTargetLanguage` — NOT attribution. The span (not the bare unit) is
  /// detected so the signal is reliable (sentence context defeats single-word noise).
  final String? detectedSpanLanguage;

  /// [detectedSpanLanguage]'s [0,1] confidence (0 when undetected).
  final double detectedSpanLanguageConfidence;

  const CaptureResult({
    required this.word,
    required this.line,
    required this.sentence,
    required this.context,
    required this.recognizedLineCount,
    required this.screenName,
    this.sourceApp,
    this.sourceTitle,
    required this.contextSource,
    this.confidence = 1.0,
    this.detectedSpanLanguage,
    this.detectedSpanLanguageConfidence = 0,
  });

  /// True when nothing usable was recognized (no word and no context).
  bool get isEmpty => (word == null || word!.isEmpty) && context.isEmpty;

  Map<String, dynamic> toMap() => {
        'word': word,
        'line': line,
        'sentence': sentence,
        'context': context,
        'recognizedLineCount': recognizedLineCount,
        'screenName': screenName,
        if (sourceApp != null) 'sourceApp': sourceApp,
        if (sourceTitle != null) 'sourceTitle': sourceTitle,
        'contextSource': contextSource.name,
        'confidence': confidence,
        if (detectedSpanLanguage != null) 'detectedSpanLanguage': detectedSpanLanguage,
        'detectedSpanLanguageConfidence': detectedSpanLanguageConfidence,
      };

  @override
  String toString() =>
      'CaptureResult(word: $word, sentence: $sentence, source: ${contextSource.name})';
}
