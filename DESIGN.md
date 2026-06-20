# Design System — Capecho

## Aesthetic Direction

Capecho runs **two deliberately distinct visual systems** — the contrast is the design, not an inconsistency:

- **Overlay = warm-tinted glass, restrained.** The capture overlay (the macOS hotkey panel, invoked by ⌥E while reading) is an `NSVisualEffectView` vibrancy panel — warm ink on warm translucent glass, tied to the Caffeine canvas, with a **single restrained Capecho accent** (the coffee/latte save mark) and otherwise warm-monochrome ink; system window shadow only. It is fleeting and polite: it appears, lets you glance and save, and disappears. This is where you _move through_; it stays quiet, never competes with what you're reading, and never goes loud.

- **App = a warm library.** Word Book / Review / Settings (macOS windows + Flutter mobile) use the **Caffeine** palette: coffee-brown primary, latte-cream accents, dark-roast ink on a warm canvas, plus an espresso dark mode. This is where you _sit_ with your words; it carries the brand, the warmth, the 质感.

**Why two systems:** the overlay is fleeting and polite — quiet, translucent warm glass disappears. The app is a destination you return to — warm coffee gives it identity and comfort. **Quiet capture, warm keeping.**

- **Decoration level:** Minimal, both. Typography + one motif (the echo mark) do the work. No gradients, no decorative blobs, no gamification, no confetti.
- **Mood:** Calm, considered, literate, mature. A serious, private tool for people who love reading.
- **Audience anchor:** high-value knowledge workers who read English at volume; they value 质感 (craft), 效率 (efficiency), 简洁 (simplicity), 隐私 (privacy), and a 成熟稳重 (mature, grounded) feel. Loud reads as cheap to them.
- **Reference points:** native macOS Look Up / vibrancy panels (the overlay); tweakcn "Caffeine" + Stripe Press + Reeder + fine-press editorial (the app).
- **Explicit anti-references:** LingQ (SaaS slop), Migaku (neon maximalism), generic shadcn templates (no point of view), blue/teal "default-app" accents, language-learning illustrations, gamification.

---

## Typography

Three voices: a display serif for the word being captured, a body serif for the explanation, system sans for chrome, monospace for data.

> **Overlay scope note.** What the free word-level layer renders is defined by the product spec — per-POS senses, **per-POS IPA + on-device audio**, an idiom badge, and the system-Dictionary handoff. **CEFR levels and dictionary-style example sentences are NOT built** (they belong to the macOS system Lookup API or stay out of scope), and **etymology / meaning-evolution was built and then removed** — do not re-add it as its own surface. The type roles + tokens below that still mention CEFR or etymology are retained for the macOS-Lookup-adjacent surfaces only; do **not** build them into the overlay.

| Role                  | Font                                                           | Source                                           | Rationale                                                                                                                                                                                         |
| --------------------- | -------------------------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Display / Hero**    | **Fraunces**                                                   | Google Fonts (free, variable)                    | Editorial weight, opentype-rich, high `opsz` setting for dictionary-headword presence. Used for: the word in the overlay, hero headings on the marketing site, the front of review cards. |
| **Body / Content**    | **Charter** → Source Serif 4 fallback                          | Preinstalled on macOS/iOS; Google Fonts fallback | Beautifully screen-optimized serif Apple ships free. Zero loading cost on Apple platforms. Used for: explanation content, example sentences, longer body text.                                    |
| **Chrome**            | **System fonts** — SF Pro Text on macOS/iOS, Roboto on Android | Native, zero loading                             | Chrome disappears; Charter carries personality. Used for: buttons, settings labels, list items, menu items, navigation.                                                                           |
| **Data / IPA / Mono** | **JetBrains Mono**                                             | Google Fonts (free)                              | IPA-capable, very legible, tabular-nums. Used for: phonetic transcriptions, dates, catalog numbers, debug-style data.                                                                                |

### Scale

The type scale — every role's size, weight, optical size, line-height, and tracking — lives in the design tokens (`--t-*` in [`design/tokens.css`](design/tokens.css)), each annotated with its surface use. Roles map to the four voices in the table above. The **phonetic/IPA** role IS built (the overlay renders per-POS IPA); the **CEFR pill** role keeps its token but is **not** built (see the scope note).

### Reader's measure

The overlay's explanation area must respect a 65-character maximum line length. Wider widths break reading rhythm.

---

## Color

Two namespaced palettes, both shipping light + dark: the **overlay** is warm-tinted glass with one restrained accent (`--ovl-*`); the **app** is warm Caffeine coffee (`--app-*`). **The exact values live in the design tokens — [`design/tokens.css`](design/tokens.css)** (the canonical source the clients' tokens are generated from). This section owns the intent + rules; tokens.css owns the numbers.

### Overlay — Warm Glass

An `NSVisualEffectView` (vibrancy) panel: a warm tint with warm ink on top, tied to the Caffeine canvas. **One restrained Capecho accent** — the coffee/latte save mark (`--ovl-accent`) — is the single warm gesture; everything else is warm ink on glass. The only other flourishes are a faint 1px "lit" top-edge sheen and a hairline rule under the headword.

**Binding rules (beyond the values):** section eyebrows + small labels use `--ovl-ink-2`, **never** `--ovl-ink-3` — `ink-3` is illegible on translucent glass over a busy desktop. The overlay is warm-tinted, **not colourful**: one coffee/latte accent (the save mark), everything else warm ink on glass, nothing that competes with the page.

### App — Caffeine

Warm coffee: coffee-brown is the one primary, latte-cream is the chip/tag colour, dark-roast is ink, white cards on a warm canvas, espresso dark mode. (Reference: tweakcn "Caffeine".)

### Semantic

Muted to match coffee, **never bright SaaS** (both modes): success = library sage (not bright green), warning = ochre, error = deep oxblood (distinct from the coffee primary), info = slate.

### Saved indicator

A "saved" word shows a tiny 6px ink-dot — never a checkmark, never a tick (a reader marking a book, not a task done). In the **overlay** the dot is the Capecho accent `--ovl-accent` (coffee/latte) — the single warm gesture on the warm glass, now matching the app's saved dot. In the **app** the dot is `--app-primary` (coffee brown; latte on dark).

### Shadows

Two systems, by surface:

- **Overlay (Warm Glass):** the vibrancy panel uses the **system window shadow only — no custom shadow, no edge.** A hard offset on translucent glass is incoherent, and the overlay must stay fleeting. Quiet capture stays frictionless.
- **App (Caffeine) — double-edge / "stacked paper":** buttons, cards, and controls carry a **restrained offset hard shadow + a defined edge**, so they read as tactile, pressable, catalog-like — not floating SaaS cards. Calibrated **restrained** (~3px, Vocabulary-like), NOT loud (Inkwell neobrutalist) — fits the calm/mature anchor. The shadow tokens (`--shadow-edge`, `-sm`, `-press`, `-soft`, `-soft-hover`, `--app-edge`, and the window ambient) live in [`design/tokens.css`](design/tokens.css); on `:active` the element presses into the ledge, and `prefers-reduced-motion` keeps the press instant.

---

## Brand Identity

The brand lives in three owned elements that recur across every surface — they are what make the app read as _Capecho_, not as a generic shadcn template.

### Wordmark

**`Capecho.`** in Fraunces 600, tight tracking (`-0.02em`), with the **period in the primary colour** (coffee brown in-app). The period is the editorial statement gesture. Used as the app masthead (top of Word Book / Review / Settings) and in onboarding.

### The echo mark (signature motif)

Three growing echo ripples — three nested C-curves that grow and brighten left → right (`(((`) — from the name (**Cap**ture + **echo**) and the mechanic (a word _echoes back_ through spaced repetition). It is identity **and** a function:

- In the **masthead**, beside the wordmark, in the primary colour.
- Beside **every saved word** as a **memory-strength meter**: full primary colour = due for review; faded ink = settled in memory. Serves 效率 — review state legible at a glance.
- The seed for the **app icon**, the review "due" pulse, the saved-word animation, and the loading sweep (see "The echo loader" below). Always thin, single-weight, never rainbow.
- **Disambiguation rule (one mark, two meanings — keep them legible):** the echo encodes either *memory state* or *activity*, never ambiguously. **Static + fill-level = memory** (the at-rest meter: full = due, faded = settled). **Motion = "working"** (the loading sweep below, sign-in, sync). A *moving* echo always means the app is doing something; a *still* echo always means memory state. So loading/spinner/sync uses animate and the memory meter never does — otherwise a faded animated ripple reads as "settling in memory" when it means "fetching." (Guards the [[echo mark]] reuse against the echo-mark overload risk — see the disambiguation rule above.)

### The echo loader (the one "working" indicator)

The app has **one** loading indicator, never the platform spinner: the echo mark with a **coffee band that sweeps the three C's left → right and loops** — the mark's own small-left → large-right grain, lit. It is the *motion* reading of the echo mark, so it must always animate; the static memory-meter (and the at-rest states that reuse it — "all caught up", "that's the set") must not (the disambiguation rule above). It replaces both the platform `CircularProgressIndicator` AND the static echo marks that used to stand in for a loader, so every working surface shows one logo doing one thing: app boot, busy buttons, the OCR loader between hotkey and overlay, the Review fetch ("Bringing your words back…"), and the Settings sync.

- **Colour:** the coffee band is `--app-primary` (latte on dark), or the button's `primaryFg` on a filled button; the unfilled C's sit underneath as a faint track (~16% of the band colour). Warm only — never a bright SaaS spinner.
- **Cadence:** one 1.5s sweep, linear, looping; the bright band sits off the mark at both ends so the loop reset is invisible. Honours reduced-motion (holds the still mark).
- **Implementations (kept in sync — one motion):** Flutter `ObEchoLoader` (`shared/app-core` `chrome.dart`, beside [`ObEchoMark`](shared/app-core/lib/src/design/chrome.dart)); native macOS `EchoPulseView` (`CaptureLoadingPanel.swift`), a gradient band masked to the arcs.

Reference SVG (single weight, `currentColor` so it tints per surface):

```
<svg viewBox="0 0 28 28" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round">
  <g transform="translate(-3.08 -3.5) scale(1.25)">
    <path d="M10.5 13 a 2.3 2.3 0 0 1 0 -4" transform="translate(-2.2 3)"/>
    <path d="M15.5 14.7 a 5 4.1 0 0 1 0 -7.4" transform="translate(-1.7 3)"/>
    <path d="M21 15.7 a 6.5 5.0 0 0 1 0 -9.4" transform="translate(-0.8 3)"/>
  </g>
</svg>
```

### Catalog numbering

Word Book entries carry a mono index number (`01`, `02` …, JetBrains Mono, `--app-ink-3`). Signals a curated reference work, not a generic list view.

---

## Spacing

- **Base unit:** 4px. **Density:** comfortable — readers like air; knowledge workers don't need crammed UI.
- The spacing scale, overlay paddings, and section gaps live in the design tokens (`--space-*`, `--ovl-pad-*`, `--ovl-gap-*` in [`design/tokens.css`](design/tokens.css)).
- **Reading measure:** max 65 characters per line in the overlay's explanation area.

---

## Locked interaction decisions

The normative interaction choices the clients implement — kept here because the code shows *what* is
built, not *why these and not the alternatives*. (These guard against re-litigating settled UX.)

**Capture overlay**

- **Two-field capture model:** the overlay has a **unit (word/phrase) — required** + a **context
  sentence — optional**. A single captured blob **auto-routes by shape** (word/short phrase → unit;
  full sentence → context); the other field is a quiet manual input. **Save is blocked until the unit
  is present** (calm hint); a context-less save is allowed.
- **Set-unit-from-sentence:** when only a sentence was captured (unit empty), the user promotes a
  **selection within the context** to the unit, or types it.
- **Language picker:** a visible inline `Explain in: X ▾` dropdown that switches the **explanation
  (gloss) language** — the language a meaning is rendered IN. The capture's **target language is fixed
  at capture time** (the recognition language) and is *not* re-litigated in the overlay; the picker
  changes only how the explanation reads (a native-language gloss vs immersion). Full keyboard via
  normal focus (Tab→open, ↑/↓ choose, Enter confirm, Esc close). **No ⌘L / bare L.**
- **Editing:** one unified, visually-quiet inline-edit model for OCR + clipboard — unit + context are
  plain text, editable on click/focus. **Tab = standard focus advance** (unit → context → language →
  Save), never retarget; **direct text edit only** — no token-strip, no ⇧+arrow span keys.
- Centered (slightly high) on the cursor's display; an empty capture presents the SAME editable panel
  (empty fields, never a dead-end "nothing found" state); the saved ink-dot dwells ~600–900ms then fades.

**Review**

- A dedicated, single-purpose **resizable** window (min + max measure, card centered) that stays open
  — quiet "done", never auto-closes. **Strictly forward**: rate (1–4) to advance; no back, skip, or
  list. Space/⏎ flips. Global **⌥R** opens Review (mirrors ⌥E). **No next-interval previews at MVP** —
  rating buttons show labels only.

**Word Book**

- Default sort = most-recent capture first; search matches **unit + meaning only** (not context
  sentences); remaining quota shown only when low ("· N of 10 left today"); Recently-Deleted shows a
  calm relative age, no purge countdown.

**Account / Settings**

- **Re-authenticate with the provider to delete the account** (macOS + mobile) — not a type-DELETE
  confirm. Delete dialog summarizes the data + the ~30-day window + notes the public cache is
  unaffected. Per-field instant-save with an inline Queued/Not-saved pill + retry.
