# capecho_capture_core

The **platform-neutral capture reconstruction core** — pure Dart, no Flutter, no
platform APIs. Written **once** and reused by every Capecho client
(macOS now; Windows/iOS/Android later). This is the realization of the
"design for Windows" rule: the Windows port swaps only the native adapter, never
this logic.

## The split (why this package exists)

Capture has two kinds of work:

| Work | Where it lives | Why |
|---|---|---|
| **Platform-inherent** — global hotkey, screen capture, OCR engine, highlight-pixel detection | the native adapter (`clients/capture_native`, Swift on macOS / C++ on Windows) | needs `ScreenCaptureKit`/`Vision` (macOS) or `Windows.Graphics.Capture`/`Windows.Media.Ocr`; the screenshot buffer must never cross the bridge (capture latency is the make-or-break metric) |
| **Reconstruction** — cursor→token targeting, geometric paragraph reconstruction, flow-text, sentence/context windowing | **here** (pure Dart) | identical on every platform; structured data, no FFI; fully `dart test`-able with no display or permission |

The native adapter produces a platform-neutral [`OcrSnapshot`]; this core turns it
into a [`CaptureResult`].

```
native adapter ──OcrSnapshot(lines+boxes, cursor, selectionRect?)──▶ CaptureReconstructor ──▶ CaptureResult(word, sentence, context)
```

## Coordinate convention (every adapter MUST match)

All geometry is normalized to `[0,1]` with the **origin at the BOTTOM-LEFT, y
up** — Apple Vision's native `boundingBox` convention. The macOS adapter emits
Vision boxes directly; a Windows adapter must convert `Windows.Media.Ocr`'s
top-left/pixel boxes into this same space. See `lib/src/geometry.dart`.

## What it is (and isn't)

This is the **capture** shape — the unit + sentence + context read off screen. It
is **not** the persisted/deduped unit: the target-language choice and the
deterministic, no-lemmatization dedup key (provisional client-side via
`localDedupKey`, authoritative server-side via `backend/src/dedup-key.ts`) happen
later in the overlay/save path.

## Provenance: a faithful port of the macOS spike

The reconstruction was ported function-by-function from the validated macOS
spike (`ScreenOCRService.swift` geometry/text logic + `LearningContextBuilder.swift`),
preserving every threshold verbatim (hit-score `outsideX*8 + outsideY*4 +
center + width*0.05`, line/token insets, `isBlockBreak` rules, `sameColumn`
tolerances, the 360/600-char context window, etc.). Each function carries a
`// port of …` origin comment.

**Deliberate divergences from the spike** (flagged for on-device validation):

1. **Token boxes are proportional-only** (with CJK/full-width 2× weighting). The
   spike preferred Vision's per-character `boundingBox(for:)`; the cross-platform
   bridge carries only **line** boxes, so the proportional estimate is the
   canonical method here.
2. **Word tokenization is Unicode-aware** — `\p{L}` (+ combining marks `\p{M}`,
   with `unicode: true`) matches letters of any script (Latin incl. diacritics,
   Greek, Cyrillic, kana, Hangul). Han stays a separate *leading* alternative
   (explicit CJK ranges, since Dart `RegExp` lacks `\p{Han}`) so embedded Latin in
   Chinese (`使用React框架`) still splits; supplementary-plane Han is not matched.
   (The spike's regex was ASCII-only — `[A-Za-z]`+Han; widened per Codex review.)
3. **Sentence segmentation** is rule-based (Latin `.!?…` with period-only-before-
   whitespace so `U.S.`/`3.14` don't split, plus CJK `。！？`), replacing Apple's
   `NLTokenizer(.sentence)`. It does not know general abbreviations (`Mr.`, `e.g.`).
4. **Length counts** use Unicode-scalar (rune) count, not Swift's grapheme count
   — differs only at the context-window edges.
5. **Boundary-exact cursor offsets** resolve to the earlier sentence (matches the
   Swift `min(by:)` tie); benign for real mid-token cursors.

## Run

```sh
cd shared/capture-core
dart pub get
dart analyze   # clean
dart test      # 46 tests
```
