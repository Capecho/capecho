-- Capture source metadata on word_contexts (one save event = one row): provenance for
-- "where I met this word" + the capture-time recognition signal.
--
-- Privacy posture (mirrors the client ClaimContext contract):
--   • source_app                  — the source application's NAME (e.g. "Google Chrome"). PLAINTEXT:
--                                   low-sensitivity (the app, not its contents) and what filtering /
--                                   "what am I reading" analytics key on, which encryption would foreclose.
--   • source_title_*              — the source window's TITLE (a chat peer, a doc name): private specifics,
--                                   so ENCRYPTED AT REST in the SAME envelope scheme as the context sentence
--                                   (per-record DEK wrapped by the versioned KEK), AAD-bound to "srctitle:<id>".
--   • detected_language[_confidence] — the BCP-47 language detected at capture + its [0,1] confidence.
--                                   PLAINTEXT: a bare language tag, not user content.
--
-- All columns are additive + nullable (existing rows read NULL). SQLite ALTER TABLE can only ADD
-- COLUMNs (no table-level CHECK can be attached post-hoc), so the source_title envelope's
-- all-present-or-all-absent integrity is enforced in code (createContext seals all four together or
-- writes none) rather than by a constraint, the one difference from the context/gloss envelopes
-- declared at table-create time in 0001.
ALTER TABLE word_contexts ADD COLUMN source_app TEXT;
ALTER TABLE word_contexts ADD COLUMN source_title_ciphertext BLOB;
ALTER TABLE word_contexts ADD COLUMN source_title_wrapped_key BLOB;
ALTER TABLE word_contexts ADD COLUMN source_title_nonce BLOB;
ALTER TABLE word_contexts ADD COLUMN source_title_key_version INTEGER;
ALTER TABLE word_contexts ADD COLUMN detected_language TEXT;
ALTER TABLE word_contexts ADD COLUMN detected_language_confidence REAL;
