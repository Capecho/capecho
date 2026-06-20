import 'geometry.dart';

/// A system word-boundary hint emitted by the native OCR adapter.
///
/// macOS produces these with `NLTokenizer(unit: .word)`; Windows should emit
/// the same shape from its word-boundary API. Ranges are UTF-16 offsets into the
/// source [OcrLine.text], and [box] is normalized in the same coordinate space
/// as the line box.
class OcrWordRun {
  final int lineIndex;
  final int utf16Start;
  final int utf16End;
  final String text;
  final NormRect box;

  const OcrWordRun({
    required this.lineIndex,
    required this.utf16Start,
    required this.utf16End,
    required this.text,
    required this.box,
  });

  factory OcrWordRun.fromMap(Map<dynamic, dynamic> map) {
    final range = map['range'] as Map<dynamic, dynamic>? ?? const {};
    return OcrWordRun(
      lineIndex: (map['lineIndex'] as num?)?.toInt() ?? -1,
      utf16Start: (range['start'] as num?)?.toInt() ?? 0,
      utf16End: (range['end'] as num?)?.toInt() ?? 0,
      text: (map['text'] as String?) ?? '',
      box: NormRect.fromMap(map['box'] as Map<dynamic, dynamic>),
    );
  }

  Map<String, dynamic> toMap() => {
        'lineIndex': lineIndex,
        'range': {
          'start': utf16Start,
          'end': utf16End,
        },
        'text': text,
        'box': box.toMap(),
      };
}

/// One recognized line of text with its normalized bounding box.
///
/// This is the atomic unit a native OCR adapter produces. The adapter should
/// attach [wordRuns] from the platform word-boundary engine; the shared core
/// consumes those runs to choose the cursor unit and reconstruct context.
class OcrLine {
  final String text;
  final NormRect box;

  /// OCR confidence for this line's top candidate, in [0,1] (Vision's
  /// `VNRecognizedText.confidence`). Defaults to 1.0 when an adapter does not
  /// report it, so confidence-unaware snapshots/fixtures still read as fully
  /// usable. The cascade uses the max line confidence to decide whether OCR is
  /// trustworthy enough to win over a fresh clipboard (US-4.1, issue #12).
  final double confidence;

  /// Real per-character bounding boxes for [text], in the SAME normalized space
  /// as [box], when the adapter can supply the OCR engine's true glyph geometry
  /// (macOS Vision's `VNRecognizedText.boundingBox(for:)`). One entry per UTF-16
  /// code unit of [text] — a non-BMP character's box is repeated across both
  /// surrogate halves — so a token's box is the union of `charBoxes` over its
  /// `[utf16Start, utf16Start+utf16Length)` range, indexable directly.
  ///
  /// Null when the adapter only sends line/word boxes. A zero-size entry marks
  /// a per-glyph gap the engine couldn't box. These boxes are used by selection
  /// sub-line extraction, not as the primary hover tokenization path.
  final List<NormRect>? charBoxes;

  /// The index of the PARAGRAPH this line belongs to, when the native adapter
  /// could supply a platform layout-analysis grouping (macOS 26+ Vision
  /// `RecognizeDocumentsRequest`). Lines that share a [paragraphId] are one
  /// paragraph; the reconstructor groups by it directly — the platform's trained
  /// model, no geometric heuristic. Null when the adapter has no layout model
  /// (older macOS, Windows), where [ParagraphReconstructor] falls back to its
  /// line-spacing / font-size signals. The value is only an identity tag (its
  /// numeric magnitude is meaningless); a missing match leaves it null.
  ///
  /// INVARIANT: the reconstructor groups by id ALONE (no column check), so an
  /// adapter MUST NOT reuse one id across separate columns. The macOS adapter is
  /// safe — it assigns each line to the Vision paragraph box containing it, and
  /// those boxes are column-scoped.
  final int? paragraphId;

  /// Visual text runs detected by the native adapter within this OCR line.
  ///
  /// This is platform-neutral layout metadata: macOS estimates it from Vision
  /// range boxes; Windows should emit the same shape from its OCR/layout API.
  /// Runs are used to describe visual continuity around the cursor, especially
  /// mixed-size rows and separate modules on one horizontal band.
  final List<OcrVisualRun> fontRuns;

  /// System word-boundary hints for this OCR line.
  ///
  /// This is the authoritative tokenization input for OCR hover. Null/empty
  /// means the adapter did not provide system word boundaries, so no hover token
  /// is reconstructed for that line.
  final List<OcrWordRun> wordRuns;

  const OcrLine(
    this.text,
    this.box, {
    this.confidence = 1.0,
    this.charBoxes,
    this.paragraphId,
    this.fontRuns = const [],
    this.wordRuns = const [],
  });

  factory OcrLine.fromMap(Map<dynamic, dynamic> map) {
    final rawCharBoxes = map['charBoxes'] as List<dynamic>?;
    final rawFontRuns = map['fontRuns'] as List<dynamic>? ?? const [];
    final rawWordRuns = map['wordRuns'] as List<dynamic>? ?? const [];
    return OcrLine(
      map['text'] as String,
      NormRect.fromMap(map['box'] as Map<dynamic, dynamic>),
      confidence: (map['confidence'] as num?)?.toDouble() ?? 1.0,
      charBoxes: rawCharBoxes == null
          ? null
          : <NormRect>[
              for (final e in rawCharBoxes) NormRect.fromMap(e as Map<dynamic, dynamic>),
            ],
      paragraphId: (map['paragraphId'] as num?)?.toInt(),
      fontRuns: rawFontRuns
          .map((e) => OcrVisualRun.fromMap(e as Map<dynamic, dynamic>))
          .toList(growable: false),
      wordRuns: rawWordRuns
          .map((e) => OcrWordRun.fromMap(e as Map<dynamic, dynamic>))
          .toList(growable: false),
    );
  }

  Map<String, dynamic> toMap() => {
        'text': text,
        'box': box.toMap(),
        'confidence': confidence,
        if (charBoxes != null) 'charBoxes': [for (final b in charBoxes!) b.toMap()],
        if (paragraphId != null) 'paragraphId': paragraphId,
        if (fontRuns.isNotEmpty) 'fontRuns': [for (final run in fontRuns) run.toMap()],
        if (wordRuns.isNotEmpty) 'wordRuns': [for (final run in wordRuns) run.toMap()],
      };

  @override
  String toString() => 'OcrLine(${box.toString()}, "$text", c=$confidence)';
}

/// A visually continuous run inside one OCR line.
///
/// The native adapter should split runs when estimated font size changes or
/// when a horizontal gap is large enough to indicate a separate text module.
/// Ranges are UTF-16 offsets into the source line text.
class OcrVisualRun {
  final int lineIndex;
  final int runIndex;
  final int utf16Start;
  final int utf16End;
  final String text;
  final NormRect box;
  final double fontSizePx;
  final double fontSizePt;

  const OcrVisualRun({
    required this.lineIndex,
    required this.runIndex,
    required this.utf16Start,
    required this.utf16End,
    required this.text,
    required this.box,
    required this.fontSizePx,
    required this.fontSizePt,
  });

  factory OcrVisualRun.fromMap(Map<dynamic, dynamic> map) {
    final range = map['range'] as Map<dynamic, dynamic>? ?? const {};
    final fontSize = map['fontSize'] as Map<dynamic, dynamic>? ?? const {};
    return OcrVisualRun(
      lineIndex: (map['lineIndex'] as num?)?.toInt() ?? -1,
      runIndex: (map['runIndex'] as num?)?.toInt() ?? -1,
      utf16Start: (range['start'] as num?)?.toInt() ?? 0,
      utf16End: (range['end'] as num?)?.toInt() ?? 0,
      text: (map['text'] as String?) ?? '',
      box: NormRect.fromMap(map['box'] as Map<dynamic, dynamic>),
      fontSizePx: (fontSize['px'] as num?)?.toDouble() ?? 0,
      fontSizePt: (fontSize['pt'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'lineIndex': lineIndex,
        'runIndex': runIndex,
        'range': {
          'start': utf16Start,
          'end': utf16End,
        },
        'text': text,
        'box': box.toMap(),
        'fontSize': {
          'px': fontSizePx,
          'pt': fontSizePt,
        },
      };
}

/// Native visual-continuity result around the cursor.
///
/// This deliberately describes visual layout, not language sentences. Dart
/// still runs sentence/windowing on [text]. When present, it is the preferred
/// OCR context input because it has already excluded visually unrelated rows
/// such as small subtitles or neighbouring modules.
class CursorVisualSpan {
  final int schemaVersion;
  final String text;
  final List<int> lineIndices;
  final CursorVisualSpanAnchor anchor;
  final List<OcrVisualRun> segments;

  /// The dominant language of [text] (BCP-47, from `NLLanguageRecognizer`), or
  /// null when undetected. A HINT for the Phase-2 unit-language confirm — it lets
  /// the core suggest switching the capture target when the user is reading a
  /// passage in a language other than their learning target (the same-script case
  /// the deterministic script auto-switch can't decide). NEVER sets attribution.
  final String? detectedLanguage;

  /// [detectedLanguage]'s [0,1] confidence (0 when undetected).
  final double detectedLanguageConfidence;

  const CursorVisualSpan({
    this.schemaVersion = 1,
    required this.text,
    required this.lineIndices,
    required this.anchor,
    required this.segments,
    this.detectedLanguage,
    this.detectedLanguageConfidence = 0,
  });

  bool get isUsable => text.trim().isNotEmpty && segments.isNotEmpty;

  factory CursorVisualSpan.fromMap(Map<dynamic, dynamic> map) {
    final rawLineIndices = map['lineIndices'] as List<dynamic>? ?? const [];
    final rawSegments = map['segments'] as List<dynamic>? ?? const [];
    return CursorVisualSpan(
      schemaVersion: (map['schemaVersion'] as num?)?.toInt() ?? 1,
      text: (map['text'] as String?) ?? '',
      lineIndices: rawLineIndices.map((e) => (e as num).toInt()).toList(growable: false),
      anchor: CursorVisualSpanAnchor.fromMap(map['anchor'] as Map<dynamic, dynamic>? ?? const {}),
      segments: rawSegments
          .map((e) => OcrVisualRun.fromMap(e as Map<dynamic, dynamic>))
          .toList(growable: false),
      detectedLanguage: map['detectedLanguage'] as String?,
      detectedLanguageConfidence: (map['detectedLanguageConfidence'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'schemaVersion': schemaVersion,
        'text': text,
        'lineIndices': lineIndices,
        'anchor': anchor.toMap(),
        'segments': [for (final segment in segments) segment.toMap()],
        if (detectedLanguage != null) 'detectedLanguage': detectedLanguage,
        'detectedLanguageConfidence': detectedLanguageConfidence,
      };
}

class CursorVisualSpanAnchor {
  final int lineIndex;
  final int runIndex;
  final int utf16Offset;
  final String position;
  final double fontSizePx;
  final double fontSizePt;
  final double lineHeightPx;
  final double lineHeightPt;

  const CursorVisualSpanAnchor({
    required this.lineIndex,
    required this.runIndex,
    this.utf16Offset = -1,
    required this.position,
    required this.fontSizePx,
    required this.fontSizePt,
    required this.lineHeightPx,
    required this.lineHeightPt,
  });

  factory CursorVisualSpanAnchor.fromMap(Map<dynamic, dynamic> map) => CursorVisualSpanAnchor(
        lineIndex: (map['lineIndex'] as num?)?.toInt() ?? -1,
        runIndex: (map['runIndex'] as num?)?.toInt() ?? -1,
        utf16Offset: (map['utf16Offset'] as num?)?.toInt() ?? -1,
        position: (map['position'] as String?) ?? 'unknown',
        fontSizePx: (map['fontSizePx'] as num?)?.toDouble() ?? 0,
        fontSizePt: (map['fontSizePt'] as num?)?.toDouble() ?? 0,
        lineHeightPx: (map['lineHeightPx'] as num?)?.toDouble() ?? 0,
        lineHeightPt: (map['lineHeightPt'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toMap() => {
        'lineIndex': lineIndex,
        'runIndex': runIndex,
        'utf16Offset': utf16Offset,
        'position': position,
        'fontSizePx': fontSizePx,
        'fontSizePt': fontSizePt,
        'lineHeightPx': lineHeightPx,
        'lineHeightPt': lineHeightPt,
      };
}

/// A clipboard reading captured natively at hotkey time (US-4.1/US-4.2).
///
/// [text] is the clipboard's string contents at the instant of capture; [fresh]
/// is true when the clipboard *changed* within the native freshness window just
/// before the hotkey (a deliberate copy-then-capture). The cascade uses [fresh]
/// to decide whether the clipboard may override a low-confidence/empty OCR — a
/// stale clipboard never overrides usable OCR (issue #12). Contents are read
/// only at capture time, never while idle.
class ClipboardCandidate {
  final String text;
  final bool fresh;

  const ClipboardCandidate({required this.text, required this.fresh});

  factory ClipboardCandidate.fromMap(Map<dynamic, dynamic> map) => ClipboardCandidate(
        text: (map['text'] as String?) ?? '',
        fresh: (map['fresh'] as bool?) ?? false,
      );

  Map<String, dynamic> toMap() => {'text': text, 'fresh': fresh};

  @override
  String toString() => 'ClipboardCandidate(fresh: $fresh, len: ${text.length})';
}

/// The platform-neutral OCR snapshot produced by a native capture adapter
/// (macOS Vision today, Windows.Media.Ocr later) and consumed by the shared
/// reconstruction core.
///
/// It contains everything the reconstruction needs and NOTHING platform
/// specific: recognized [lines] (with normalized boxes), the [cursor] position
/// in the same normalized space, an optional [selectionRect] (the user's
/// highlighted region, detected natively from screenshot pixels — null when the
/// user had no active selection), and lightweight metadata.
class OcrSnapshot {
  final List<OcrLine> lines;
  final NormPoint cursor;
  final NormRect? selectionRect;
  final String screenName;

  /// The capture SOURCE application's name (the owning app of the window under
  /// the cursor, e.g. "Google Chrome", "Books"), or null when it couldn't be
  /// resolved. Provenance metadata — "where I met this word" — never attribution.
  /// Low-sensitivity (the app, not its contents), so it stays PLAINTEXT end to end.
  final String? sourceApp;

  /// The capture source WINDOW's title (the page/document title of the window
  /// under the cursor), or null when the window exposes none. Carries the private
  /// specifics (a chat peer, a doc name), so it is plaintext only on-device and
  /// is ENCRYPTED AT REST once synced — same posture as the context sentence.
  final String? sourceTitle;

  final List<String> recognitionLanguages;
  final CursorVisualSpan? cursorVisualSpan;

  /// The clipboard reading at capture time, or null when the clipboard had no
  /// usable text. Feeds the cascade's OCR→clipboard fallback (US-4.1).
  final ClipboardCandidate? clipboard;

  /// Whether Screen Recording was granted (OCR was attempted). False = SR-off
  /// direct-clipboard mode (no OCR), where the clipboard is the only input. The
  /// cascade hard-requires a FRESH clipboard in both modes (D4); SR-off just
  /// measures freshness against a more generous native window (a deliberate
  /// copy→⌥E may take a few seconds), so an old, unrelated clipboard still falls
  /// through to the editable overlay rather than becoming a confident capture.
  /// Defaults true so OCR-only snapshots/fixtures keep their prior meaning.
  final bool screenRecordingEnabled;

  const OcrSnapshot({
    required this.lines,
    required this.cursor,
    this.selectionRect,
    this.screenName = '',
    this.sourceApp,
    this.sourceTitle,
    this.recognitionLanguages = const [],
    this.cursorVisualSpan,
    this.clipboard,
    this.screenRecordingEnabled = true,
  });

  factory OcrSnapshot.fromMap(Map<dynamic, dynamic> map) {
    final rawLines = map['lines'] as List<dynamic>? ?? const [];
    final rawSelection = map['selectionRect'];
    final rawClipboard = map['clipboard'];
    final rawLangs = map['recognitionLanguages'] as List<dynamic>? ?? const [];
    final rawVisualSpan = map['cursorVisualSpan'];
    return OcrSnapshot(
      lines:
          rawLines.map((e) => OcrLine.fromMap(e as Map<dynamic, dynamic>)).toList(growable: false),
      cursor: NormPoint.fromMap(map['cursor'] as Map<dynamic, dynamic>),
      selectionRect:
          rawSelection == null ? null : NormRect.fromMap(rawSelection as Map<dynamic, dynamic>),
      screenName: (map['screenName'] as String?) ?? '',
      sourceApp: map['sourceApp'] as String?,
      sourceTitle: map['sourceTitle'] as String?,
      recognitionLanguages: rawLangs.map((e) => e as String).toList(growable: false),
      cursorVisualSpan: rawVisualSpan == null
          ? null
          : CursorVisualSpan.fromMap(rawVisualSpan as Map<dynamic, dynamic>),
      clipboard: rawClipboard == null
          ? null
          : ClipboardCandidate.fromMap(rawClipboard as Map<dynamic, dynamic>),
      screenRecordingEnabled: (map['screenRecordingEnabled'] as bool?) ?? true,
    );
  }

  Map<String, dynamic> toMap() => {
        'lines': lines.map((l) => l.toMap()).toList(),
        'cursor': cursor.toMap(),
        'selectionRect': selectionRect?.toMap(),
        'screenName': screenName,
        if (sourceApp != null) 'sourceApp': sourceApp,
        if (sourceTitle != null) 'sourceTitle': sourceTitle,
        'recognitionLanguages': recognitionLanguages,
        'cursorVisualSpan': cursorVisualSpan?.toMap(),
        'clipboard': clipboard?.toMap(),
        'screenRecordingEnabled': screenRecordingEnabled,
      };
}
