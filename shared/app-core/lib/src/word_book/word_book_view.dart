import 'package:capecho_api/capecho_api.dart' show WordFsrs;
import 'package:flutter/material.dart';

import '../design/chrome.dart';

/// Shared Word Book presentational helpers — the bits the catalog row, the word-detail header/snippets,
/// and the review card render identically across both clients, kept here (rather than duplicated per
/// client) so the two can't drift:
///   - the echo-mark **memory meter** (the level enum + the FSRS-projection → (level, "due") mapping +
///     the static echo widget), and
///   - the small row/label helpers (the POS chip, the neutral "phrase" tag, the in-sentence highlight,
///     and the terse capture/context date).
///
/// Each client keeps only its platform-specific extras (the macOS pre-login dashed-row painter + the
/// native save-panel `ExportFileSaver` typedef; the mobile share-sheet `ExportFileSharer` typedef).

/// The four echo-mark memory-meter levels: full = due now, then weakening, then settled.
enum MeterLevel { full, mid, low, settled }

/// Map a unit's server FSRS projection → (memory-meter level, "due" text), shared by the catalog-row
/// aside and the detail header. Full = due now; otherwise a more-stable card is more-settled
/// (mid → low → settled), with a "Due in …" hint. A null projection (never reviewed at this epoch)
/// → (null, null) so the meter shows its calm "not yet scheduled" placeholder.
(MeterLevel?, String?) meterFor(WordFsrs? fsrs, int nowMs) {
  if (fsrs == null) return (null, null);
  const dayMs = 86400000;
  final diff = fsrs.dueAt - nowMs;
  if (diff <= 0) {
    return (MeterLevel.full, 'Due now'); // due (or overdue) → the review-now level
  }
  // Not due yet: how settled, bucketed by FSRS stability (days to ~90% retention).
  final level = fsrs.stability >= 30
      ? MeterLevel.settled
      : (fsrs.stability >= 7 ? MeterLevel.low : MeterLevel.mid);
  // "in N days" / "in N months".
  final days = (diff / dayMs).ceil();
  final String due;
  if (days < 30) {
    due = days == 1 ? 'in 1 day' : 'in $days days';
  } else {
    final months = (days / 30).round();
    due = months == 1 ? 'in 1 month' : 'in $months months';
  }
  return (level, due);
}

/// The static echo-mark at a meter [level]; a null level is the calm "not yet scheduled" placeholder.
/// Static-fill — the memory meter is never animated (DESIGN.md's
/// motion=working / static-fill=memory rule). Callers pass the surface size (catalog row 18/19,
/// detail header 24).
Widget meterEcho(OnboardingPalette p, MeterLevel? level, {required double size}) {
  switch (level) {
    case MeterLevel.full:
      return ObEchoMark(color: p.primary, size: size);
    case MeterLevel.mid:
      return ObEchoMark(color: p.primary, size: size, ringOpacities: const [1, 0.6, 0.55]);
    case MeterLevel.low:
      return ObEchoMark(color: p.primary, size: size, ringOpacities: const [1, 0.4, 0.25]);
    case MeterLevel.settled:
      return ObEchoMark(color: p.ink3, size: size, ringOpacities: const [0.6, 0.6, 0.6]);
    case null:
      return ObEchoMark(color: p.ink3, size: size, ringOpacities: const [0.4, 0.4, 0.4]);
  }
}

// ── row / label helpers ──────────────────────────────────────────────────────

/// The standard dictionary abbreviation for a POS label (founder call: "noun"/"verb" stay full
/// words, "adjective" → "adj.", the learner's-dictionary convention). Mirrors the Swift overlay's
/// `OverlayReading.abbreviatePos` so the meaning surfaces render POS identically. The backend always
/// emits closed-set ENGLISH POS labels, so this map is English-only; an unknown label passes through
/// lowercased rather than guessing an abbreviation.
const Map<String, String> _posAbbreviations = {
  'noun': 'noun',
  'verb': 'verb',
  'adjective': 'adj.',
  'adverb': 'adv.',
  'phrasal verb': 'phr. verb',
  'preposition': 'prep.',
  'pronoun': 'pron.',
  'conjunction': 'conj.',
  'interjection': 'interj.',
  'determiner': 'det.',
  'particle': 'part.',
  'measure word': 'meas.',
  'idiom': 'idiom',
  'phrase': 'phrase',
};

String abbreviatePos(String pos) =>
    _posAbbreviations[pos.trim().toLowerCase()] ?? pos.trim().toLowerCase();

/// A reading's compact POS note for the one-line `US /…/ UK /…/ · noun, adj.` rendering (overlay
/// B-final, founder D1: the POS rides the reading line for EVERY word): the DISTINCT abbreviated
/// labels, first-seen order, case-insensitively deduped, joined with `, `. `''` when none. Mirrors
/// the Swift overlay's `OverlayReading.posLine`.
String posNote(List<String> partsOfSpeech) {
  final seen = <String>[];
  for (final raw in partsOfSpeech) {
    if (raw.trim().isEmpty) continue;
    final abbr = abbreviatePos(raw);
    if (!seen.any((s) => s.toLowerCase() == abbr.toLowerCase())) seen.add(abbr);
  }
  return seen.join(', ');
}

/// A small filled POS chip.
Widget chip(OnboardingPalette p, String text) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
  decoration: BoxDecoration(color: p.chip, borderRadius: BorderRadius.circular(8)),
  child: Text(
    text,
    style: p.chrome(size: 11, weight: FontWeight.w600, color: p.chipFg),
  ),
);

/// A neutral OUTLINED "phrase" tag (never a wrong POS label).
Widget phraseTag(OnboardingPalette p) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
  decoration: BoxDecoration(
    border: Border.all(color: p.line),
    borderRadius: BorderRadius.circular(5),
  ),
  child: Text(
    'phrase',
    style: p.chrome(size: 10, weight: FontWeight.w600, color: p.ink3, letterSpacing: 0.6),
  ),
);

/// The unit highlight inside a sentence: a calm primary-soft wash in primary ink, upright at weight
/// 500. Falls back to plain text for an out-of-range span
/// (CJK-safe — no lemma re-find).
Widget wbHighlight(
  OnboardingPalette p,
  String text,
  int? start,
  int? end, {
  double size = 15.5,
  bool italic = false,
  Color? baseColor,
  double height = 1.5,
  int? lineClamp,
}) {
  final base = p.body(
    size: size,
    height: height,
    color: baseColor ?? (italic ? p.ink : p.ink2),
    fontStyle: italic ? FontStyle.italic : null,
  );
  final valid = start != null && end != null && start >= 0 && end <= text.length && start < end;
  final maxLines = lineClamp;
  final overflow = lineClamp == null ? TextOverflow.clip : TextOverflow.ellipsis;
  if (!valid) {
    return Text(text, maxLines: maxLines, overflow: overflow, style: base);
  }
  final hl = base.copyWith(
    color: p.ink,
    backgroundColor: p.primarySoft,
    fontWeight: FontWeight.w500,
    fontStyle: FontStyle.normal,
  );
  return Text.rich(
    TextSpan(
      style: base,
      children: [
        TextSpan(text: text.substring(0, start)),
        TextSpan(text: text.substring(start, end), style: hl),
        TextSpan(text: text.substring(end)),
      ],
    ),
    maxLines: maxLines,
    overflow: overflow,
  );
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// A terse "Mon D" capture/context date.
String shortDate(int epochMs) {
  if (epochMs <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
  return '${_months[d.month - 1]} ${d.day}';
}
