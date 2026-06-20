/// Shape heuristic shared by the capture cascade (clipboard routing, US-4.2)
/// and the reconstructor (selection routing, Phase 2): does [text] read as a
/// full SENTENCE (route to the context) rather than a word / short phrase / 词组
/// (route to the unit)?
///
/// Deliberately simple — the overlay's inline edit is the safety net for a wrong
/// guess, so this is a heuristic, not a parser. A run is sentence-like when it
/// has more than [phraseWordCeiling] whitespace-separated words, OR carries
/// sentence-terminal punctuation with more than one TOKEN.
///
/// Sentence-like in three ways: more than [phraseWordCeiling] whitespace-separated
/// words; more than [cjkCharCeiling] CJK ideographs (a long space-free run); OR
/// sentence-terminal punctuation with more than one TOKEN.
///
/// "Token" is script-aware: whitespace words don't count CJK (no inter-word
/// spaces — every Chinese run would otherwise be a single "word"), so CJK runs are
/// bounded by an ideograph count instead. That keeps a selection-driven 词组
/// ("学习") a unit while routing a long clause ("我在学习中文很有意思") OR a
/// terminal-punctuated sentence ("我在学习中文。") to the context — the bound the
/// captured unit must respect (a sentence is never a word/short phrase). The CJK
/// ceiling mirrors the server `unitWithinBounds` ceiling so client + server agree.
library;

import 'tokenizer.dart';

final RegExp _whitespace = RegExp(r'\s+');
final RegExp _terminal = RegExp(r'[.!?。！？…]');

bool looksLikeSentence(String text, {int phraseWordCeiling = 4, int cjkCharCeiling = 8}) {
  final words = text.split(_whitespace).where((w) => w.isNotEmpty).length;
  if (words > phraseWordCeiling) return true;
  final han = Tokenizer.hanCharCount(text);
  // A long space-free CJK run is a clause, not a 词组 — whitespace word-count can't see it (always
  // ≤1 "word"), so bound ideograph length directly (mirrors the server unitWithinBounds CJK ceiling).
  if (han > cjkCharCeiling) return true;
  if (!_terminal.hasMatch(text)) return false;
  // Terminal punctuation marks a sentence — but a single word with a trailing period
  // ("serendipity.") is not one. Use the larger of the whitespace-word and CJK-ideograph counts so a
  // terminal-punctuated CJK run of >1 char counts as multi-token (whitespace alone sees 1).
  final tokens = words > han ? words : han;
  return tokens > 1;
}
