/// A row from the `words` table, plus a derived `contextCount`. Returned by
/// [LocalStore.activeWords].
class WordRow {
  final String clientRowId;
  final String installId;
  final String targetLanguage;
  final String surfaceUnit;
  final String normalizedUnit;
  final String targetNormalizationVersion;
  final bool isPhrase;
  final String source;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;
  final String? serverWordId;
  final bool syncDirty;

  /// False = anonymous (a pre-login capture, shown in a signed-out Word Book); true = synced into an
  /// account and therefore hidden from the signed-out catalog. See [LocalStore.markClaimed].
  final bool claimed;

  /// Number of `word_contexts` rows linked to this word.
  final int contextCount;

  const WordRow({
    required this.clientRowId,
    required this.installId,
    required this.targetLanguage,
    required this.surfaceUnit,
    required this.normalizedUnit,
    required this.targetNormalizationVersion,
    required this.isPhrase,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
    required this.serverWordId,
    required this.syncDirty,
    this.claimed = false,
    required this.contextCount,
  });

  @override
  String toString() => 'WordRow(clientRowId: $clientRowId, surfaceUnit: "$surfaceUnit", '
      'normalizedUnit: "$normalizedUnit", targetLanguage: $targetLanguage, '
      'isPhrase: $isPhrase, deletedAt: $deletedAt, claimed: $claimed, '
      'contextCount: $contextCount)';
}

/// A row from the `word_contexts` table. Returned by [LocalStore.contextsFor].
class ContextRow {
  final String clientRowId;
  final String wordClientRowId;
  final String? contextText;
  final String? contextLanguage;
  final int? spanStart;
  final int? spanEnd;

  /// Capture provenance ("where I met this word"): the source application name
  /// ([sourceApp], e.g. "Google Chrome") and the source window's title
  /// ([sourceTitle]). Null when the capture couldn't resolve them.
  final String? sourceApp;
  final String? sourceTitle;

  /// The capture-time detected language ([detectedLanguage], BCP-47) of the captured
  /// span and its [0,1] [detectedLanguageConfidence]. Null when none was detected.
  final String? detectedLanguage;
  final double? detectedLanguageConfidence;

  /// The cached in-sentence "Explain here" gloss for this saved sentence (the one combined
  /// word-in-context + whole-sentence explanation), or null when none was generated. Lets the
  /// signed-out Word Book show it without re-generating. See [LocalStore.setContextGloss].
  final String? glossMeaning;

  final int createdAt;
  final bool syncDirty;

  const ContextRow({
    required this.clientRowId,
    required this.wordClientRowId,
    required this.contextText,
    required this.contextLanguage,
    required this.spanStart,
    required this.spanEnd,
    this.sourceApp,
    this.sourceTitle,
    this.detectedLanguage,
    this.detectedLanguageConfidence,
    this.glossMeaning,
    required this.createdAt,
    required this.syncDirty,
  });

  @override
  String toString() => 'ContextRow(clientRowId: $clientRowId, wordClientRowId: $wordClientRowId, '
      'span: [$spanStart, $spanEnd), contextLanguage: $contextLanguage, '
      'sourceApp: $sourceApp, detectedLanguage: $detectedLanguage)';
}

/// One part of speech under a cached reading: its closed-set label ([partOfSpeech], e.g. "noun") and
/// its frequency-ordered meanings ([senses], written in the explanation/native language — ALL of them,
/// every surface shows the full set). Mirrors the api `PosGroup` (Phase 1 per-POS senses).
class LocalPosGroup {
  final String partOfSpeech;
  final List<String> senses;

  const LocalPosGroup({required this.partOfSpeech, required this.senses});

  @override
  String toString() => 'LocalPosGroup(partOfSpeech: $partOfSpeech, senses: $senses)';
}

/// One pronunciation reading of a cached explanation: the bare primary/secondary transcriptions
/// ([pronunciationPrimary] / [pronunciationSecondary] — the renderer decorates; `""` when that slot was
/// omit-on-failed or the target has no second slot), the reading [kind] (`"idiom"` for a phrase reading
/// → badge, no IPA; null for an ordinary word), and the per-POS meaning groups under it ([pos]). A
/// heteronym ("object", "bow") is two readings.
class LocalReading {
  final String pronunciationPrimary;
  final String pronunciationSecondary;
  final String? kind;
  final List<LocalPosGroup> pos;

  const LocalReading({
    required this.pronunciationPrimary,
    required this.pronunciationSecondary,
    this.kind,
    required this.pos,
  });

  @override
  String toString() =>
      'LocalReading(primary: "$pronunciationPrimary", secondary: "$pronunciationSecondary", '
      'kind: $kind, pos: $pos)';
}

/// A cached free word-layer explanation (context-independent) from `word_explanations`. Returned by
/// [LocalStore.getExplanation] — the offline meaning shown on a re-capture of a known word. Phase 1: the
/// per-POS senses inside [readings] ARE the explanation (the prose `summary` is gone). MUST-PASS = at
/// least one non-blank sense — a blob without one is never written, and an old/corrupt one reads as a
/// MISS; pronunciations under each reading are omit-on-fail.
class LocalExplanation {
  final List<LocalReading> readings;

  const LocalExplanation({required this.readings});

  @override
  String toString() => 'LocalExplanation(readings: $readings)';
}
