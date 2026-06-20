# capecho_local_store

The **device-local store** — the pre-login, single-user mirror of the backend
`words` / `word_contexts` tables, plus the **idempotent drain** of the native
capture journal. Pure Dart (no Flutter), reused by every client (macOS now;
Windows/iOS/Android later). This is the queryable half of the durable-save
spine (ENG-1); the durable *write* is the native fsync'd journal.

## The two-phase durable save (ENG-1)

```
overlay/dev-shell  ──save──▶  native journal (append + fsync)  ──▶ "saved" ink-dot
                                      │  (the durable commit; survives a dead Flutter isolate)
                                      ▼  async, idempotent, replayable on next launch
                              LocalStore.drain(entries)  ──▶  words + word_contexts (sqlite)
```

Phase 1 (native journal) is the durable commit; **the ink-dot fires only after
that fsync**. Phase 2 (this store) is an idempotent projection — re-draining the
same journal entries is a no-op, so a crash between phases self-heals on the next
launch drain.

## Guarantees (all `dart test`-covered)

- **Idempotent drain** — keyed by the journal entry's `client_row_id` (the
  `word_contexts` PK, `INSERT OR IGNORE`); a persisted `last_drained_seq` cursor
  only advances. Re-applying a batch inserts nothing and never regresses the cursor.
- **Dedup** — `UNIQUE(target_language, normalized_unit, claimed, claimed_account_id)`; N captures of
  one unit → ONE word, N contexts. The unit is keyed by the *normalized* form. The two ownership
  columns partition the store into isolated slices: anonymous (`claimed = 0`, the only rows a
  signed-out Word Book shows) and claimed-into-an-account (`claimed = 1`, keyed by the owning
  `claimed_account_id` so a shared device keeps each account's synced words distinct).
- **Resurrect-on-resave** — the unique index spans tombstones; re-saving a
  soft-deleted unit clears `deleted_at` on the same row (no duplicate).
- **Soft delete** — `deleted_at` tombstone; contexts are retained.
- **Crash recovery** — the cursor + idempotency make a re-drain after an
  ungraceful exit safe (covered by a reopen test).

## Normalizer is injected (DI)

The store takes a `Normalizer` (`String Function(String surfaceUnit)`) + a
`normalizationVersion`, rather than hard-coding one — so
this package stays dependency-light and `dart test`-able with a stub. The macOS
app wires `localDedupKey` (a deterministic, no-lemmatization dedup key that
mirrors the server's `dedupKey`); the backend re-keys authoritatively on sync.
Changing the normalizer is a re-key event.

## What's deferred

Backend **sync** (the `sync_dirty` / `server_word_id` columns exist but the M3
sync engine, the encrypted-context envelope, and FSRS are not here — those are
server-side / M3+). Context text is stored **plaintext locally**; encryption
happens at sync (T8).

## Run

```sh
cd shared/local-store
dart pub get
dart analyze   # clean
dart test
```
