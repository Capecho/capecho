/// The local store's SQLite schema, as SQL strings. Created on open if absent (see
/// `LocalStore._migrate`). The shape mirrors the backend `words` / `word_contexts` tables so the
/// device-local store is a faithful pre-login, single-user mirror; sync columns
/// (`sync_dirty`, `server_word_id`) carry the eventual reconciliation state.
library;

/// Bump when the schema changes in a way that needs a migration. Stored in `meta.schema_version`.
/// On a bump `LocalStore` runs its migration step; the only disposable table — `word_explanations`,
/// the offline mirror of the free explanation cache — is wiped rather than backfilled
/// (a stale explanation is benign single-user; the next `/explain` success refills it).
///
/// v2 — the multilingual word-contract reset (PROMPT v2): the cached blob became
/// `{summary (must-pass), readings[{pronunciationPrimary, pronunciationSecondary,
/// partsOfSpeech[]}]}`; v1 rows (per-sense glosses, ipaUs/ipaUk) are wiped on upgrade.
///
/// v3 — capture source metadata: `word_contexts` gains `source_app` / `source_title`
/// (capture provenance — "where I met this word") and `detected_language` /
/// `detected_language_confidence` (the capture-time recognition signal). Additive
/// columns, backfilled NULL on existing rows (an `ALTER TABLE ADD COLUMN` migration);
/// no data is touched.
///
/// v4 — the bilingual per-POS overlay contract (PROMPT v3, overlay-bilingual-plan.md): the cached blob
/// dropped the standalone `summary` (the per-POS senses ARE the explanation now) and `readings` carries
/// `[{pronunciationPrimary, pronunciationSecondary, kind, pos: [{partOfSpeech, senses[]}]}]`. (The
/// `senses`-cap + `hasMore` "more" hint were later retired — every sense is always shown; an old row's
/// `hasMore` key is simply ignored on read, so no schema bump was needed.) `word_explanations` is the
/// disposable mirror, so the migration DROPs + recreates it (the old `summary` column can't be altered
/// away in place); the next `/explain` success refills the new shape.
///
/// v5 — the in-sentence gloss cache: `word_contexts` gains `gloss_meaning` — the metered "Explain here"
/// result for THIS saved sentence (the one combined word-in-context + whole-sentence explanation). An
/// additive nullable column (ALTER ADD COLUMN; existing rows read NULL). Unlike `word_explanations` (the
/// disposable shared free-layer mirror), this is the user's OWN per-context gloss, kept beside its
/// sentence so the signed-out Word Book renders it without re-generating (the signed-in path also adopts
/// it server-side via the claim handle). No existing data is touched.
const int kSchemaVersion = 5;

/// PRAGMAs applied on every open. `foreign_keys` must be ON for the `word_contexts` ->
/// `words` cascade (and is per-connection, not persisted in the file).
const List<String> kOpenPragmas = [
  'PRAGMA foreign_keys = ON;',
];

/// `meta` — key/value store for the drain cursor (`last_drained_seq`) and `schema_version`.
const String kCreateMeta = '''
CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''';

/// `words` — the deduped vocabulary. Dedup key is
/// `(target_language, normalized_unit, claimed, claimed_account_id)`, enforced by a UNIQUE index that
/// INCLUDES tombstoned rows, so a resave of a soft-deleted unit resurrects the same row rather than
/// creating a duplicate.
///
/// `claimed` partitions the store into two isolated namespaces: `0` = anonymous (pre-login captures,
/// the only rows a signed-out Word Book shows) and `1` = synced into an account. Folding it into the
/// dedup key lets the SAME unit exist once as an anonymous row and once as a claimed row (so a
/// post-sync re-capture while signed out still lands a fresh anonymous row rather than resurrecting
/// the hidden, already-synced one).
///
/// `claimed_account_id` records WHICH account a claimed row was synced into — the server account id
/// (`Account.id`). It sub-partitions the `claimed = 1` namespace by owner so a device used by account
/// A then account B keeps each account's claimed rows distinct, and the signed-in "already saved" cue
/// (`hasActiveWord`) can scope to the current account instead of leaking A's words to B. The sentinel
/// `''` means "no known owner" (every anonymous row, `claimed = 0`). It is `''`, not NULL, for the same
/// reason `claimed` is a 0/1 bucket — SQLite treats every NULL as distinct in a UNIQUE index, which
/// would silently allow duplicate anonymous rows. `claimed` is kept as its own column (not derived from
/// `claimed_account_id != ''`) because every display-isolation query already filters on `claimed`.
const String kCreateWords = '''
CREATE TABLE IF NOT EXISTS words (
  client_row_id                TEXT PRIMARY KEY,
  install_id                   TEXT NOT NULL,
  target_language              TEXT NOT NULL,
  surface_unit                 TEXT NOT NULL CHECK(length(surface_unit) > 0),
  normalized_unit              TEXT NOT NULL CHECK(length(normalized_unit) > 0),
  target_normalization_version TEXT NOT NULL,
  is_phrase                    INTEGER NOT NULL DEFAULT 0 CHECK(is_phrase IN (0, 1)),
  source                       TEXT NOT NULL,
  created_at                   INTEGER NOT NULL,
  updated_at                   INTEGER NOT NULL,
  deleted_at                   INTEGER,
  server_word_id               TEXT,
  sync_dirty                   INTEGER NOT NULL DEFAULT 1 CHECK(sync_dirty IN (0, 1)),
  claimed                      INTEGER NOT NULL DEFAULT 0 CHECK(claimed IN (0, 1)),
  claimed_account_id           TEXT NOT NULL DEFAULT ''
);
''';

/// Device-scoped dedup key, partitioned by ownership (`claimed` + `claimed_account_id`). Tombstoned
/// rows KEEP the key (resurrect-on-resave updates the same row), so this index spans active + deleted
/// rows. Both ownership columns are stable, non-NULL buckets — deliberately NOT nullable, since SQLite
/// treats every NULL as distinct in a UNIQUE index and would silently allow duplicate anonymous rows.
const String kCreateWordsDedupIndex = '''
CREATE UNIQUE INDEX IF NOT EXISTS idx_words_dedup
  ON words(target_language, normalized_unit, claimed, claimed_account_id);
''';

const String kCreateWordsActiveIndex = '''
CREATE INDEX IF NOT EXISTS idx_words_active ON words(deleted_at);
''';

/// `word_contexts` — one row per save event. `client_row_id` == the journal entry's `clientRowId`,
/// which makes re-draining an already-applied entry an `INSERT OR IGNORE` no-op.
const String kCreateWordContexts = '''
CREATE TABLE IF NOT EXISTS word_contexts (
  client_row_id                TEXT PRIMARY KEY,
  word_client_row_id           TEXT NOT NULL REFERENCES words(client_row_id) ON DELETE CASCADE,
  context_text                 TEXT,
  context_language             TEXT,
  span_start                   INTEGER,
  span_end                     INTEGER,
  source_app                   TEXT,
  source_title                 TEXT,
  detected_language            TEXT,
  detected_language_confidence REAL,
  gloss_meaning                TEXT,
  created_at                   INTEGER NOT NULL,
  sync_dirty                   INTEGER NOT NULL DEFAULT 1,
  CHECK (
    (span_start IS NULL AND span_end IS NULL)
    OR (span_start IS NOT NULL AND span_end IS NOT NULL
        AND span_start >= 0 AND span_end >= span_start)
  )
);
''';

/// The v2→v3 column additions, applied by `LocalStore._migrate` to an EXISTING
/// `word_contexts` (the base DDL above already carries them on a fresh database).
/// Each is an additive nullable column — existing rows read NULL — so the migration
/// is a pure `ALTER TABLE ADD COLUMN` with no row rewrite. Keyed by column name so the
/// migration can SKIP any column already present (`PRAGMA table_info`), keeping the
/// step idempotent: re-running it, or running it against a DB built fresh from the
/// current base DDL, never throws "duplicate column name".
const Map<String, String> kAddWordContextSourceColumns = {
  'source_app': 'ALTER TABLE word_contexts ADD COLUMN source_app TEXT;',
  'source_title': 'ALTER TABLE word_contexts ADD COLUMN source_title TEXT;',
  'detected_language': 'ALTER TABLE word_contexts ADD COLUMN detected_language TEXT;',
  'detected_language_confidence':
      'ALTER TABLE word_contexts ADD COLUMN detected_language_confidence REAL;',
};

/// The v4→v5 column addition (the in-sentence gloss cache), applied by `LocalStore._migrate` to an
/// existing `word_contexts` — same idempotent `ALTER ... ADD COLUMN` pattern as the source columns above
/// (skipped when `PRAGMA table_info` shows the column is already present, e.g. a fresh DB).
const String kAddWordContextGlossColumn =
    'ALTER TABLE word_contexts ADD COLUMN gloss_meaning TEXT;';

const String kCreateContextsWordIndex = '''
CREATE INDEX IF NOT EXISTS idx_contexts_word ON word_contexts(word_client_row_id);
''';

/// `metric_buffer` — the durable, offline-surviving queue of §14 metric events. One row per
/// event; `payload` is the opaque JSON of a single metric event (durations / enums / bools only —
/// NEVER captured text, T8). The MetricsRecorder drains it FIFO to `POST /metrics` and deletes the
/// rows it successfully flushed; a bounded size (drop-oldest) keeps a long offline stretch from
/// growing the file unbounded. AUTOINCREMENT `seq` is the FIFO order + the post-flush delete key.
const String kCreateMetricBuffer = '''
CREATE TABLE IF NOT EXISTS metric_buffer (
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,
  payload    TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
''';

/// `word_explanations` — a small LOCAL mirror of the free word-layer explanation cache. Keyed like the
/// server's shared `wordCacheKey`:
/// `(target_language, normalized_unit, explanation_language)` — context-INDEPENDENT (the free word
/// meaning), so it is independent of the per-row ownership in `words` and of which save event fetched
/// it. `INSERT OR REPLACE` on each `/explain` success. The capture overlay reads it to show a
/// re-captured word's meaning offline (so suppressing the redundant `/explain` doesn't blank the slot).
/// Holds the PUBLIC free-layer blob ONLY — never the private per-context gloss (that layer is never
/// shared-cached).
///
/// Phase 1 (v4): `readings` is the word's ONLY explanation text — a JSON array
/// `[{pronunciationPrimary, pronunciationSecondary, kind, pos: [{partOfSpeech, senses[]}]}, ...]`.
/// The per-POS `senses` ARE the meaning (the prose `summary` column is gone). MUST-PASS = at least one
/// non-blank sense (the writer refuses a senseless blob; the reader treats one as a MISS). Pronunciations
/// are omit-on-fail (`""` when a slot failed or the target has no second slot); `kind` is `"idiom"` for a
/// phrase reading (no IPA) or null.
const String kCreateWordExplanations = '''
CREATE TABLE IF NOT EXISTS word_explanations (
  target_language      TEXT NOT NULL,
  normalized_unit      TEXT NOT NULL CHECK(length(normalized_unit) > 0),
  explanation_language TEXT NOT NULL,
  readings             TEXT NOT NULL CHECK(length(readings) > 0),
  cached_at            INTEGER NOT NULL,
  PRIMARY KEY (target_language, normalized_unit, explanation_language)
);
''';

/// All DDL statements, in creation order (tables before their indexes).
const List<String> kSchemaStatements = [
  kCreateMeta,
  kCreateWords,
  kCreateWordsDedupIndex,
  kCreateWordsActiveIndex,
  kCreateWordContexts,
  kCreateContextsWordIndex,
  kCreateMetricBuffer,
  kCreateWordExplanations,
];
