/// Pre-explain junk filter (RFC §B, Proposal B): is [unit] obvious junk that should NOT cost an
/// `/explain` call? This is the cheap, best-effort CLIENT gate — the server keeps its own
/// authoritative gate, and a filter's cross-platform divergence is harmless (worst case: one extra
/// call, caught by the server gate + cache).
///
/// THE DISCIPLINE: reject TRUE junk ONLY. A false
/// reject means a real word is NEVER explained/saved — far worse than a wasted call. So anything that
/// could be a real word — proper nouns, technical terms, OCR-corrupted words, diacritics, and CJK —
/// MUST pass; we reject only degenerate non-vocabulary shapes. When unsure, PASS.
library;

final RegExp _hasLetter = RegExp(r'\p{L}', unicode: true);

/// An email's "@" sits BETWEEN word characters (`user@host`). Anchoring on `\w@\w` avoids rejecting a
/// LEADING-"@" technical term — CSS at-rules (`@media`, `@font-face`) and decorators (`@Override`) are
/// real units, not emails.
final RegExp _emailish = RegExp(r'\w@\w');

/// True ⇒ skip the `/explain` call (the unit is degenerate non-vocabulary). False ⇒ pass it through.
///
/// Rejects: empty / whitespace-only; strings with no letter in ANY script (pure punctuation, numbers,
/// symbols, or emoji); and clear URL / email shapes. Everything with linguistic content passes —
/// `\p{L}` matches every script incl. CJK ideographs (category Lo), so real words, OCR typos, proper
/// nouns, diacritics, and 学习 all pass.
bool isLikelyJunk(String unit) {
  final trimmed = unit.trim();
  if (trimmed.isEmpty) return true;
  // No letter in any script → punctuation / number / symbol / emoji only (e.g. "→", "42", "3.14",
  // "•••", "😀"). \p{L} includes CJK ideographs, so any real word in any script keeps linguistic
  // content and passes.
  if (!_hasLetter.hasMatch(trimmed)) return true;
  // URL / email shapes carry letters but are never a vocabulary unit: "://" anywhere, or an "@"
  // between word chars (an email local@domain). A LEADING "@" (a CSS at-rule / decorator) is a real
  // unit, so it is NOT matched here and passes.
  if (trimmed.contains('://') || _emailish.hasMatch(trimmed)) return true;
  // Has letters, not a URL/email → it could be a real word (incl. an OCR typo). PASS.
  return false;
}
