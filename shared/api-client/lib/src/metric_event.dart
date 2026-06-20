/// The §14 metric-event contract — the Dart side of the SINGLE source of truth for the event shape
/// the macOS client emits and the backend validates.
///
/// This mirrors `backend/src/metrics.ts` `METRIC_CONTRACT`; both are pinned to the committed fixture
/// `shared/api-client/fixtures/metric-events-contract.json`. A Dart test (`test/metric_contract_test.dart`)
/// AND a TS test (`backend/test/metric-contract.test.ts`) each assert equality to that fixture, so a
/// Dart↔TS drift fails CI — the same anti-drift posture as the normalization golden vectors and the
/// DES-2 token gate. PRIVACY (T8): every field below is a duration / count / enum / bool — never a
/// captured unit or context sentence.
library;

/// Bump only alongside both ports + a migration story. Wire value of `contractVersion` on the batch.
/// `capture_completed.clientRowId` is the WORD id, so it shares the id-space of the sync funnel +
/// claim_records — that powers the backend's word-keyed funnels (captureToSync / repeatLookup).
const int kMetricContractVersion = 1;

/// Sanity ceiling on any duration field (ms) — a span over an hour is junk (clock glitch / a window
/// left open), rejected rather than allowed to poison the percentiles. Mirrors backend MAX_DURATION_MS.
const int kMetricMaxDurationMs = 60 * 60 * 1000;

/// The metric event types, in contract order.
enum MetricEventType {
  captureCompleted('capture_completed'),
  capturePresented('capture_presented'),
  captureAbandoned('capture_abandoned'),
  captureFailed('capture_failed'),
  syncAttempted('sync_attempted'),
  syncAccepted('sync_accepted');

  const MetricEventType(this.wire);

  /// The wire string stored in `metric_events.event_type` (snake_case, matches the backend).
  final String wire;
}

/// A single metadata field's validation rule. `type` is one of `int` | `bool` | `enum`.
class MetricFieldSpec {
  const MetricFieldSpec({required this.type, this.min, this.max, this.values});

  /// Integer field bounded by [min]..[max].
  const MetricFieldSpec.integer(int this.min, int this.max)
      : type = 'int',
        values = null;

  /// Boolean field.
  const MetricFieldSpec.boolean()
      : type = 'bool',
        min = null,
        max = null,
        values = null;

  /// Enum field constrained to [values].
  const MetricFieldSpec.enumerated(List<String> this.values)
      : type = 'enum',
        min = null,
        max = null;

  final String type;
  final int? min;
  final int? max;
  final List<String>? values;
}

/// The metadata contract for one event type. Every listed field is REQUIRED; unknown fields are
/// rejected at ingest (the T8 whitelist).
class MetricEventSpec {
  const MetricEventSpec({required this.needsClientRowId, required this.fields});

  /// capture_completed + sync_* tie to a specific captured unit (`clientRowId` required); the funnel
  /// events (presented/abandoned/empty/failed) must NOT carry one.
  final bool needsClientRowId;
  final Map<String, MetricFieldSpec> fields;
}

const MetricFieldSpec _ms = MetricFieldSpec.integer(0, kMetricMaxDurationMs);
const MetricFieldSpec _source = MetricFieldSpec.enumerated(['ocr', 'clipboard', 'selection']);

/// The contract, keyed by the wire event_type. Asserted against the committed fixture in CI.
const Map<String, MetricEventSpec> kMetricEventContract = {
  'capture_completed': MetricEventSpec(
    needsClientRowId: true,
    fields: {
      'selToPanelMs': _ms, // t1 - t0 (system latency)
      'panelToSaveMs': _ms, // t2 - t1 (human dwell)
      'totalMs': _ms, // t2 - t0 (headline capture time)
      'source': _source,
      'hasContext': MetricFieldSpec.boolean(),
      'langOverride': MetricFieldSpec.boolean(),
    },
  ),
  'capture_presented':
      MetricEventSpec(needsClientRowId: false, fields: {'selToPanelMs': _ms, 'source': _source}),
  'capture_abandoned': MetricEventSpec(needsClientRowId: false, fields: {'selToPanelMs': _ms}),
  'capture_failed': MetricEventSpec(needsClientRowId: false, fields: {
    'errorKind': MetricFieldSpec.enumerated(['ocr', 'permission', 'native', 'unknown'])
  }),
  'sync_attempted': MetricEventSpec(needsClientRowId: true, fields: {}),
  'sync_accepted': MetricEventSpec(needsClientRowId: true, fields: {}),
};

// --- wire DTOs (POST /metrics) ---------------------------------------------

/// A single metric event on the wire. [metadata] holds ONLY the contract fields for [eventType]
/// (durations / enums / bools) — never captured text (T8).
class MetricEvent {
  const MetricEvent(
      {required this.eventType, this.clientRowId, required this.clientTs, required this.metadata});

  final String eventType;
  final String? clientRowId;
  final int clientTs;
  final Map<String, Object?> metadata;

  Map<String, Object?> toJson() => {
        'eventType': eventType,
        if (clientRowId != null) 'clientRowId': clientRowId,
        'clientTs': clientTs,
        'metadata': metadata,
      };

  factory MetricEvent.fromJson(Map<String, Object?> json) => MetricEvent(
        eventType: json['eventType'] as String,
        clientRowId: json['clientRowId'] as String?,
        clientTs: (json['clientTs'] as num).toInt(),
        metadata: (json['metadata'] as Map?)?.cast<String, Object?>() ?? const {},
      );
}

/// A batch of [MetricEvent]s plus the device envelope. The server (POST /metrics) accepts it
/// anonymously (install_id only) so the pre-login first-capture latency is measured.
class MetricBatch {
  const MetricBatch({
    required this.installId,
    this.platform = 'macos',
    this.appVersion,
    this.contractVersion = kMetricContractVersion,
    required this.events,
  });

  final String installId;
  final String platform;
  final String? appVersion;
  final int contractVersion;
  final List<MetricEvent> events;

  Map<String, Object?> toJson() => {
        'installId': installId,
        'platform': platform,
        if (appVersion != null) 'appVersion': appVersion,
        'contractVersion': contractVersion,
        'events': events.map((e) => e.toJson()).toList(),
      };
}

/// The POST /metrics result: how many of the batch were stored vs dropped by the server ceiling.
class MetricIngestResult {
  const MetricIngestResult({required this.accepted, required this.dropped});

  final int accepted;
  final int dropped;

  factory MetricIngestResult.fromJson(Map<String, Object?> json) => MetricIngestResult(
        accepted: (json['accepted'] as num?)?.toInt() ?? 0,
        dropped: (json['dropped'] as num?)?.toInt() ?? 0,
      );
}
