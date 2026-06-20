import 'package:capecho_api/capecho_api.dart' show WordExplanation;
import 'package:flutter/material.dart';

import '../design/chrome.dart';
import '../sense_layout.dart';
import 'pronunciation_display.dart';
import 'word_book_view.dart' show abbreviatePos;

/// Renders a word explanation's per-POS bilingual SENSES (Phase 1) — the Flutter mirror of the macOS
/// capture overlay's reading blocks, so the Word Book detail and the Review card show the SAME format the
/// overlay does: one block per reading (a heteronym gets several, separated by a hairline) — the
/// reading's pronunciation line (labels + decoration from the target profile via [pronunciationParts])
/// or an `idiom` badge, then ONE LINE per part of speech: its abbreviated label + that POS's senses
/// joined with "; ", with any shared form [SensePosRow.note] once at the front. Every stored sense is
/// shown (uncapped); [showPronunciation] / [showPosLabels] trim the chrome for the minimal Review card.
class SenseModules extends StatelessWidget {
  const SenseModules({
    super.key,
    required this.p,
    required this.explanation,
    required this.targetLanguage,
    this.pronunciationSize = 15,
    this.senseSize = 16,
    this.senseColor,
    this.showPronunciation = true,
    this.showPosLabels = true,
  });

  final OnboardingPalette p;
  final WordExplanation explanation;

  /// The word's target language — drives the pronunciation labels/decoration (never hard-coded).
  final String targetLanguage;

  final double pronunciationSize;
  final double senseSize;

  /// The sense text colour (defaults to the primary ink); Review dims it to ink2.
  final Color? senseColor;

  /// Whether to render the pronunciation line. The Review card hides it (the reading sits in the head,
  /// keeping the answer minimal — E7); the Word Book detail shows it.
  final bool showPronunciation;

  /// Whether to render the POS label column. The Review card hides it (its head already shows the POS,
  /// so the body is a clean list of meanings); the Word Book detail shows it.
  final bool showPosLabels;

  @override
  Widget build(BuildContext context) {
    final layout = computeSenseLayout(explanation);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final (i, r) in layout.readings.indexed) _block(r, first: i == 0)],
    );
  }

  Widget _block(SenseReadingRow r, {required bool first}) {
    final head = r.isIdiom ? _idiomBadge() : (showPronunciation ? _pronunciationLine(r) : null);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (head != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: head),
        for (final pos in r.pos) _posRow(pos),
      ],
    );
    if (first) return content;
    // A later reading block: a hairline + top padding sets it apart as its own word (heteronym).
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: content,
    );
  }

  /// The pronunciation line — `US /…/  UK /…/` — or null when the reading has no transcription.
  Widget? _pronunciationLine(SenseReadingRow r) {
    final parts = pronunciationParts(
      targetLanguage: targetLanguage,
      primary: r.pronunciationPrimary,
      secondary: r.pronunciationSecondary,
    );
    if (parts.isEmpty) return null;
    return Text.rich(
      TextSpan(
        children: [
          for (final part in parts)
            TextSpan(
              text: part.label == null ? '${part.display}  ' : '${part.label} ${part.display}  ',
              semanticsLabel: part.label == null
                  ? ' pronunciation, '
                  : ' ${part.label} pronunciation, ',
              style: p.body(size: pronunciationSize, height: 1.4, color: p.ink3),
            ),
        ],
      ),
    );
  }

  Widget _idiomBadge() => Text(
    'idiom',
    style: p.chrome(size: 11, weight: FontWeight.w600, color: p.ink3),
  );

  /// One POS row: that part of speech's senses joined onto ONE line (matching the capture overlay), with
  /// any shared form note ([SensePosRow.note]) once at the front. When [showPosLabels] (the Word Book)
  /// the abbreviated label sits in a quiet italic left column; when not (Review, E7) the line stands
  /// alone and the head chip carries the POS.
  Widget _posRow(SensePosRow pos) {
    final joined = pos.senses.join('; ');
    final line = Text(
      pos.note.isEmpty ? joined : '(${pos.note}) $joined',
      style: p.body(size: senseSize, height: 1.45, color: senseColor ?? p.ink),
    );
    if (!showPosLabels) {
      return Padding(padding: const EdgeInsets.only(bottom: 4), child: line);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(
              abbreviatePos(pos.partOfSpeech),
              textAlign: TextAlign.right,
              style: p
                  .body(size: pronunciationSize, height: 1.45, color: p.ink2)
                  .copyWith(fontStyle: FontStyle.italic),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: line),
        ],
      ),
    );
  }
}
