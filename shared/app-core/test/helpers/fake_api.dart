import 'package:capecho_api/capecho_api.dart';

/// A test double for [CapechoApi] that makes NO real network calls — every high-level method is
/// overridden to return injected data / record calls. Used by the review-controller + widget-snapshot
/// tests. Subclassing works because Dart methods are virtual; the dead transport
/// guarantees a real request would throw rather than silently hit the network.
class FakeCapechoApi extends CapechoApi {
  FakeCapechoApi() : super(baseUrl: 'http://test.local', transport: _DeadTransport());

  bool sessionActive = true;
  DueReviews due = const DueReviews(due: [], newCards: [], dueCount: 0, newCount: 0);
  List<Word> words = const [];
  final Map<String, List<ContextView>> contextsByWord = {};

  /// unit → explain result (default: a `generated` result with no explanation = unavailable).
  ExplainResult Function(String unit)? explainFor;

  /// Override the due-reviews fetch (e.g. to throw a transient failure then succeed, for the publish
  /// retry path); default returns the injected [due].
  Future<DueReviews> Function()? onDueReviews;

  /// Override the flush behavior; default acks every event as `applied`.
  Future<List<SyncEventResult>> Function(List<SyncEvent> events)? onSync;

  /// Override the single-submit behavior; default returns a non-replay outcome.
  Future<ReviewOutcome> Function(SyncEvent event)? onSubmit;

  final List<List<SyncEvent>> syncCalls = [];
  final List<SyncEvent> submitted = [];

  @override
  bool get hasSession => sessionActive;

  @override
  Future<DueReviews> dueReviews({int? newLimit}) async =>
      onDueReviews != null ? onDueReviews!() : due;

  @override
  Future<List<ContextView>> contexts(String wordId) async => contextsByWord[wordId] ?? const [];

  @override
  Future<ExplainResult> explain({
    required String unit,
    required String target,
    String? explanationLang,
    String? wordId,
  }) async =>
      explainFor?.call(unit) ??
      const ExplainResult(status: ExplainStatus.generated, explanation: null);

  @override
  Future<List<Word>> listWords() async => words;

  @override
  Future<ReviewOutcome> submitReview(SyncEvent event) async {
    submitted.add(event);
    if (onSubmit != null) return onSubmit!(event);
    return const ReviewOutcome(replay: false, card: null);
  }

  @override
  Future<List<SyncEventResult>> sync(List<SyncEvent> events) async {
    syncCalls.add(List.of(events));
    if (onSync != null) return onSync!(events);
    return [
      for (final e in events)
        SyncEventResult(eventId: e.eventId, status: ReviewStatus.applied, card: null),
    ];
  }
}

class _DeadTransport implements HttpTransport {
  @override
  Future<TransportResponse> send(TransportRequest request) => throw StateError(
    'FakeCapechoApi makes no real network calls (${request.method} ${request.url})',
  );
}

// --- model builders (concise scenario construction) --------------------------

DueCard fakeDueCard(
  String wordId, {
  String unit = 'word',
  String lang = 'en',
  int dueAt = 0,
  bool isNew = false,
}) => DueCard(
  wordId: wordId,
  surfaceUnit: unit,
  targetLanguage: lang,
  state: isNew ? CardState.isNew : CardState.review,
  dueAt: dueAt,
  isNew: isNew,
);

/// A minimal Word Book entry — enough for `listWords()`-driven branches (e.g. the "all caught up" vs
/// cold "nothing captured" distinction) without spelling out every FSRS field.
Word fakeWord(String id, {String unit = 'word', String lang = 'en'}) => Word(
  id: id,
  userId: 'u',
  targetLanguage: lang,
  surfaceUnit: unit,
  normalizedUnit: unit,
  targetNormalizationVersion: 'v1',
  isPhrase: false,
  explanationState: ExplanationState.ready,
  explanationCacheKey: null,
  fsrsEpoch: 0,
  createdAt: 0,
  updatedAt: 0,
  deletedAt: null,
);

ContextView fakeContext(
  String wordId,
  String text, {
  int createdAt = 0,
  int? spanStart,
  int? spanEnd,
  String id = 'ctx',
  String? meaning,
}) => ContextView(
  id: id,
  wordId: wordId,
  contextLanguage: null,
  contextText: text,
  spanStart: spanStart,
  spanEnd: spanEnd,
  meaning: meaning,
  createdAt: createdAt,
);

/// A `ready` explanation whose primary sense (`summary` alias) is the word's meaning text, optionally
/// with one reading carrying a [pos] label and a primary [pronunciation].
ExplainResult fakeExplain(String summary, {String pos = 'noun', String pronunciation = ''}) =>
    ExplainResult(
      status: ExplainStatus.generated,
      explanation: WordExplanation(
        readings: [
          Reading(
            pronunciationPrimary: pronunciation,
            pronunciationSecondary: '',
            pos: [
              PosGroup(partOfSpeech: pos, senses: [summary]),
            ],
          ),
        ],
      ),
    );

const ExplainResult fakeUnsupported = ExplainResult(
  status: ExplainStatus.languageUnsupported,
  explanation: null,
);
