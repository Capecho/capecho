// Typed models for the Capecho backend wire contract. Field casing mirrors the server VERBATIM:
//  - request bodies for auth / words / review / claim are snake_case;
//  - response bodies for review-due, projected cards, explain, and contexts are camelCase.
// Each model documents which it is. Hand-written fromJson/toJson (no freezed), matching the other
// shared/ packages. Parsing is lenient on unknown enum strings (falls back) so a new server enum
// value degrades gracefully instead of crashing a review session.

// --- small parse helpers -----------------------------------------------------

bool _asBool(Object? v) => v is bool ? v : (v is num ? v != 0 : false);
int _asInt(Object? v) => (v as num).toInt();
int? _asIntOrNull(Object? v) => v == null ? null : (v as num).toInt();
double _asDouble(Object? v) => (v as num).toDouble();

T _enumFromWire<T>(Object? raw, Map<String, T> table, T fallback) =>
    raw is String ? (table[raw] ?? fallback) : fallback;

// --- auth --------------------------------------------------------------------

/// The OIDC providers accepted by `POST /auth/session`. (Email sign-in uses the dedicated
/// `/auth/email/*` routes, not a provider value here.)
enum AuthProvider {
  apple('apple'),
  google('google');

  const AuthProvider(this.wire);

  /// The exact string the backend expects in the request body.
  final String wire;
}

/// The signed-in account (`user` object from `/auth/session`, `/auth/email/verify`, `/auth/me`).
/// Wire: snake_case.
class Account {
  const Account({
    required this.id,
    required this.ianaTimezone,
    required this.explanationLanguage,
    required this.learningLanguage,
    required this.explanationFollowsLearning,
    this.provider,
    this.email,
    required this.reminderEnabled,
    this.reminderTime,
    required this.pro,
    this.proUntil,
  });

  final String id;

  /// The sign-in provider: `"apple"` | `"google"` | `"email"` (the Settings identity badge). A
  /// plain string, not [AuthProvider], because the account can be `email` (which isn't a `/auth/session`
  /// provider).
  final String? provider;

  /// The account's email (the Settings identity row), or null when the provider shared none
  /// (e.g. Apple private relay).
  final String? email;

  /// IANA timezone captured at first sign-in (drives the per-account review day boundary).
  final String ianaTimezone;

  /// The **effective** gloss language for explanations — a canonical BCP-47 tag from the
  /// explanation-language set (`en`, `es`, `de`, `it`, `fr`, `pt`, `zh-Hans`, `ja`, `ko`),
  /// resolved server-side. Read this directly for glosses; when [explanationFollowsLearning]
  /// is true it equals the resolved learning language (English if none set / unsupported).
  final String explanationLanguage;

  /// When true, the explanation language **follows the learning language** (the immersion
  /// default) rather than an explicit pick — Settings renders this as "Same as learning
  /// language". [explanationLanguage] already carries the resolved effective value either way.
  final bool explanationFollowsLearning;

  /// Default target language (canonical BCP-47) or null if unset.
  final String? learningLanguage;

  /// Whether daily review reminders are on (US-14.1; the CLIENT fires the local notification — both
  /// clients now do, via capecho_app_core's ReminderScheduler — the account just stores the preference
  /// so it syncs across devices).
  final bool reminderEnabled;

  /// Local "HH:MM" reminder time, or null when unset.
  final String? reminderTime;

  /// Server-authoritative Pro entitlement (computed at fetch time = `pro_until > now`). The client
  /// renders the paywall/cap state off this; every Pro-gated SERVER path re-checks, so a stale-true
  /// value can never actually grant access.
  final bool pro;

  /// The Pro entitlement horizon (epoch ms), or null when free — drives the Settings "Pro until …" row.
  final int? proUntil;

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: json['id'] as String,
        ianaTimezone: json['iana_timezone'] as String,
        explanationLanguage: json['explanation_language'] as String,
        explanationFollowsLearning: json['explanation_follows_learning'] as bool,
        learningLanguage: json['learning_language'] as String?,
        provider: json['provider'] as String?,
        email: json['email'] as String?,
        reminderEnabled: json['reminder_enabled'] as bool,
        reminderTime: json['reminder_time'] as String?,
        pro: json['pro'] as bool,
        proUntil: _asIntOrNull(json['pro_until']),
      );

  @override
  String toString() => 'Account($id, tz: $ianaTimezone, learning: $learningLanguage)';
}

/// A minted bearer session. Wire: `{ token, expires_at, user }`.
class AuthSession {
  const AuthSession({required this.token, required this.expiresAt, required this.account});

  /// The raw bearer token — returned ONCE; store it securely (Keychain). Sent as
  /// `Authorization: Bearer <token>` on every authed request.
  final String token;

  /// Absolute expiry, epoch milliseconds.
  final int expiresAt;

  final Account account;

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
        token: json['token'] as String,
        expiresAt: _asInt(json['expires_at']),
        account: Account.fromJson(json['user'] as Map<String, dynamic>),
      );
}

// --- words -------------------------------------------------------------------

/// Server-side explanation state for a word. Wire string (snake_case-ish): `pending` | `ready` |
/// `language_unsupported` | `failed`.
enum ExplanationState {
  pending,
  ready,
  languageUnsupported,
  failed;

  static ExplanationState fromWire(Object? raw) => _enumFromWire(
      raw,
      const {
        'pending': ExplanationState.pending,
        'ready': ExplanationState.ready,
        'language_unsupported': ExplanationState.languageUnsupported,
        'failed': ExplanationState.failed,
      },
      ExplanationState.pending);
}

/// A word from `GET /words` (the Word Book). Wire: snake_case (this is the raw D1 row).
class Word {
  const Word({
    required this.id,
    required this.userId,
    required this.targetLanguage,
    required this.surfaceUnit,
    required this.normalizedUnit,
    required this.targetNormalizationVersion,
    required this.isPhrase,
    required this.explanationState,
    required this.explanationCacheKey,
    required this.fsrsEpoch,
    required this.createdAt,
    required this.updatedAt,
    required this.deletedAt,
    this.fsrs,
  });

  final String id;
  final String userId;
  final String targetLanguage;
  final String surfaceUnit;
  final String normalizedUnit;
  final String targetNormalizationVersion;
  final bool isPhrase;
  final ExplanationState explanationState;
  final String? explanationCacheKey;
  final int fsrsEpoch;
  final int createdAt;
  final int updatedAt;
  final int? deletedAt;

  /// Per-unit FSRS state (the Word Book memory meter), joined at the unit's current epoch by
  /// `GET /words`. Null until the unit has been reviewed at this epoch (a new card, or a freshly
  /// resurrected one) — render the meter's "not yet scheduled" placeholder then.
  final WordFsrs? fsrs;

  factory Word.fromJson(Map<String, dynamic> json) => Word(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        targetLanguage: json['target_language'] as String,
        surfaceUnit: json['surface_unit'] as String,
        normalizedUnit: json['normalized_unit'] as String,
        targetNormalizationVersion: json['target_normalization_version'] as String,
        isPhrase: _asBool(json['is_phrase']),
        explanationState: ExplanationState.fromWire(json['explanation_state']),
        explanationCacheKey: json['explanation_cache_key'] as String?,
        fsrsEpoch: _asInt(json['fsrs_epoch']),
        createdAt: _asInt(json['created_at']),
        updatedAt: _asInt(json['updated_at']),
        deletedAt: _asIntOrNull(json['deleted_at']),
        fsrs: json['fsrs'] == null ? null : WordFsrs.fromJson(json['fsrs'] as Map<String, dynamic>),
      );

  @override
  String toString() => 'Word($id, "$surfaceUnit" [$targetLanguage], $explanationState)';
}

/// Per-unit FSRS projection carried on a `GET /words` row (the memory meter). Wire: **snake_case**
/// (`due_at`, `last_review_at`) because it rides the raw `/words` row — distinct from the camelCase
/// [ProjectedCard] that `POST /review` returns. `state` + `stability` drive the meter's level;
/// `dueAt` drives the "due now / in N days" line.
class WordFsrs {
  const WordFsrs({
    required this.stability,
    required this.difficulty,
    required this.dueAt,
    required this.state,
    required this.reps,
    required this.lapses,
    required this.lastReviewAt,
  });

  final double stability;
  final double difficulty;
  final int dueAt;
  final CardState state;
  final int reps;
  final int lapses;
  final int? lastReviewAt;

  factory WordFsrs.fromJson(Map<String, dynamic> json) => WordFsrs(
        stability: _asDouble(json['stability']),
        difficulty: _asDouble(json['difficulty']),
        dueAt: _asInt(json['due_at']),
        state: CardState.fromWire(json['state']),
        reps: _asInt(json['reps']),
        lapses: _asInt(json['lapses']),
        lastReviewAt: _asIntOrNull(json['last_review_at']),
      );
}

// --- review ------------------------------------------------------------------

/// FSRS card lifecycle state. Wire: `new` | `learning` | `review` | `relearning`.
enum CardState {
  isNew('new'),
  learning('learning'),
  review('review'),
  relearning('relearning');

  const CardState(this.wire);
  final String wire;

  static CardState fromWire(Object? raw) => _enumFromWire(
      raw,
      const {
        'new': CardState.isNew,
        'learning': CardState.learning,
        'review': CardState.review,
        'relearning': CardState.relearning,
      },
      CardState.review);
}

/// The four review grades. Wire value: 1–4 (server-authoritative FSRS; the client never previews
/// the next interval). The UI buttons map Forget/Hard/Good/Easy → these.
enum Rating {
  again(1),
  hard(2),
  good(3),
  easy(4);

  const Rating(this.value);
  final int value;

  static Rating fromValue(int v) =>
      Rating.values.firstWhere((r) => r.value == v, orElse: () => Rating.good);
}

/// A card surfaced by `GET /review/due`. Wire: camelCase.
class DueCard {
  const DueCard({
    required this.wordId,
    required this.surfaceUnit,
    required this.targetLanguage,
    required this.state,
    required this.dueAt,
    required this.isNew,
  });

  final String wordId;
  final String surfaceUnit;
  final String targetLanguage;
  final CardState state;

  /// Due time, epoch milliseconds.
  final int dueAt;

  /// True for a never-before-reviewed card (counts against the daily new-card soft cap).
  final bool isNew;

  factory DueCard.fromJson(Map<String, dynamic> json) => DueCard(
        wordId: json['wordId'] as String,
        surfaceUnit: json['surfaceUnit'] as String,
        targetLanguage: json['targetLanguage'] as String,
        state: CardState.fromWire(json['state']),
        dueAt: _asInt(json['dueAt']),
        isNew: _asBool(json['isNew']),
      );

  @override
  String toString() => 'DueCard($wordId, "$surfaceUnit", $state, new: $isNew)';
}

/// The `GET /review/due` payload: due cards + new cards + counts.
class DueReviews {
  const DueReviews(
      {required this.due, required this.newCards, required this.dueCount, required this.newCount});

  /// Already-scheduled cards that are due now (most-overdue first), uncapped.
  final List<DueCard> due;

  /// Never-reviewed cards introduced today, capped by the per-day new-card soft cap.
  final List<DueCard> newCards;

  final int dueCount;
  final int newCount;

  factory DueReviews.fromJson(Map<String, dynamic> json) {
    final counts = (json['counts'] as Map<String, dynamic>?) ?? const {};
    List<DueCard> cards(Object? raw) =>
        (raw as List? ?? const []).cast<Map<String, dynamic>>().map(DueCard.fromJson).toList();
    final due = cards(json['due']);
    final newCards = cards(json['new']);
    return DueReviews(
      due: due,
      newCards: newCards,
      dueCount: _asIntOrNull(counts['due']) ?? due.length,
      newCount: _asIntOrNull(counts['new']) ?? newCards.length,
    );
  }

  /// All cards to review this session, due first then new (the order the queue should present).
  List<DueCard> get all => [...due, ...newCards];
}

/// The server's FSRS projection after a rating (`POST /review` → `card`). Wire: camelCase. The
/// client renders these; it never computes them.
class ProjectedCard {
  const ProjectedCard({
    required this.stability,
    required this.difficulty,
    required this.dueAt,
    required this.lastReviewAt,
    required this.reps,
    required this.lapses,
    required this.state,
  });

  final double stability;
  final double difficulty;
  final int dueAt;
  final int lastReviewAt;
  final int reps;
  final int lapses;
  final CardState state;

  factory ProjectedCard.fromJson(Map<String, dynamic> json) => ProjectedCard(
        stability: _asDouble(json['stability']),
        difficulty: _asDouble(json['difficulty']),
        dueAt: _asInt(json['dueAt']),
        lastReviewAt: _asInt(json['lastReviewAt']),
        reps: _asInt(json['reps']),
        lapses: _asInt(json['lapses']),
        state: CardState.fromWire(json['state']),
      );
}

/// Result of a single applied rating (`POST /review`, 200). Non-2xx outcomes (not_found,
/// unit_deleted, event_id_conflict) surface as [ApiException].
class ReviewOutcome {
  const ReviewOutcome({required this.replay, required this.card});

  /// True if this event_id was already applied (idempotent replay) — no double-count.
  final bool replay;

  /// The post-rating FSRS projection (may be null in unusual server responses).
  final ProjectedCard? card;

  factory ReviewOutcome.fromJson(Map<String, dynamic> json) => ReviewOutcome(
        replay: _asBool(json['replay']),
        card: json['card'] == null
            ? null
            : ProjectedCard.fromJson(json['card'] as Map<String, dynamic>),
      );
}

/// Per-event status in a `POST /sync` flush.
enum ReviewStatus {
  applied,
  notFound,
  unitDeleted,
  idConflict,
  error,
  invalid;

  static ReviewStatus fromWire(Object? raw) => _enumFromWire(
      raw,
      const {
        'applied': ReviewStatus.applied,
        'not_found': ReviewStatus.notFound,
        'unit_deleted': ReviewStatus.unitDeleted,
        'id_conflict': ReviewStatus.idConflict,
        'error': ReviewStatus.error,
        'invalid': ReviewStatus.invalid,
      },
      ReviewStatus.error);
}

/// One queued rating event sent to `POST /review` (single) or `POST /sync` (batch). Wire: snake_case
/// (`word_id`, `event_id`, `rating`, `client_review_ts`). `event_id` is a client-generated UUID that
/// makes the rating idempotent across retries (the offline queue re-flush can't double-count).
class SyncEvent {
  const SyncEvent({
    required this.wordId,
    required this.eventId,
    required this.rating,
    required this.clientReviewTs,
    this.source = 'app',
  });

  final String wordId;
  final String eventId;
  final Rating rating;

  /// When the user rated, epoch milliseconds (the server clamps elapsed time from this).
  final int clientReviewTs;

  /// Which surface produced the rating: `app` (in-app review), `widget` (the home-screen widget
  /// grade), or `notification` (an actionable reminder). ATTRIBUTION ONLY — the server stores it on
  /// the event log for `/analytics`, never folds it into FSRS. Defaults `app` so the in-app review
  /// path (and any older client) is tagged in-app with no change at the call site.
  final String source;

  Map<String, dynamic> toJson() => {
        'word_id': wordId,
        'event_id': eventId,
        'rating': rating.value,
        'client_review_ts': clientReviewTs,
        'source': source,
      };

  /// Reconstruct a queued event from its [toJson] map — used by the durable offline queue to persist
  /// ratings across a cold start (the widget's App-Group-backed store, Phase 1). Lenient: an
  /// unknown/absent rating falls back via [Rating.fromValue]; an absent source reads as `app`.
  factory SyncEvent.fromJson(Map<String, dynamic> json) => SyncEvent(
        wordId: json['word_id'] as String,
        eventId: json['event_id'] as String,
        rating: Rating.fromValue(_asInt(json['rating'])),
        clientReviewTs: _asInt(json['client_review_ts']),
        source: json['source'] as String? ?? 'app',
      );
}

/// Per-event result from `POST /sync`. Wire: camelCase (`eventId`, `status`, `card`).
class SyncEventResult {
  const SyncEventResult({required this.eventId, required this.status, required this.card});

  final String eventId;
  final ReviewStatus status;
  final ProjectedCard? card;

  factory SyncEventResult.fromJson(Map<String, dynamic> json) => SyncEventResult(
        eventId: json['eventId'] as String? ?? '',
        status: ReviewStatus.fromWire(json['status']),
        card: json['card'] == null
            ? null
            : ProjectedCard.fromJson(json['card'] as Map<String, dynamic>),
      );
}

// --- explain -----------------------------------------------------------------

/// One part of speech under a reading + its meanings — the bilingual per-POS gloss row the overlay
/// renders (Phase 1, overlay-bilingual-plan.md). [senses] are written in the explanation/native
/// language: translations when it differs from the word's own language, short definitions when it
/// matches. Wire: camelCase (`partOfSpeech`, `senses`). Every sense is shown — there is no cap and no
/// "more" hint (an old cached blob may still carry an ignored `hasMore` key).
class PosGroup {
  const PosGroup({required this.partOfSpeech, required this.senses});

  /// Closed-set short English POS label (e.g. "noun", "verb"), or "idiom" for a phrase.
  final String partOfSpeech;

  /// Frequency-ordered meanings — ALL the word's common senses under this part of speech (every
  /// surface shows them all, scrolling if tall).
  final List<String> senses;

  factory PosGroup.fromJson(Map<String, dynamic> json) => PosGroup(
        partOfSpeech: json['partOfSpeech'] as String? ?? '',
        senses: (json['senses'] as List? ?? const []).cast<String>(),
      );
}

/// One PRONUNCIATION (reading) of a word + the parts of speech (each with its meanings) used under it
/// — the entry's organizing axis. Most words have one reading; a heteronym has several (the noun
/// "object" vs the verb). What a "pronunciation" IS is target-profile-defined (en: GenAm + RP IPA;
/// zh-Hans: Hanyu Pinyin, no secondary) — the fields are target-neutral; display labels ("US"/"UK")
/// come from the target profile, never from the data. Either slot may be `''` when omit-on-failed.
/// Wire: camelCase (`pronunciationPrimary`, `pronunciationSecondary`, `kind`, `pos`).
class Reading {
  const Reading({
    required this.pronunciationPrimary,
    required this.pronunciationSecondary,
    this.kind,
    required this.pos,
  });

  /// Bare primary transcription (the renderer decorates); `''` when omit-on-failed.
  final String pronunciationPrimary;

  /// Bare secondary transcription; `''` when the target has no second slot or omit-on-failed.
  final String pronunciationSecondary;

  /// "idiom" for a phrase/idiom reading (render a badge, suppress IPA); null for an ordinary word.
  final String? kind;

  /// The parts of speech under this reading, each carrying its meanings.
  final List<PosGroup> pos;

  /// Whether either slot has a renderable transcription.
  bool get hasPronunciation => pronunciationPrimary.isNotEmpty || pronunciationSecondary.isNotEmpty;

  /// Whether this reading is a phrase/idiom (badge, no IPA).
  bool get isIdiom => kind == 'idiom';

  factory Reading.fromJson(Map<String, dynamic> json) => Reading(
        pronunciationPrimary: json['pronunciationPrimary'] as String? ?? '',
        pronunciationSecondary: json['pronunciationSecondary'] as String? ?? '',
        kind: json['kind'] as String?,
        pos: (json['pos'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(PosGroup.fromJson)
            .toList(),
      );
}

/// A word explanation (`GET /explain` → `explanation`). Wire: camelCase.
///
/// Phase 1 (overlay-bilingual-plan.md): the single prose `summary` was replaced by per-POS [readings]
/// → [PosGroup.senses]. The server-side MUST-PASS core is the captured unit's PRIMARY sense, so
/// [primarySense] is effectively non-empty. Compact surfaces (Word Book row, Review preview, widget)
/// derive their one-liner from [primarySense]; the overlay + Word Book detail render the full per-POS
/// senses.
class WordExplanation {
  const WordExplanation({required this.readings});

  /// The word's distinct readings: pronunciation + per-POS meanings.
  final List<Reading> readings;

  /// The captured unit's PRIMARY sense — the one-line preview compact surfaces show. One home for the
  /// derivation (mirrors the backend `previewLine`). `''` only for a degenerate blob with no senses.
  String get primarySense {
    for (final r in readings) {
      for (final g in r.pos) {
        if (g.senses.isNotEmpty && g.senses.first.trim().isNotEmpty) return g.senses.first.trim();
      }
    }
    return '';
  }

  factory WordExplanation.fromJson(Map<String, dynamic> json) => WordExplanation(
        readings: (json['readings'] as List? ?? const [])
            .cast<Map<String, dynamic>>()
            .map(Reading.fromJson)
            .toList(),
      );
}

/// The status of `GET /explain`. Most are 200 bodies; [notAWord] arrives as a 422 (`not_a_word`) that
/// [CapechoApi.explain] catches and maps here, so the caller sees one result type. (`budget_exhausted`
/// (503) and `generation_failed` (502) still surface as [ApiException].)
enum ExplainStatus {
  hit,
  generated,
  languageUnsupported,
  anonMiss,

  /// The unit isn't a real word — the model declined it ({"notAWord": true}) or a server junk/gibberish
  /// gate caught it. No explanation; the capture still saves.
  notAWord;

  static ExplainStatus fromWire(Object? raw) => _enumFromWire(
      raw,
      const {
        'hit': ExplainStatus.hit,
        'generated': ExplainStatus.generated,
        'language_unsupported': ExplainStatus.languageUnsupported,
        'anon_miss': ExplainStatus.anonMiss,
        'not_a_word': ExplainStatus.notAWord,
      },
      ExplainStatus.anonMiss);
}

/// The `GET /explain` payload (a 200). [explanation] is present for `hit`/`generated`, null for
/// `language_unsupported`/`anon_miss`.
class ExplainResult {
  const ExplainResult({required this.status, required this.explanation});

  final ExplainStatus status;
  final WordExplanation? explanation;

  bool get hasExplanation => explanation != null;

  factory ExplainResult.fromJson(Map<String, dynamic> json) => ExplainResult(
        status: ExplainStatus.fromWire(json['status']),
        explanation: json['explanation'] == null
            ? null
            : WordExplanation.fromJson(json['explanation'] as Map<String, dynamic>),
      );
}

// --- contexts ----------------------------------------------------------------

/// A saved context sentence for a word (`GET /contexts`), decrypted server-side. Wire: camelCase.
class ContextView {
  const ContextView({
    required this.id,
    required this.wordId,
    required this.contextLanguage,
    required this.contextText,
    required this.spanStart,
    required this.spanEnd,
    required this.meaning,
    this.sourceApp,
    this.sourceTitle,
    required this.createdAt,
  });

  final String id;
  final String wordId;
  final String? contextLanguage;
  final String contextText;

  /// UTF-16 offsets of the unit within [contextText] for highlighting (both null if no span).
  final int? spanStart;
  final int? spanEnd;

  /// Private context-layer gloss, if generated (decrypted): one combined explanation of the unit's
  /// in-context meaning AND the whole sentence's meaning. Null when not yet generated (or a
  /// stale-version payload).
  final String? meaning;

  /// Capture provenance ("where I met this word"): the source application's name and the source
  /// window's title (decrypted server-side). Null when the capture didn't carry them. Shown as a quiet
  /// caption on the Review card + each Word Book context; never gates anything.
  final String? sourceApp;
  final String? sourceTitle;

  final int createdAt;

  /// True once the in-context gloss has been generated.
  bool get hasGloss => meaning != null;

  /// True when any source provenance is present (drives whether the source caption renders).
  bool get hasSource =>
      (sourceApp != null && sourceApp!.isNotEmpty) ||
      (sourceTitle != null && sourceTitle!.isNotEmpty);

  factory ContextView.fromJson(Map<String, dynamic> json) => ContextView(
        id: json['id'] as String,
        wordId: json['wordId'] as String,
        contextLanguage: json['contextLanguage'] as String?,
        contextText: json['contextText'] as String,
        spanStart: _asIntOrNull(json['spanStart']),
        spanEnd: _asIntOrNull(json['spanEnd']),
        meaning: json['meaning'] as String?,
        sourceApp: json['sourceApp'] as String?,
        sourceTitle: json['sourceTitle'] as String?,
        createdAt: _asInt(json['createdAt']),
      );

  /// A copy with selected fields replaced. [clearGloss] forces both gloss fields to null — used after an
  /// edit, which clears the server-stored gloss (it was for the old sentence). Without it, null gloss
  /// arguments leave the current values untouched. Source provenance is preserved across edits.
  ContextView copyWith({
    String? contextText,
    String? meaning,
    bool clearGloss = false,
  }) =>
      ContextView(
        id: id,
        wordId: wordId,
        contextLanguage: contextLanguage,
        contextText: contextText ?? this.contextText,
        spanStart: spanStart,
        spanEnd: spanEnd,
        meaning: clearGloss ? null : (meaning ?? this.meaning),
        sourceApp: sourceApp,
        sourceTitle: sourceTitle,
        createdAt: createdAt,
      );
}

/// The result of `POST /explain/context` — the paid sentence-specific gloss: one combined explanation
/// of the unit's in-context meaning AND the whole sentence's meaning. [charged] is false when the gloss
/// was already stored (a re-view that didn't spend daily quota, §16).
class ContextExplanation {
  const ContextExplanation({
    required this.meaning,
    required this.charged,
  });

  /// The unit's in-context meaning AND the whole sentence's meaning, as one plain explanation.
  final String meaning;

  /// False when the gloss was already stored (a re-view that didn't spend quota). Forward-hook: not yet
  /// read by the macOS UI — it surfaces once the remaining-quota count is shown (the route returns this,
  /// not the count).
  final bool charged;

  factory ContextExplanation.fromJson(Map<String, dynamic> json) => ContextExplanation(
        meaning: json['meaning'] as String,
        charged: json['charged'] as bool? ?? true,
      );
}

/// The result of `POST /explain/context/preview` (E2) — the metered in-context gloss for a word that
/// is NOT yet saved (explained from the overlay on the raw sentence). [previewHandle] is the opaque,
/// user-scoped token Save passes back (as `preview_handle`) to ADOPT this gloss onto the new context
/// with no recharge; if the user dismisses, the preview just TTL-expires. Wire: camelCase.
class ContextPreview {
  const ContextPreview({
    required this.meaning,
    required this.previewHandle,
    required this.charged,
  });

  /// The unit's in-context meaning AND the whole sentence's meaning, as one plain explanation.
  final String meaning;
  final String previewHandle;

  /// False when the daily slot wasn't spent (a generation that outran its reservation TTL but still
  /// produced a stored, adoptable gloss).
  final bool charged;

  factory ContextPreview.fromJson(Map<String, dynamic> json) => ContextPreview(
        meaning: json['meaning'] as String,
        previewHandle: json['previewHandle'] as String,
        charged: json['charged'] as bool? ?? true,
      );
}

// --- claim (pre-login) -------------------------------------------------------

/// A local context attached to a claimed word. Wire (request): snake_case.
class ClaimContext {
  const ClaimContext({
    required this.text,
    this.contextLanguage,
    this.spanStart,
    this.spanEnd,
    this.sourceApp,
    this.sourceTitle,
    this.detectedLanguage,
    this.detectedLanguageConfidence,
    this.previewHandle,
  });

  final String text;
  final String? contextLanguage;
  final int? spanStart;
  final int? spanEnd;

  /// Capture-source provenance ("where I met this word"). [sourceApp] (the source application's name)
  /// and [detectedLanguage] / [detectedLanguageConfidence] (the capture-time recognition signal) stay
  /// PLAINTEXT at rest on the backend — low-sensitivity, and the app is what filtering/analytics key on.
  /// [sourceTitle] (the source window's title) carries private specifics, so the backend ENCRYPTS it at
  /// rest in the same envelope as the sentence. All optional — null when the capture didn't resolve them.
  final String? sourceApp;
  final String? sourceTitle;
  final String? detectedLanguage;
  final double? detectedLanguageConfidence;

  /// E2 adopt-on-save: a still-fresh capture-time "Explain in this sentence" preview handle. When
  /// present, the backend attaches that already-metered gloss to this context on claim (no recharge);
  /// a stale/foreign/expired handle is simply ignored. Null for backlog rows captured before any preview.
  final String? previewHandle;

  Map<String, dynamic> toJson() => {
        'text': text,
        if (contextLanguage != null) 'context_language': contextLanguage,
        if (spanStart != null) 'span_start': spanStart,
        if (spanEnd != null) 'span_end': spanEnd,
        if (sourceApp != null) 'source_app': sourceApp,
        if (sourceTitle != null) 'source_title': sourceTitle,
        if (detectedLanguage != null) 'detected_language': detectedLanguage,
        if (detectedLanguageConfidence != null)
          'detected_language_confidence': detectedLanguageConfidence,
        if (previewHandle != null) 'preview_handle': previewHandle,
      };
}

/// One locally-captured row to claim into the account (`POST /words/claim`). Wire (request):
/// snake_case (`client_row_id`, `surface_unit`, `target_language`, `context`).
class ClaimRow {
  const ClaimRow({
    required this.clientRowId,
    required this.surfaceUnit,
    required this.targetLanguage,
    this.context,
  });

  final String clientRowId;
  final String surfaceUnit;
  final String targetLanguage;
  final ClaimContext? context;

  Map<String, dynamic> toJson() => {
        'client_row_id': clientRowId,
        'surface_unit': surfaceUnit,
        'target_language': targetLanguage,
        if (context != null) 'context': context!.toJson(),
      };
}

/// Per-row result from `POST /words/claim`. Wire (response): camelCase (`clientRowId`, `status`,
/// `wordId`, `contextStored`). `status` is one of created/deduped/resurrected/replayed/
/// invalid_target_language/empty_unit/unit_too_large.
class ClaimResult {
  const ClaimResult(
      {required this.clientRowId,
      required this.status,
      required this.wordId,
      required this.contextStored});

  final String clientRowId;
  final String status;
  final String? wordId;
  final bool? contextStored;

  /// True if the row landed a word in the account (created/deduped/resurrected/replayed).
  bool get claimed => wordId != null;

  /// True if the row was blocked by the free saved-word cap (the Pro lever): it was NOT claimed and
  /// stays on the device. The client surfaces the upgrade nudge (existing words are untouched).
  bool get capReached => status == 'cap_reached';

  factory ClaimResult.fromJson(Map<String, dynamic> json) => ClaimResult(
        clientRowId: json['clientRowId'] as String,
        status: json['status'] as String,
        wordId: json['wordId'] as String?,
        contextStored: json['contextStored'] as bool?,
      );
}

/// The result of `POST /billing/apple/verify` — the server-authoritative entitlement after it
/// re-fetched the subscription's canonical state from Apple (API-authority). [pro] / [proUntil] mirror
/// the [Account] fields so the buy flow can reflect the unlock immediately; [status] is the applied
/// outcome (`active` | `expired` | `grace_period` | `revoked` | `refunded` | …) for diagnostics. The
/// client still treats [Account] (re-pulled via `/auth/me`) as the source of truth — this is the fast
/// confirmation that the purchase landed.
class AppleVerifyResult {
  const AppleVerifyResult({
    required this.pro,
    required this.proUntil,
    required this.status,
    this.attributedToOtherAccount = false,
  });

  final bool pro;
  final int? proUntil;
  final String status;

  /// True when the verified Apple-ID subscription is already linked to a DIFFERENT Capecho account — Apple
  /// binds an auto-renewable sub to its first purchaser's appAccountToken, so this account can't take it
  /// over by re-buying. Lets the client say "already linked to another account" instead of "not active".
  final bool attributedToOtherAccount;

  factory AppleVerifyResult.fromJson(Map<String, dynamic> json) => AppleVerifyResult(
        pro: json['pro'] as bool? ?? false,
        proUntil: _asIntOrNull(json['pro_until']),
        status: json['status'] as String? ?? '',
        attributedToOtherAccount: json['attributed_to_other_account'] as bool? ?? false,
      );
}

/// One export row — ONE active unit (surface form + most-recent context sentence + word-level
/// definition + BCP-47 target language). The `GET /export?format=json` shape; the same data the
/// CSV/Anki text formats carry, JSON-encoded so the client can assemble the one-click Anki `.apkg`
/// deck locally (SQLite `collection.anki2` + zip). `contextLanguage` is non-empty ONLY when the
/// sentence's language differs from `targetLanguage` (US-6.1); `definition` is `''` when the word's
/// explanation isn't generated yet. Fields mirror the backend `ExportRow` (`backend/src/export.ts`).
class ExportRow {
  const ExportRow({
    required this.word,
    required this.context,
    required this.contextLanguage,
    required this.definition,
    required this.targetLanguage,
  });

  final String word;
  final String context;
  final String contextLanguage;
  final String definition;
  final String targetLanguage;

  factory ExportRow.fromJson(Map<String, dynamic> json) => ExportRow(
        word: json['word'] as String? ?? '',
        context: json['context'] as String? ?? '',
        contextLanguage: json['contextLanguage'] as String? ?? '',
        definition: json['definition'] as String? ?? '',
        targetLanguage: json['targetLanguage'] as String? ?? '',
      );
}
