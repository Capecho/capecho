# Changelog

All notable changes to Capecho are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versions are `MAJOR.MINOR.PATCH.MICRO`.

## [Unreleased]

**Source-available readiness.** Prepare the repo to go public under the Functional Source License
(FSL-1.1-Apache-2.0) — license + community/legal scaffolding, scrub the release-script examples of
personal identifiers, and one request-body hardening the pre-publish security audit surfaced. No
user-facing behavior change.

- **License + governance:** root [`LICENSE`](LICENSE) (FSL-1.1-Apache-2.0), [`NOTICE`](NOTICE) +
  [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) (Sparkle 2.9.2 MIT attribution — was previously
  unattributed), [`TRADEMARK.md`](TRADEMARK.md) (the Capecho name/brand stay reserved; the code is
  source-available), [`CONTRIBUTING.md`](CONTRIBUTING.md) (DCO sign-off), [`SECURITY.md`](SECURITY.md)
  (private disclosure). Replaces the placeholder `clients/capture_native/LICENSE`.
- **README:** a "Source-available & pricing pledge" section — capture/save/review is free forever, only
  per-use AI is paid.
- **Scrubbed examples:** `scripts/{macos,ios}/release.env.example` no longer carry a real Apple Team
  ID / App Store Connect key id (placeholders; the values were never secrets but don't belong in a
  committed template).
- **Security hardening:** `readJson` now rejects oversized bodies (Content-Length pre-check + a 1 MiB
  cap) before parsing, instead of materializing an arbitrarily large body — the one MEDIUM finding
  from the pre-publish backend security audit (verdict: 0 critical/high; auth/IDOR, billing
  integrity, budget atomicity, and the injection surface all verified solid).

## [0.2.7.1] - 2026-06-19

**Post-MVP consolidation — prune dead code + sync every doc to the shipped reality.** No user-facing
behavior change: a repo-wide pass that removes residue from decisions that wavered during development and
aligns docs/comments with what actually shipped (billing live, `en`/`zh-Hans`/`ja` enabled, iOS on the App
Store, meaning-evolution removed).

- **Dead code removed:** the orphaned "Same as learning language" immersion write-affordance (the
  unreachable setters + the macOS `includeFollow` menu branch — the `explanationFollowsLearning` read/wire
  path stays for back-compat with accounts already in that state); the parsed-but-unrouted
  `CaptureDeepLink` (`capecho://capture`); and the broken, unwired `backend/scripts/seed-cache/` pipeline
  (obsolete blob shape, −1413 lines).
- **Stale comments fixed:** `target-profiles.ts` / `lang.ts` no longer say zh-Hans/ja "ship disabled"
  (both are enabled targets); the three dormant meaning-evolution "Phase 2" comments are gone;
  `cache-key.ts` drops the deleted-script reference + the resolved v5 deploy-gate warning.
- **Source-of-truth docs synced:** `product-definition.md` (billing is live + unlimited saving + per-use
  context-AI is the one metered lever, the saved-word cap a dormant retained lever; explanation model =
  per-POS senses + IPA, no summary/origin scaffold; iOS live, macOS dual-channel) and `DESIGN.md` (IPA
  shipped, etymology/meaning-evolution removed, only CEFR + dictionary example-sentences out of scope).
- **Docs/READMEs/web swept:** `README.md`, the mobile/lang/capture-native READMEs, `web-content-strategy.md`,
  `TODOS.md`, and two web strings dropped "English-only / phone-coming / saved-word-cap / billing-deferred";
  `multilingual-explanations.md` stamped SHIPPED (superseded by `adding-a-target-language.md`). Confirmed the
  client target-allowlist is already server-authoritative (the READMEs were just stale — no code bug).

Suites green: backend 752 + tsc · lang 67 · app-core 192 · macOS 268 · mobile 24 · web tsc. analyze +
dart format clean.

## [0.2.7.0] - 2026-06-18

**Japanese (`ja`) added as a learning/capture target — ENABLED (its paid eval gate passed) — plus a
context-layer fix the gate surfaced.** `ja` is now selectable alongside `en`/`zh-Hans`. Existing
languages are untouched — a new target lands on its own cache keyspace, so **no word-layer
`PROMPT_VERSION` bump and no rekey**.

**The `ja` target:**

- **Lang registry** (`shared/lang`): `JA_PROFILE` (`enabled: true`) — Japanese POS subset (keeps
  `particle` 助詞 + `measure word` 助数詞; drops `preposition`/`determiner`/`phrasal verb`), kana-furigana
  reading unlabeled like pinyin, no second pronunciation slot.
- **Backend prompt** (`target-profiles.ts`): `JA` `TargetPromptProfile` (kana reading, the
  meaning-bearing readings-split rule 辛い からい/つらい, 慣用句/四字熟語 idiom branch).
- **Eval**: `words.ja.ts` (24 gold), `context-cases.ja.ts` (10), `normalizeKana`
  (katakana→hiragana + width + spaces fold, keeps the long vowel/dakuten), `run-*` registration +
  `eval:grounded:ja` / `eval:context:ja` + offline `eval.ja.test.ts`. **WORD gate PASS** both axes
  (ja→ja 100/100/96/100/92/100, ja→en 100/100/96/100/100/100 = pron/cover/correct/pure/plain/etym).
- **Clients**: the learning-target picker is centralized into app-core's shared `learningLanguages`
  (now `en` + `zh-Hans` + `ja`; one list for onboarding + both Settings, mirroring
  `explanationLanguages`). The stale macOS Settings comment claiming ja/ko are deferred for "no portable
  word-segmentation" is corrected — segmentation is the OS tokenizer's job and the user adjusts the
  selection before saving, so the deferral was purely the per-language eval gate.

**Context layer** (`CONTEXT_PROMPT_VERSION` v3→v4 — per-user lazy regen, **no rekey**; affects all
targets, surfaced while gating `ja`):

- **Fix**: a bare label / single word (e.g. a UI button "送信") is no longer padded into a fabricated
  sentence — the prompt forbids inventing context the text doesn't contain.
- **Fix**: a marked repeated occurrence is steered explicitly — the model was drifting to the word's
  most-common/first sense (e.g. the 2nd 結構 = "fine as is", not the 1st's "quite").
- **Fix**: a faithful-retelling rule — don't add obligation/certainty/cause the text doesn't state,
  don't swap a relationship (a rate is not a total), and prefer the weaker reading when unsure. This
  removed real user-misleading distortions (fabricated "must"/"you should", rate→total flattening).
- **The context eval's VOICE dimension is no longer a gate** (founder decision): occurrence + logic are
  the quality bar. Voice was too subjective/noisy a binary gate — the model's plain "the word means…"
  framing reads fine, and near-identical phrasings scored inconsistently. Voice is still judged +
  reported, informational only.
- **en context corpus expanded 12 → 26** (logic-stressing causal/conditional/negation/comparative/
  contrast cases) to cut per-case variance at the gate.
- **Model stays `gemini-3.1-flash-lite`** — a same-corpus sweep of `gemini-2.5-flash`,
  `gemini-3-flash-preview`, `gemini-3.5-flash` (and 2.5/3.1 lite) all landed at the SAME ~88.5% logic and
  were slower; the flash tier buys no fidelity here. The lone residual (`comparative-outpaced`,
  rate→total) is a documented flash-tier ceiling, not fixable by model version or prompt rules.
- **CONTEXT gates PASS** (lite): en occ 100 / logic 96.2, zh-Hans occ 100 / logic 91.7, ja occ 100 / logic 100.

**Docs**: new `docs/adding-a-target-language.md` — the repeatable
checklist for the next target (ko/es/…); CLAUDE.md invariant + `multilingual-explanations.md` point to it.

Suites green: backend 752 + tsc · lang 67 · app-core 194 · mobile 24 · macOS 268. analyze + dart format
clean. All paid gates (`eval:grounded:ja`, `eval:context:{en,zh,ja}`) run green; reports in `eval/out/`
(gitignored).

## [0.2.6.3] - 2026-06-18

**Web: macOS + iOS are live on the App Store — footer store links activated + site-wide availability
copy.** Both App Store listings passed review, so the marketing site now says "now on Mac and iPhone"
instead of "Mac now, phone coming." Web-only; no app/backend/prompt change.

- Footer "Get the app": the **App Store** (iPhone) and **Mac App Store** badges are now live links
  (`siteConfig.appLinks`, listing `id6771973675`; Mac variant carries `?platform=mac`) and the "Soon" tag
  is removed. Google Play and Microsoft Store stay greyed (no Android/Windows build yet).
- The canonical `betaLine` / `description` → "Now on Mac and iPhone — capture on your Mac, review on your
  phone." Swept the home, how-it-works, download, FAQ, About, terms, and nine SEO landing sections so
  nothing still says the phone companion "is coming." The download page's phone half now reads "available
  now · App Store" and renders as a live card. Nuances kept: Android is still coming, and capture stays
  Mac-first.

Verified: `tsc --noEmit` clean; a dev-server render confirms the two live Apple badges plus the greyed
Google Play / Microsoft Store, and a full-text scan finds zero remaining "phone is coming / Mac first /
not on the App Store" strings.

## [0.2.6.2] - 2026-06-18

**Pre-beta cleanup, part 2 — the deferred signature/API trims.** The four items the behavior-preserving
pass (`0.2.6.1`) left for a follow-up, now that internal testing is over. No behavior change; callers were
migrated first.

- backend `WordPayload`: dropped the vestigial `summary?` / readings `partsOfSpeech?` and reflected the
  real `pos` shape. Type-only — the runtime schema is `buildWordSchemaObject(...)` and the result is
  validated as `unknown` by `validate.ts`, so no schema/wire change, **no `PROMPT_VERSION` bump, no
  eval/rekey**.
- api-client: removed the back-compat getters `WordExplanation.summary` (→ `primarySense`) and
  `Reading.partsOfSpeech` (→ `pos.map((g) => g.partOfSpeech)`); migrated the two production callers (the
  Word Book meaning-ready gate, the reading-module POS note) and the test assertions.
- mobile `LanguageSheet`: removed the `includeFollow` param + its dead "Same as learning language" branch
  (no mobile call site ever passed it — mobile has no follow concept).
- Test files: the comment trim the `0.2.6.1` pass skipped (it was production-only) — stale mockup-state
  references, internal review tags, and done TODOs removed from the test suites (titles untouched).

All suites green: backend 745 + tsc · local-store 63 · capture-core 329 · api-client 77 · capture_native
36 · app-core 194 · macOS 268 · mobile 24 · swift-logic 84 · WidgetReviewKit 20. Format + analyze clean.

## [0.2.6.1] - 2026-06-18

**Pre-beta cleanup — leaner comments + dead code, no behavior change.** Internal testing is over, so a
repo-wide pass trimmed redundant/stale comments and removed dead code, without touching runtime behavior,
public APIs, wire contracts, or the DB migration chains (kept intact by decision). Removed: references to
deleted mockups (`mock state N`, `.css-class` anchors), done/obsolete TODOs and internal review-attribution
tags, "port-of-the-spike" narrative, stale phase/milestone markers, and a handful of provably-unused
symbols — one dead method (`launchPayload`), one unused web component (`CaptureOverlayMock`), and three
unused web exports. Invariants, security/privacy notes, and design rationale were preserved. All suites
green; net ≈ −180 lines.

## [0.2.6.0] - 2026-06-18

**Six "Explain here" / Word Book / Review polish fixes.**

- **The "Explain here" result now persists to the Word Book.** Previously, generating the in-sentence
  explanation in the capture overlay and saving left the Word Book blank — you had to re-generate it.
  Signed-in saves already adopted the gloss server-side via the claim handle; the gap was the
  *signed-out / local* path, which never kept the gloss at all. Fixed by caching it on the saved context
  row: `word_contexts` gains a `gloss_meaning` column (local-store schema **v4 → v5**, additive
  `ALTER ADD COLUMN`), the overlay controller now exposes the gloss text (`adoptableGlossFor`, twin of
  `adoptableHandleFor`), and the save path writes it — matched on the exact saved `(unit, sentence)` so an
  edited unit/sentence after the preview never adopts a stale one. The Word Book then renders it offline.

- **"Explain in this sentence" → "Explain here"** on the Word Book detail (matching the overlay), and the
  **"Free, with a daily limit" caption is gone** — the lock glyph alone signals it's metered.

- **Pill buttons unified + roomier.** Shared `kPillButtonPadding` / `kPillIconButtonPadding`
  (`app-core/chrome.dart`) give the Word Book pills (Explain here, Delete word, Edit / Remove) consistent,
  more generous vertical padding across both clients; the standalone control clusters (Delete word,
  Save / Cancel) now right-align like the existing Edit / Remove cluster.

- **The "Explain here" gloss now shows on the Review card back** — macOS, mobile, and the iOS widget's
  largest face. The gloss already rides along free from the `/contexts` fetch (never the metered
  endpoint); on the large widget it takes the secondary slot in place of re-showing the sentence (already
  on the front). Additive `contextMeaning` snapshot field — no widget schema bump (forward-compatible).

- **The "already in your Word Book" cue no longer false-positives after an account switch.** When signed
  in, `hasActiveWord` now counts only rows synced into *this* account, not un-synced anonymous local rows
  (which aren't in any account's book until claimed) — so the cue and the signed-in Word Book agree.

- **Dropped the redundant "Explaining in this sentence…" caption** under the overlay's in-context loader
  — the pulsing echo already reads as "working". The VoiceOver announce still speaks it for non-visual
  users.

## [0.2.5.0] - 2026-06-18

**Pro now actually lifts the daily in-context explanation cap.** The "Explain here" / in-context
explanation layer is metered at a per-user daily cap (`CONTEXT_DAILY_CAP`, default 10), and Pro is sold
on lifting exactly it ("unlimited in-context explanations"). But the cost plane never consulted
entitlement: both `explainContext` (`POST /explain/context`) and `explainContextPreview`
(`POST /explain/context/preview`) passed `config.contextDailyCap` to the quota reservation
*unconditionally*, so a paying member hit "Daily explanation limit reached" at the same 10/day as a free
user. Fixed by threading the account's Pro status into both functions — when `isPro(account, now)` (i.e.
`pro_until > now`), the daily cap is lifted to an unreachable bound, the same shape `saveWord` already
uses to let Pro bypass the free saved-word cap. The global AI-spend budget still applies to everyone. No
prompt/schema/cache change; pure entitlement wiring. Backend `bun test` (747) + `tsc` green. **Needs
`wrangler deploy` to take effect.**

## [0.2.4.0] - 2026-06-18

**"Explain here" — one combined answer, simpler words.** The in-sentence explanation is now a single
free-form `meaning` field instead of two (`sentenceMeaning` + `wordMeaning`): one plain explanation that
covers both what the captured word means *as used here* and what the whole sentence is saying, with no
fixed format. The prompt is pared down to a simple input plus Maimemo's one load-bearing rule — **never
explain with a word harder than the headword** — letting the model phrase it naturally (a cross-language
gloss reads as a translation; a same-language one as a plain definition + retelling). The capture overlay
and the Word Book detail now render that one explanation directly (the "Sentence meaning" disclosure
toggle and its state are gone, both clients + the native overlay). `CONTEXT_PROMPT_VERSION` v2→v3 — this
is the **per-user** context layer, so the bump just lazily regenerates each stored gloss on next view
(no shared-cache rekey); an old two-field payload is ignored on read and regenerated. Contract collapsed
end-to-end: prompt, JSON schema `{ meaning }`, validator, the `ContextExplanation`/`ContextPreview`/
`ContextView` models, the overlay bridge + `ContextPreviewSlot`, and the eval judge (one combined answer,
graded on the same occurrence/logic/voice dimensions). Backend `bun test` (743) + `tsc` and every
Dart/Swift suite green; run `bun run eval:context` before deploy to confirm fidelity. macOS overlay +
Word Book render want an on-device pass.

## [0.2.3.0] - 2026-06-17

**`hasMore` deleted — always show every sense.** The "more senses · open Dictionary" hint and the
`hasMore` flag that drove it are gone end-to-end (backend prompt + schema + validate, the typed contract,
the local store, both Flutter clients, and the native macOS overlay). Every surface now renders a word's
full set of common senses, one line per part of speech, and the capture overlay scrolls past its max
height when a polysemous word (`run`, `set`) runs tall — no nag, no cap. The system-dictionary button
stays in the overlay footer for the long tail. The backend no longer trims senses at all (the only
remaining bound is the generation-time schema `maxItems`, a safety ceiling a real word never reaches).
**No `PROMPT_VERSION` bump:** the senses-listing instruction is unchanged, so the change is
quality-neutral — the hint only ever rendered because the *client* read `hasMore`, so dropping it from
the contract retires the hint for cached **and** fresh words with no cache rekey, no regeneration, and no
paid eval owed (an old cached blob's `hasMore` key is simply ignored on read). Backend `bun test` + `tsc`
and every Dart/Swift suite green; the macOS overlay scroll + iOS widget render still want an on-device
build pass.

## [0.2.2.0] - 2026-06-17

**No sense cap — every common meaning per part of speech.** The model now lists ALL of a word's common
meanings under each part of speech (`PROMPT_VERSION` v4→v5, was "up to 4"); the schema/validate bound of
12 is only an anti-hallucination guard, never a display cap. So a polysemous word like `commands` shows
its full verb/noun meanings instead of 4 + a "more senses" hint — the hint now fires only when the model
still left a common meaning out (rare). 0.2.1.0 had already uncapped the *display*; this removes the cap
at the *source* (the prompt + schema), which is what was still clipping to 4. ⚠ v5 rekeys the shared word
cache — a paid reference-grounded eval must pass, the Worker must deploy, and a word must be re-captured
before its full senses appear. Backend `bun test` + `tsc` green.

## [0.2.1.0] - 2026-06-17

**Per-part-of-speech senses, one line each, across every surface.** A word's meaning now renders the
SAME way everywhere — the capture overlay, Word Book, Review (macOS + mobile), and the iOS home-screen
widget: one line per part of speech (`noun  阅读; 读物; 读数; 解读`), with a form note shared by every
sense (e.g. `make 的现在分词`) pulled to the front once instead of repeating. Every surface now shows
**all** of a word's stored senses — the per-surface display cap is gone; the "more senses · open
Dictionary" hint fires only when the model genuinely flags more, never because a cap trimmed the list.
The capture overlay's explanation region **scrolls** past a max height instead of growing the panel
off-screen (uncapped senses plus a heteronym can run tall). Removed the now-dead per-sense `numbered`
flag (no surface numbers senses) and the unused widget `pos` field (the part of speech sits inline on
each meaning line). Backend, `swiftc`, and all Dart/Swift suites green; the iOS widget render + the
overlay scroll still need an on-device pass.

## [0.2.0.0] - 2026-06-17

**Bilingual, per-part-of-speech word meanings — translate when your language differs, define when it
matches.** A captured word's explanation is no longer one prose summary; it is the word's meanings grouped
by part of speech (`noun`, `verb`, …), each carrying its senses. When the explanation language differs from
the word's own language you now get the **translation** — the equivalent word(s) a bilingual dictionary
lists (e.g. English `word` → `词；单词；话；诺言`) — not a same-language definition of it; when they match you
still get a short plain definition. Earlier the definitional voice overpowered a conditional "translate"
instruction, so a Chinese gloss of `word` came out as `语言的最小单位…` (a definition) instead of `词；单词`;
the prompt now forks translate-vs-define **at build time** so the model gets one unambiguous instruction.
The capture overlay shows each part of speech's senses on **one line** with the label flush-left, and the
"more senses · open Dictionary" hint appears **only when meanings genuinely remain** beyond those shown.
Word Book and Review render the same per-POS shape. (`PROMPT_VERSION` v4; the shared explanation cache
rekeys — re-warm `scripts/seed-cache` for the top words.)

**Word-explanation model → `gemini-3.1-flash-lite`.** The word layer now uses the faster, cheaper lite
model (the one the in-sentence context layer already uses). On the reference-grounded quality gate it
passes both axes — monolingual (en→en) and bilingual (en→zh-Hans) — matching the previous
`gemini-2.5-flash` on meaning accuracy and pronunciation; `gemini-2.5-flash-lite` was measured and
rejected (it fails pronunciation + correctness). The earlier "2.5-flash beats lite" verdict was the
old prose-summary contract; per-POS senses/translations are an easier task that lite handles well. The
model is a per-environment override (`GEMINI_MODEL`) and is not part of the cache key, so the switch does
not rekey the cache.

**Quality gate fixed for the per-POS contract.** The grounded-eval judge was written for the old prose
summary and wrongly failed the new senses output — it counted the English part-of-speech labels as
"stray language" and the concise sense lists as "not tutor prose". The judge now understands the
per-POS / translation format, so the gate measures meaning, pronunciation, and language purity correctly
(this is why the senses contract could not pass the gate before).

**App Store compliance: an Apple ID's active subscription unlocks Pro for whoever is signed in (Guideline
2.1(a)).** App Review rejected the macOS build because, after creating a new account with Sign in with
Apple, buying a subscription showed an error instead of unlocking Pro: the Apple ID had already subscribed
under an earlier account, and Capecho locks each subscription to the first account that bought it (Apple's
immutable per-purchase `appAccountToken`). Now `POST /billing/apple/verify` **transfers** the subscription
to the signed-in account when the posted StoreKit2 transaction is genuinely Apple-signed, so the Apple ID's
sub follows the user (real re-subscribers are unblocked too). The transfer is gated by a new pure-Web-Crypto
JWS verifier (`backend/src/billing/apple-jws.ts`, no new deps) that validates the full StoreKit2 certificate
chain before any re-attribution: the pinned Apple Root CA - G3, the exact three-cert shape, the WWDR
intermediate + App Store Server leaf purpose-marker OIDs (matching Apple's own `app-store-server-library`),
every certificate signature and validity window, and the ES256 payload signature. A forged or unsigned post
fails verification and falls back to the prior strict, attribution-only behavior, so the documented
"never re-attribute off a forgeable transaction id" guard still holds for anything not Apple-signed. Because
`appAccountToken` is immutable, the strict notification path now attributes later renewals, refunds, and
revocations to the subscription's **current** owner, so a transferred sub still extends on renewal and claws
back on refund. Backend-only — the macOS/iOS binary is unchanged; deploy the Worker, then resubmit for
review. Server-authoritative entitlement and the reconcile cron are unaffected.

**App Store compliance: Sign in with Apple on the macOS App Store build, plus an iOS export-compliance
flag.** The Mac App Store build now offers "Continue with Apple" alongside Google (App Store Review
Guideline 4.8). The shared `SignInPanel` takes an `appleAvailable` flag — the gate becomes
`appleAvailable ?? (platform == iOS)` so iOS is unchanged — and the four macOS sign-in call sites pass
`isMacAppStoreBuild()`, so the button appears only in the MAS build (the same receipt / `CAPECHO_DIST`
gate already used for the IAP rail), never in the directly-distributed Developer-ID build, which still
omits the `applesignin` entitlement Apple forbids there. `Runner-MAS.entitlements` carries
`com.apple.developer.applesignin`. No backend change: macOS shares the iOS bundle id `com.capecho.app`,
so the Apple identity-token audience is already accepted by `APPLE_CLIENT_ID`. This also unblocks App
Review, which can't complete the macOS email one-time-code sign-in. Separately, the iOS `Info.plist` now
declares `ITSAppUsesNonExemptEncryption=false` (the app uses only standard/exempt encryption — HTTPS plus
the AES-256-GCM context envelope), matching macOS, so submissions stop re-asking the export-compliance
question.

**Fix: mobile bottom sheets fill the full width on wide screens.** Material 3 caps modal bottom sheets at
640dp and centers them, so on iPad / landscape / a resized window every Capecho mobile sheet (Settings,
Word Book, the two language pickers, export, and the delete-word / remove-sentence / delete-account
confirms) sat narrow with side margins. Each now passes `constraints: maxWidth: double.infinity` to fill
the full width; height is unchanged. The compact upgrade / paywall sheet keeps the default centered width —
the one intended exception.

**Legal: public-release privacy, terms, and cookies copy + paywall legal links.** The web legal pages drop
their pre-launch "draft / before public release" placeholders, name the subprocessors with links
(Cloudflare, Google, Stripe, Apple), and the mobile purchase flow now surfaces Privacy Policy + Terms of
Use inline (App Store Review Guideline 3.1.2) via the in-app browser.

**Capture now records where you met each word.** Every capture stores its provenance alongside the
context sentence — the **source app** (e.g. "Google Chrome", "Books"), the **source window title**, and
the **capture-time detected language** + confidence. The capture engine already resolved the owning
app + window title of the window under the cursor (it was folded into a diagnostic string and dropped);
they now flow through the fsync'd journal → local store → encrypted sync into the account. Privacy
posture: the **app name** and **detected language** stay plaintext (low-sensitivity, and what
filtering / "what am I reading" analytics key on), while the **window title** is encrypted at rest in
its own envelope (AAD `srctitle:<id>`) exactly like the context sentence. New `word_contexts` columns on
both the local store (schema v3, additive `ALTER` migration) and the backend (migration `0002`);
`OcrSnapshot` / `CaptureResult` / `JournalEntry` / `ContextRow` / `ClaimContext` / `ContextView` and the
native overlay save path carry the fields end to end. All metadata is optional — a capture that can't
resolve a field, or a manually-typed context, stores null.

Recording the source is a **Settings toggle** ("Capture source → Record where you captured", on by
default, device-local on macOS) — the capture overlay stays quiet and doesn't show or edit it. With it
off, a capture records no source app or title; existing saved sources are untouched. The source is then
**shown read-only** as a quiet `app · title` caption under the sentence on the **Review** card back and
each **Word Book** context, on both clients (a shared `captureSourceCaption` widget) — so the provenance
is useful where you review, not just stored. `ContextView` carries the source for display (from the
backend for signed-in users, from the local store signed-out). The detected language stays an internal
recognition signal (not displayed).

**Signed-out in-context explanation now prompts sign-in (with a button).** When a signed-out user taps
"Explain here" on the capture overlay, the account-only in-context explanation 401'd into the same generic
"couldn't explain" note as a real failure. It now shows a distinct, calm prompt — *"Explaining a word in
your sentence is free with an account — 10 a day. You can still save this word."* — with a **Sign in**
button that dismisses the overlay, brings the app forward, and opens Settings auto-scrolled to the Account
section's sign-in panel. The Dart preview controller maps a 401 to a new `login` phase (distinct from
`quota`/`failed`); the native overlay gains a `needsLogin` slot and an `onRequestSignIn` callback that
reuses the existing `capecho.showSurface` path via a new `signIn` surface; `SettingsScreen` gains a
`scrollToAccount` flag that `Scrollable.ensureVisible`-scrolls the keyed Account section into view on open.

**Pricing: free unlimited saving — only per-use AI is metered.** The free saved-word cap (the former Pro
"library ceiling") is disabled for the MVP: saving is now free and unlimited, so the corpus and the usage
habit accumulate, and the only metered lever is per-use AI generation (the in-context explanation —
10/day free, unlimited on Pro). Backend: `FREE_WORD_CAP=0` ⇒ no cap (`freeWordCapFromEnv` returns
`undefined` for any non-positive value); the entire `cap_reached` enforcement path in `words.ts`/`claim.ts`
is retained so a single positive value re-enables it later. Web pricing/home/FAQ/download/terms/SEO copy
reframed to the one paid lever (`siteConfig.freeWordCap` removed); macOS + mobile paywall and settings copy
collapsed to the single in-context lever (the dormant client `cap_reached` handling is kept).

**Fix: Pro paywall crash ("setState() called during build").** Opening the Mac App Store paywall (and
the mobile upgrade sheet) could throw — its `initState` called `clearError()` + `loadProducts()` on the
shared `ProPurchaseController` synchronously, and both notify, which marked Settings' own
`AnimatedBuilder`s (listening to the same controller) dirty mid-build. Those notifying side-effects are
now deferred to a post-frame callback (the non-notifying `clearJustUpgraded()` stays synchronous so its
stale-one-shot guard is unchanged), and `clearError()` no longer notifies when there's nothing to clear.

**Empty Word Book — a crafted "open, blank book" that actually reads as empty.** The empty-catalog
invite (macOS + mobile Word Book, and the mobile "nothing captured yet" Review state) used a *closed*
book, which read as "a book", not "empty". It's now an **open book with blank cream pages** — same warm
craft (cover thickness, page-edge stack, soft contact shadow) but open to empty pages with only a faint
dotted writing-guide, the echo mark settled and **centered** above the spine (the first word will echo
in). Unified into one shared `WordBookEmptyArt` (`shared/app-core`) so both clients render identical art;
the old per-client `WordBookClosedBookArt` (macOS) and `ClosedBookIllustration` (mobile) are removed.

**One branded loading animation — the echo mark, coffee-filled left→right.** Every loading indicator is
now the brand echo mark with a coffee band that sweeps the three C's left→right and loops — the *motion*
reading of the mark (DESIGN.md's disambiguation rule: motion = "working", static fill-level = memory). A
new shared `ObEchoLoader` (`shared/app-core`) replaces every `CircularProgressIndicator` across both
Flutter clients (busy buttons incl. **Export deck/CSV**, app boot, Settings sync, the Review fetch
"Bringing your words back…") and the static echo marks that used to stand in for a loader; the native
macOS capture HUD (`CaptureLoadingPanel`) and the overlay's inline "filling in…" loader switch from their
old spinners to the same left→right sweep. The at-rest states that reuse the mark ("all caught up",
"that's the set", the memory-strength meters) stay **static** — motion only ever means working. Honours
reduced-motion. The macOS **export dialog** also now shows the loader on its Export button while the deck
builds + saves (it previously left the button idle and tappable).

**The macOS home hub closes with Esc / ⌘W.** The agent front door (`AgentHome`) was the one surface with
no keyboard way out; it now hides the window back to the menu-bar agent on Esc or ⌘W, exactly like
Review / Word Book / Settings.

**Review widget layout — fixed head + more room for context (iOS `CapechoReviewWidget`).** The word and
its "N due" meter now share one fixed row (word at a single size on every face/family, due pinned to the
top-right corner); the reading drops to its own line beneath, so a long unit and a long reading no longer
compete for a single row. Context/meaning gain guaranteed line space: front context caps at 5 lines
(medium) / 11 lines (large), back meaning at 3 / 6, and the large example sentence at 6 — bounded by the
card frame, so text fills the available height and truncates to fit. The word now carries its
**part of speech inline** (the IPA reading's POS labels, ` · `-joined) — a new optional `pos` field
on the widget snapshot (Dart + Swift, additive, no schema bump). Mockup
([design/mockups/widget-review.html](design/mockups/widget-review.html)) updated to match.

**Review card shows the reading + restores multi-POS labels.** The in-app Review answer (both clients)
now renders the word's **IPA reading** on its own line beneath the head — the primary slot (else
secondary) of a single-reading word, matching the widget and Word Book (a heteronym stays minimal: one
line can't carry two pronunciations). It also **fixes a POS regression**: the head chip required a single
POS label, so a multi-POS word like *prompt* (noun/verb/adjective) showed none; it now ` · `-joins the
single reading's labels, like the widget. This relaxes the E7 "recall card stays minimal" rule to allow
the reading + full POS (per-reading modules still never surface).

**Branded macOS DMG installer (build tooling).** `make_dmg.sh` now produces a designed
drag-to-Applications window — a warm Capecho background (rendered offscreen by `dmg_background.swift`,
no external deps), large icons, a custom volume icon, and a saved Finder layout — using only macOS
built-ins (`hdiutil` + Finder/AppleScript + Swift/AppKit). The window frame compensates for the title
bar so the art isn't clipped, and `DEVELOPER_ID_APP="-"` ad-hoc-signs for local test builds. `release.sh`
prunes stale `Capecho-*.dmg` files before packaging so the appcast sees only the current release.

**zh-Hans enablement groundwork (Phase D1–D4 of
docs/multilingual-explanations.md).** Everything before the
enable flip: the zh-Hans prompt pack now carries the eval-locked invariant voice (truth-first
attested claims, reader-defined coverage with the 打 anchor, the 多音字 readings-binding rule, no
meta language); the input gates gained zh parity vectors (多音字/成语/离合词/AABB pass, 哈哈哈哈
rejects); the clients hold NO target allowlist anymore — every capture asks `/explain` and the
SERVER's `language_unsupported` drives the overlay note (new bridge phase `lang_unsupported`); and
the eval harness is target-parametrized (`EVAL_TARGET`/`EVAL_GLOSS`, pinyin grounding via
`normalizePinyin`, zh word + context gold corpora, the notAWord probe, a one-retry judge transport).
All three zh gates PASS on `gemini-2.5-flash` words / `3.1-flash-lite` context (word zh-gloss
100/100/100/100/100/95.2; word en-gloss all 100; context 100/91.7/91.7). **zh-Hans is ENABLED**
(the D5 flip, founder-approved): `generationCacheKey("zh-CN") → "zh-Hans"` now generates. The
learning-language pickers (macOS onboarding + both Settings) are constrained to the
generation-enabled targets (en + 简体中文) — a target without explanations would break the core
loop; the explanation-language pickers keep all nine backend-supported gloss languages.


**Eval rework: cross-vendor Claude judge + record/replay + the context gate (Phase C of
docs/multilingual-explanations.md).** The harness that gates
every prompt change now judges with Claude, never the Gemini generator grading itself:

- **Claude judge, two transports, zero new deps** (`eval/judge.ts` pure / `eval/judge-live.ts`
  wiring): by default the local **Claude Code CLI** in headless mode (`claude -p` — reuses the
  signed-in subscription; no Anthropic Console key required); `ANTHROPIC_API_KEY` switches to the
  direct Messages API via plain fetch. Verdicts are strict per-dimension booleans; any transport or
  parse failure fails CLOSED (an unjudgeable sample never helps a gate pass).
- **The word gate (`eval:grounded`) grades four dimensions** — summary correctness, gloss-language
  purity, plain tutor voice, no invented etymology (gates 90/95/85/95%) — on top of the unchanged
  CMUdict pronunciation + WordNet POS-coverage axes.
- **New context gate (`eval:context`)** for `CONTEXT_PROMPT_VERSION`: 12 synthetic gold cases —
  repeated units (the span must explain the RIGHT occurrence), the mixed zh-in-en capture,
  headline/fragment/commit-title decoding, dictionary-vs-context divergence — judged for
  occurrence-correctness, logic fidelity, and the natural lead-in-free voice (gates 90/90/85%).
  Requests are built exactly as production builds them (same span resolution, ctxLang
  script-certain-or-null).
- **Record/replay**: every generating run records its validated outputs + a full report under
  `eval/out/` (the archived gate artifacts); `EVAL_REPLAY=1` re-runs judge + gates on the recording
  with ZERO Gemini spend, so judge iterations are free. Strict replay parsers refuse stale/garbage
  recordings (prompt-version mismatch included).
- Offline tests pin the prompts, verdict parsing, gate math, sample (de)serialization, and corpus
  sanity (every declared span selects its unit; the production marker resolves every case). Live
  smoke (replay + real judge): a fabricated-etymology/jargon summary and a wrong-occurrence gloss
  are each caught with the exact right dimension flipped.


**Context layer: natural tutor voice + honest language/span axes (Phase B of
docs/multilingual-explanations.md). `CONTEXT_PROMPT_VERSION`
v1 → v2** — pends the one paid eval run (with the word layer's v2) before any backend deploy.

- **No more fixed lead-ins.** The «The sentence is saying …» / «Here, "X" means …» openers are removed
  from the context prompt and schema (too formulaic, unscalable across languages); the model now
  phrases `sentenceMeaning`/`wordMeaning` naturally in the explanation language. The tutor persona,
  retell-don't-render rule, logic fidelity, and the shell/meta/example/etymology bans all stay.
  ⚠ The B-layout gloss callout relied on the lead-in for sentence-vs-word labeling — device-verify;
  tiny eyebrow labels are the ready fallback.
- **`contextLanguage` never defaults to the target** — on either path (preview
  `context-preview.ts`, saved-layer `explain-context.ts`), in the native Save stamp, or the (dormant)
  Dart save path. The text's language is stated only when the client knew it with **script-certainty**
  (new `scriptCertainLanguage` twins: Dart `capture-core/unit_language.dart` + Swift `UnitLanguage`,
  parity-tested): mono-script Han → `zh-Hans`, kana → `ja`, Hangul → `ko`; any Latin/Cyrillic letter —
  including the normal "zh word inside an English article" mix — means unknown, and the prompt just
  says "the text below". Stored values are canonicalized-or-dropped at the server chokepoints
  (`createContext`, preview).
- **The prompt marks the asked-about occurrence**: `[[TARGET]]…[[/TARGET]]` around the span when it
  resolves (introduced to the model as annotation, not text), so a repeated unit explains the RIGHT
  occurrence. Server-side `resolveMarkedRange` trusts nothing: the client span must be in-bounds,
  select the unit (case-insensitively), and sit on word bounds (Latin/Cyrillic edges only — CJK has no
  word boundaries); otherwise it falls back to the unique occurrence (the save path's
  `UnitSpanResolver` semantics, so span-less saved rows still mark), and a repeated unit without a
  valid span stays unmarked rather than guessing. Language names (never raw BCP-47 tags) throughout.
- **The overlay preview request now carries the axes**: the native side computes the span
  (`UnitSpanResolver` — the same resolver the Save path stamps the journal with) and the
  script-certain context language on the CURRENT, possibly user-edited text; they ride
  `onOverlayContextPreviewRequest` → `previewFor` → `POST /explain/context/preview` (the api-client
  already had the parameters).
- **Post-CR hardening** (dual-agent review of both PRs): `scriptCertainLanguage` now treats a letter
  of ANY non-pinning script as certainty-killing (Arabic/Thai/full-width-Latin text with one Han char
  no longer mislabels as zh-Hans; 々 carved out as Han), both twins + parity tests; the prompt labels
  the text's language only for a NAMED tag (a valid-but-unnamed "en-US" degrades to "the text below" —
  raw tags never reach prompts); `resolveMarkedRange`'s fallback counts only WORD-BOUNDED occurrences
  ("particular art" now marks the standalone "art") and its word-bound set covers Latin Extended
  Additional + Greek Extended; the Swift axes glue is extracted to `ContextRequestAxes` (logic-tested,
  pinning the payload key spellings against the Dart `fromMap` keys); call-site regression tests pin
  contextLanguage-arrives-null on BOTH orchestration paths and canonicalize-or-drop at `createContext`.
- **The preview fingerprint hashes every answer-changing axis** — `(unit, text, explanationLanguage,
  targetLanguage, contextLanguage, spanStart, spanEnd)`, `\x00`-escaped separators — so one
  reservation key can't be replayed for a request differing only in the marked occurrence or a
  language axis. In-flight v1 previews simply TTL-expire; v1 stored glosses lazily regenerate on next
  view (version-guarded re-view).

**Multilingual word contract (Phase A of docs/multilingual-explanations.md):
`senses[]` deleted, the summary IS the explanation, prompts/keys/schema are target-profile-driven.**
The word layer's English-era shape is reset before launch so a second target language (zh-Hans,
defined but disabled until its eval gate) is an additive profile, not a rewrite:

- **The blob is `{summary, readings[{pronunciationPrimary, pronunciationSecondary, partsOfSpeech[]}]}`.**
  The per-sense gloss list is gone end-to-end (schema → validate → API/store models → overlay bridge →
  every surface). The `summary` is the word's ONLY explanation text — capture overlay, Review back,
  Word Book detail, iOS-widget back, and the export definition all show the same text, with **no
  fallback field** (validation polarity flipped: summary is must-pass / `missing_summary`; senses used
  to be). Pronunciation fields are target-neutral; `partsOfSpeech` is a closed English label set
  (`@capecho/lang POS_LABELS`), schema-enum'd per profile and re-filtered at the cache-write gate.
- **Target-generation profiles** (`shared/lang`): one profile per explainable language — identity,
  gating (`enabled`), POS subset, pronunciation display labels — resolved via likely-subtags so the
  script axis can never collapse (`zh`/`zh-CN` → `zh-Hans`; `zh-Hant` → no profile, never a collision).
  `en` keeps collapsing regions. The provider builds the prompt AND the word schema per profile
  (schema descriptions are model instructions); the v5 tutor-voice text is preserved verbatim apart
  from the senses-line edits.
- **`notAWord` contract fixed.** The word schema drops its top-level `required`, so the prompt's bare
  `{"notAWord": true}` exit is schema-legal under constrained decoding — the model no longer fabricates
  summary/readings on the non-word path; validate.ts hard-gates instead.
- **Pronunciation display is profile-driven everywhere.** No hard-coded `US`/`UK`: Dart computes
  labels + decoration from the target profile (`pronunciationParts`; en = labeled, slashed IPA) and the
  overlay bridge now carries display-ready `{label, display}` parts — the Swift renderer is
  target-dumb. `PROMPT_VERSION` v1→v2 (rekeys the word cache; the paid E3 re-run pends per the plan);
  local-store schema v2 wipes v1-shape offline blobs (words/contexts untouched). E3's offline gates
  reworked: POS coverage replaces sense coverage; the live runner judges the summary per unit.

**Pre-MVP reset: the compat/dead paths an unreleased product doesn't need.** With no installed base and
no external clients, the transition shims accumulated during development were removed rather than
carried into the release:

- **The deprecated "Nothing found" dead-end is gone end-to-end.** The product decision already routed
  empty captures to the normal editable overlay; this removes the dormant `showNothingFound` channel
  (Dart facade → platform interface → method channel → Swift handler + the full-panel overlay state) —
  and, with it, the now-unreachable `capture_empty` metric across the whole §14 chain (the Swift
  emitter, the recorder mapping, the Dart/TS contract + shared fixture, the backend validator and the
  gate readout's `funnel.empty`). An empty capture is simply a `presented` overlay now.
- **`words.pos` removed end-to-end.** The column was never written (always NULL on the wire) and the
  Word Book chip it fed could never render; sense-level POS from the explanation blob is unaffected.
- **D1 migrations squashed to one `0001_init.sql`** (the `fsrs_events.source` column and the billing
  tables fold into init — fine pre-release, where every real database is recreatable).
- **Account parsing is strict.** `pro` / `reminder_enabled` / `explanation_follows_learning` are now
  required on the wire; the "pre-billing/pre-identity response" defaults and their tests are gone.
- **The capture journal is camelCase-only.** `JournalEntry.fromMap` no longer tolerates snake_case keys
  the Swift writer never emits.
- **`Normalizer` takes just the surface unit.** The unused `targetLanguage` parameter (dedup is
  language-independent) is dropped from the typedef, `localDedupKey`, and every call site.
- Assorted dead scaffolding: the backend's empty route-stub registry (+ its 501 helper) and stale
  "pre-v4" / "nothing found" comments.
- **Version markers reset to v1.** `PROMPT_VERSION` (was v5) and `CONTEXT_PROMPT_VERSION` (was v3)
  restart at `v1` — the bump history was development churn, not shipped migrations — and the v2→v5
  changelog-style comment blocks collapse into present-tense contract docs. Dev-round tags ("v5
  tutor voice", "ctx-v3", "founder round 4", "since v4") are gone from comments and test names, and
  fixtures drop the dead `promptVersion` key (never on the wire) plus their arbitrary `'v2'`
  normalization-version stubs. ⚠ Deploy note: the word-cache key now reuses the original-`v1` keyspace,
  so wipe the R2 explanation cache (and recreate the dev D1) before the next deploy — otherwise
  first-prompt-era blobs would be served as current.

**Capture overlay — a "tutor voice" redesign.** The warm-glass panel (⌥E) was rebuilt around one idea:
a card that sounds like a seasoned learner explaining a word to a newcomer, not a dictionary entry.

- **The headline is now a short origin story.** Instead of a one-line gist, the definition opens with a
  1-3 sentence plain-spoken story of where the word comes from and how it reached today's senses ("From
  the Latin *salarium* — salt money — *salary* first meant a soldier's allowance for buying salt; over
  time it became any fixed pay"). It leads at a deliberate 16px, one step above the supporting text.
- **One quiet line per pronunciation.** Each reading reads as `US /…/ UK /…/ · noun` — the IPA and the
  part of speech share a single record-style line for every word, so a heteronym is just several lines.
  The standalone POS chips are gone.
- **The in-context "Explain here" answer retells, it doesn't translate.** The gloss now speaks the way a
  fluent friend would: it names the thing the word points to in *your* sentence and decodes headlines,
  labels, and fragments into something easier than the original, rather than producing stiff
  translationese. The word's meaning leads as an attached callout under your sentence; the whole-sentence
  paraphrase rests behind a quiet "Sentence meaning" disclosure.
- **Warmer surface details.** Section dividers and text selection now take the warm accent tint instead
  of flashing system-blue/grey on the glass, and the one "Generated with AI" credit sits once in the
  footer instead of interrupting the definition mid-card.

**Removed the "Core meaning & evolution" feature.** The meaning-evolution chain (the numbered
etymology→today timeline shown in the overlay, the Word Book detail, and the review-card back) was cut.
The origin story now lives in the definition headline itself. This removed the whole `origin` data path —
the prompt field and schema, the shared `OriginBlock` renderer, and the model/cache/store plumbing across
the backend and both clients — rather than leaving dormant code behind.

**Mixed-script capture — read any language, attribute the right one.** Capture now reads arbitrary
mixed-script text and decides the captured word's language for you, decoupled from what you're learning.

- **Recognition is language-agnostic.** OCR no longer forces your configured languages onto the page
  (Vision auto-detection), so a page mixing scripts — 中文 with English, etc. — is read accurately instead
  of garbling the minority script.
- **The capture target follows the word.** When the word you point at is in a script your learning language
  can't be (a 中文 word while you're learning English, say), the capture is attributed — and explained — in
  that language automatically. Your configured learning language is unchanged; only this capture follows.
- **A gentle suggestion when it isn't certain.** When the word could be a *different same-script* language
  (you're reading a Spanish passage while learning English), the overlay's new target chip surfaces it as a
  one-tap switch you confirm — it never silently guesses.
- **Cleaner internals.** Removed the now-unused language-restricted recognition path (the resolver + the
  push-to-native plumbing) and the macOS-26 document-layout pass whose output the visual-span engine no
  longer consumes.

**Capture recognition — the right word, the whole sentence.** A pass on what capture actually grabs, driven
by on-device testing across English and 中文 pages.

- **The captured word is the system's own word boundary.** The unit under the cursor comes straight from the
  OS word tokenizer, so it lands on the whole word you pointed at — across scripts — instead of a fragment
  or a neighbour.
- **The whole wrapped sentence comes back.** Sentence reconstruction follows a paragraph's line *cadence*
  (centre-to-centre rhythm) rather than raw box-edge gaps, so it's robust to the OCR mis-sizing a line's
  box: a sentence that wraps across lines is captured in full instead of collapsing to one line, a large
  title no longer swallows the smaller byline / tab labels beneath it, and the cursor no longer pulls in a
  separate headline above.
- **Sentences don't split on abbreviations.** "Sen.", "Gov.", "Lt.", "etc." and the like no longer cut a
  captured sentence in half.
- **Cleaner captured text.** Invisible / zero-width characters the OCR can pick up are stripped from the
  sentence, and a stray space inserted between two Chinese characters at a line-wrap is removed (Latin word
  spacing is kept). The captured word itself is left untouched so its dedup key stays stable.
- **Capture inside Capecho itself.** ⌥E now works on Capecho's own Word Book / Review / Settings windows —
  capture no longer skips its own app.

**Capture overlay — a UX pass on the warm-glass panel.** A round of polish on the macOS capture overlay
(⌥E), driven by on-device review.

- **Word + sentence read as editable inputs.** The unit and sentence fields now sit in faint inset boxes —
  a warm fill plus a hairline border that's visible at rest and strengthens on focus — so they read as
  inputs distinct from the AI explanation below, instead of looking like plain captions. The empty word
  prompt drops from the 32px headword size to a quiet, vertically-centred 19px hint (a typed word still
  shows at full size), the sentence box is roomier, and "Set the word…" / typed text no longer jump on
  focus.
- **The overlay follows the app's theme.** Light / Dark / System now matches your Capecho appearance
  choice rather than the OS — the overlay glass *and* the menu-bar status dropdown flip with the app.
- **One language control per capture.** The per-capture "Explain in ▾" explanation-language picker was
  removed — in practice nobody re-picked it per word — so the explanation language now follows your account
  setting, and the header keeps just the control that matters per capture: the target-language chip.
- **AI attribution that's accurate.** A quiet "✨ AI" credit now sits with the explanation itself (plus
  a hover tooltip), off the footer where it used to sit beside the Apple *Dictionary* button (which isn't
  AI). The in-context "Explain here" action carries its own ✨ (a separate AI call) and its label was
  shortened.
- **Smaller fixes.** "Core meaning & evolution" expand *and* collapse now animate; the system Look Up popover renders
  the looked-up word at the headword's size; the Save button is clean at rest (the brand ink-dot appears
  only on "● Saved", on commit); the picker's dropdown caret is a proper chevron glyph; the redundant
  "Sentence" eyebrow is gone (the placeholder already says it); and all explanation text — meaning, IPA,
  POS, the evolution chain, the in-context gloss — is selectable to copy.

**Onboarding — a clearer, shorter first run.** The macOS first-run flow was reworked from on-device review.

- **Language is chosen before you capture.** Picking what you're learning (and the explanation language) is
  now its own step, ahead of the capture walkthrough — it used to be buried on the final sign-in screen,
  set only *after* the first capture. Your very first ⌥E now captures in the language you picked.
- **Sign-in stands on its own.** The terminal screen is sign-in / sync only; splitting it from the language
  picker gives each step one clear job.
- **One fewer wall.** The redundant "No problem — clipboard capture" screen is gone — it was a third prompt
  to turn on Screen Recording. "Use copy & paste instead" now goes straight to the guided capture.
- **Back / forward arrows.** A bottom nav bar (← / →) rides every step, so you can move *backward* (which
  wasn't possible before) as well as forward.
- **Less to read, bigger welcome.** The Screen Recording explainer and the "Turn on Screen Recording" steps
  were trimmed for impatient readers; the welcome wordmark + echo mark are larger and the tagline breaks
  cleanly into two lines (no stranded em-dash) across a wider measure.
- **Rebind the capture shortcut during the walkthrough.** The guided-capture step now has a "Change…"
  affordance that opens the same shortcut recorder Settings uses, so you can set the capture key before
  your first ⌥E — the on-card hint and the coachmark update with it.

**Settings, reordered by what matters.** Settings sections now run in one priority order on Mac and iPhone —
Language, then Capture permission, Shortcuts, Account, Reminders, Subscription, Appearance, your Word Book,
Getting started, and About last — so the controls that shape every capture sit at the top. (macOS also drops
the redundant per-section "macOS" label.)

**macOS status-bar dropdown opens on the current Space instead of yanking you to another one.** The
dropdown panel was calling `NSApp.activate(ignoringOtherApps:)`, which pulled the app — and any Settings /
Word Book / Review window already open on *another* Space — to the front, switching you over to that Space
just to show the menu. The panel is a `.nonactivatingPanel` that already takes Esc + click-to-select from
`makeKeyAndOrderFront` alone (the capture overlay's proven pattern), so the activate call is dropped: the
`.canJoinAllSpaces` dropdown now appears on the *current* Space and only choosing a row brings a surface
forward.

**macOS auto-update restored for the direct build — without leaking Sparkle into the Mac App Store build.**
The Mac App Store work removed Sparkle as a Swift Package (a package auto-embeds in *every* build
configuration, which broke App Store validation) and `#if SPARKLE`-guarded every use — but `SPARKLE` was
then defined nowhere, so the *direct* Developer ID release silently shipped with no updater and no
"Check for Updates…" row while the appcast pipeline kept feeding it. Sparkle 2.9.2 is now a vendored,
manually linked + embedded framework (`clients/macos/macos/Frameworks/Sparkle.framework`) gated by a single
`SPARKLE_ENABLED` build switch that defaults **off**: `scripts/macos/build_release.sh` turns it on for the
direct archive (and asserts Sparkle is embedded + linked), while `scripts/macos/build_mas.sh` leaves it off
and now asserts the archive embeds/links **no** Sparkle. The App Store build stays provably Sparkle-free.
A `build:mas` npm script wraps the App Store build alongside the existing `build:macos`. Pipeline-only — no
app-visible behavior change.

**Review reliability — don't drop ratings.** Two fixes to the spaced-repetition sync path found in a
pre-launch review of the FSRS flow. Both are invisible in the happy path; they close edge cases where a
rating could be silently lost.

- **A widget grade is no longer clobbered by the foreground flush.** Draining the Home Screen widget's
  queued grades on app foreground wrote the queue back from a *pre-flush* snapshot, so a grade the widget
  enqueued during the `/sync` network window was overwritten and lost (the card simply reappeared as
  due). The flush now re-reads the shared queue and removes only the acked grades, so a grade enqueued
  mid-flush survives. (A sub-millisecond residual window between two uncoordinated cross-process writes
  remains; fully closing it needs an `NSFileCoordinator`-guarded App-Group file, tracked separately.)
- **Rating event ids are collision-free UUIDs.** The in-app and widget rating ids were a
  `timestamp+counter` two fresh processes could mint identically. The server keys idempotency on the
  event id *globally*, so a clash across devices was rejected (`id_conflict`) and that rating dropped.
  Both paths now generate RFC-4122 UUIDs, matching the backend contract.

**Capture overlay — explanation-language switch, titled meaning-evolution, one AI attribution.** Three
refinements to the macOS capture overlay from a design review.

- **The language picker switches the *explanation* language, not the target.** The overlay dropdown was
  relabeled `Learning: X ▾` → `Explain in: X ▾` and now changes the language a meaning is rendered IN (a
  native-language gloss vs immersion). The capture's target language is fixed at recognition time and is
  no longer re-litigated in the overlay; Save still persists that fixed target, and switching the picker
  re-fetches `/explain` in the chosen gloss language.
- **"Core meaning & evolution" reads as titled stages.** Each meaning-evolution step now leads with a short bold
  title (e.g. "Rock Mass", "Sky Mass", "Crowd", "Computing") then its explanation. The `/explain`
  generation carries a structured `{title, text}` per step end-to-end (prompt + JSON schema + cache-write
  validation → API model → device cache → Swift overlay), and the overlay, Word Book detail, and
  review-card back render the title in bold; reads are backward-compatible with older string steps
  (`Title — explanation` is split, a bare string stays text-only). `PROMPT_VERSION` bumps to `v3` (rekeys
  the word cache; pends a paid grounded-eval re-run before deploy). The "Core meaning & evolution" toggle is
  left-aligned.
- **A single "Generated by Gemini" attribution.** The overlay footer carries one icon-only sparkle with
  a "Generated by Gemini" hover tooltip — dim while the explanation is generating, full once ready, and
  hidden when there is nothing AI-generated to attribute.

## [0.1.14] - 2026-06-08

**Pre-launch UI polish across the site and both apps.** A pass over the rough edges spotted before
promotion — the marketing site behaves in dark mode, the footer carries real store badges, and the
onboarding reads cleaner.

- **Web — dark mode that holds together.** The hero MacBook/iPhone screens now flip to the app's real
  espresso dark mode instead of sitting as bright slabs on the dark page, and the device stage is centred
  on phones (it was scaled off to the side, leaving only a sliver visible).
- **Web — a fuller closing CTA + real download badges.** The closing band carries the echo mark, a value
  line, a secondary link and the three core reassurances. The footer gains a "Get the app" block with the
  recognizable official store lockups — separate App Store and Mac App Store badges (iOS vs macOS), Google
  Play, and a greyed-out Microsoft Store marked "Soon" (no Windows build in the MVP). Store links stay blank
  until each listing is live.
- **Web — aesthetics pass (design review).** Scroll-reveal no longer strands content half-faded on deep
  links or fast scrolls — anything at or above the fold reveals immediately. The sticky header condenses and
  turns opaque on scroll, so content stops bleeding through onto the wordmark. The mobile hero headline
  wraps in full lines instead of one word at a time. The SEO landing pages and Contact move to a
  two-column / card layout that fills the width instead of a narrow column floating in whitespace. The CTA
  buttons trade the hard stacked-paper offset for a soft warm elevation (DESIGN.md §8), and the Capecho
  column in the comparison table is tinted so it reads as the answer.
- **macOS onboarding.** The welcome title is rebuilt with the brand "Capture / echo" emphasis and a clean
  wrap; the permission step states plainly that capture needs macOS's Screen Recording permission for
  on-device OCR of text you can't select; the "first word saved" pill is gone.
- **Mobile.** The word-detail header keeps only the back affordance — the word headlines the body below.
- **macOS Word Book.** The whole row is tappable (the sentence opens the detail too, not just the
  headword), the "N due today" meta sits flush right in the header instead of stranded mid-row, and the
  back button gets a roomier hit target.
- **Tooling.** Adds the `build:ios` release script alongside `build:macos`.

## [0.1.13] - 2026-06-08

**An iPhone Home Screen widget that turns dead minutes into review.** Capecho now ships a native iOS
widget you can reveal and grade right on the Home Screen — no need to open the app to keep words moving
through spaced repetition.

- **Interactive review in the widget.** It shows the next due word; tap to reveal its meaning and IPA
  reading, then grade Forget / Hard / Good / Easy — all via App Intents, without launching the app. A
  static echo due-meter shows how much is still waiting.
- **Caffeine visual layer (DESIGN.md §4.5).** Warm canvas, coffee-brown serif word, Charter sentence,
  the brand echo ripple, muted oxblood/sage grade buttons, and an espresso dark mode.
- **SwiftPM-pure App-Group bridge.** The app publishes its review snapshot to the widget through a shared
  App Group (`group.com.capecho.app`) over a `MethodChannel`, and grades made on the widget queue up
  offline and drain back into the app on next open — no `home_widget` plugin, so the iOS build stays
  CocoaPods-free.
- **Tap-through deep links.** Tapping into a word opens the app via `app_links` straight to that review.
- **Shared, tested logic (`WidgetReviewKit`).** Snapshot decode, the reveal/grade state machine, and
  dedupe live in a Swift package unit-tested against a golden-fixture contract shared with the Dart side.

## [0.1.12] - 2026-06-08

**Pre-launch copy pass: one voice across the site and both apps.** Tightened every user-facing string
before promotion. Nothing functional changed — but the words now line up.

- **One tagline everywhere.** The marketing hero, macOS onboarding, and mobile sign-in all read
  "Capture the new words you're reading — and echo them back before they fade." The old home hero
  was a grammatically broken fragment ("…echo back before they fade.").
- **The site reflects reality.** The Mac app is presented as available now via a direct notarized DMG
  download — the email "join the beta" waitlist (which had no send path, so signups never heard back) is
  gone. The iPhone companion stays "coming". Terms and Privacy no longer claim Mac App Store distribution
  (direct download today, App Store planned), governing law is set (Delaware) with the placeholder clauses
  resolved, and the in-context limit reads "10 a day, free" consistently.
- **Consistent in-app wording.** The free word layer is "meaning" everywhere (was a mix of
  "meaning"/"explanation"); "Word Book" replaces stray "catalog"; the menu-bar entry matches Settings
  ("Get Started"); CSV export counts "words and phrases", not "cards"; and the macOS empty states
  show your real capture shortcut instead of a hardcoded ⌥E. Straight apostrophes are now curly throughout.
- **Language claims scoped to English.** Copy promises generated explanations for English first; other
  languages are still captured, saved, and reviewed, with generation expanding as quality is validated.

## [0.1.11] - 2026-06-08

**The "Explain in this sentence" daily-limit hint no longer shows a made-up count.** The line next to the
button always read "10 of 10 left today" no matter how many context explanations you'd already spent — a
fixed placeholder, not your real remaining quota — which then contradicted itself the moment you hit the
cap. The app can't actually know your remaining count yet (the server doesn't report it), so rather than
fake a number, both macOS and iOS/Android now show a plain **"Free, with a daily limit"** hint. The
offline and error messages likewise drop their invented "today's 10" wording while keeping the true
reassurance that those attempts aren't counted against your limit. The daily limit itself is unchanged.

## [0.1.10] - 2026-06-08

**Review timing now matches how memory actually works.** Tuned the server-authoritative spaced-repetition
scheduler so words echo back on a sensible, growing rhythm instead of a fixed loop:

- **A word you know leaves your queue and comes back days later — then keeps growing.** Rating a new word
  *Good* now schedules it ~2 days out (not the same session), and every time you recall it the gap widens
  (≈ 2d → 11d → 46d → months, up to a year). That growth *is* the "I've learned this" signal — a familiar
  word is no longer shown on a short, fixed cycle.
- **A word you forget comes back the same day.** *Forget* (and a struggled *Hard*) re-surface in ~10–15
  minutes — the moment the forgetting curve says re-exposure matters most — instead of waiting a full day.
- **Even a mastered word resurfaces at least once a year**, so nothing silently disappears forever.

Why it changed: the default scheduler bounced a freshly-rated *Good* card back in 10 minutes, while an
earlier fix over-corrected (a forgotten word waited a full day). The scheduler now uses a single 10-minute
(re)learning step at 90% target retention — the FSRS team's own recommendation. Scheduling stays 100%
server-authoritative (FSRS-6, interval fuzz off for reproducible due dates).

## [0.1.9] - 2026-06-07

**Review cards flip on the phone, and the back now shows how the word evolved.** Two improvements to the
spaced-repetition flashcards:

- **The phone's card flips.** Tapping a review card to reveal the answer now turns it over with the same
  3D flip the Mac already used, instead of swapping instantly. (The flip animation is now shared between
  the two clients so they can't drift.)
- **"Core meaning & evolution" on the answer side.** After you flip a card, the back shows — beneath the meaning —
  the word's meaning-evolution chain: its through-line idea and the numbered steps from its etymological
  root to today's sense. It's the same "Core meaning & evolution" the Word Book detail shows, surfaced as
  enrichment *after* the recall attempt (on both Mac and phone). Words whose explanation has no evolution
  data simply don't show the section.

## [0.1.8] - 2026-06-07

**Phone polish: working reminders, real data export, and pages that stay in the app.** Five fixes to the
iOS/Android app (the last also lands on Mac):

- **Reminders now tell you when notifications are switched off.** Turning on the daily reminder while
  notifications were blocked for Capecho looked like it worked but never showed anything. The Reminders
  setting now warns when notifications are off at the system level and offers a one-tap jump to the right
  Settings screen to turn them back on.
- **Export your Word Book from the phone.** The phone exports the same way the Mac does now — a one-click
  Anki deck (`.apkg`) or a CSV — handed to the system share sheet, so you can save it to Files, AirDrop
  it, or send it on. (It previously only copied CSV to the clipboard.)
- **Signing out closes Settings.** Tapping Sign out now dismisses the Settings panel instead of leaving
  it floating over the sign-in screen.
- **Privacy, Terms, and the contact page open inside the app.** Those links open in an in-app browser
  rather than bouncing you out to Safari or Chrome (with an "open in browser" option if you'd rather).
- **The version number sits quietly at the bottom of Settings** — on both phone and Mac — as plain,
  non-tappable text.

## [0.1.7] - 2026-06-07

**A smaller capturing loader, and reminders that visibly work.** Two fixes:

- **The "capturing…" loader is more compact.** The brand echo mark that animates while the on-device
  OCR runs was a touch large; it's now smaller and calmer, still centered where the result overlay
  appears.
- **Turning on the daily reminder now visibly confirms itself.** Enabling the reminder asks for
  notification permission right then — so the macOS prompt always appears, instead of only when
  something happened to be due — and once you allow it, a one-time "Reminders on" notification fires
  immediately, so you can see it actually works rather than waiting for the scheduled time. The daily
  nudge itself is unchanged: it still arrives at your chosen time and stays quiet on days nothing is due.

## [0.1.6] - 2026-06-07

**An About section in the app, and a Contact page on the site.** Settings now has an **About** section
on both macOS and iOS/Android: the app version (read from the bundle, so it always matches the build
you're running), links to the **Privacy Policy** and **Terms of Service**, a **Contact support** link (which opens the
new capecho.com/contact page), and a link to capecho.com. On the web, **capecho.com gains a dedicated
Contact page** — linked from the footer — for support, feedback, and privacy / data requests.

## [0.1.5] - 2026-06-07

**The Dock icon now disappears when you close a window.** Capecho is a menu-bar agent with no Dock icon
at rest; opening Word Book / Review / Settings gives it one (to ⌘-Tab to), and closing should take it
away. The icon used to stay stranded when you closed with the window's red ✕ — on current macOS the ✕
closes a window through a different internal path than ⌘W, and that path skipped Capecho's return to a
Dock-less agent. Now the icon drops however you close the window (✕, ⌘W, or Esc), and closing no longer
yanks focus back to whatever app you were in before. Opening a window from inside another app's
full-screen Space now overlays it there, instead of flipping to a separate Space and bouncing back when
you close.

## [0.1.4] - 2026-06-07

**A capturing animation while the OCR runs.** Pressing the capture shortcut now shows a small
warm-glass loader the instant the screenshot is taken, so the brief on-device OCR pass is no longer a
blank wait — it animates the brand echo mark (the three concentric ripples from the app icon) pulsing
outward, then hands straight off to the result overlay. It appears only on the Screen-Recording OCR
path, and only after the shot is secured, so it never lands in the captured screenshot.

## [0.1.3] - 2026-06-07

**The capture overlay no longer looks up gibberish.** Capturing a non-word — a keyboard mash like
`asdfgh`, a held-key smear like `aaaa`, or a pronounceable-but-meaningless string — now shows a calm
"this doesn't look like a word" note instead of querying the AI and inventing an explanation. Two layers
catch it:

- **A local, instant heuristic** rejects a single-token keyboard-row walk (`asdf`/`qwerty`/`hjkl`) or a
  4+ character repeat before any network call — tuned to never reject a real, rare, proper, or
  mis-OCR'd word (phrases and non-Latin scripts always pass). Mirrored server-side as a spend guard.
- **The explanation model can now decline.** For a word-shaped string the heuristic can't judge, the
  model itself returns a `notAWord` verdict rather than fabricating meaning; the word-layer prompt bumps
  to `v2` for this path.

The capture still saves to your Word Book either way — delete it if you don't want it.

## [0.1.2] - 2026-06-06

**Adopt-on-save, a Dock presence for open windows, and a squared-off overlay close.** Three macOS fixes:

- **"Explain in this sentence" now persists on Save.** Preview a word's in-context explanation in the
  capture overlay, then Save, and that already-paid gloss is adopted onto the saved Word Book entry — no
  re-charge, no re-clicking "Explain" in the Word Book. The capture-time preview handle rides the
  immediate post-save claim through a new `preview_handle` field; a stale / edited-sentence / expired
  handle simply falls back to re-explaining (the previous behavior).
- **A Dock icon appears while a window is open.** Capecho is a menu-bar agent (no Dock icon at rest);
  opening Word Book / Review / Settings / onboarding now flips it to a regular app so there's a Dock icon
  to ⌘-Tab to and re-open, then back to agent-only when the window hides. The capture overlay stays
  Dock-less. Re-launching the app (or clicking its Dock icon) brings the existing window forward instead
  of spawning a second instance.
- **The overlay ✕ now sits an equal distance from the top and right edges** (it was noticeably closer to
  the top).

## [0.1.1] - 2026-06-06

**"Explain in this sentence" now teaches the sentence first, then the word.** The metered
in-context explanation returns two parts instead of a single gloss: `sentenceMeaning` — the whole
sentence's meaning (a faithful translation in the gloss language) — and `wordMeaning` — the sense the
unit takes *here* in this sentence. Surfaces in the macOS capture overlay and in both clients' Word
Book detail. The context prompt stays version `v1` (pre-launch, no stored glosses to migrate); the
re-view path guards on the two-field shape so any legacy single-field gloss regenerates.

## [0.1.0] - 2026-06-06

**First public beta.** Capture the words you meet while reading, understand them in context,
review them with spaced repetition.

- **macOS client** (menu-bar agent): capture overlay (OCR + clipboard), context-aware
  explanation, FSRS review, Word Book, account sign-in + sync, Anki/CSV export.
- **iOS/Android client**: sign-in, touch Review, Word Book, Settings — the "echo" half, built
  on the shared `capecho_app_core`. Not yet store-shipped.
- **Backend** (Cloudflare Workers + D1): explanations + cost plane, server-authoritative FSRS +
  sync + pre-login claim, metered context layer, Anki/CSV export, bearer-session auth with
  email one-time-code sign-in.

> The pre-`0.1.0` build history (the path from spike to MVP) lives in git history.
