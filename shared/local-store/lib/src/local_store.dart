import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'journal_entry.dart';
import 'rows.dart';
import 'schema.dart';
import 'uuid.dart';

/// Normalizes a raw surface unit into its dedup key (`normalized_unit`). Language-independent by
/// design (the dedup scope key already carries the target language).
///
/// INJECTED so this package stays dependency-light: the macOS app wires `localDedupKey` (deterministic,
/// NO lemmatization — `study`/`studied` stay distinct; mirrors the server's `dedupKey`), passing
/// `kLocalDedupVersion` as the store's `normalizationVersion`; tests pass a stub such as
/// `(u) => u.trim().toLowerCase()`. May return an empty string (e.g. the unit normalized away to
/// nothing) — the drain treats that as "skip but still advance the cursor".
typedef Normalizer = String Function(String surfaceUnit);

const String _kLastDrainedSeqKey = 'last_drained_seq';
const String _kSchemaVersionKey = 'schema_version';
const String _kMetricDroppedKey = 'metric_dropped';

/// Bounded size of the §14 metric buffer. A long offline stretch evicts the OLDEST events past this
/// (drop-oldest) so the store file can't grow without bound; the eviction is COUNTED (never silent).
const int kMaxMetricBuffer = 1000;

/// Capecho's device-local store: the pre-login, single-user mirror of the backend `words` /
/// `word_contexts` tables, plus the idempotent [drain] of the native capture journal.
///
/// Correctness contract ("zero silent failures"): replaying the journal — same `seq`s, or an entry
/// re-sent below the cursor — never duplicates words or contexts and never moves the cursor
/// backwards. Idempotency rests on three invariants:
///   1. The drain cursor (`meta.last_drained_seq`): only entries with `seq > lastDrainedSeq` apply,
///      and the cursor advances monotonically (`max`).
///   2. The dedup key `UNIQUE(target_language, normalized_unit, claimed, claimed_account_id)`
///      (spanning tombstoned rows): one word per `(language, normalized unit)` within each ownership
///      slice (anonymous, or claimed-into-a-given-account); a resave resurrects the same row.
///   3. The context PK `word_contexts.client_row_id == entry.clientRowId`: re-applying an entry is
///      an `INSERT OR IGNORE` no-op.
/// A whole [drain] batch runs inside one transaction.
class LocalStore {
  final Database _db;
  final Normalizer _normalizer;
  final String _normalizationVersion;

  LocalStore._(this._db, this._normalizer, this._normalizationVersion) {
    _applyPragmas();
    _migrate();
  }

  /// Opens (creating if absent) a file-backed store at [path].
  static LocalStore open({
    required String path,
    required Normalizer normalizer,
    required String normalizationVersion,
  }) {
    return LocalStore._(sqlite3.open(path), normalizer, normalizationVersion);
  }

  /// Opens an in-memory store (for tests).
  static LocalStore openInMemory({
    required Normalizer normalizer,
    required String normalizationVersion,
  }) {
    return LocalStore._(sqlite3.openInMemory(), normalizer, normalizationVersion);
  }

  void _applyPragmas() {
    for (final pragma in kOpenPragmas) {
      _db.execute(pragma);
    }
  }

  void _migrate() {
    // Base DDL builds the v1 schema. Every statement is CREATE ... IF NOT EXISTS, so on a fresh
    // database it builds the current shape and on an existing one it is a no-op. A future schema change
    // that must transform existing rows adds a version-gated migration step here (gated on the stored
    // `meta.schema_version`); the only disposable table, `word_explanations`, can simply be dropped +
    // recreated (the next `/explain` success refills it).
    for (final stmt in kSchemaStatements) {
      _db.execute(stmt);
    }
    // Seed meta defaults if missing (no-op on a populated DB): the drain cursor + the stored schema
    // version (the anchor the version-gated migrations below gate on). A FRESH database seeds the
    // CURRENT version (its DDL is already current); an existing one keeps its stored version until a
    // migration advances it.
    _db.execute(
      'INSERT OR IGNORE INTO meta(key, value) VALUES(?, ?)',
      [_kLastDrainedSeqKey, '0'],
    );
    _db.execute(
      'INSERT OR IGNORE INTO meta(key, value) VALUES(?, ?)',
      [_kSchemaVersionKey, '$kSchemaVersion'],
    );
    // v1 → v2: the multilingual word-contract reset changed the cached explanation blob
    // (per-sense glosses deleted; summary became the must-pass core; pronunciation fields renamed).
    // word_explanations is the designed-disposable table — wipe it; the next `/explain` refills.
    // Words/contexts/journal state are untouched.
    final stored = int.tryParse(_metaGet(_kSchemaVersionKey) ?? '') ?? kSchemaVersion;
    if (stored < 2) {
      _db.execute('DELETE FROM word_explanations');
      _metaSet(_kSchemaVersionKey, '2');
    }
    // v2 → v3: add the capture-source-metadata columns to an existing word_contexts (a fresh DB already
    // has them from the base DDL, so its seeded version is 3 and this is skipped). Pure additive
    // ALTER ADD COLUMN — existing rows read NULL; words/contexts/journal state untouched.
    if (stored < 3) {
      final existing = {
        for (final r in _db.select('PRAGMA table_info(word_contexts)')) r['name'] as String,
      };
      kAddWordContextSourceColumns.forEach((column, ddl) {
        // Skip a column already present (idempotent: a re-run, or a DB built fresh from the current
        // base DDL whose stored version was rewound, won't hit "duplicate column name").
        if (!existing.contains(column)) _db.execute(ddl);
      });
      _metaSet(_kSchemaVersionKey, '3');
    }
    // v3 → v4: the bilingual per-POS overlay contract reshaped the cached blob (the standalone `summary`
    // column is gone; `readings` now carries per-POS senses). word_explanations is the designed-disposable
    // mirror, and the old shape's `summary` column can't be dropped in place on older SQLite — so DROP +
    // recreate to the current shape (the base DDL's IF NOT EXISTS above is a no-op while the old table
    // still exists). The next `/explain` success refills it; words/contexts/journal state are untouched.
    if (stored < 4) {
      _db.execute('DROP TABLE IF EXISTS word_explanations');
      _db.execute(kCreateWordExplanations);
      _metaSet(_kSchemaVersionKey, '4');
    }
    // v4 → v5: add the in-sentence gloss cache column to an existing word_contexts (a fresh DB already
    // has it from the base DDL → seeded version 5, skipped). Pure additive ALTER ADD COLUMN — existing
    // rows read NULL; words/contexts/journal state untouched. Idempotent (skips a column already present).
    if (stored < 5) {
      final existing = {
        for (final r in _db.select('PRAGMA table_info(word_contexts)')) r['name'] as String,
      };
      if (!existing.contains('gloss_meaning')) _db.execute(kAddWordContextGlossColumn);
      _metaSet(_kSchemaVersionKey, '5');
    }
  }

  String? _metaGet(String key) {
    final rs = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    if (rs.isEmpty) return null;
    return rs.first['value'] as String;
  }

  void _metaSet(String key, String value) {
    _db.execute(
      'INSERT INTO meta(key, value) VALUES(?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  /// The highest journal `seq` applied so far. Entries at or below this are no-ops.
  int get lastDrainedSeq {
    final raw = _metaGet(_kLastDrainedSeqKey) ?? '0';
    return int.tryParse(raw) ?? 0;
  }

  /// 1 if the trimmed [surfaceUnit] has internal whitespace (a phrase), else 0.
  static int _derivePhrase(String surfaceUnit) {
    final trimmed = surfaceUnit.trim();
    // Any run of whitespace BETWEEN non-whitespace characters makes it a phrase.
    return RegExp(r'\S\s+\S').hasMatch(trimmed) ? 1 : 0;
  }

  /// Idempotently applies [entries] (sorted internally by `seq`). Returns the count of NEW entries
  /// applied (i.e. those with `seq > lastDrainedSeq` at the time of application). Re-applying
  /// already-drained entries, or entries whose normalized unit is empty, advances the cursor but
  /// creates no rows. The whole batch runs in a single transaction; on any error it rolls back.
  ///
  /// [onApplied] is invoked WITHIN the transaction for each entry that resolved/created a word, with
  /// `(entry.clientRowId, wordId)` — the §14 capture-funnel hook (T17). The recorder threads the WORD
  /// id onto `capture_completed` so "captured but never synced" correlates with the word-id-keyed sync
  /// funnel. It must stay side-effect-free + cheap (a list append); it does NOT fire for an entry that
  /// normalized to empty (no word) or was already drained.
  int drain(
    List<JournalEntry> entries, {
    void Function(String clientRowId, String wordId, bool created)? onApplied,
  }) {
    if (entries.isEmpty) return 0;

    // Validate everything BEFORE opening the transaction so a malformed entry fails loudly
    // without leaving a half-applied batch.
    for (final e in entries) {
      e.validate();
    }

    // Apply in seq order regardless of input order (defensive; the journal is already monotonic).
    final ordered = [...entries]..sort((a, b) => a.seq.compareTo(b.seq));

    var applied = 0;
    _db.execute('BEGIN');
    try {
      var cursor = lastDrainedSeq;
      for (final e in ordered) {
        if (e.seq <= cursor) {
          // Already drained (or out-of-order duplicate below the cursor): skip, don't regress.
          continue;
        }
        _applyEntry(e, onApplied);
        applied++;
        cursor = e.seq; // monotonic: ordered ascending, each > previous cursor
      }
      // Persist the advanced cursor once for the batch. Never regress below the prior value.
      final newCursor = cursor > lastDrainedSeq ? cursor : lastDrainedSeq;
      _metaSet(_kLastDrainedSeqKey, '$newCursor');
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
    return applied;
  }

  /// Applies one already-validated, above-cursor entry within the open transaction. [onApplied], when
  /// given, fires with `(entry.clientRowId, wordId, created)` once the word is resolved/created (never
  /// for a normalized-empty entry, which creates no word) — the §14 capture-funnel hook (see [drain]).
  /// `created` is true only when this entry inserted a BRAND-NEW word row, false when it deduped into
  /// (or resurrected) an existing one — so the caller can tell a fresh capture from a re-capture that
  /// landed on a pre-existing (possibly pre-login) word.
  void _applyEntry(
    JournalEntry e, [
    void Function(String clientRowId, String wordId, bool created)? onApplied,
  ]) {
    final normalized = _normalizer(e.surfaceUnit);
    if (normalized.isEmpty) {
      // Normalized away to nothing: skip the row, but the caller still advances the cursor so the
      // entry is never reconsidered (zero silent retries / no stuck cursor).
      return;
    }

    // 1) Resolve the word via the dedup key (target_language, normalized_unit) WITHIN the anonymous
    //    namespace (claimed = 0). The drain only ever writes anonymous rows, and scoping the lookup
    //    to claimed = 0 means a previously-synced (claimed = 1, hidden) row never swallows a fresh
    //    anonymous re-capture. The unique index spans tombstoned rows, so a soft-deleted anonymous
    //    match is RESURRECTED rather than duplicated.
    final existing = _db.select(
      'SELECT client_row_id, deleted_at FROM words '
      'WHERE target_language = ? AND normalized_unit = ? AND claimed = 0',
      [e.targetLanguage, normalized],
    );

    final String wordId;
    if (existing.isNotEmpty) {
      wordId = existing.first['client_row_id'] as String;
      final deletedAt = existing.first['deleted_at'];
      if (deletedAt != null) {
        // Resurrect-on-resave: clear the tombstone, bump updated_at, re-dirty for sync.
        _db.execute(
          'UPDATE words SET deleted_at = NULL, updated_at = ?, sync_dirty = 1 '
          'WHERE client_row_id = ?',
          [e.capturedAt, wordId],
        );
      }
      // Active match: reuse as-is. (No metadata churn for a plain re-capture of an active word.)
    } else {
      wordId = uuidV4();
      _db.execute(
        'INSERT INTO words('
        'client_row_id, install_id, target_language, surface_unit, normalized_unit, '
        'target_normalization_version, is_phrase, source, created_at, updated_at, '
        'deleted_at, server_word_id, sync_dirty) '
        'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, 1)',
        [
          wordId,
          e.installId,
          e.targetLanguage,
          e.surfaceUnit,
          normalized,
          _normalizationVersion,
          _derivePhrase(e.surfaceUnit),
          e.source,
          e.capturedAt,
          e.capturedAt,
        ],
      );
    }

    // 2) Insert the context. PK == entry.clientRowId makes re-draining the SAME entry a no-op.
    _db.execute(
      'INSERT OR IGNORE INTO word_contexts('
      'client_row_id, word_client_row_id, context_text, context_language, '
      'span_start, span_end, source_app, source_title, detected_language, '
      'detected_language_confidence, created_at, sync_dirty) '
      'VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)',
      [
        e.clientRowId,
        wordId,
        e.contextText,
        e.contextLanguage,
        e.spanStart,
        e.spanEnd,
        e.sourceApp,
        e.sourceTitle,
        e.detectedLanguage,
        e.detectedLanguageConfidence,
        e.capturedAt,
      ],
    );

    // §14 capture funnel (T17): surface the (save-event id → word id) mapping so the metrics recorder
    // can thread the WORD id onto capture_completed (correlatable with the word-id-keyed sync funnel).
    // `created` distinguishes a brand-new word from a re-capture that deduped into an existing row.
    onApplied?.call(e.clientRowId, wordId, existing.isEmpty);
  }

  /// Active words (`deleted_at IS NULL`), newest first (by `created_at`, then `client_row_id` for a
  /// stable tiebreak), each with its `contextCount`. [limit] / [offset] page the result;
  /// [targetLanguage] filters to one language when given; [anonymousOnly] restricts to `claimed = 0`
  /// (the anonymous, pre-login rows — see [anonymousWords]).
  List<WordRow> activeWords({
    int? limit,
    int? offset,
    String? targetLanguage,
    bool anonymousOnly = false,
  }) {
    final where = StringBuffer('w.deleted_at IS NULL');
    final params = <Object?>[];
    if (anonymousOnly) {
      where.write(' AND w.claimed = 0');
    }
    if (targetLanguage != null) {
      where.write(' AND w.target_language = ?');
      params.add(targetLanguage);
    }

    final sql = StringBuffer(
      'SELECT w.client_row_id, w.install_id, w.target_language, w.surface_unit, '
      'w.normalized_unit, w.target_normalization_version, w.is_phrase, w.source, '
      'w.created_at, w.updated_at, w.deleted_at, w.server_word_id, w.sync_dirty, w.claimed, '
      '(SELECT COUNT(*) FROM word_contexts c WHERE c.word_client_row_id = w.client_row_id) '
      'AS context_count '
      'FROM words w WHERE ',
    )
      ..write(where)
      ..write(' ORDER BY w.created_at DESC, w.client_row_id DESC');
    if (limit != null) {
      sql.write(' LIMIT ?');
      params.add(limit);
      if (offset != null) {
        sql.write(' OFFSET ?');
        params.add(offset);
      }
    }

    final rs = _db.select(sql.toString(), params);
    return rs.map(_wordFromRow).toList();
  }

  /// Active words that are still anonymous (`claimed = 0`) — the rows a signed-out Word Book shows.
  /// Account-synced rows (`claimed = 1`) are excluded, which is what keeps them out of view after a
  /// sign-out (display isolation rests entirely on this filter; sign-out itself mutates nothing here).
  List<WordRow> anonymousWords({int? limit, int? offset, String? targetLanguage}) => activeWords(
        limit: limit,
        offset: offset,
        targetLanguage: targetLanguage,
        anonymousOnly: true,
      );

  /// Whether an ACTIVE (non-tombstoned) word already exists for [surfaceUnit] under [targetLanguage]
  /// that the current viewer would see in their Word Book. Drives the capture overlay's "already in
  /// your Word Book" cue on a re-capture (bug #6). [surfaceUnit] is normalized the same way the drain
  /// dedups, so a different surface form of the same unit (e.g. casing/whitespace) still matches; a
  /// unit that normalizes to empty is never "saved".
  ///
  /// The match is scoped to EXACTLY what the current viewer's Word Book shows, so the cue and the book
  /// never disagree. Signed OUT ([accountId] null) → anonymous rows only (`claimed = 0`), the signed-out
  /// catalog. Signed IN → only rows synced into THIS account (`claimed_account_id = accountId`); a word
  /// only another account ever synced doesn't count, AND — deliberately — neither do anonymous local
  /// rows. Anonymous rows aren't in ANY account's (server) Word Book until the user explicitly syncs, so
  /// counting them made the cue falsely claim "already in your Word Book" for un-synced captures after a
  /// sign-in / account switch (the signed-in book reads the server, where they're absent). A
  /// just-captured word becomes this account's the instant its background auto-claim lands — the same
  /// moment it appears in the account's book — so the cue and the book stay consistent through that
  /// window too.
  bool hasActiveWord(
    String surfaceUnit,
    String targetLanguage, {
    String? accountId,
  }) {
    final normalized = _normalizer(surfaceUnit);
    if (normalized.isEmpty) return false;
    final params = <Object?>[targetLanguage, normalized];
    final String ownerClause;
    if (accountId == null) {
      ownerClause = 'claimed = 0'; // signed out: the anonymous catalog
    } else {
      ownerClause = 'claimed_account_id = ?'; // signed in: only THIS account's synced rows
      params.add(accountId);
    }
    final rs = _db.select(
      'SELECT 1 FROM words '
      'WHERE target_language = ? AND normalized_unit = ? AND deleted_at IS NULL '
      'AND $ownerClause LIMIT 1',
      params,
    );
    return rs.isNotEmpty;
  }

  /// Caches the free word-layer explanation (the per-POS senses + pronunciation [readings]) for
  /// [surfaceUnit] under [targetLanguage] / [explanationLanguage], so a later re-capture can show it
  /// OFFLINE — at the SAME depth — and skip the redundant `/explain`. Keyed by the
  /// SAME normalization as the dedup (so any surface form of the unit hits), `INSERT OR REPLACE` so the
  /// newest `/explain` wins.
  ///
  /// Phase 1 must-pass: the per-POS senses ARE the explanation, so the blob is filtered to usable
  /// content (blank senses dropped → empty POS dropped → readings with no POS left dropped) and a unit
  /// that normalizes to empty, or a blob with NO non-blank sense, is not cached (mirrors the server
  /// must-pass + the overlay's primary-sense gate; there is no fallback field). PUBLIC free-layer blob
  /// ONLY — never a private per-context gloss.
  void putExplanation({
    required String surfaceUnit,
    required String targetLanguage,
    required String explanationLanguage,
    required List<LocalReading> readings,
    required int now,
  }) {
    final normalized = _normalizer(surfaceUnit);
    if (normalized.isEmpty) return;
    // Keep only readings that carry at least one POS with a non-blank sense — pronunciation alone (no
    // meaning) is not an explanation. A senseless blob is never cached.
    final usable = <LocalReading>[];
    for (final r in readings) {
      final pos = <LocalPosGroup>[];
      for (final g in r.pos) {
        final senses = [
          for (final s in g.senses)
            if (s.trim().isNotEmpty) s,
        ];
        if (senses.isNotEmpty) {
          pos.add(LocalPosGroup(partOfSpeech: g.partOfSpeech, senses: senses));
        }
      }
      if (pos.isNotEmpty) {
        usable.add(LocalReading(
          pronunciationPrimary: r.pronunciationPrimary,
          pronunciationSecondary: r.pronunciationSecondary,
          kind: r.kind,
          pos: pos,
        ));
      }
    }
    if (usable.isEmpty) return; // no sense to show — never cache a senseless blob
    final readingsJson = jsonEncode([
      for (final r in usable)
        {
          'pronunciationPrimary': r.pronunciationPrimary,
          'pronunciationSecondary': r.pronunciationSecondary,
          'kind': r.kind,
          'pos': [
            for (final g in r.pos) {'partOfSpeech': g.partOfSpeech, 'senses': g.senses},
          ],
        },
    ]);
    _db.execute(
      'INSERT OR REPLACE INTO word_explanations '
      '(target_language, normalized_unit, explanation_language, readings, cached_at) '
      'VALUES (?, ?, ?, ?, ?)',
      [targetLanguage, normalized, explanationLanguage, readingsJson, now],
    );
  }

  /// The cached free word-layer explanation for [surfaceUnit] under [targetLanguage] /
  /// [explanationLanguage], or null on a miss. Normalized the same way as the dedup, so a different
  /// surface form of the same unit still hits. Drives the offline meaning on a re-capture of a known
  /// word. A row with NO non-blank sense is a MISS — the senses are the only explanation text; there is
  /// no fallback (this also degrades an old-shape / corrupt row to a clean re-fetch).
  LocalExplanation? getExplanation({
    required String surfaceUnit,
    required String targetLanguage,
    required String explanationLanguage,
  }) {
    final normalized = _normalizer(surfaceUnit);
    if (normalized.isEmpty) return null;
    final rs = _db.select(
      'SELECT readings FROM word_explanations '
      'WHERE target_language = ? AND normalized_unit = ? AND explanation_language = ? LIMIT 1',
      [targetLanguage, normalized, explanationLanguage],
    );
    if (rs.isEmpty) return null;
    // The writer (putExplanation) guarantees a well-formed, sense-bearing row — but a corrupt / partial
    // / old-shape row (a truncated write, a manual DB edit, a pre-v4 blob a migration somehow missed)
    // must degrade to a cache MISS so the caller fetches fresh, NEVER throw on the capture path.
    try {
      final readings = <LocalReading>[];
      for (final r
          in (jsonDecode(rs.first['readings'] as String) as List).cast<Map<String, dynamic>>()) {
        final pos = <LocalPosGroup>[];
        for (final g in (r['pos'] as List? ?? const []).cast<Map<String, dynamic>>()) {
          pos.add(LocalPosGroup(
            partOfSpeech: g['partOfSpeech'] as String? ?? '',
            // EAGER element-checked copy — a lazy `.cast<String>()` view would construct fine here and
            // throw on FIRST ITERATION, outside this try, on the overlay's unguarded cache-hit path. A
            // non-string element must surface as a miss NOW. (A legacy `hasMore` key is simply ignored.)
            senses: List<String>.from(g['senses'] as List? ?? const []),
          ));
        }
        readings.add(LocalReading(
          pronunciationPrimary: r['pronunciationPrimary'] as String? ?? '',
          pronunciationSecondary: r['pronunciationSecondary'] as String? ?? '',
          kind: r['kind'] as String?,
          pos: pos,
        ));
      }
      // Must-pass mirror: no non-blank sense anywhere = nothing to show — a miss, never a fallback.
      final hasSense =
          readings.any((r) => r.pos.any((g) => g.senses.any((s) => s.trim().isNotEmpty)));
      if (!hasSense) return null;
      return LocalExplanation(readings: readings);
    } catch (_) {
      return null; // malformed JSON / unexpected shape → a cache miss, not a crash
    }
  }

  /// Contexts linked to [wordClientRowId], newest first.
  List<ContextRow> contextsFor(String wordClientRowId) {
    final rs = _db.select(
      'SELECT client_row_id, word_client_row_id, context_text, context_language, '
      'span_start, span_end, source_app, source_title, detected_language, '
      'detected_language_confidence, gloss_meaning, created_at, sync_dirty '
      'FROM word_contexts WHERE word_client_row_id = ? '
      'ORDER BY created_at DESC, client_row_id DESC',
      [wordClientRowId],
    );
    return rs.map(_contextFromRow).toList();
  }

  /// Store the in-sentence "Explain here" gloss for a saved context row (the one combined
  /// word-in-context + whole-sentence explanation), so the signed-out Word Book renders it without
  /// re-generating. A local display cache only — the signed-in path adopts the same gloss server-side via
  /// the claim handle. No-op for an unknown id; does NOT re-dirty the row (the gloss isn't its own sync
  /// unit — it rides the context's server adopt).
  void setContextGloss(String contextClientRowId, String meaning) {
    _db.execute(
      'UPDATE word_contexts SET gloss_meaning = ? WHERE client_row_id = ?',
      [meaning, contextClientRowId],
    );
  }

  /// The `(unit, contextText)` of a single saved context row, joined to its word — used to match an
  /// overlay preview's held gloss to the row it belongs to (the overlay guards on exactly this pair, so
  /// an edited unit/sentence after the preview never adopts a stale gloss). Null for an unknown id or a
  /// context with no text.
  ({String unit, String contextText})? contextGlossKey(String contextClientRowId) {
    final rs = _db.select(
      'SELECT w.surface_unit AS unit, c.context_text AS text '
      'FROM word_contexts c JOIN words w ON w.client_row_id = c.word_client_row_id '
      'WHERE c.client_row_id = ?',
      [contextClientRowId],
    );
    if (rs.isEmpty) return null;
    final text = rs.first['text'] as String?;
    if (text == null) return null;
    return (unit: rs.first['unit'] as String, contextText: text);
  }

  /// Soft-deletes a word (sets `deleted_at`, re-dirties for sync). Idempotent and a no-op for an
  /// unknown id. The dedup key is retained, so a later resave resurrects this same row.
  void softDelete(String wordClientRowId) {
    _db.execute(
      'UPDATE words SET deleted_at = ?, sync_dirty = 1 '
      'WHERE client_row_id = ? AND deleted_at IS NULL',
      [DateTime.now().millisecondsSinceEpoch, wordClientRowId],
    );
  }

  /// Restores a soft-deleted word (clears `deleted_at`, re-dirties for sync). Symmetric with
  /// [softDelete]; idempotent and a no-op for an unknown or already-active id. Drives the signed-out
  /// Word Book's delete → Undo without a UI-only shadow list.
  void restore(String wordClientRowId) {
    _db.execute(
      'UPDATE words SET deleted_at = NULL, sync_dirty = 1 '
      'WHERE client_row_id = ? AND deleted_at IS NOT NULL',
      [wordClientRowId],
    );
  }

  /// Marks [clientRowIds] as synced into the account identified by [accountId] (`claimed = 1`,
  /// `claimed_account_id = accountId`), so a signed-out Word Book no longer shows them — the migration
  /// of anonymous local data into the account after the user opts to sync. [accountId] is the server
  /// account id (`Account.id`), recorded so the signed-in "already saved" cue can scope to the current
  /// account ([hasActiveWord]); the caller (the auth controller) binds it to the session that started
  /// the claim, so a mid-claim account switch never stamps a row for the wrong account. Idempotent;
  /// unknown or already-claimed ids are skipped. Runs in one transaction.
  ///
  /// Guards the `UNIQUE(target_language, normalized_unit, claimed, claimed_account_id)` index: if
  /// flipping a row to claimed = 1 would collide with an EXISTING sibling already claimed into THE SAME
  /// account (same language + normalized unit) — e.g. the user synced a word, re-captured it
  /// anonymously, then synced again — the redundant anonymous row is HARD-deleted instead (the claimed
  /// sibling already represents it in the account; its contexts cascade via the FK, which is correct
  /// since they were duplicates). The collision check is scoped to [accountId]: a sibling claimed into a
  /// DIFFERENT account shares the unit but not the index key, so it doesn't block this claim. A plain `UPDATE OR REPLACE` is deliberately avoided — it would
  /// cascade-delete the kept row's contexts.
  void markClaimed(List<String> clientRowIds, String accountId) {
    if (clientRowIds.isEmpty) return;
    _db.execute('BEGIN');
    try {
      for (final id in clientRowIds) {
        final rows = _db.select(
          'SELECT target_language, normalized_unit FROM words '
          'WHERE client_row_id = ? AND claimed = 0',
          [id],
        );
        if (rows.isEmpty) continue; // unknown id, or already claimed — nothing to do
        final lang = rows.first['target_language'] as String;
        final norm = rows.first['normalized_unit'] as String;
        final clash = _db.select(
          'SELECT 1 FROM words '
          'WHERE target_language = ? AND normalized_unit = ? AND claimed = 1 '
          'AND claimed_account_id = ? LIMIT 1',
          [lang, norm, accountId],
        );
        if (clash.isEmpty) {
          _db.execute(
            'UPDATE words SET claimed = 1, claimed_account_id = ? WHERE client_row_id = ?',
            [accountId, id],
          );
        } else {
          // A sibling already claimed into this account exists → this anonymous row is redundant.
          // Hard-delete it (contexts cascade) rather than flip it, which would violate the dedup index.
          _db.execute('DELETE FROM words WHERE client_row_id = ?', [id]);
        }
      }
      _db.execute('COMMIT');
    } catch (e) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  // --- §14 metric buffer ----------------------------------------------------

  /// Enqueue one opaque metric-event [payload] (JSON of a single event). Enforces the bounded buffer:
  /// if appending would exceed [kMaxMetricBuffer], the OLDEST overflow rows are dropped and the
  /// persistent dropped counter is bumped (so a long offline stretch can't grow the file unbounded,
  /// and the loss is COUNTED — never silent). Returns the resulting buffered count.
  int enqueueMetric(String payload, {required int now}) {
    _db.execute('INSERT INTO metric_buffer(payload, created_at) VALUES(?, ?)', [payload, now]);
    final count = _metricBufferCount();
    if (count <= kMaxMetricBuffer) return count;
    final over = count - kMaxMetricBuffer;
    _db.execute(
      'DELETE FROM metric_buffer WHERE seq IN (SELECT seq FROM metric_buffer ORDER BY seq ASC LIMIT ?)',
      [over],
    );
    final dropped = (int.tryParse(_metaGet(_kMetricDroppedKey) ?? '0') ?? 0) + over;
    _metaSet(_kMetricDroppedKey, '$dropped');
    return kMaxMetricBuffer;
  }

  int _metricBufferCount() =>
      _db.select('SELECT COUNT(*) AS n FROM metric_buffer').first['n'] as int;

  /// The oldest [limit] buffered events (FIFO), each with its `seq` — the key to delete after a
  /// successful flush. Empty when the buffer is drained.
  List<({int seq, String payload})> metricBatch(int limit) {
    final rs =
        _db.select('SELECT seq, payload FROM metric_buffer ORDER BY seq ASC LIMIT ?', [limit]);
    return rs.map((r) => (seq: r['seq'] as int, payload: r['payload'] as String)).toList();
  }

  /// Delete buffered events with `seq <= throughSeq` (called after that batch flushed successfully).
  void deleteMetricsThrough(int throughSeq) {
    _db.execute('DELETE FROM metric_buffer WHERE seq <= ?', [throughSeq]);
  }

  /// Count of events dropped by the bounded-buffer eviction. Surfaced for the GATE runbook / future
  /// telemetry so a client-side drop is never mistaken for "no activity".
  int metricDroppedCount() => int.tryParse(_metaGet(_kMetricDroppedKey) ?? '0') ?? 0;

  /// Closes the underlying database connection.
  void close() => _db.close();

  WordRow _wordFromRow(Row r) => WordRow(
        clientRowId: r['client_row_id'] as String,
        installId: r['install_id'] as String,
        targetLanguage: r['target_language'] as String,
        surfaceUnit: r['surface_unit'] as String,
        normalizedUnit: r['normalized_unit'] as String,
        targetNormalizationVersion: r['target_normalization_version'] as String,
        isPhrase: (r['is_phrase'] as int) == 1,
        source: r['source'] as String,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
        deletedAt: r['deleted_at'] as int?,
        serverWordId: r['server_word_id'] as String?,
        syncDirty: (r['sync_dirty'] as int) == 1,
        claimed: (r['claimed'] as int) == 1,
        contextCount: r['context_count'] as int,
      );

  ContextRow _contextFromRow(Row r) => ContextRow(
        clientRowId: r['client_row_id'] as String,
        wordClientRowId: r['word_client_row_id'] as String,
        contextText: r['context_text'] as String?,
        contextLanguage: r['context_language'] as String?,
        spanStart: r['span_start'] as int?,
        spanEnd: r['span_end'] as int?,
        sourceApp: r['source_app'] as String?,
        sourceTitle: r['source_title'] as String?,
        detectedLanguage: r['detected_language'] as String?,
        detectedLanguageConfidence: (r['detected_language_confidence'] as num?)?.toDouble(),
        glossMeaning: r['gloss_meaning'] as String?,
        createdAt: r['created_at'] as int,
        syncDirty: (r['sync_dirty'] as int) == 1,
      );
}
