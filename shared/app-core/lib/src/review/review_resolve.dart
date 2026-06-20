import 'package:capecho_api/capecho_api.dart';

/// Pure, shared resolve helpers for a review card's front (context) + back (meaning), used by BOTH
/// the in-app [ReviewController] and the widget snapshot builder — so the two producers of a review
/// card can't drift on "which context" or "what counts as a ready meaning". No Flutter deps.

/// How a card's meaning (the back) resolved. [unsupported] = the target language is off the
/// explanation allowlist (English-only at MVP); [unavailable] = a fetch failure or an empty blob.
/// (Defined here, not on the controller, so the widget path shares one definition.)
enum MeaningStatus { loading, ready, unsupported, unavailable }

/// The MOST-RECENT context sentence for a card, or null for a bare (context-less) card.
///
/// `GET /contexts` returns a unit's contexts OLDEST-first (`ORDER BY created_at ASC, id ASC` — see
/// `backend/src/contexts.ts:listContextsForWord`), so the latest sentence is the LAST element. Taking
/// `.first` (the oldest) was a latent bug: after a re-capture the review front showed the STALEST
/// sentence, not the newest. Both the in-app card and the widget snapshot pick the latest here.
ContextView? pickLatestContext(List<ContextView> contexts) =>
    contexts.isEmpty ? null : contexts.last;

/// The resolved back of a card: its [MeaningStatus] and (when ready) the explanation.
class ResolvedMeaning {
  const ResolvedMeaning(this.status, [this.explanation]);
  final MeaningStatus status;

  /// Set only when [status] is [MeaningStatus.ready].
  final WordExplanation? explanation;
}

/// Map an [ExplainResult] to the review back-state, mirroring the rules the in-app review uses:
/// `language_unsupported` → [MeaningStatus.unsupported]; a blob carrying a non-blank `summary` (the
/// word's ONLY explanation text — the server's must-pass core) → [MeaningStatus.ready]; anything
/// else (empty blob, not-a-word, anon-miss) → [MeaningStatus.unavailable] (still reviewable, just no
/// meaning on the back).
ResolvedMeaning resolveMeaning(ExplainResult res) {
  if (res.status == ExplainStatus.languageUnsupported) {
    return const ResolvedMeaning(MeaningStatus.unsupported);
  }
  final e = res.explanation;
  // Ready when the blob carries a primary sense (the must-pass core — Phase 1 per-POS senses).
  if (e != null && e.primarySense.trim().isNotEmpty) return ResolvedMeaning(MeaningStatus.ready, e);
  return const ResolvedMeaning(MeaningStatus.unavailable);
}
