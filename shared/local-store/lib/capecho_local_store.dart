/// Capecho's device-local store — the pre-login, single-user mirror of the backend
/// `words` / `word_contexts` tables, plus the idempotent drain of the native capture journal.
///
/// Pure Dart, dependency-light: the unit normalizer is INJECTED (see [Normalizer]). The macOS app wires
/// `localDedupKey` (deterministic, no lemmatization) + `kLocalDedupVersion`; tests pass a stub.
///
/// ```dart
/// final store = LocalStore.openInMemory(
///   normalizer: (u) => u.trim().toLowerCase(),
///   normalizationVersion: 'v1',
/// );
/// final n = store.drain([entry]); // idempotent; returns # NEW entries applied
/// final words = store.activeWords();
/// ```
library;

export 'src/journal_entry.dart' show JournalEntry, kJournalSources;
export 'src/local_store.dart' show LocalStore, Normalizer, kMaxMetricBuffer;
export 'src/rows.dart' show WordRow, ContextRow, LocalExplanation, LocalReading, LocalPosGroup;
export 'src/schema.dart' show kSchemaVersion;
// A collision-free id generator, shared so callers that need a client-generated uuid (e.g. the review
// event id — the backend's GLOBAL idempotency PK) don't each reinvent one.
export 'src/uuid.dart' show uuidV4;
