import 'dart:async';
import 'dart:convert';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_local_store/capecho_local_store.dart';
import 'package:capture_native/capture_native.dart';

/// Records §14 success-metric events (CEO-10) for the After-M3 GATE.
///
/// Listens to the native overlay's [CaptureNative.captureLifecycle], maps each signal to a typed
/// [MetricEvent] (the monotonic capture-time split, lookup-funnel, context-fill, language-override),
/// durably buffers it in the local store, and flushes batches to `POST /metrics`. Design notes:
///   • OFF the hot path — enqueue is a fast local insert; the flush is fire-and-forget, so a capture
///     never waits on the network (a save's ink-dot is unaffected).
///   • DURABLE + offline — buffered in SQLite (survives restart); a flush failure keeps the events
///     for the next attempt. A new launch flushes whatever accrued offline.
///   • SELF-HEALING — a server 4xx (the batch shape was rejected) DROPS that batch so a single bad
///     event can't wedge the queue forever; a 5xx / transport failure KEEPS it to retry.
///   • PRIVACY (T8) — only the contract's durations / enums / bools are ever enqueued; a lifecycle
///     event missing a required field is dropped rather than sent (which also avoids a wedged batch).
class MetricsRecorder {
  MetricsRecorder({
    required this.lifecycle,
    required this.store,
    required this.api,
    required this.installId,
    this.appVersion,
    this.platform = 'macos',
    int Function()? clock,
    this.flushBatchSize = 50,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Stream<CaptureLifecycleEvent> lifecycle;
  final LocalStore store;
  final CapechoApi api;
  final String installId;
  final String? appVersion;
  final String platform;
  final int flushBatchSize;
  final int Function() _clock;

  StreamSubscription<CaptureLifecycleEvent>? _sub;
  bool _flushing = false;

  // capture_completed is word-id-keyed (T17), but the timings ride the lifecycle stream while the word
  // id is assigned later by the local-store drain — two async sources joined by the journal clientRowId.
  // Buffer whichever half arrives first; emit capture_completed when both meet. Bounded so an orphan
  // half (a normalized-empty save → no word; a launch-recovery drain → no in-session timings) can't leak.
  static const int _maxPendingCompleted = 256;
  final Map<String, _PendingCompleted> _pendingCompleted = {};

  /// Subscribe to lifecycle signals and flush anything buffered from a previous (possibly offline)
  /// session. Safe to call once.
  void start() {
    _sub ??= lifecycle.listen(_onLifecycle);
    unawaited(flush());
  }

  void _onLifecycle(CaptureLifecycleEvent e) {
    if (e.phase == 'completed') {
      _onCompletedTimings(e); // word-id-keyed (T17): deferred until the drain assigns the word id
      return;
    }
    final event = _toEvent(e, _clock());
    if (event != null) _enqueueAndFlush(event); // null = unknown phase / missing field → drop
  }

  /// The native 'completed' lifecycle: stash its timings keyed by the journal clientRowId, to be joined
  /// with the word id the drain later assigns (T17). A missing required field drops it (contract guard).
  void _onCompletedTimings(CaptureLifecycleEvent e) {
    final sel = e.selToPanelMs, pan = e.panelToSaveMs, tot = e.totalMs;
    final src = e.source, ctx = e.hasContext, ovr = e.langOverride, crid = e.clientRowId;
    if (sel == null ||
        pan == null ||
        tot == null ||
        src == null ||
        ctx == null ||
        ovr == null ||
        crid == null) {
      return;
    }
    _joinCompleted(
      crid,
      metadata: <String, Object?>{
        'selToPanelMs': sel,
        'panelToSaveMs': pan,
        'totalMs': tot,
        'source': src,
        'hasContext': ctx,
        'langOverride': ovr,
      },
    );
  }

  /// The local-store drain assigned word ids (T17): join each `(journal clientRowId → word id)` with the
  /// buffered 'completed' timings and emit capture_completed keyed by the WORD id (same id-space as the
  /// sync funnel). Called by [CaptureRepository] after a save drains. A drained entry with no buffered
  /// timings (a launch-recovery drain, or the programmatic save path with no overlay timings) is held
  /// briefly then evicted — no capture_completed is fabricated for it.
  void onCaptureDrained(Iterable<({String clientRowId, String wordId})> saved) {
    for (final s in saved) {
      _joinCompleted(s.clientRowId, wordId: s.wordId);
    }
  }

  /// Join the two async halves of a capture_completed — timings (lifecycle) + word id (drain) — keyed by
  /// the journal clientRowId. Emits when both are present; otherwise buffers the first half (bounded: an
  /// orphan half is evicted oldest-first so the buffer can't grow without limit).
  void _joinCompleted(String journalClientRowId, {Map<String, Object?>? metadata, String? wordId}) {
    final pending = _pendingCompleted.putIfAbsent(journalClientRowId, _PendingCompleted.new);
    if (metadata != null) pending.metadata = metadata;
    if (wordId != null) pending.wordId = wordId;
    final md = pending.metadata, wid = pending.wordId;
    if (md != null && wid != null) {
      _pendingCompleted.remove(journalClientRowId);
      _enqueueAndFlush(
        MetricEvent(
          eventType: 'capture_completed',
          clientRowId: wid,
          clientTs: _clock(),
          metadata: md,
        ),
      );
      return;
    }
    // Only one half so far: keep it, bounded so an orphan half can't leak (a normalized-empty save → no
    // word id; the programmatic save path → no overlay timings). Evict oldest-first: a real save's two
    // halves arrive within the same sub-second drain, so the oldest entries are the true orphans — a live
    // half can't be evicted unless 256 newer saves land before its partner, unreachable at human pace.
    while (_pendingCompleted.length > _maxPendingCompleted) {
      _pendingCompleted.remove(_pendingCompleted.keys.first);
    }
  }

  void _enqueueAndFlush(MetricEvent event) {
    store.enqueueMetric(jsonEncode(event.toJson()), now: _clock());
    unawaited(flush()); // fire-and-forget; never blocks the capture / sync path
  }

  /// The chain-completeness sync funnel (3-state, Issue 2): one `sync_attempted` per submitted
  /// client_row_id, one `sync_accepted` per row the server acknowledged. Called by the claim flow.
  void recordSyncAttempted(Iterable<String> clientRowIds) =>
      _recordSync('sync_attempted', clientRowIds);
  void recordSyncAccepted(Iterable<String> clientRowIds) =>
      _recordSync('sync_accepted', clientRowIds);

  void _recordSync(String eventType, Iterable<String> clientRowIds) {
    var any = false;
    for (final id in clientRowIds) {
      store.enqueueMetric(
        jsonEncode(
          MetricEvent(
            eventType: eventType,
            clientRowId: id,
            clientTs: _clock(),
            metadata: const {},
          ).toJson(),
        ),
        now: _clock(),
      );
      any = true;
    }
    if (any) unawaited(flush());
  }

  /// A pre-overlay capture failure (cascade error before any overlay) — the one phase emitted
  /// Dart-side (native emits presented/abandoned/empty/completed). [errorKind] ∈ ocr|permission|native|unknown.
  void recordCaptureFailed(String errorKind) => _enqueueAndFlush(
    MetricEvent(
      eventType: 'capture_failed',
      clientTs: _clock(),
      metadata: {'errorKind': errorKind},
    ),
  );

  /// Drain the buffer to the server, FIFO, in batches. Best-effort + re-entrancy-guarded. A 4xx drops
  /// the offending batch (non-retryable); a 5xx / transport error stops the round, keeping the events.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (true) {
        final batch = store.metricBatch(flushBatchSize);
        if (batch.isEmpty) return;
        final maxSeq = batch.last.seq;
        // Decode defensively: a corrupt / forward-incompatible buffered payload must not wedge the
        // queue (review P2 — the no-wedge guarantee otherwise lived only at enqueue). Skip poison rows;
        // they're cleared with the batch below.
        final events = <MetricEvent>[];
        for (final r in batch) {
          try {
            events.add(MetricEvent.fromJson(jsonDecode(r.payload) as Map<String, Object?>));
          } catch (_) {
            // unreadable payload → drop it (it's within [.., maxSeq], deleted on success/empty)
          }
        }
        if (events.isEmpty) {
          store.deleteMetricsThrough(maxSeq); // whole batch was poison → evict it, re-read
          continue;
        }
        final wire = MetricBatch(
          installId: installId,
          platform: platform,
          appVersion: appVersion,
          events: events,
        );
        try {
          await api.postMetrics(wire);
          store.deleteMetricsThrough(maxSeq); // flushed → clear
        } on ApiException catch (ex) {
          // 4xx = the server rejected the batch shape; retrying can't help → drop so the queue can't
          // wedge. 5xx = transient → keep + retry next time.
          if (ex.statusCode >= 400 && ex.statusCode < 500) store.deleteMetricsThrough(maxSeq);
          return;
        } catch (_) {
          // Transport failure (offline) → keep the batch, stop the round, retry later.
          return;
        }
        // Re-read instead of short-circuiting on a sub-full batch: an event enqueued DURING the await
        // above had its own flush() dropped by the _flushing guard, so this loop is the only drainer —
        // it must re-read until metricBatch is empty, or that event is stranded until the next one (the
        // re-entrant lost-wakeup, review P1). In Dart's single thread, no enqueue can interleave between
        // the empty read and `_flushing = false`, so no dirty flag is needed.
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
  }

  /// Map a native lifecycle signal to a contract-valid [MetricEvent], or null to drop it (unknown
  /// phase, or a required field absent — dropping keeps a malformed event from wedging a flush batch).
  /// Excludes the 'completed' phase, which is word-id-keyed and joined separately ([_onCompletedTimings]).
  MetricEvent? _toEvent(CaptureLifecycleEvent e, int clientTs) {
    switch (e.phase) {
      case 'presented':
        final sel = e.selToPanelMs, src = e.source;
        if (sel == null || src == null) return null;
        return MetricEvent(
          eventType: 'capture_presented',
          clientTs: clientTs,
          metadata: {'selToPanelMs': sel, 'source': src},
        );
      case 'abandoned':
        final sel = e.selToPanelMs;
        if (sel == null) return null;
        return MetricEvent(
          eventType: 'capture_abandoned',
          clientTs: clientTs,
          metadata: {'selToPanelMs': sel},
        );
      case 'failed':
        return MetricEvent(
          eventType: 'capture_failed',
          clientTs: clientTs,
          metadata: {'errorKind': e.errorKind ?? 'unknown'},
        );
      default:
        return null;
    }
  }
}

/// One half-joined capture_completed (T17): the lifecycle timings and the drained word id arrive on
/// separate async paths; whichever lands first is held here until the other completes the pair.
class _PendingCompleted {
  Map<String, Object?>? metadata;
  String? wordId;
}
