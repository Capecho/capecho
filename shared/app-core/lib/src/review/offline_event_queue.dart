import 'package:capecho_api/capecho_api.dart';

/// Flush a batch of queued rating events. Matches [CapechoApi.sync]; injected (not the whole API) so
/// the queue stays pure and trivially testable.
typedef SyncEventsFn = Future<List<SyncEventResult>> Function(List<SyncEvent> events);

/// The outcome of one [OfflineEventQueue.flush] — a count breakdown so callers can drive UI (e.g. a
/// "synced N / still pending M" pill) and decide whether to prompt re-auth.
class FlushResult {
  const FlushResult({
    this.acked = 0,
    this.retained = 0,
    this.quarantined = 0,
    this.needsReauth = false,
    this.transportFailed = false,
  });

  /// Events the server APPLIED (landed in the authoritative event log) — removed from the queue.
  final int acked;

  /// Events still queued for a later retry: a transient `error`, OR (when [needsReauth] /
  /// [transportFailed]) the whole batch that never reached the server.
  final int retained;

  /// Permanently-rejected events dropped from the queue (not_found / unit_deleted / id_conflict /
  /// invalid) — resending them can't change the outcome, so they're quarantined out.
  final int quarantined;

  /// A 401 — the whole batch stays queued and retries pause until the app re-authenticates.
  final bool needsReauth;

  /// A network throw (non-401) — the whole batch stays queued for a later retry.
  final bool transportFailed;

  /// True when the queue fully drained (nothing left to retry, no auth/transport block).
  bool get fullyDrained => retained == 0 && !needsReauth && !transportFailed;
}

/// A durable-shaped, PER-EVENT-acked queue of review rating events — the ONE offline event producer
/// shared by the in-app review path and (Phase 1) the widget grade path.
///
/// Replaces [ReviewController]'s in-memory `_pendingSync` + the unsafe batch-clear `_flushPending`,
/// which dropped EVERY queued event whenever a single `/sync` call succeeded. The backend returns
/// PER-EVENT results, so a partial failure must keep the un-acked events: applied + permanent failures
/// are removed, a transient `error` is kept, and a 401 / network throw keeps the whole batch. Idempotent
/// on event id (the backend folds by server_seq on the client id), so a kept-then-resent event can't
/// double-count.
///
/// Persistence is injected via [EventQueueStore] so the in-app path stays in-memory while the widget
/// path persists to the App Group (Phase 1 native) — a grade then survives a cold widget process and
/// drains on the next app foreground. The queue LOGIC lives here once, unit-tested against a fake sync.
class OfflineEventQueue {
  OfflineEventQueue({EventQueueStore? store}) : _store = store ?? InMemoryEventQueueStore() {
    _events.addAll(_store.load());
  }

  final EventQueueStore _store;
  final List<SyncEvent> _events = [];

  /// Per-event outcomes that are PERMANENT — resending can't change them, so the event is removed
  /// (acked if applied, else quarantined). Everything else (`error`) is transient → kept for retry.
  static const Set<ReviewStatus> _terminal = {
    ReviewStatus.applied,
    ReviewStatus.notFound,
    ReviewStatus.unitDeleted,
    ReviewStatus.idConflict,
    ReviewStatus.invalid,
  };

  /// A read-only snapshot of the queued events, oldest-first (flush order).
  List<SyncEvent> get events => List.unmodifiable(_events);
  int get length => _events.length;
  bool get isEmpty => _events.isEmpty;
  bool get isNotEmpty => _events.isNotEmpty;

  /// The most-recently enqueued event, or null when empty (drives the "Rated X — will sync" badge).
  SyncEvent? get last => _events.isEmpty ? null : _events.last;

  /// Append an event (a failed optimistic submit, or a widget grade) and persist.
  void enqueue(SyncEvent event) {
    _events.add(event);
    _store.save(_events);
  }

  /// The max events sent per `/sync` call — kept at/under the backend's `MAX_SYNC_EVENTS` (500) so a
  /// large queue is CHUNKED rather than POSTed whole. A >500 batch is rejected 413 by the backend, which
  /// [flush] would treat as a transient transport failure and retry forever — a permanent, unrecoverable
  /// wedge of that account's review sync. Chunking guarantees forward progress no matter how deep the
  /// queue got while offline.
  static const int defaultBatchLimit = 200;

  /// Flush via [sync], acking PER EVENT, in chunks of at most [batchLimit]. Applied + permanent failures
  /// are removed; a transient `error` (or an event the server returned NO result for) is kept; a 401
  /// keeps the un-acked rest and flags [FlushResult.needsReauth]; a network throw keeps the rest and
  /// flags [FlushResult.transportFailed] (events acked in EARLIER chunks stay removed).
  Future<FlushResult> flush(SyncEventsFn sync, {int batchLimit = defaultBatchLimit}) async {
    if (_events.isEmpty) return const FlushResult();
    final limit = batchLimit < 1 ? 1 : batchLimit;
    // Iterate a STABLE snapshot in fixed windows (never re-taking from the front), so a chunk of
    // all-transient `error`s can't loop forever; removals are collected and applied once at the end.
    final snapshot = List<SyncEvent>.from(_events);
    final toRemove = <String>{};
    var acked = 0;
    var quarantined = 0;
    for (var i = 0; i < snapshot.length; i += limit) {
      final end = (i + limit < snapshot.length) ? i + limit : snapshot.length;
      final chunk = snapshot.sublist(i, end);
      final List<SyncEventResult> results;
      try {
        results = await sync(chunk);
      } on ApiException catch (e) {
        // 401 → pause + re-auth; any other API error → transient transport failure. Keep the un-acked
        // rest (events acked in earlier chunks are already in toRemove).
        _removeAndPersist(toRemove);
        return FlushResult(
          acked: acked,
          retained: _events.length,
          quarantined: quarantined,
          needsReauth: e.isUnauthorized,
          transportFailed: !e.isUnauthorized,
        );
      } catch (_) {
        _removeAndPersist(toRemove);
        return FlushResult(
          acked: acked,
          retained: _events.length,
          quarantined: quarantined,
          transportFailed: true,
        );
      }
      final statusById = {for (final r in results) r.eventId: r.status};
      for (final e in chunk) {
        final status = statusById[e.eventId];
        if (status == null || !_terminal.contains(status)) continue; // no result / transient → keep
        if (status == ReviewStatus.applied) {
          acked++;
        } else {
          quarantined++;
        }
        toRemove.add(e.eventId);
      }
    }
    _removeAndPersist(toRemove);
    return FlushResult(acked: acked, retained: _events.length, quarantined: quarantined);
  }

  /// Drop all queued events — e.g. on a genuine sign-out, so a DIFFERENT account signing in next can't
  /// inherit (and silently quarantine) the previous account's un-synced ratings. Persists empty.
  void clear() {
    if (_events.isEmpty) return;
    _events.clear();
    _store.save(_events);
  }

  void _removeAndPersist(Set<String> eventIds) {
    if (eventIds.isEmpty) return;
    _events.removeWhere((e) => eventIds.contains(e.eventId));
    _store.save(_events);
  }
}

/// Persistence seam for [OfflineEventQueue]. The in-app path uses [InMemoryEventQueueStore]; the widget
/// path injects an App-Group-backed store (Phase 1 native) that serializes via [SyncEvent.toJson] /
/// [SyncEvent.fromJson], so a grade survives a cold widget process and drains on the next app foreground.
abstract class EventQueueStore {
  /// Load the persisted events (oldest-first), or empty.
  List<SyncEvent> load();

  /// Replace the persisted events with [events] (the queue calls this after every mutation).
  void save(List<SyncEvent> events);
}

/// The default store: holds events in memory only (the in-app review session). Nothing survives a
/// process restart — correct for the in-app path; the widget path injects a durable store instead.
class InMemoryEventQueueStore implements EventQueueStore {
  final List<SyncEvent> _events = [];

  @override
  List<SyncEvent> load() => List.of(_events);

  @override
  void save(List<SyncEvent> events) {
    _events
      ..clear()
      ..addAll(events);
  }
}
