/// Pre-explain GIBBERISH gate (RFC §B, the cheap CLIENT fast-path "L1"): is [unit] a single
/// keyboard-mash / repeated-key token that no learner could have meant to look up? This is the
/// companion to [isLikelyJunk] (`junk_filter.dart`): junk rejects strings with NO linguistic content
/// (pure punctuation / numbers / URL / email); THIS rejects strings that DO carry letters but are still
/// not words — the "asdfgh" / "aaaa" that the junk gate, by design, lets through.
///
/// THE SAME DISCIPLINE as the junk gate: reject TRUE non-words ONLY — a false reject means
/// a real word is NEVER explained/saved, far worse than one wasted call. So this fires on ONLY the two
/// signals that NO real word produces, and is the AUTHORITY for nothing: the server's LLM gate ("L3")
/// is what decides the ambiguous, word-SHAPED middle. The two signals:
///
///  1. the WHOLE token being a monotonic WALK of >= 5 keys along ONE QWERTY row — "qwerty", "asdfgh",
///     "poiuy" (the fingerprint of a finger sliding across the keyboard). It must be the ENTIRE token,
///     NOT a substring: real words merely CONTAINING a run must pass — "liberty" / "property" /
///     "poverty" / "puberty" all contain "erty" (e→r→t→y on the top row), and direction-changing words
///     like "were" are not a single run either. The >= 5 floor (not 4) keeps the ONE 4-key single-row
///     real word — "wert" (archaic "thou wert") — out of the net; a bare 4-key mash ("asdf") defers to
///     the L3 model gate, so this stays PROVABLY free of real-word false-rejects (313k-word brute-force).
///  2. the SAME character >= 4 times in a row — "aaaa", "loooool" (a held key / OCR stutter). English
///     never doubles a letter past 2, so 4+ is unambiguous.
///
/// Multi-word phrases and any non-Latin script are left to the LLM gate (the row/repeat signals are
/// single-token + Latin-keyboard specific). When unsure, PASS.
library;

/// QWERTY rows (lowercased). A learner mashing keys slides along one of these.
const List<String> _kbRows = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];

/// char → (row, column) on the QWERTY layout; absent for anything off the letter rows (digits,
/// punctuation, every non-Latin script) — which simply breaks a walk.
final Map<String, ({int row, int col})> _kbPos = {
  for (var r = 0; r < _kbRows.length; r++)
    for (var c = 0; c < _kbRows[r].length; c++) _kbRows[r][c]: (row: r, col: c),
};

/// True ⇒ the SAME character repeats >= 4 times consecutively (a held key / OCR stutter).
bool _hasLongRepeat(String s) {
  var run = 1;
  for (var i = 1; i < s.length; i++) {
    if (s[i] == s[i - 1]) {
      if (++run >= 4) return true;
    } else {
      run = 1;
    }
  }
  return false;
}

/// True ⇒ the ENTIRE token [s] is a single monotonic run of >= 5 keys along ONE QWERTY row (a keyboard
/// "walk": "qwerty", "asdfgh", "poiuy"). EVERY key must sit on the same row, be horizontally adjacent to
/// the previous, and keep one direction — so a word that merely CONTAINS a run ("liberty" holds "erty")
/// fails at its first off-row/non-adjacent pair, and a direction flip ("were") fails too. Whole-token +
/// the >= 5 floor (excludes the lone 4-key real word "wert") keep this from ever rejecting a real word.
bool _isKeyboardWalk(String s) {
  final lower = s.toLowerCase();
  if (lower.length < 5) return false;
  final first = _kbPos[lower[0]];
  if (first == null) return false;
  final row = first.row;
  var prevCol = first.col;
  int? dir; // +1 (rightward) or -1 (leftward); fixed by the first step
  for (var i = 1; i < lower.length; i++) {
    final p = _kbPos[lower[i]];
    if (p == null || p.row != row) return false; // every key on the SAME row…
    final d = p.col - prevCol;
    if (d != 1 && d != -1) return false; // …horizontally adjacent…
    if (dir == null) {
      dir = d;
    } else if (d != dir) {
      return false; // …keeping one direction (a flip ⇒ not a straight mash)
    }
    prevCol = p.col;
  }
  return true;
}

/// True ⇒ skip the `/explain` call: [unit] is a single keyboard-mash / repeated-key token, not a word.
/// False ⇒ pass it through (it could be a real word — incl. an OCR typo, a proper noun, or a phrase).
bool isLikelyGibberish(String unit) {
  final t = unit.trim();
  if (t.isEmpty) return false; // empties are the junk gate's job, not ours
  // A real multi-word phrase is never pure mash, and the row/repeat signals are single-token; defer any
  // phrase to the LLM authority rather than risk rejecting "give up" because one part looks odd.
  if (RegExp(r'\s').hasMatch(t)) return false;
  return _hasLongRepeat(t) || _isKeyboardWalk(t);
}
