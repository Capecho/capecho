import 'dart:convert';

import 'package:capecho_api/capecho_api.dart';

import 'offline_event_queue.dart';
import 'widget_snapshot_builder.dart';

/// The platform seam between the Dart app and the home-screen widget — the App Group shared container
/// plus the OS reload trigger. The concrete impl is per-client (mobile: `home_widget` saveWidgetData +
/// updateWidget); this interface keeps [WidgetBridge]'s orchestration pure + testable.
///
/// Two payloads cross the App Group:
///  - the SNAPSHOT (app → widget): the resolved review queue the widget renders;
///  - the QUEUE (widget ⇄ app): a JSON array of rating events the widget process (native Swift, the
///    hot path) APPENDS on each grade, in [SyncEvent.toJson] wire form (snake_case) — the app reads
///    + flushes them on foreground and writes back whatever didn't ack.
abstract class WidgetHost {
  /// Write the snapshot JSON into the shared container under the widget's key and ask the OS to reload
  /// the widget's timeline.
  Future<void> publishSnapshot(String snapshotJson);

  /// Read the raw queue JSON the widget wrote (a JSON array of events), or null/empty when none.
  Future<String?> readQueueJson();

  /// Replace the shared queue with [queueJson] (a JSON array; `[]` clears it), so the widget process
  /// sees exactly the events that still need syncing.
  Future<void> writeQueueJson(String queueJson);
}

/// The result of a foreground widget-grade flush: the per-event [flush] outcome plus the wordIds whose
/// grades are STILL queued (un-acked / re-auth-blocked, or enqueued by the widget mid-flush) — used to
/// exclude those cards from the freshly re-published snapshot so the widget doesn't re-show a card the
/// user just graded (D6).
class WidgetFlushOutcome {
  const WidgetFlushOutcome(this.flush, this.stillQueuedWordIds);
  final FlushResult flush;
  final Set<String> stillQueuedWordIds;
}

/// Orchestrates the Dart side of the review widget (Phase 1, foreground flush — D9-C):
///  - [publish]: build a fresh snapshot and hand it to the widget (post-sync / post-session / on
///    foreground / at reminder-schedule time);
///  - [onForeground]: drain the grades the widget enqueued while the app was away, then re-publish.
///
/// The FSRS hot path stays server-authoritative: the widget only PRODUCES [SyncEvent]s (natively),
/// and this drains them through the existing per-event-acked [OfflineEventQueue] → `/sync`. No FSRS is
/// computed here. Pure Dart on [WidgetHost] + [WidgetSnapshotBuilder]; the platform plugin is injected.
class WidgetBridge {
  WidgetBridge({
    required this.host,
    required this.builder,
    this.publishRetryBackoff = const [Duration(milliseconds: 300), Duration(milliseconds: 900)],
  });

  final WidgetHost host;
  final WidgetSnapshotBuilder builder;

  /// Back-off delays between [publish] retries; its length is the number of RETRIES after the first
  /// attempt (default: two). [publish] is fire-and-forget at its call sites (the sign-in edge / app
  /// foreground), so a transient failure — most likely right after sign-in, when the network is busy
  /// and the new session token was just set — would otherwise strand the widget on its cleared empty
  /// state until the next foreground. Tests pass `[]` (no retries) or `[Duration.zero]` to stay fast.
  final List<Duration> publishRetryBackoff;

  /// Build a snapshot (DUE-only, shared resolve) and publish it. [excludeWordIds] drops cards whose
  /// grade is still queued so a just-graded card isn't re-shown after a rebuild (D6 reconcile). Retries
  /// a transient build/publish failure per [publishRetryBackoff]; a final failure still throws (the
  /// fire-and-forget caller swallows it, and the next app foreground republishes regardless).
  Future<void> publish({Set<String> excludeWordIds = const {}}) async {
    Object? lastError;
    for (var attempt = 0; attempt <= publishRetryBackoff.length; attempt++) {
      if (attempt > 0) await Future<void>.delayed(publishRetryBackoff[attempt - 1]);
      try {
        final snapshot = await builder.build(excludeWordIds: excludeWordIds);
        await host.publishSnapshot(jsonEncode(snapshot.toJson()));
        return;
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError!;
  }

  /// Drain the widget's queued grades on app foreground: read them from the shared container, flush
  /// per-event via `/sync`, and write back whatever didn't ack. Returns the outcome (incl. which
  /// wordIds remain queued). Does NOT re-publish — see [onForeground] for the combined routine.
  Future<WidgetFlushOutcome> flushWidgetGrades() async {
    final events = _decodeQueue(await host.readQueueJson());
    if (events.isEmpty) return const WidgetFlushOutcome(FlushResult(), {});

    // Seed a transient queue with the widget's events and flush it (per-event ack, chunked). Using the
    // shared OfflineEventQueue keeps the ack/quarantine/reauth semantics identical to the in-app path.
    final queue = OfflineEventQueue(store: InMemoryEventQueueStore()..save(events));
    final result = await queue.flush(builder.api.sync);

    // The ids that LEFT the queue (synced, or permanently quarantined) = the flushed events minus those
    // still queued for retry. We subtract THESE from the queue rather than blind-overwriting it with the
    // pre-flush remainder: the widget process (native) can APPEND a fresh grade to the same App-Group key
    // DURING the /sync network window, and a blind overwrite would clobber it (a silently-lost rating).
    // So re-read the CURRENT queue and write back everything except the acked ids — a grade enqueued
    // mid-flush survives. The still-queued events are folded back in defensively (keyed by id, so no
    // double-count) so a re-read that came back short can never DROP a rating the server didn't accept —
    // the regression this fix exists to prevent. (Both processes do an uncoordinated read-modify-write on
    // the key, so a sub-millisecond residual window remains between this re-read and the write-back;
    // fully closing it needs an NSFileCoordinator-guarded App-Group file — tracked separately.)
    final stillQueued = queue.events;
    final stillQueuedIds = {for (final e in stillQueued) e.eventId};
    final ackedIds = {
      for (final e in events)
        if (!stillQueuedIds.contains(e.eventId)) e.eventId,
    };
    final kept = <String, SyncEvent>{};
    for (final e in _decodeQueue(await host.readQueueJson())) {
      if (!ackedIds.contains(e.eventId)) kept[e.eventId] = e;
    }
    for (final e in stillQueued) {
      kept.putIfAbsent(e.eventId, () => e);
    }
    await host.writeQueueJson(jsonEncode([for (final e in kept.values) e.toJson()]));
    return WidgetFlushOutcome(result, {for (final e in kept.values) e.wordId});
  }

  /// The app-foreground routine: flush the widget's grades, then re-publish a fresh snapshot that
  /// excludes any still-queued grades (so they aren't re-shown before they sync).
  Future<WidgetFlushOutcome> onForeground() async {
    final outcome = await flushWidgetGrades();
    await publish(excludeWordIds: outcome.stillQueuedWordIds);
    return outcome;
  }

  /// Parse the widget's queue blob into events. A null/blank/corrupt blob → empty (never throws on a
  /// foreground); a single unparseable entry would surface as a thrown decode, so we guard the whole.
  static List<SyncEvent> _decodeQueue(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [for (final e in list) SyncEvent.fromJson(e as Map<String, dynamic>)];
    } catch (_) {
      return const []; // a corrupt queue blob must not wedge the foreground flush
    }
  }
}
