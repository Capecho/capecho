import 'package:capecho_api/capecho_api.dart' show Reading;
import 'package:flutter/material.dart';

import '../design/chrome.dart';
import 'pronunciation_display.dart';
import 'word_book_view.dart' show posNote;

/// Renders a heteronym's readings — one visually distinct MODULE per reading, separated by a
/// hairline, so the noun "object" and the verb "object" (or the two "bow"s) read as the different
/// words they are. Each module is the reading's pronunciation line (labels + decoration from the
/// target profile via [pronunciationParts] — "US /…/  UK /…/" for English, bare pinyin for Chinese)
/// over its POS chips. The reading carries NO meaning text — the word's one `summary` is the only
/// explanation text, rendered by the surface above these modules.
///
/// Used ONLY for a heteronym (`readings.length > 1`) — a single-reading word renders its
/// pronunciation inline at the headword. Shared by the Word Book detail on both clients (and
/// mirrored in the Swift capture overlay) so the meaning surfaces render a heteronym identically.
class ReadingModules extends StatelessWidget {
  const ReadingModules({
    super.key,
    required this.p,
    required this.readings,
    required this.targetLanguage,
    this.pronunciationSize = 14.5,
  });

  final OnboardingPalette p;
  final List<Reading> readings;

  /// The word's target language — drives the pronunciation labels/decoration (never hard-coded).
  final String targetLanguage;

  final double pronunciationSize;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final (i, r) in readings.indexed) _module(r, first: i == 0)],
    );
  }

  /// One reading's module: the `US /…/ UK /…/ · noun, adj.` line — the pronunciation parts with the
  /// reading's DISTINCT abbreviated POS riding as a quieter trailing note (overlay B-final; the POS
  /// rides the line for every word rather than a chip row). After the first, a hairline + top padding
  /// sets it apart as its own block.
  Widget _module(Reading r, {required bool first}) {
    final parts = pronunciationParts(
      targetLanguage: targetLanguage,
      primary: r.pronunciationPrimary,
      secondary: r.pronunciationSecondary,
    );
    final pos = posNote([for (final g in r.pos) g.partOfSpeech]);
    final body = Text.rich(
      TextSpan(
        children: [
          for (final part in parts) _pronunciationSpan(part),
          if (pos.isNotEmpty)
            TextSpan(
              text: parts.isEmpty ? pos : '· $pos',
              semanticsLabel: ' $pos',
              style: p.body(size: pronunciationSize, height: 1.5, color: p.ink3),
            ),
        ],
      ),
    );
    if (first) return body;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: body,
    );
  }

  /// One pronunciation part: `US /…/  ` (label per the target profile; absent = bare value).
  /// `semanticsLabel` keeps screen readers from spelling the glyphs (DR4).
  InlineSpan _pronunciationSpan(PronunciationPart part) => TextSpan(
    text: part.label == null ? '${part.display}  ' : '${part.label} ${part.display}  ',
    semanticsLabel: part.label == null ? ' pronunciation, ' : ' ${part.label} pronunciation, ',
    style: p.body(size: pronunciationSize, height: 1.5, color: p.ink3),
  );
}
