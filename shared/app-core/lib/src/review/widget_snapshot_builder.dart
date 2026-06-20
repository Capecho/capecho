import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_local_store/capecho_local_store.dart' show uuidV4;

import '../sense_layout.dart' show computeSenseLayout;
import '../word_book/word_book_view.dart' show abbreviatePos;
import 'review_resolve.dart';
import 'widget_review_snapshot.dart';

/// Builds a [WidgetReviewSnapshot] from the server's due queue, resolving each card's front (latest
/// context) + back (meaning) with the SAME shared helpers the in-app review uses ([pickLatestContext]
/// / [resolveMeaning]) — so the widget and the app can't drift. Pure on [CapechoApi]; no Flutter.
///
/// Invariants (widget RFC §5.1):
///  - DUE cards first, then today's server-surfaced NEW cards — the SAME queue the in-app review shows
///    (review_controller adds due then new), so the widget reviews new words too. The server already
///    caps how many new cards it surfaces per day (the cap is applied at `/review/due` SURFACE time, not
///    at grade time), so the widget only shows new cards the server chose to introduce today. The one
///    cost of grading a new card from the widget: an offline grade whose flush crosses local midnight
///    counts that card's "introduced today" toward the next day (server-receive-time attributed) — a
///    soft-pacing off-by-one, never a scheduling/data error.
///  - Free word-level meaning only ([CapechoApi.explain], R2-cached) + the already-stored sentence —
///    NEVER the metered context-level endpoint (one rebuild would burn the daily paid quota).
///  - Tolerates partial failure: a card with no context / no meaning is still carried (reviewable).
class WidgetSnapshotBuilder {
  WidgetSnapshotBuilder({
    required this.api,
    this.explanationLanguage = 'en',
    this.maxCards = 12,
    this.staleAfterMs = _defaultStaleAfterMs,
    int Function()? now,
    String Function()? newSnapshotId,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _newSnapshotId = newSnapshotId ?? _defaultSnapshotId;

  static const int _defaultStaleAfterMs = 24 * 60 * 60 * 1000; // 24h

  final CapechoApi api;
  final String explanationLanguage;
  final int maxCards;
  final int staleAfterMs;
  final int Function() _now;
  final String Function() _newSnapshotId;

  /// Build a fresh snapshot. [excludeWordIds] drops cards whose grade is already queued but not yet
  /// flushed (the rebuild-reconcile case, D6) so the widget never re-shows / re-grades a card it just
  /// rated while the app was rebuilding.
  Future<WidgetReviewSnapshot> build({Set<String> excludeWordIds = const {}}) async {
    final due = await api.dueReviews();
    // DUE cards first (priority), then today's surfaced NEW cards — the SAME ordering the in-app review
    // uses (due.all). The server already caps the new cards it surfaces, so this only ever includes new
    // cards it chose to introduce today; the widget reviews them like any due card.
    final selected = [
      ...due.due,
      ...due.newCards,
    ].where((c) => !excludeWordIds.contains(c.wordId)).take(maxCards).toList();

    // Resolve every card's front + back CONCURRENTLY (Future.wait preserves order, so the queue stays in
    // server order). The old await-in-loop made 1 + 2·N serial round trips (≤25), a multi-second window
    // in which the publish — fire-and-forget right after sign-in — could be suspended by the OS before it
    // ever reached the App Group. Each [_resolveCard] swallows its own per-card failures, so the wait
    // never rejects on a single bad card.
    final cards = await Future.wait(selected.map(_resolveCard));

    return WidgetReviewSnapshot(
      snapshotId: _newSnapshotId(),
      builtAt: _now(),
      staleAfterMs: staleAfterMs,
      cursor: 0,
      cards: cards,
    );
  }

  Future<WidgetReviewCard> _resolveCard(DueCard c) async {
    // Front: the most-recent saved sentence (tolerate a fetch failure → bare card).
    ContextView? context;
    try {
      context = pickLatestContext(await api.contexts(c.wordId));
    } catch (_) {
      context = null;
    }

    // Back: the free word-level meaning (tolerate a failure → unavailable, still reviewable).
    ResolvedMeaning meaning;
    try {
      final res = await api.explain(
        unit: c.surfaceUnit,
        target: c.targetLanguage,
        explanationLang: explanationLanguage,
        wordId: c.wordId,
      );
      meaning = resolveMeaning(res);
    } catch (_) {
      meaning = const ResolvedMeaning(MeaningStatus.unavailable);
    }

    // Validate through the factory (not the raw constructor) so a non-normalized span can't reach the
    // snapshot — a null degrades to plain text on the widget, an invalid pair would be a silent mismatch.
    final span = WidgetTargetSpan.fromBounds(context?.spanStart, context?.spanEnd);
    // The card back = the per-POS senses laid out like the in-app Review card — one line per part of
    // speech, the abbreviated POS label inline ([widgetMeaningText], a string mirror of SenseModules).
    // '' (no usable sense) degrades to null so the front stays reviewable; a long one may clip on the
    // widget — tapping through opens the app.
    final backText = (meaning.status == MeaningStatus.ready && meaning.explanation != null)
        ? widgetMeaningText(meaning.explanation!)
        : '';
    final back = backText.isEmpty ? null : backText;
    // The word's pronunciation: the first reading's primary slot (else secondary), null when
    // omit-on-failed. (The snapshot field keeps its `ipa` wire name — the iOS widget reads it;
    // en-only until the zh-Hans gate, where it would carry pinyin.)
    String? ipa;
    if (meaning.status == MeaningStatus.ready) {
      final readings = meaning.explanation?.readings ?? const <Reading>[];
      if (readings.isNotEmpty) {
        final r = readings.first;
        ipa = r.pronunciationPrimary.isNotEmpty
            ? r.pronunciationPrimary
            : (r.pronunciationSecondary.isNotEmpty ? r.pronunciationSecondary : null);
      }
    }

    // The stored in-sentence gloss rides along from the SAME `/contexts` fetch above (the front
    // sentence) — free, never the metered context endpoint. Blank degrades to null (no callout).
    final contextGloss = (context?.meaning?.trim().isNotEmpty ?? false) ? context!.meaning : null;

    return WidgetReviewCard(
      wordId: c.wordId,
      surfaceUnit: c.surfaceUnit,
      targetLang: c.targetLanguage,
      dueAt: c.dueAt,
      state: c.isNew ? 'new' : 'due',
      contextText: context?.contextText ?? '',
      targetSpan: span,
      ipa: ipa,
      meaning: back,
      meaningStatus: WidgetMeaningStatus.fromMeaningStatus(meaning.status),
      contextMeaning: contextGloss,
    );
  }
}

/// The cursor to resume at for [snapshot], given the cursor the widget last stored against
/// [storedSnapshotId]. D6: the cursor is SCOPED to a snapshotId — a stored cursor only applies to the
/// snapshot it was taken against. Once the app rebuilds (new snapshotId) the stored cursor is
/// meaningless, so we fall back to the new snapshot's own cursor (which the app already reconciled past
/// any queued grades via [WidgetSnapshotBuilder.build]'s `excludeWordIds`). A matching cursor is clamped
/// into range (defensive against a shrunk card list).
int resumeCursor({
  required String? storedSnapshotId,
  required int storedCursor,
  required WidgetReviewSnapshot snapshot,
}) => storedSnapshotId == snapshot.snapshotId
    ? storedCursor.clamp(0, snapshot.cards.length)
    : snapshot.cursor;

/// Advance [snapshot]'s cursor PAST any leading cards already graded ([gradedWordIds]) — the
/// belt-and-braces reconcile for the race where a snapshot still contains a card the widget just
/// rated (its grade is queued but the rebuild started before it landed). Pure; stops at the first
/// ungraded card.
int reconcileCursor(WidgetReviewSnapshot snapshot, Set<String> gradedWordIds) {
  var cursor = snapshot.cursor;
  while (cursor < snapshot.cards.length && gradedWordIds.contains(snapshot.cards[cursor].wordId)) {
    cursor++;
  }
  return cursor;
}

// The widget derives each grade's event id as `snapshotId#cursor` (WidgetReviewSession), and that id is
// the backend's GLOBAL idempotency PK — so the snapshot id must be collision-free across devices, else
// two devices building a snapshot in the same microsecond would mint identical grade ids and one
// device's rating would be quarantined (id_conflict). A fresh UUIDv4 per build also keeps the stored
// cursor correctly scoped to its snapshot (resumeCursor falls back once the id changes on a rebuild).
String _defaultSnapshotId() => uuidV4();

/// The iOS widget's `meaning` text: the per-POS senses laid out the SAME way the in-app Review card
/// shows them (capecho_app_core `SenseModules` with POS labels) — ONE line per part of speech,
/// `"<label>  <(note) >senses joined '; '"`, lines joined by `\n`. Uncapped (every stored sense; the
/// backend already caps per POS), so the glance matches the card. Returns `''` for a blob with no
/// usable sense (the caller degrades that to a null, still-reviewable card).
String widgetMeaningText(WordExplanation explanation) {
  final layout = computeSenseLayout(explanation);
  final lines = <String>[
    for (final reading in layout.readings)
      for (final row in reading.pos)
        '${abbreviatePos(row.partOfSpeech)}  '
            '${row.note.isEmpty ? row.senses.join('; ') : '(${row.note}) ${row.senses.join('; ')}'}',
  ];
  return lines.join('\n');
}
