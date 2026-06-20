# CLAUDE.md

Guidance for Claude Code (and other AI agents) working in this repository. **Code is the
documentation of record** — the docs hold only structure, purpose, and the decisions code can't
express.

## What this repo is

**Capecho** is a *capture-first vocabulary memory tool*: capture the words you meet while reading
(desktop), understand them in context, review them with spaced repetition (phone). The name =
**Cap**ture + **echo**. Version lives in [`VERSION`](VERSION) + the top [`CHANGELOG.md`](CHANGELOG.md)
entry.

## Where things live

- **`clients/macos/`** — Flutter macOS app (menu-bar agent): onboarding, the capture overlay, Review
  (FSRS flashcards), Word Book, Settings. → [`clients/macos/README.md`](clients/macos/README.md)
- **`clients/mobile/`** — Flutter iOS/Android app (the "echo" half): sign-in, touch Review, Word Book,
  Settings, on the shared `capecho_app_core`. → [`clients/mobile/README.md`](clients/mobile/README.md)
- **`clients/capture_native/`** — Swift/AppKit + Dart capture plugin: the warm-glass overlay,
  screen-capture/OCR, and the fsync'd journal that drains into the local store.
- **`backend/`** — Cloudflare Workers + D1: explanations + cost plane, server-authoritative FSRS + sync +
  pre-login claim, the metered context layer, Anki/CSV export, bearer-session + email-OTP auth. →
  [`backend/README.md`](backend/README.md)
- **`shared/`** — `capture-core` (reconstruction), `local-store` (`capecho_local_store`), `api-client`
  (`capecho_api`, the typed backend client), `app-core` (`capecho_app_core`, the shared
  auth/review/Word-Book/settings controllers + sign-in panel + warm design system both Flutter clients
  build on), `design-tokens` (generates Dart/Swift tokens from `design/tokens.css`), `lang` (BCP-47 +
  the explanation allowlist).
- **`web/`** — the public Next.js marketing site.
- **`DESIGN.md`** (root) + **`design/tokens.css`** — the design system.

Per-package build/test commands live in each package's README (Flutter for the two clients + the shared
Dart packages; Bun for the backend).

## Invariants (don't re-litigate)

These are the load-bearing product/design decisions. Read them before changing behavior; for anything
that touches them, open an issue to discuss first (see [`CONTRIBUTING.md`](CONTRIBUTING.md)).

- **Multi-target, not English-only.** Target language is a per-capture user value, never hard-coded
  English; the user's explicit choice. Recognition is language-agnostic (Vision auto-detect), decoupled
  from the target. The target auto-switches to the captured unit's own language ONLY when that unit's
  script is provably incompatible with the chosen one (a deterministic certainty — e.g. a 中文 unit while
  learning English); a same-script difference is surfaced as a pre-save suggestion the user confirms,
  never a silent probabilistic guess. Generation targets are an `enabled`-gated registry (`en`, `zh-Hans`,
  `ja` live); adding one is a server-authoritative profile + a paid eval gate (propose via an issue).
- **The captured unit is immutable.** No `PATCH /words` / word-text edit; the editable surfaces are the
  context sentence + its gloss. Fix a mis-capture via delete + restore or re-capture.
- **Dedup = a deterministic, no-lemmatization key** (`backend/src/dedup-key.ts`, mirrored client-side by
  `localDedupKey`). `study`≠`studied`; scope = `(user_id, target_language, normalized_unit)`.
- **Capture is user-triggered OCR, never silent/continuous;** no screen image is retained or uploaded.
- **FSRS is server-authoritative** (the event log is the source of truth; clients render server
  due-dates, never compute FSRS locally).
- **Architecture:** Flutter clients (macOS + iOS/Android); Cloudflare backend with D1 as the single
  source of truth, R2 + CDN for the shared public explanation cache.

## Conventions

- Keep cross-doc links working when you move or rename files.
- `.gitignore` excludes `.DS_Store` and local secrets (`.dev.vars`, `release.env`, `*.p8`).
- Pricing pledge: capture/save/review is free forever; only the per-use in-context AI is metered. Don't
  add gates that charge for saving or reviewing words.
