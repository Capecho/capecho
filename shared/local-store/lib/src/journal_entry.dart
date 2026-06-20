/// The valid `source` values for a capture. The store rejects anything else.
const Set<String> kJournalSources = {'ocr', 'clipboard', 'selection'};

/// One native capture journal entry — the input contract to [LocalStore.drain].
///
/// The native capture process appends one entry per save event to a monotonic journal; the
/// store drains entries in `seq` order and applies them idempotently. The unit of idempotency
/// is [clientRowId] (the UUID minted for THIS save event), which becomes the primary key of the
/// created `word_contexts` row — so re-draining the same entry is an `INSERT OR IGNORE` no-op.
class JournalEntry {
  /// Native monotonic sequence (per install). The drain cursor key: the store applies an entry
  /// only when `seq > lastDrainedSeq`, then advances the cursor to `seq`.
  final int seq;

  /// UUID for THIS save event. Equals the created context row's `client_row_id`; the idempotency
  /// unit. (NOT the word's id — a resave of the same unit reuses an existing word but is still a
  /// distinct save event with its own [clientRowId].)
  final String clientRowId;

  final String installId;

  /// The unit exactly as captured/saved (raw, pre-normalization).
  final String surfaceUnit;

  final String targetLanguage;

  /// Plaintext context (encrypted only later, at sync). `null` = a context-less save.
  final String? contextText;

  final String? contextLanguage;

  /// UTF-16 `[spanStart, spanEnd)` of the unit within [contextText]. Paired: both null, or both
  /// non-null with `0 <= spanStart <= spanEnd`.
  final int? spanStart;
  final int? spanEnd;

  /// One of [kJournalSources]: `'ocr'`, `'clipboard'`, `'selection'`.
  final String source;

  /// Capture-time provenance ("where I met this word"). [sourceApp] is the owning
  /// application of the captured window (e.g. "Google Chrome"); [sourceTitle] is that
  /// window's title (page/document name). Both are null when the capture couldn't
  /// resolve them. They are NOT attribution and never gate dedup/explanation.
  final String? sourceApp;
  final String? sourceTitle;

  /// The BCP-47 language the captured span was detected to be at capture time
  /// (`NLLanguageRecognizer`), with its [0,1] [detectedLanguageConfidence] — the same
  /// recognition signal the overlay's target-switch suggestion reads, persisted so the
  /// stored card keeps the evidence. Null language ⇒ none detected (confidence 0).
  final String? detectedLanguage;
  final double? detectedLanguageConfidence;

  /// Capture time, epoch milliseconds.
  final int capturedAt;

  const JournalEntry({
    required this.seq,
    required this.clientRowId,
    required this.installId,
    required this.surfaceUnit,
    required this.targetLanguage,
    this.contextText,
    this.contextLanguage,
    this.spanStart,
    this.spanEnd,
    required this.source,
    this.sourceApp,
    this.sourceTitle,
    this.detectedLanguage,
    this.detectedLanguageConfidence,
    required this.capturedAt,
  });

  /// Validates [source] membership and span pairing. Throws [ArgumentError] on violation.
  /// Called by the constructor-side path ([fromMap]) and by [LocalStore.drain] before apply,
  /// so a malformed entry fails loudly rather than corrupting the store (zero silent failures).
  void validate() {
    if (!kJournalSources.contains(source)) {
      throw ArgumentError.value(source, 'source', 'must be one of ${kJournalSources.toList()}');
    }
    final hasStart = spanStart != null;
    final hasEnd = spanEnd != null;
    if (hasStart != hasEnd) {
      throw ArgumentError('span must be paired: spanStart=$spanStart, spanEnd=$spanEnd '
          '(both null or both non-null)');
    }
    if (hasStart) {
      if (spanStart! < 0) {
        throw ArgumentError.value(spanStart, 'spanStart', 'must be >= 0');
      }
      if (spanEnd! < spanStart!) {
        throw ArgumentError('spanEnd ($spanEnd) must be >= spanStart ($spanStart)');
      }
    }
  }

  /// Builds a [JournalEntry] from a decoded map (the camelCase JSON the native journal writes —
  /// the same shape [toMap] round-trips). Validates on construction; a missing or mistyped field
  /// fails loudly rather than corrupting the store.
  factory JournalEntry.fromMap(Map<dynamic, dynamic> map) {
    int reqInt(String key) {
      final v = map[key];
      if (v is int) return v;
      if (v is num) return v.toInt();
      throw ArgumentError('missing/invalid int field "$key": $v');
    }

    int? optInt(String key) {
      final v = map[key];
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      throw ArgumentError('invalid int field "$key": $v');
    }

    String reqStr(String key) {
      final v = map[key];
      if (v is String) return v;
      throw ArgumentError('missing/invalid string field "$key": $v');
    }

    String? optStr(String key) {
      final v = map[key];
      if (v == null) return null;
      if (v is String) return v;
      throw ArgumentError('invalid string field "$key": $v');
    }

    double? optDouble(String key) {
      final v = map[key];
      if (v == null) return null;
      if (v is num) return v.toDouble();
      throw ArgumentError('invalid num field "$key": $v');
    }

    final entry = JournalEntry(
      seq: reqInt('seq'),
      clientRowId: reqStr('clientRowId'),
      installId: reqStr('installId'),
      surfaceUnit: reqStr('surfaceUnit'),
      targetLanguage: reqStr('targetLanguage'),
      contextText: optStr('contextText'),
      contextLanguage: optStr('contextLanguage'),
      spanStart: optInt('spanStart'),
      spanEnd: optInt('spanEnd'),
      source: reqStr('source'),
      sourceApp: optStr('sourceApp'),
      sourceTitle: optStr('sourceTitle'),
      detectedLanguage: optStr('detectedLanguage'),
      detectedLanguageConfidence: optDouble('detectedLanguageConfidence'),
      capturedAt: reqInt('capturedAt'),
    );
    entry.validate();
    return entry;
  }

  /// Serializes to a camelCase map (round-trips with [fromMap]).
  Map<String, Object?> toMap() => {
        'seq': seq,
        'clientRowId': clientRowId,
        'installId': installId,
        'surfaceUnit': surfaceUnit,
        'targetLanguage': targetLanguage,
        'contextText': contextText,
        'contextLanguage': contextLanguage,
        'spanStart': spanStart,
        'spanEnd': spanEnd,
        'source': source,
        'sourceApp': sourceApp,
        'sourceTitle': sourceTitle,
        'detectedLanguage': detectedLanguage,
        'detectedLanguageConfidence': detectedLanguageConfidence,
        'capturedAt': capturedAt,
      };

  @override
  String toString() =>
      'JournalEntry(seq: $seq, clientRowId: $clientRowId, surfaceUnit: "$surfaceUnit", '
      'targetLanguage: $targetLanguage, source: $source)';
}
