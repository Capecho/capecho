import 'package:flutter/material.dart';

import '../design/chrome.dart';

/// Shared Review-card chrome — the offline/sync status badges + the card shell — so the macOS and
/// mobile review screens render them identically rather than as two copies. The shell's [radius] +
/// [padding] are the only per-platform difference (macOS 11 / (24,24,24,18); mobile 14 /
/// (20,22,20,18)), passed by the caller.

/// The "Offline · N queued" pill shown in the progress header while N grades sit in the offline queue.
Widget reviewOfflinePill(OnboardingPalette p, int n) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
  decoration: BoxDecoration(color: p.primary, borderRadius: BorderRadius.circular(20)),
  child: Text(
    'Offline · $n queued',
    style: p.chrome(size: 11, weight: FontWeight.w600, color: p.primaryFg),
  ),
);

/// A calm latte pill with a warning-toned dot — "Rated 'X' — saved, will sync", shown while a rating
/// sits in the offline queue (US-1.1 / US-12.1).
Widget reviewSyncBadge(OnboardingPalette p, String label) => Center(
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
    decoration: BoxDecoration(color: p.primarySoft, borderRadius: BorderRadius.circular(20)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: p.warning, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          'Rated “$label” — saved, will sync',
          style: p.chrome(size: 12, weight: FontWeight.w600, color: p.ink2),
        ),
      ],
    ),
  ),
);

/// The saved in-sentence "Explain here" gloss on a review card back (word-in-context + whole sentence) —
/// a warm left-rule callout attached under the captured sentence, mirroring the Word Book detail. Shared
/// so both clients render it identically; the caller gates on a non-empty gloss.
Widget reviewGlossCallout(OnboardingPalette p, String meaning, {double size = 14}) =>
    IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(width: 2, color: p.primary.withValues(alpha: 0.4)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              meaning,
              style: p.body(size: size, height: 1.5, color: p.ink2),
            ),
          ),
        ],
      ),
    );

/// The review flashcard's shell — the card surface + border + the stacked-paper soft-edge shadow.
/// [radius] + [padding] vary by platform (macOS 11 / (24,24,24,18); mobile 14 / (20,22,20,18)).
Widget reviewCardShell(
  OnboardingPalette p, {
  required List<Widget> children,
  double radius = 11,
  EdgeInsets padding = const EdgeInsets.fromLTRB(24, 24, 24, 18),
}) => Container(
  decoration: BoxDecoration(
    color: p.card,
    border: Border.all(color: p.line),
    borderRadius: BorderRadius.circular(radius),
    boxShadow: kSoftEdgeShadow,
  ),
  padding: padding,
  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
);
