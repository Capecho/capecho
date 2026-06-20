/// Sentence-around-cursor selection + wider-context expansion.
///
/// port of LearningContextBuilder (LearningContextBuilder.swift, whole file).
///
/// SEGMENTATION DIVERGENCE (read this): the spike delegated sentence
/// segmentation to Apple's `NLTokenizer(unit: .sentence)`, which is not
/// available in Dart. We port the *behavior* with a rule-based segmenter that
/// matches the spike's documented fallback bounding:
///   - Latin terminators: `.  !  ?  …`
///   - a PERIOD terminates a sentence ONLY when it is followed by whitespace or
///     end-of-text, so "U.S." and "3.14" do NOT split (decimals / initialisms);
///     `!`, `?`, `…` terminate regardless of what follows.
///   - a period after a known ABBREVIATION (Mr., Dr., Sen., Gov., Lt., etc.) does
///     NOT split — without this, titles / honorifics / "etc." fragment a sentence
///     mid-way and the capture loses the half BEFORE the abbreviation.
///   - CJK terminators: `。  ！  ？` (always terminate; CJK has no spacing).
/// Trailing closing quotes / brackets after a terminator are kept with the
/// sentence they close.
///
/// Everything else — the "sentence nearest the cursor" selection, the
/// outward context expansion, and the size constants — is ported verbatim.
library;

/// The result of windowing a flowing paragraph around the cursor.
class LearningContext {
  /// The single complete sentence containing (or nearest) the cursor.
  final String? sentence;

  /// The sentence plus neighbouring sentences, up to [LearningContextBuilder.maxContextLength].
  final String context;

  const LearningContext({required this.sentence, required this.context});
}

/// A half-open UTF-16 range `[location, location + length)` within the source
/// flowing text. Mirrors Swift's `NSRange` (which is UTF-16 based, exactly like
/// a Dart `String`).
class _Range {
  final int location;
  final int length;
  const _Range(this.location, this.length);
  int get end => location + length;
}

abstract final class LearningContextBuilder {
  // port of LearningContextBuilder constants (LearningContextBuilder.swift
  // lines 21-22).
  static const int maxContextLength = 600;
  static const int targetSentenceLength = 360;

  /// Clip [text] to at most [maxLength] runes (default [maxContextLength]) — the rune-aware truncation
  /// used to BOUND the clipboard + selection capture paths, which (unlike OCR reconstruction) have no
  /// inherent size limit, so a multi-MB clipboard / whole-page selection can't bloat the overlay, the
  /// fsync'd journal, or the `/explain` payload (capture P1). OCR already clips via `build`.
  static String clip(String text, [int maxLength = maxContextLength]) => _clipped(text, maxLength);

  /// Scrub OCR-injected noise from a FINAL learning string before it leaves the
  /// reconstructor. Two passes:
  ///   1. Drop invisible / non-printable / zero-width / control / format scalars
  ///      Vision (or a PDF/web source) can inject — these survive [_cleaned]
  ///      because Dart's `\s` doesn't match them — then collapse + trim.
  ///   2. Drop a space wedged BETWEEN two CJK characters. CJK has no
  ///      inter-character spacing, so such a space is always a line-wrap join or
  ///      a split-word artifact (a wrapped "拿文" + "本" rejoining as "拿文 本"
  ///      → "拿文本"). Latin word spacing and CJK↔Latin boundary spaces are kept.
  /// Idempotent. Walks runes so non-BMP CJK ideographs count as one character.
  static String sanitizeOutput(String text) {
    if (text.isEmpty) return text;

    final visible = StringBuffer();
    for (final rune in text.runes) {
      if (!_isInvisibleScalar(rune)) visible.writeCharCode(rune);
    }
    final collapsed = _cleaned(visible.toString());
    if (collapsed.isEmpty) return collapsed;

    final runes = collapsed.runes.toList(growable: false);
    final out = StringBuffer();
    for (var i = 0; i < runes.length; i++) {
      final r = runes[i];
      final isSpace = r == 0x20 || r == 0x3000; // regular or ideographic space
      if (isSpace &&
          i > 0 &&
          i + 1 < runes.length &&
          _isCjkScalar(runes[i - 1]) &&
          _isCjkScalar(runes[i + 1])) {
        continue; // inter-CJK space → drop
      }
      out.writeCharCode(r);
    }
    return out.toString();
  }

  /// Invisible / non-printable scalars that survive whitespace collapse: C0/C1
  /// controls (EXCLUDING \t\n\v\f\r 0x09–0x0D, left for the collapse), soft
  /// hyphen, zero-width spaces/joiners, bidi controls, word joiner + invisible
  /// operators + deprecated format chars, and the BOM / ZWNBSP.
  static bool _isInvisibleScalar(int c) =>
      c <= 0x08 ||
      (c >= 0x0E && c <= 0x1F) ||
      (c >= 0x7F && c <= 0x9F) ||
      c == 0xAD ||
      (c >= 0x200B && c <= 0x200F) ||
      (c >= 0x202A && c <= 0x202E) ||
      (c >= 0x2060 && c <= 0x206F) ||
      c == 0xFEFF;

  /// Whether [c] is a CJK scalar with no inter-character spacing — Han (+ Ext
  /// A/B and compat), kana, Hangul, and CJK / fullwidth punctuation. Used only
  /// to spot a stray space flanked by CJK on both sides.
  static bool _isCjkScalar(int c) =>
      (c >= 0x2E80 && c <= 0x2EFF) || // CJK radicals
      (c >= 0x3000 && c <= 0x303F) || // CJK symbols & punctuation
      (c >= 0x3040 && c <= 0x30FF) || // hiragana + katakana
      (c >= 0x3400 && c <= 0x4DBF) || // CJK Ext A
      (c >= 0x4E00 && c <= 0x9FFF) || // CJK unified ideographs
      (c >= 0xAC00 && c <= 0xD7AF) || // Hangul syllables
      (c >= 0xF900 && c <= 0xFAFF) || // CJK compatibility ideographs
      (c >= 0xFE30 && c <= 0xFE4F) || // CJK compatibility forms
      (c >= 0xFF00 && c <= 0xFFEF) || // halfwidth + fullwidth forms
      (c >= 0x20000 && c <= 0x2FA1F); // CJK Ext B–F + compat supplement

  /// port of LearningContextBuilder.build(in:around:)
  /// (LearningContextBuilder.swift lines 31-55).
  static LearningContext build(String text, int characterOffset) {
    final units = text.codeUnits; // UTF-16, == Swift `text as NSString`.
    if (units.isEmpty) {
      return const LearningContext(sentence: null, context: '');
    }

    // safeOffset = min(max(characterOffset, 0), nsText.length - 1)
    final safeOffset = characterOffset.clamp(0, units.length - 1);

    final sentences = _sentenceRanges(text);

    if (sentences.isEmpty) {
      final whole = _clipped(_cleaned(text), maxContextLength);
      return LearningContext(
        sentence: whole.isEmpty ? null : whole,
        context: whole,
      );
    }

    // selectedIndex = argmin distance(safeOffset, sentences[i])
    var selectedIndex = 0;
    var bestDistance = _distance(safeOffset, sentences[0]);
    for (var i = 1; i < sentences.length; i++) {
      final d = _distance(safeOffset, sentences[i]);
      if (d < bestDistance) {
        bestDistance = d;
        selectedIndex = i;
      }
    }

    final rawSentence = _cleanedRange(sentences[selectedIndex], units);
    final sentence = rawSentence.isEmpty ? null : _clipped(rawSentence, maxContextLength);
    final context = _expandedContext(selectedIndex, sentences, units);

    return LearningContext(
      sentence: sentence,
      context: context.isEmpty ? rawSentence : context,
    );
  }

  /// port of LearningContextBuilder.sentenceRanges(in:)
  /// (LearningContextBuilder.swift lines 58-72), with the NLTokenizer call
  /// replaced by [_segment]. Empty (whitespace-only) ranges are dropped exactly
  /// as the Swift did.
  static List<_Range> _sentenceRanges(String text) {
    final units = text.codeUnits;
    final ranges = <_Range>[];
    for (final r in _segment(units)) {
      if (_cleanedRange(r, units).isNotEmpty) {
        ranges.add(r);
      }
    }
    return ranges;
  }

  /// Rule-based replacement for `NLTokenizer(unit: .sentence)`. Walks the UTF-16
  /// units and cuts after each terminator boundary. The ranges returned are
  /// CONTIGUOUS and cover the whole text (matching NLTokenizer's behavior of
  /// partitioning the input, including the whitespace that follows a
  /// terminator), so the empty-range filter above removes purely-blank tails.
  static List<_Range> _segment(List<int> units) {
    final ranges = <_Range>[];
    final n = units.length;
    var start = 0;
    var i = 0;
    while (i < n) {
      final c = units[i];
      if (_isHardTerminator(c) || (c == _period && _periodTerminates(units, i))) {
        // Extend across any run of terminators (e.g. "?!", "...") and trailing
        // closing quotes / brackets that belong with this sentence.
        var j = i + 1;
        while (j < n && (_isTerminatorUnit(units[j]) || _isClosing(units[j]))) {
          j++;
        }
        // End the sentence right after the terminator + closing run. The
        // whitespace that follows is left to begin the NEXT range (where
        // `_cleaned` trims it). Keeping it OUT of this range makes the
        // word-offset that lands at the next sentence's first character map
        // unambiguously into that next sentence (mirrors NLTokenizer's
        // inter-sentence boundary, and fixes the boundary tie in `_distance`).
        ranges.add(_Range(start, j - start));
        start = j;
        i = j;
        continue;
      }
      i++;
    }
    if (start < n) {
      ranges.add(_Range(start, n - start));
    }
    return ranges;
  }

  static const int _period = 0x2E; // '.'
  static const int _bang = 0x21; // '!'
  static const int _question = 0x3F; // '?'
  static const int _ellipsis = 0x2026; // '…'
  static const int _cjkPeriod = 0x3002; // '。'
  static const int _cjkBang = 0xFF01; // '！'
  static const int _cjkQuestion = 0xFF1F; // '？'

  /// Terminators that always end a sentence regardless of the following char.
  static bool _isHardTerminator(int c) =>
      c == _bang ||
      c == _question ||
      c == _ellipsis ||
      c == _cjkPeriod ||
      c == _cjkBang ||
      c == _cjkQuestion;

  /// Any unit that is itself a terminator (used when extending across runs).
  static bool _isTerminatorUnit(int c) => c == _period || _isHardTerminator(c);

  /// A period terminates ONLY when followed by whitespace, end-of-text, or a
  /// closing quote/bracket (e.g. `."` ). This is what keeps "3.14" from
  /// splitting — the next char there is a digit, not whitespace.
  ///
  /// One extra guard reproduces NLTokenizer's handling of single-letter
  /// initialisms ("U.S.", "e.g." style): a period does NOT terminate when the
  /// letter immediately before it is itself preceded by a period — the `.X.`
  /// pattern — so "U.S. now" stays one sentence. (The spike relied on
  /// NLTokenizer's abbreviation knowledge here; this is the minimal
  /// rule-based stand-in named in the divergence note.)
  static bool _periodTerminates(List<int> units, int i) {
    if (_isInitialismPeriod(units, i)) return false;
    if (_precededByAbbreviation(units, i)) return false;
    final next = i + 1;
    if (next >= units.length) return true; // end of text
    final n = units[next];
    return _isWhitespace(n) || _isClosing(n);
  }

  /// Common abbreviations that take a trailing period WITHOUT ending a sentence,
  /// matched case-insensitively against the Latin-letter run immediately before
  /// the period. A heuristic stand-in for NLTokenizer's abbreviation knowledge
  /// (the spike used it — see the divergence note): without it, "Sen.", "Gov.",
  /// "Lt.", "Mr.", "Dr." and editorial "etc." falsely terminate, so a capture in
  /// the tail of such a sentence loses everything before the abbreviation. It errs
  /// toward NOT splitting (a slightly long sentence beats a fragment, and the
  /// overlay edit is the safety net); a genuine terminator elsewhere still ends the
  /// sentence. Only UNAMBIGUOUS abbreviations are listed — deliberately excludes
  /// "no" / "am" / "pm", which are common sentence-final words.
  static const Set<String> _abbreviations = {
    // Titles / honorifics
    'mr', 'mrs', 'ms', 'mx', 'dr', 'prof', 'st', 'sr', 'jr', 'rev', 'hon', 'fr', 'messrs',
    // Military / government ranks + roles
    'gen', 'col', 'capt', 'cmdr', 'lt', 'sgt', 'cpl', 'maj', 'pvt', 'adm', 'brig',
    'gov', 'sen', 'rep', 'pres', 'supt', 'det', 'ofc', 'insp',
    // Editorial / Latin
    'vs', 'etc', 'eg', 'ie', 'al', 'cf', 'viz', 'esp', 'approx', 'est', 'vol', 'vols',
    'pp', 'fig', 'figs', 'ch', 'sec', 'ed', 'eds', 'trans',
    // Organizations
    'inc', 'corp', 'ltd', 'co', 'llc', 'plc', 'bros', 'assn', 'dept', 'univ', 'inst',
    // Address
    'ave', 'blvd', 'rd', 'hwy', 'ste', 'apt',
    // Month abbreviations
    'jan', 'feb', 'mar', 'apr', 'jun', 'jul', 'aug', 'sep', 'sept', 'oct', 'nov', 'dec',
  };

  /// Whether the run of Latin letters immediately before the period at [i] is a
  /// known [_abbreviations] entry, so the period is part of the abbreviation rather
  /// than a sentence boundary. Returns false when no letters precede the period
  /// (e.g. a numbered-list "3." — which SHOULD split off the list marker).
  static bool _precededByAbbreviation(List<int> units, int i) {
    var start = i;
    while (start > 0 && _isLatinLetter(units[start - 1])) {
      start -= 1;
    }
    if (start == i) return false;
    return _abbreviations.contains(String.fromCharCodes(units, start, i).toLowerCase());
  }

  /// True when the period at [i] closes a `.X.` single-letter initialism
  /// group (preceding char is a single letter that is itself preceded by a
  /// period), e.g. the trailing period of "U.S.".
  static bool _isInitialismPeriod(List<int> units, int i) {
    if (i < 2) return false;
    final prev = units[i - 1];
    final prev2 = units[i - 2];
    return _isLatinLetter(prev) && prev2 == _period;
  }

  static bool _isLatinLetter(int c) => (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

  static bool _isWhitespace(int c) =>
      c == 0x20 || // space
      c == 0x09 || // tab
      c == 0x0A || // LF
      c == 0x0B ||
      c == 0x0C ||
      c == 0x0D || // CR
      c == 0xA0 || // NBSP
      c == 0x2028 ||
      c == 0x2029 ||
      c == 0x3000; // ideographic space

  /// Closing quotes / brackets that should stay with the sentence they close.
  static bool _isClosing(int c) =>
      c == 0x22 || // "
      c == 0x27 || // '
      c == 0x2019 || // ’
      c == 0x201D || // ”
      c == 0x29 || // )
      c == 0x5D || // ]
      c == 0x7D || // }
      c == 0xFF09 || // ）
      c == 0x300D || // 」
      c == 0x300F; // 』

  /// port of LearningContextBuilder.expandedContext(around:sentences:in:)
  /// (LearningContextBuilder.swift lines 76-113). Constants and the
  /// expand-up-then-recheck-then-expand-down ordering are verbatim.
  static String _expandedContext(
    int selectedIndex,
    List<_Range> sentences,
    List<int> units,
  ) {
    var firstIndex = selectedIndex;
    var lastIndex = selectedIndex;

    while (_runeCount(_joinedSentences(sentences, firstIndex, lastIndex, units)) <
        targetSentenceLength) {
      var didExpand = false;

      if (firstIndex > 0) {
        final candidate = _joinedSentences(sentences, firstIndex - 1, lastIndex, units);
        if (_runeCount(candidate) <= maxContextLength) {
          firstIndex -= 1;
          didExpand = true;
        }
      }

      if (_runeCount(_joinedSentences(sentences, firstIndex, lastIndex, units)) >=
          targetSentenceLength) {
        break;
      }

      if (lastIndex < sentences.length - 1) {
        final candidate = _joinedSentences(sentences, firstIndex, lastIndex + 1, units);
        if (_runeCount(candidate) <= maxContextLength) {
          lastIndex += 1;
          didExpand = true;
        }
      }

      if (!didExpand) {
        break;
      }
    }

    return _joinedSentences(sentences, firstIndex, lastIndex, units);
  }

  /// port of LearningContextBuilder.joinedSentences (lines 115-120).
  static String _joinedSentences(
    List<_Range> sentences,
    int first,
    int last,
    List<int> units,
  ) {
    final parts = <String>[];
    for (var i = first; i <= last; i++) {
      final s = _cleanedRange(sentences[i], units);
      if (s.isNotEmpty) parts.add(s);
    }
    return parts.join(' ');
  }

  /// port of LearningContextBuilder.distance(from:to:) (lines 122-130).
  static int _distance(int offset, _Range range) {
    if (offset >= range.location && offset < range.end) return 0;
    if (offset < range.location) return range.location - offset;
    return offset - range.end + 1;
  }

  /// port of LearningContextBuilder.cleanedRange(_:in:) (lines 132-134).
  static String _cleanedRange(_Range range, List<int> units) {
    final end = range.end <= units.length ? range.end : units.length;
    final start = range.location < 0 ? 0 : range.location;
    if (start >= end) return '';
    return _cleaned(String.fromCharCodes(units, start, end));
  }

  /// port of LearningContextBuilder.cleaned(_:) (lines 136-140): collapse
  /// whitespace runs to a single space and trim.
  static final RegExp _whitespaceRun = RegExp(r'\s+');
  static String _cleaned(String text) => text.replaceAll(_whitespaceRun, ' ').trim();

  /// port of LearningContextBuilder.clipped(_:maxLength:) (lines 142-147).
  /// Swift `String.prefix(maxLength)` / `.count` operate on characters; we use
  /// runes (Unicode scalar values), the closest pure-Dart analogue, so a clip
  /// never splits a code point.
  static String _clipped(String text, int maxLength) {
    final runes = text.runes.toList(growable: false);
    if (runes.length <= maxLength) return text;
    final head = String.fromCharCodes(runes.take(maxLength));
    return '${head.trim()}…';
  }

  /// Rune (Unicode scalar) count — the pure-Dart stand-in for Swift's
  /// `String.count` used by the context-window size comparisons.
  static int _runeCount(String s) => s.runes.length;
}
