/// The captured unit's writing system → the effective capture target language.
///
/// Recognition is now language-agnostic (the native adapter auto-detects scripts),
/// so a user reading mixed text can capture a unit in a language they did NOT
/// configure as their learning target — e.g. an English learner pointing at a 中文
/// word. This module decides that capture's `target_language`:
///
///   * When the unit's WRITING SYSTEM is provably incompatible with the configured
///     learning language's (a 中文/Han unit while learning English/Latin, or
///     한국어/Hangul), it is — with deterministic 100% certainty, no probabilistic
///     language ID involved — a different language, so the capture is attributed to
///     the unit's own language ([effectiveTargetLanguage] auto-switches it).
///   * A SAME-script difference (English vs Spanish, both Latin) is never certain
///     from script alone; it stays on the configured target here and is handled by a
///     separate pre-save confirm prompt that uses real language detection.
///
/// This is the ONLY place attribution is auto-derived, and only on the certain
/// (script-disjoint) path — the "target_language is the user's explicit choice"
/// rule otherwise stands: the configured learning language is never mutated, and a
/// same-script capture is never silently re-attributed. The mapping is deterministic
/// (no probabilistic detector), so the `(user, target_language, unit)` dedup key
/// stays stable across captures of the same unit.
library;

/// Writing systems distinguished for the capture-target decision.
enum UnitScript { latin, han, kana, hangul, cyrillic, other }

/// The dominant writing system of [text]: the most language-identifying script
/// present, scanned by code point, ignoring punctuation / digits / whitespace.
///
/// Priority Hangul > Kana > Han > Cyrillic > Latin, so a Japanese unit carrying
/// kana (勉強する) resolves to [UnitScript.kana] (→ ja) despite its Han, and Korean
/// to [UnitScript.hangul]. A pure-Han unit is [UnitScript.han] (defaulting to
/// Chinese — kana/Hangul are what distinguish ja/ko). Empty / symbol-only text is
/// [UnitScript.other].
UnitScript dominantScript(String text) {
  var hasHan = false;
  var hasCyrillic = false;
  var hasLatin = false;
  for (final rune in text.runes) {
    if (_isHangul(rune)) return UnitScript.hangul;
    if (_isKana(rune)) return UnitScript.kana;
    if (_isHan(rune)) {
      hasHan = true;
    } else if (_isCyrillic(rune)) {
      hasCyrillic = true;
    } else if (_isLatin(rune)) {
      hasLatin = true;
    }
  }
  if (hasHan) return UnitScript.han;
  if (hasCyrillic) return UnitScript.cyrillic;
  if (hasLatin) return UnitScript.latin;
  return UnitScript.other;
}

/// The writing systems a BCP-47 learning-language tag is normally written in
/// (matched on the primary subtag). Used to decide whether a captured unit's
/// script is compatible with the learning language.
Set<UnitScript> scriptsOfLanguage(String bcp47) {
  switch (_primarySubtag(bcp47)) {
    case 'zh':
    case 'yue':
      return const {UnitScript.han};
    case 'ja':
      return const {UnitScript.han, UnitScript.kana};
    case 'ko':
      return const {UnitScript.hangul};
    case 'ru':
    case 'uk':
    case 'be':
    case 'bg':
    case 'sr':
    case 'mk':
      return const {UnitScript.cyrillic};
    default:
      // The learning-language set is Latin-script (en/es/de/it/fr/pt) plus
      // zh-Hans (handled above); an unknown tag is treated as Latin so a Han /
      // Hangul / kana unit still reads as "different" and auto-switches.
      return const {UnitScript.latin};
  }
}

/// The effective capture target for [unit]: the configured [learningLanguage],
/// auto-switched to the unit's own language ONLY when the unit's script is provably
/// incompatible with the learning language's (a deterministic "different language",
/// never a probabilistic guess).
///
/// Returns [learningLanguage] unchanged when the scripts are compatible, the unit is
/// empty, or the disjoint unit's script doesn't pin a supported target: a Latin unit
/// needs language ID (which Latin? en / es / …), so it defers to the confirm-prompt
/// path rather than guess; a Cyrillic / other-script unit has no supported target at
/// all, so it simply stays on the configured language (still capturable + editable,
/// just not auto-attributed — generalizing to those scripts is out of scope).
String effectiveTargetLanguage({
  required String unit,
  required String learningLanguage,
}) {
  final trimmed = unit.trim();
  if (trimmed.isEmpty) return learningLanguage;
  final script = dominantScript(trimmed);
  if (scriptsOfLanguage(learningLanguage).contains(script)) return learningLanguage;
  switch (script) {
    case UnitScript.han:
      return 'zh-Hans';
    case UnitScript.kana:
      return 'ja';
    case UnitScript.hangul:
      return 'ko';
    case UnitScript.latin:
    case UnitScript.cyrillic:
    case UnitScript.other:
      return learningLanguage;
  }
}

/// Targets the app can attribute a capture to + explain (the learning-language
/// picker plus the CJK targets the script auto-switch produces). A suggestion is
/// only offered for one of these, so the overlay never proposes a target the
/// backend can't gloss.
const Set<String> supportedTargetLanguages = {
  'en',
  'es',
  'de',
  'it',
  'fr',
  'pt',
  'zh-Hans',
  'ja',
  'ko',
};

/// The minimum span-language confidence to surface a target suggestion — a floor
/// against noise, NOT an auto-switch bar (the suggestion is itself the pre-save
/// confirm the user accepts or ignores). Sentence-length spans detect well above
/// this for a clear language; a lower value means genuinely ambiguous → no nudge.
const double suggestedTargetConfidenceGate = 0.65;

/// The capture target the overlay should SUGGEST switching to (a pre-save confirm,
/// never auto-applied), or null when no suggestion is warranted.
///
/// This covers exactly the cases [effectiveTargetLanguage] deliberately does NOT
/// auto-switch — where the difference isn't script-certain: reading a Spanish
/// passage while learning English, or a Latin word while learning Chinese (the
/// script says "different" but not WHICH Latin). It offers the span's confidently
/// detected language when (a) it's a supported target, (b) it differs from the
/// current [effectiveTarget], and (c) that language can be written in the captured
/// [unit]'s script — so the span actually reflects the unit, and a script-disjoint
/// unit the auto-switch already attributed is never second-guessed (its English
/// surrounding sentence won't drag a 中文 unit back to English).
String? suggestedTargetLanguage({
  required String unit,
  required String effectiveTarget,
  required String? spanLanguage,
  required double spanLanguageConfidence,
  double confidenceGate = suggestedTargetConfidenceGate,
}) {
  final detected = spanLanguage;
  if (detected == null || detected.isEmpty) return null;
  if (spanLanguageConfidence < confidenceGate) return null;
  if (!supportedTargetLanguages.contains(detected)) return null;
  if (detected == effectiveTarget) return null;
  if (!scriptsOfLanguage(detected).contains(dominantScript(unit))) return null;
  return detected;
}

/// The TEXT's language when its writing system alone makes it certain, else null.
///
/// The context-language axis for a captured sentence (the value stamped on a saved
/// context / sent on the preview request): a language is named ONLY when the text is
/// mono-script in a script that pins one — the same deterministic bar (and the same
/// accepted Han→zh-Hans / kana→ja defaults) as [effectiveTargetLanguage]. A letter of
/// ANY other script kills certainty — Latin/Cyrillic (which Latin language? and the
/// normal capture — a zh unit inside an English article — is exactly such a mix), but
/// equally Arabic, Thai, full-width Latin, …: one Han char must never "pin" zh-Hans on
/// text that is mostly something else. Null means the backend prompt says "the text
/// below" and lets the model read the text — an absent label is always correct; a
/// guessed one can be wrong. Mirrored natively as `UnitLanguage.scriptCertainLanguage`
/// (the overlay computes per save/preview on the CURRENT, possibly user-edited text;
/// keep the twins in parity).
String? scriptCertainLanguage(String text) {
  var han = false;
  var kana = false;
  var hangul = false;
  for (final rune in text.runes) {
    if (_isHangul(rune)) {
      hangul = true;
    } else if (_isKana(rune)) {
      kana = true;
    } else if (_isHan(rune) || rune == 0x3005) {
      // 々 (U+3005, the CJK iteration mark — 人々/山々) reads as Han here: it is a letter
      // (category Lm) outside the Han ranges, so without the carve-out it would hit the
      // any-other-letter branch and wrongly kill certainty for everyday zh/ja text.
      han = true;
    } else if (_isOtherLetter(rune)) {
      return null; // a letter of any non-pinning script — never certain
    }
  }
  if (hangul) return kana ? null : 'ko'; // Hangul pins Korean (rare hanja OK); +kana = nonsense mix
  if (kana) return 'ja'; // kana pins Japanese (kanji OK)
  if (han) return 'zh-Hans'; // pure Han: the same accepted default as the unit auto-switch
  return null; // symbols / digits only
}

/// Unicode general category L* (any letter), matched per code point so astral-plane
/// letters (mathematical alphanumerics, …) count too. Digits, punctuation, and marks are
/// not letters and never affect certainty.
final RegExp _letterRe = RegExp(r'\p{L}', unicode: true);

bool _isOtherLetter(int rune) => _letterRe.hasMatch(String.fromCharCodes([rune]));

String _primarySubtag(String tag) => tag.split('-').first.toLowerCase();

bool _isHan(int r) =>
    (r >= 0x4E00 && r <= 0x9FFF) || // CJK Unified Ideographs
    (r >= 0x3400 && r <= 0x4DBF) || // Extension A
    (r >= 0xF900 && r <= 0xFAFF) || // Compatibility Ideographs
    (r >= 0x20000 && r <= 0x2A6DF); // Extension B

bool _isKana(int r) =>
    (r >= 0x3040 && r <= 0x30FF) || // Hiragana + Katakana
    (r >= 0xFF66 && r <= 0xFF9D); // half-width Katakana

bool _isHangul(int r) =>
    (r >= 0xAC00 && r <= 0xD7A3) || // Hangul syllables
    (r >= 0x1100 && r <= 0x11FF) || // Jamo
    (r >= 0x3130 && r <= 0x318F); // compatibility Jamo

bool _isCyrillic(int r) => (r >= 0x0400 && r <= 0x04FF) || (r >= 0x0500 && r <= 0x052F);

bool _isLatin(int r) =>
    (r >= 0x41 && r <= 0x5A) || // A-Z
    (r >= 0x61 && r <= 0x7A) || // a-z
    (r >= 0x00C0 && r <= 0x024F); // Latin-1 Supplement + Extended-A/B (accents)
