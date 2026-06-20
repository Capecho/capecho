import 'dart:async';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_local_store/capecho_local_store.dart' show uuidV4;
import 'package:flutter/foundation.dart';

import 'offline_event_queue.dart';
import 'review_resolve.dart';

// Re-export the shared queue + resolve helpers (incl. MeaningStatus, which used to be declared here)
// so existing importers of this controller keep seeing them.
export 'offline_event_queue.dart';
export 'review_resolve.dart';

/// Drives a single review session: load the server's due/new queue, present each card
/// front (context sentence, target highlighted) → back (meaning) → rating, and submit
/// each rating to the server-authoritative FSRS. Ratings are submitted optimistically
/// (the next card shows immediately); a failed submit queues in-memory and is flushed
/// best-effort at session end.
///
/// Platform-agnostic pure Dart on [CapechoApi] — no Flutter/macOS deps beyond
/// [ChangeNotifier] — so it lifts cleanly into a shared package when the mobile client
/// reuses it (the review UI itself is per-platform: keyboard window vs touch tab).
///
/// FSRS is 100% server-authoritative: the client never computes intervals, so the
/// rating buttons show labels only (no next-interval preview).
enum ReviewPhase { loading, signedOut, card, done, allCaughtUp, nothingCaptured, error }

/// One card in the session — a due/new word plus its lazily-loaded context + meaning.
class ReviewCardModel {
  ReviewCardModel(this.card);

  final DueCard card;
  String get wordId => card.wordId;
  String get unit => card.surfaceUnit;
  String get targetLanguage => card.targetLanguage;

  /// The most-recent context sentence (front). Null → a bare (context-less) card.
  ContextView? context;
  bool contextLoaded = false;

  /// The resolved meaning (back). [explanation] is set only when [meaningStatus] is ready.
  WordExplanation? explanation;
  MeaningStatus meaningStatus = MeaningStatus.loading;

  /// Guards against a double fetch when present + prefetch race on the same card.
  bool loadStarted = false;

  bool get hasContext => context != null && context!.contextText.isNotEmpty;
}

class ReviewController extends ChangeNotifier {
  ReviewController({
    required this.api,
    this.explanationLanguage = 'en',
    OfflineEventQueue? queue,
    int Function()? now,
    String Function()? newEventId,
  }) : _pendingSync = queue ?? OfflineEventQueue(),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _newEventId = newEventId ?? _defaultEventId;

  final CapechoApi api;

  /// The account's explanation language (BCP-47) — the language the meaning is rendered in.
  final String explanationLanguage;

  final int Function() _now;
  final String Function() _newEventId;

  ReviewPhase _phase = ReviewPhase.loading;
  ReviewPhase get phase => _phase;

  final List<ReviewCardModel> _queue = [];
  int _index = 0;
  int get index => _index;
  int get total => _queue.length;
  ReviewCardModel? get current => (_index >= 0 && _index < _queue.length) ? _queue[_index] : null;

  bool _showBack = false;
  bool get showBack => _showBack;

  /// A wordId the widget deep-link asked the session to open at — applied once the queue is loaded
  /// (so the app shows the SAME word the widget showed). Null when nothing is pending.
  String? _pendingFocusWordId;

  int _reviewed = 0;
  int get reviewedCount => _reviewed;

  String? _error;
  String? get error => _error;

  /// Ratings that failed to submit online — held in the shared [OfflineEventQueue] and flushed
  /// best-effort at session end with PER-EVENT ack (a partial /sync failure keeps the un-acked events
  /// instead of dropping the whole batch). The in-app session uses the default in-memory store; the
  /// widget grade path injects an App-Group-backed store so a grade survives a cold widget process.
  final OfflineEventQueue _pendingSync;
  int get pendingSyncCount => _pendingSync.length;

  static const Map<Rating, String> _ratingLabels = {
    Rating.again: 'Forget',
    Rating.hard: 'Hard',
    Rating.good: 'Good',
    Rating.easy: 'Easy',
  };

  /// The rating label for the most-recent offline-queued submit — drives the per-rating
  /// "Rated 'X' — saved, will sync" badge. Null when nothing is queued. FSRS is
  /// server-authoritative (US-1.2), so the badge never previews an interval.
  String? get offlineRatingLabel {
    final last = _pendingSync.last;
    return last == null ? null : _ratingLabels[last.rating];
  }

  /// In-flight optimistic submits — awaited before the end-of-session flush so the last card's
  /// rating can't race past it (otherwise a failed final rating would never sync).
  final List<Future<void>> _inflight = [];

  /// WordIds whose optimistic submit is still in flight (dispatched, not yet acked or failed-to-queue).
  /// A [refresh] mid-flight must exclude these too: the server's due fetch can still list a card whose
  /// rating hasn't landed, and we must not re-show one the user just graded. Cleared as each submit
  /// settles (success → gone from the server's due list; failure → moved into [_pendingSync], also
  /// excluded). Without this, only the FAILED-submit path was covered (via [_pendingSync]).
  final Set<String> _inflightWordIds = {};

  bool _disposed = false;

  /// Guards [refresh] against overlapping foreground re-syncs.
  bool _refreshing = false;

  /// Load the session: fetch the due/new queue, warm the first card, and present it.
  Future<void> start() async {
    _phase = ReviewPhase.loading;
    _error = null;
    _showBack = false;
    _index = 0;
    _reviewed = 0;
    _queue.clear();
    // NB: the offline queue is NOT cleared here — un-synced ratings from a prior session are real and
    // must survive into this one (the durable queue retries them); only the transient session state
    // (in-flight futures below) resets.
    _inflight.clear(); // a fresh session must not inherit a prior run's in-flight submits
    _inflightWordIds.clear();
    _notify();
    // Signed out: the server-authoritative FSRS schedule is unreachable (the client never computes
    // intervals). Show the calm gated state with inline sign-in — scheduling lives in the cloud so a
    // review streak syncs across devices — rather than a fetch error.
    if (!api.hasSession) {
      // Genuine sign-out (the token was cleared — token EXPIRY keeps hasSession true and routes through
      // 401/needsReauth instead, which retains the queue). Drop any un-synced ratings so a DIFFERENT
      // account signing in next can't inherit them and have them silently quarantined (not_found) under
      // its own session.
      _pendingSync.clear();
      _phase = ReviewPhase.signedOut;
      _notify();
      return;
    }
    try {
      final due = await api.dueReviews();
      _queue
        ..addAll(due.due.map(ReviewCardModel.new))
        ..addAll(due.newCards.map(ReviewCardModel.new));
      if (_queue.isEmpty) {
        // Distinguish a warm "all caught up" (you have words, none due now) from the cold
        // "nothing captured yet" — the latter only when the Word Book is genuinely empty.
        final wordCount = await _safeWordCount();
        _phase = wordCount == 0 ? ReviewPhase.nothingCaptured : ReviewPhase.allCaughtUp;
        _notify();
        return;
      }
      await _load(0); // first card fully ready before we leave the loading state
      _phase = ReviewPhase.card;
      _notify();
      _applyPendingFocus(); // open at the widget deep-link's word, if one arrived before/during load
      unawaited(_load(_index + 1)); // prefetch the next (the one after wherever the focus landed)
    } catch (e) {
      _phase = ReviewPhase.error;
      _error = (e is ApiException && e.isUnauthorized)
          ? 'Sign in to review your words.'
          : 'Couldn’t load your review — check your connection.';
      _notify();
    }
  }

  Future<int> _safeWordCount() async {
    try {
      return (await api.listWords()).length;
    } catch (_) {
      return 1; // unknown → treat as "caught up", not the cold empty state, on a transient error
    }
  }

  /// Flip the current card between front and back.
  void flip() {
    if (_phase != ReviewPhase.card || current == null) return;
    _showBack = !_showBack;
    _notify();
  }

  /// Open the session at [wordId] (the widget deep-link target), so the app shows the SAME word the
  /// widget was on. Applied now if the queue is loaded, else remembered and applied at the end of
  /// [start]. A no-op when the word isn't in the current due queue (e.g. already reviewed).
  void focusWord(String wordId) {
    _pendingFocusWordId = wordId;
    _applyPendingFocus();
  }

  void _applyPendingFocus() {
    final target = _pendingFocusWordId;
    if (target == null || _phase != ReviewPhase.card) return;
    final i = _queue.indexWhere((c) => c.wordId == target);
    _pendingFocusWordId = null;
    if (i < 0 || i == _index) return; // not in queue / already there
    _index = i;
    _showBack = false;
    _notify();
    _load(_index);
    _load(_index + 1);
  }

  /// Rate the current card (only meaningful once flipped to the back), then advance.
  Future<void> rate(Rating rating) async {
    final c = current;
    if (_phase != ReviewPhase.card || c == null || !_showBack) return;
    final event = SyncEvent(
      wordId: c.wordId,
      eventId: _newEventId(),
      rating: rating,
      clientReviewTs: _now(),
    );
    _reviewed++;
    // Optimistic: the next card shows immediately while the submit runs in the background.
    _inflightWordIds.add(c.wordId);
    _inflight.add(_submit(event));
    _advance();
  }

  void _advance() {
    _showBack = false;
    _index++;
    if (_index >= _queue.length) {
      _phase = ReviewPhase.done;
      _notify();
      unawaited(_finishSession()); // await in-flight submits, then flush any failures
      return;
    }
    _notify();
    _load(_index); // usually already prefetched
    _load(_index + 1); // prefetch the following card
  }

  Future<void> _finishSession() async {
    await Future.wait(_inflight);
    _inflight.clear();
    await _flushPending();
  }

  Future<void> _submit(SyncEvent event) async {
    try {
      await api.submitReview(event);
    } catch (_) {
      _pendingSync.enqueue(event);
      _notify(); // surface the queued count
    } finally {
      // Settled: success → off the server's due list; failure → now in _pendingSync. Either way it's
      // no longer "in flight" and the per-source exclusion above (or the server) covers it.
      _inflightWordIds.remove(event.wordId);
    }
  }

  Future<void> _flushPending() async {
    if (_pendingSync.isEmpty) return;
    // Per-event ack: applied + permanent failures (not_found/unit_deleted/id_conflict/invalid) are
    // removed; a transient `error`, a 401, or a network throw keeps the un-acked events queued for a
    // later retry — NO whole-batch clear (that dropped ratings the server never accepted). Idempotent
    // on event id, so a kept-then-resent event can't double-count.
    await _pendingSync.flush(api.sync);
    _notify();
  }

  void retry() => start();

  /// Re-sync the queue to current server truth WITHOUT tearing the session down — called on app
  /// foreground, so reviews done while away (the home-screen widget, or another device) are reflected:
  /// cards reviewed elsewhere drop out, newly-due cards appear. The user keeps their current card (and
  /// its flip state) when it's still due; otherwise they land on the card that shifted into its place.
  ///
  /// Deliberately gentler than [start]: it never shows the loading screen and reuses already-loaded card
  /// models, so an unchanged refresh is invisible. A no-op while loading / signed-out (start owns those)
  /// or when the fetch throws (keep the live session rather than blanking it on a transient error). The
  /// caller must drain any widget grades to the server FIRST, or a just-graded card would re-appear here.
  Future<void> refresh() async {
    if (!api.hasSession) return;
    if (_phase == ReviewPhase.loading || _phase == ReviewPhase.signedOut) return;
    if (_refreshing) return;
    _refreshing = true;
    try {
      List<DueCard> fresh;
      try {
        final due = await api.dueReviews();
        fresh = [...due.due, ...due.newCards];
      } catch (_) {
        return; // transient — keep showing the current queue rather than blanking it
      }
      _error = null;
      // Drop cards whose in-app rating hasn't landed on the server yet — either still IN FLIGHT
      // ([_inflightWordIds]) or already failed-and-queued offline ([_pendingSync]). The due fetch can
      // still list such a card, and a re-fetch must not re-show one the user just graded here. Mirrors
      // the widget's still-queued exclusion in WidgetBridge.onForeground.
      final pendingWordIds = {for (final e in _pendingSync.events) e.wordId, ..._inflightWordIds};
      final focusWordId = current?.wordId;
      // Reuse loaded models (context + meaning already fetched) so an unchanged card never flickers.
      final existing = {for (final m in _queue) m.wordId: m};
      _queue
        ..clear()
        ..addAll(
          fresh
              .where((c) => !pendingWordIds.contains(c.wordId))
              .map((c) => existing[c.wordId] ?? ReviewCardModel(c)),
        );
      if (_queue.isEmpty) {
        // The queue emptied out (everything got reviewed away). Keep a just-finished `done` summary as
        // is; otherwise distinguish warm "all caught up" from the cold "nothing captured".
        if (_phase != ReviewPhase.done) {
          final wordCount = await _safeWordCount();
          _phase = wordCount == 0 ? ReviewPhase.nothingCaptured : ReviewPhase.allCaughtUp;
        }
        _index = 0;
        _showBack = false;
        _notify();
        return;
      }
      // Land on the SAME card by id when it's still due (handles cards removed *before* it shifting the
      // index); else clamp the old index into the now-shorter queue (or 0 when coming from `done`).
      final keepAt = focusWordId == null ? -1 : _queue.indexWhere((m) => m.wordId == focusWordId);
      if (keepAt >= 0) {
        _index = keepAt; // same card still due — keep the user (and their flip state) in place
      } else {
        _index = focusWordId == null ? 0 : _index.clamp(0, _queue.length - 1);
        _showBack = false; // landed on a different card — show its front
      }
      _phase = ReviewPhase.card;
      _notify();
      await _load(_index); // the landed card (reused models return immediately)
      unawaited(_load(_index + 1));
    } finally {
      _refreshing = false;
    }
  }

  /// Fetch a card's context (front) then meaning (back). Idempotent per card.
  Future<void> _load(int i) async {
    if (i < 0 || i >= _queue.length) return;
    final c = _queue[i];
    if (c.loadStarted) return;
    c.loadStarted = true;

    try {
      final ctx = await api.contexts(c.wordId);
      c.context = pickLatestContext(ctx); // the MOST-RECENT sentence (contexts are oldest-first)
    } catch (_) {
      c.context = null; // a fetch failure falls back to a bare card — still reviewable
    }
    c.contextLoaded = true;
    _notify();

    try {
      final res = await api.explain(
        unit: c.unit,
        target: c.targetLanguage,
        explanationLang: explanationLanguage,
        wordId: c.wordId,
      );
      final m = resolveMeaning(res);
      c.explanation = m.explanation;
      c.meaningStatus = m.status;
    } catch (_) {
      c.meaningStatus = MeaningStatus.unavailable; // still reviewable, just no meaning
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // Best-effort on teardown: await in-flight submits, then flush failures (shrinks the
    // lost-rating window if the window closes mid-session). _notify is inert after dispose.
    unawaited(_finishSession());
    super.dispose();
  }
}

// The backend ingests on the client-supplied event id and treats it as a GLOBAL idempotency PK
// (review.ts) — a non-unique id from a different (user, unit) is rejected as `id_conflict` and the
// rating silently dropped. So the default must be collision-free across devices/processes: a UUIDv4,
// per the backend contract. (The prior `evt-<micros>-<counter>` could collide — the counter resets per
// process, so two fresh processes minting their first id in the same microsecond produced the same id.)
String _defaultEventId() => uuidV4();
