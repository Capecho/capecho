// Drift guard: the app's [OnboardingPalette] is a hand-port of the design tokens
// (`design/tokens.css`). The generated Dart port
// (`shared/design-tokens/generated/capecho_tokens.dart`) is the source of
// truth, but it isn't a Dart package the client can depend on yet — so the palette
// is transcribed by hand. This test asserts the transcription is exact for every
// shared field, in both brightnesses, so a `tokens.css` change that's regenerated
// but not reflected in [OnboardingPalette] fails here instead of shipping stale
// colors. Imported by relative path (the generated file is a loose artifact, not a
// package); making it a real dependency is the follow-up that retires this guard.
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../shared/design-tokens/generated/capecho_tokens.dart';

void main() {
  // The fields OnboardingPalette carries, mapped to their CapechoColors source. The
  // overlay-only tokens (ovlInk3 / ovlActiveFg / ovlActiveBg) aren't on the app palette
  // — the native capture overlay owns those — so they're intentionally not checked here.
  void expectMatches(String mode, OnboardingPalette p, CapechoColors t) {
    final pairs = <String, (Object, Object)>{
      'canvas': (p.canvas, t.appCanvas),
      'card': (p.card, t.appCard),
      'titlebar': (p.titlebar, t.appTitlebar),
      'ink': (p.ink, t.appInk),
      'ink2': (p.ink2, t.appInk2),
      'ink3': (p.ink3, t.appInk3),
      'line': (p.line, t.appLine),
      'edge': (p.edge, t.appEdge),
      'primary': (p.primary, t.appPrimary),
      'primaryFg': (p.primaryFg, t.appPrimaryFg),
      'primarySoft': (p.primarySoft, t.appPrimarySoft),
      'chip': (p.chip, t.appChip),
      'chipFg': (p.chipFg, t.appChipFg),
      'success': (p.success, t.success),
      'warning': (p.warning, t.warning),
      'error': (p.error, t.error),
      'info': (p.info, t.info),
      'ovlTint': (p.ovlTint, t.ovlTint),
      'ovlEdge': (p.ovlEdge, t.ovlEdge),
      'ovlInk': (p.ovlInk, t.ovlInk),
      'ovlInk2': (p.ovlInk2, t.ovlInk2),
      'ovlRule': (p.ovlRule, t.ovlRule),
      'ovlDivider': (p.ovlDivider, t.ovlDivider),
      'ovlAccent': (p.ovlAccent, t.ovlAccent),
      'ovlSaveEdge': (p.ovlSaveEdge, t.ovlSaveEdge),
    };
    for (final entry in pairs.entries) {
      final (palette, token) = entry.value;
      expect(
        palette,
        token,
        reason:
            '$mode.${entry.key} drifted from the generated token — '
            'regenerate shared/design-tokens or update OnboardingPalette to match.',
      );
    }
  }

  test('light OnboardingPalette matches the generated CapechoColors.light', () {
    expectMatches('light', OnboardingPalette.lightForTest, CapechoColors.light);
  });

  test('dark OnboardingPalette matches the generated CapechoColors.dark', () {
    expectMatches('dark', OnboardingPalette.darkForTest, CapechoColors.dark);
  });
}
