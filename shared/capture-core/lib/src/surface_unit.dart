/// Normalizes a captured surface UNIT for display + save.
///
/// OCR / selection can leave stray non-word characters clinging to the captured
/// term — a selection of "(non-governmental)," keeps the parens + comma, a token
/// next to punctuation can pick up an edge mark. [surfaceUnit] strips leading and
/// trailing runs of non-(letter | mark | number) so the unit shown in the
/// overlay, written to the journal, and sent to `/explain` is just the word —
/// while INTERNAL hyphens / apostrophes stay intact (compound words like
/// "non-governmental" and contractions like "don't" survive).
///
/// This is the EDGE-strip of the dedup key (backend `dedup-key.ts` /
/// `localDedupKey`) applied to the SURFACE form: same `[\p{L}\p{M}\p{N}]` class
/// at the boundaries, so a unit and its dedup key agree on where the word begins
/// and ends — but case is preserved and no NFC / lowercase is applied (those are
/// dedup-only). A unit made of nothing but punctuation / symbols trims to the
/// empty string (the caller drops it; the junk gate would reject it anyway).
library;

final RegExp _edgeJunk = RegExp(r'^[^\p{L}\p{M}\p{N}]+|[^\p{L}\p{M}\p{N}]+$', unicode: true);

/// [raw] with leading + trailing non-(letter | mark | number) runs removed.
/// Internal characters (incl. hyphens / apostrophes) are untouched. Returns the
/// empty string when [raw] has no letter / mark / number anywhere.
String surfaceUnit(String raw) => raw.replaceAll(_edgeJunk, '');
