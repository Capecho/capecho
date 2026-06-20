/// Capecho's typed backend client — the shared contract for the mobile + macOS Flutter clients.
///
/// The [CapechoApi] client builds requests + parses responses for every backend route the clients
/// use; the HTTP [HttpTransport] is injected (the app supplies a `package:http` adapter, tests a
/// fake). Wire-field casing mirrors the server exactly — see each model's `fromJson`/`toJson`.
library;

export 'src/client.dart' show CapechoApi;
export 'src/errors.dart' show ApiException;
export 'src/metric_event.dart'
    show
        kMetricContractVersion,
        kMetricMaxDurationMs,
        MetricEventType,
        MetricFieldSpec,
        MetricEventSpec,
        kMetricEventContract,
        MetricEvent,
        MetricBatch,
        MetricIngestResult;
export 'src/models.dart'
    show
        Account,
        AuthSession,
        AuthProvider,
        Word,
        WordFsrs,
        ExplanationState,
        DueCard,
        DueReviews,
        CardState,
        Rating,
        ReviewOutcome,
        ReviewStatus,
        ProjectedCard,
        SyncEvent,
        SyncEventResult,
        WordExplanation,
        Reading,
        PosGroup,
        ExplainResult,
        ExplainStatus,
        ContextView,
        ContextPreview,
        ClaimRow,
        ClaimContext,
        ClaimResult,
        AppleVerifyResult,
        ExportRow;
export 'src/transport.dart' show HttpTransport, TransportRequest, TransportResponse;
