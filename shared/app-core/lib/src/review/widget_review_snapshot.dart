import 'review_resolve.dart';

/// The pre-resolved review queue the app hands the widget (App → App Group → SwiftUI). The widget
/// NEVER fetches and NEVER computes FSRS — it renders these cards and emits rating events that drain
/// back through the shared offline queue. Pure serialization (no Flutter / no API deps); the SwiftUI
/// side decodes the SAME JSON, pinned by a committed golden fixture so the Dart encoder and the Swift
/// decoder can't drift.
///
/// Schema (widget RFC §5.1): a [snapshotId] (cursor scope + rebuild-reconcile anchor), a [builtAt] +
/// [staleAfterMs] freshness window (a stale snapshot degrades to glance and forbids offline grading),
/// a [cursor], and the [cards]. The queue carries DUE cards then today's server-surfaced NEW cards —
/// the SAME set the in-app review shows — so the widget reviews new words too (each [WidgetReviewCard]
/// records its own `state`). Grading a new card offline can, only when the flush crosses local midnight,
/// shift that card's "introduced today" tally to the next day (the new-card cap is server-receive-time
/// attributed) — a soft-pacing off-by-one, never a scheduling/data error.
class WidgetReviewSnapshot {
  const WidgetReviewSnapshot({
    required this.snapshotId,
    required this.builtAt,
    required this.staleAfterMs,
    required this.cursor,
    required this.cards,
    this.schemaVersion = currentSchemaVersion,
  });

  /// Bumped only on an INCOMPATIBLE wire change. The CONSUMER is the SwiftUI widget (App → App Group →
  /// Swift), so the Swift decoder is the enforcing gate: it rejects a snapshot whose [schemaVersion]
  /// exceeds the one it was built for (rather than mis-render). The Dart side here is the PRODUCER and
  /// is intentionally forward-lenient on decode (app→app round-trips only) — see [fromJson].
  static const int currentSchemaVersion = 1;

  final int schemaVersion;

  /// Identifies this build. The widget's cursor is SCOPED to it (see [resumeCursor]); a rebuild mints
  /// a new id so a stale cursor can't apply to a different card list.
  final String snapshotId;

  /// When the snapshot was built (epoch ms).
  final int builtAt;

  /// How long the snapshot stays fresh (ms). Past it the widget shows a glance + "open to refresh" and
  /// refuses to grade offline (a grade against a stale queue risks a wrong card).
  final int staleAfterMs;

  /// The card the widget should show next (index into [cards]).
  final int cursor;

  final List<WidgetReviewCard> cards;

  /// True when [nowMs] is at or past the freshness window.
  bool isStaleAt(int nowMs) => nowMs - builtAt >= staleAfterMs;

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'snapshotId': snapshotId,
    'builtAt': builtAt,
    'staleAfterMs': staleAfterMs,
    'cursor': cursor,
    'cards': [for (final c in cards) c.toJson()],
  };

  factory WidgetReviewSnapshot.fromJson(Map<String, dynamic> json) => WidgetReviewSnapshot(
    schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? currentSchemaVersion,
    snapshotId: json['snapshotId'] as String,
    builtAt: (json['builtAt'] as num).toInt(),
    staleAfterMs: (json['staleAfterMs'] as num).toInt(),
    cursor: (json['cursor'] as num?)?.toInt() ?? 0,
    cards: (json['cards'] as List? ?? const [])
        .cast<Map<String, dynamic>>()
        .map(WidgetReviewCard.fromJson)
        .toList(),
  );
}

/// One fully-resolved card in a [WidgetReviewSnapshot]: the front (context sentence + the target span
/// to highlight) and the back ([meaning] + [meaningStatus]). The front always shows the word — this is
/// RECOGNITION review (see the word → recall the meaning), NOT a fill-in-the-blank cloze.
class WidgetReviewCard {
  const WidgetReviewCard({
    required this.wordId,
    required this.surfaceUnit,
    required this.targetLang,
    required this.dueAt,
    required this.state,
    required this.contextText,
    required this.targetSpan,
    required this.meaning,
    required this.meaningStatus,
    this.ipa,
    this.contextMeaning,
  });

  final String wordId;
  final String surfaceUnit;
  final String targetLang;

  /// Bare IPA for the word — the primary reading's US transcription (else UK), or null when the
  /// explanation omitted it (omit-on-fail). The renderer adds the `/…/` slashes.
  final String? ipa;

  /// Due time (epoch ms). Used ONLY for the glance count — the widget never locally re-sorts or
  /// re-filters by it (the server already ordered the queue).
  final int dueAt;

  /// `due` (already-scheduled, due now) | `new` (never reviewed — surfaced within the server's daily
  /// new-card cap). Both are reviewable in the widget; the renderer doesn't branch on this today.
  final String state;

  /// The most-recent context sentence (front), or `''` for a bare card.
  final String contextText;

  /// The UTF-16 offsets of the target word within [contextText] to highlight, or null when there's no
  /// span (bare card / no highlight). UTF-16 so Swift's `String`/`NSRange` and Dart's UTF-16 indexing
  /// agree (a committed CJK fixture pins this).
  final WidgetTargetSpan? targetSpan;

  /// The back: the per-POS senses laid out one line per part of speech ([widgetMeaningText]), or null
  /// when [meaningStatus] is not [ready]. The wire key stays `meaning` (the shipped widget reads it).
  final String? meaning;

  /// Whether the back is renderable: `ready` | `unsupported` (target language off the allowlist) |
  /// `unavailable` (fetch failure / no blob). The front is reviewable regardless.
  final WidgetMeaningStatus meaningStatus;

  /// The in-sentence "Explain here" gloss for the front sentence (word-in-context + whole-sentence), or
  /// null when none was generated. Read for FREE from the already-fetched `/contexts` (NOT the metered
  /// endpoint), so the large widget back can show it like the in-app Review card. Additive optional field
  /// — an older widget build that lacks it just ignores the key, so no [WidgetReviewSnapshot] schema bump.
  final String? contextMeaning;

  Map<String, dynamic> toJson() => {
    'wordId': wordId,
    'surfaceUnit': surfaceUnit,
    'targetLang': targetLang,
    'dueAt': dueAt,
    'state': state,
    'contextText': contextText,
    'targetSpan': targetSpan?.toJson(),
    'ipa': ipa,
    'meaning': meaning,
    'meaningStatus': meaningStatus.wire,
    'contextMeaning': contextMeaning,
  };

  factory WidgetReviewCard.fromJson(Map<String, dynamic> json) => WidgetReviewCard(
    wordId: json['wordId'] as String,
    surfaceUnit: json['surfaceUnit'] as String,
    targetLang: json['targetLang'] as String,
    dueAt: (json['dueAt'] as num).toInt(),
    state: json['state'] as String? ?? 'due',
    contextText: json['contextText'] as String? ?? '',
    targetSpan: WidgetTargetSpan.fromJson(json['targetSpan']),
    ipa: json['ipa'] as String?,
    meaning: json['meaning'] as String?,
    meaningStatus: WidgetMeaningStatus.fromWire(json['meaningStatus']),
    contextMeaning: json['contextMeaning'] as String?,
  );
}

/// A half-open UTF-16 `[start, end)` highlight range within a card's context text. Serialized as a
/// 2-element array `[start, end]` (matching the RFC), or null.
class WidgetTargetSpan {
  const WidgetTargetSpan(this.start, this.end);

  final int start;
  final int end;

  List<int> toJson() => [start, end];

  /// Build a span from raw start/end bounds, or null if either is absent or the pair is malformed
  /// (negative / inverted). Construct spans through this — NOT the raw constructor — so a
  /// non-normalized source can't put an invalid span into a snapshot (which the Swift side would then
  /// silently drop to null, an asymmetric, hard-to-debug mismatch).
  static WidgetTargetSpan? fromBounds(int? start, int? end) {
    if (start == null || end == null || start < 0 || end < start) return null;
    return WidgetTargetSpan(start, end);
  }

  /// Decode `[start, end]` defensively: a malformed / one-sided / inverted span → null (the widget
  /// then renders plain text), never a crash — mirroring the backend's span normalization.
  static WidgetTargetSpan? fromJson(Object? raw) {
    if (raw is! List || raw.length != 2) return null;
    return fromBounds((raw[0] as num?)?.toInt(), (raw[1] as num?)?.toInt());
  }

  @override
  bool operator ==(Object other) =>
      other is WidgetTargetSpan && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// The serialized form of a widget card's meaning state — [MeaningStatus] minus `loading` (a snapshot
/// card is always fully resolved; the widget never fetches). A stable wire string the SwiftUI side
/// switches on.
enum WidgetMeaningStatus {
  ready('ready'),
  unsupported('unsupported'),
  unavailable('unavailable');

  const WidgetMeaningStatus(this.wire);
  final String wire;

  /// Lenient decode: an unknown/absent value → [unavailable] (the safe "no meaning, still reviewable"
  /// state), so a future status string can't crash an older widget.
  static WidgetMeaningStatus fromWire(Object? raw) {
    for (final s in values) {
      if (s.wire == raw) return s;
    }
    return WidgetMeaningStatus.unavailable;
  }

  /// Project a resolved [MeaningStatus] onto the wire enum (`loading` shouldn't reach a built snapshot;
  /// it degrades to [unavailable]).
  static WidgetMeaningStatus fromMeaningStatus(MeaningStatus status) => switch (status) {
    MeaningStatus.ready => WidgetMeaningStatus.ready,
    MeaningStatus.unsupported => WidgetMeaningStatus.unsupported,
    MeaningStatus.unavailable || MeaningStatus.loading => WidgetMeaningStatus.unavailable,
  };
}
