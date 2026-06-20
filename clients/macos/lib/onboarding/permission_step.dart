import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import '../capture_shortcut_scope.dart';
import '../onboarding_art.dart';
import 'onboarding_chrome.dart';

// ---- Step 3 — permission ----

class PermissionStep extends StatefulWidget {
  const PermissionStep({
    super.key,
    required this.p,
    required this.busy,
    required this.alreadyGranted,
    required this.onEnable,
    required this.onSkip,
    required this.onOpenPrivacy,
  });
  final OnboardingPalette p;
  final bool busy;

  /// A preflight found Screen Recording already on — swap to the "ready"
  /// variant (no re-prompt; the CTA arms OCR and goes straight to rehearsal).
  final bool alreadyGranted;
  final Future<void> Function() onEnable;
  final VoidCallback onSkip;

  /// Opens the privacy explainer (the "Why does macOS call this 'Screen Recording'?" link).
  final Future<void> Function() onOpenPrivacy;
  @override
  State<PermissionStep> createState() => _PermissionState();
}

class _PermissionState extends State<PermissionStep> {
  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final granted = widget.alreadyGranted;
    final captureDisplay = CaptureShortcutScope.displayOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (granted) ...[
          const SizedBox(height: 16),
        ] else ...[
          ObKeyCombo(p: p, parts: captureKeyComboParts(captureDisplay)),
          const SizedBox(height: 18),
        ],
        Headline(
          granted ? 'On-device capture is ready.' : 'Capture words — privately, on your Mac.',
          p: p,
        ),
        const SizedBox(height: 12),
        const SizedBox(height: 20),
        // The IL-06 trust card and the privacy facts sit SIDE BY SIDE (a flex row) so the screen
        // doesn't read as a tall wall.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: LayoutBuilder(
            builder: (context, c) {
              final card = PermissionTrustCard(p: p, showEdit: !granted);
              final facts = _privacyColumn(p);
              if (c.maxWidth < 500) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [card, const SizedBox(height: 16), facts],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  card,
                  const SizedBox(width: 20),
                  Expanded(child: facts),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        // The "why Screen Recording" disclosure gets its OWN full-width line below
        // the side-by-side block, so it isn't cramped into the narrow right column.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 540),
          child: _whyScreenRecording(p),
        ),
        const SizedBox(height: 24),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ObPrimaryButton(
                p: p,
                label: granted ? 'Continue' : 'Allow on-device capture',
                busy: widget.busy,
                fullWidth: true,
                onPressed: widget.onEnable,
              ),
              // With Screen Recording already granted, the clipboard fallback is
              // moot — ⌥E already captures on-device — so the "use copy & paste"
              // escape only shows when capture isn't armed yet.
              if (!granted) ...[
                const SizedBox(height: 10),
                ObPrimaryButton(
                  p: p,
                  label: 'Use copy & paste instead',
                  filled: false,
                  fullWidth: true,
                  onPressed: widget.onSkip,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// The three privacy facts, as a left-aligned column that sits beside the IL-06
  /// trust card. (The "why Screen Recording" disclosure is a separate full-width
  /// line below the card — see [_whyScreenRecording] — so it isn't cramped here.)
  Widget _privacyColumn(OnboardingPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _privacyTick(p, 'On-device only'),
        _privacyTick(
          p,
          'Only the recognized text is read; the screen image never reaches Capecho.',
        ),
        _privacyTick(p, 'Nothing is uploaded — only what you save is kept.'),
      ],
    );
  }

  /// The "why does macOS call this Screen Recording?" link (US-ON.2) — centered on
  /// its own line; tapping it opens the privacy explainer in the browser.
  Widget _whyScreenRecording(OnboardingPalette p) {
    return Align(
      alignment: Alignment.center,
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: p.primary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          minimumSize: Size.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: p.chrome(size: 13, weight: FontWeight.w500),
        ),
        onPressed: () => widget.onOpenPrivacy(),
        child: const Text('Why does macOS call this “Screen Recording”?  ↗'),
      ),
    );
  }

  Widget _privacyTick(OnboardingPalette p, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 3, right: 10),
            child: Icon(Icons.check, size: 14, color: p.success),
          ),
          Expanded(
            child: Text(
              text,
              style: p
                  .chrome(size: 13, weight: FontWeight.w400, color: p.ink2)
                  .copyWith(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Step 2 branch — permission pending (prompt shown, awaiting the grant) ----

/// macOS shows the Screen-Recording prompt but `CGRequestScreenCaptureAccess`
/// returns `false` immediately and the grant only applies on relaunch — so a
/// fresh request lands here, not on the clipboard wall. We explain the exact
/// switch to flip, offer a re-check, and keep a non-blocking clipboard escape.
class PermissionPendingStep extends StatelessWidget {
  const PermissionPendingStep({
    super.key,
    required this.p,
    required this.busy,
    required this.notDetectedYet,
    required this.onRecheck,
    required this.onOpenSettings,
    required this.onSkip,
  });
  final OnboardingPalette p;
  final bool busy;

  /// A re-check came back still-not-granted → show the relaunch hint.
  final bool notDetectedYet;
  final Future<void> Function() onRecheck;
  final Future<void> Function() onOpenSettings;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final captureDisplay = CaptureShortcutScope.displayOf(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ObKeyCombo(p: p, parts: captureKeyComboParts(captureDisplay)),
        const SizedBox(height: 18),
        Headline('Turn on Screen Recording', p: p),
        const SizedBox(height: 12),
        Lede('macOS applies it after you turn it on and relaunch Capecho:', p: p),
        const SizedBox(height: 22),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: p.card,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: p.line),
              boxShadow: const [
                BoxShadow(color: Color(0x212B2320), blurRadius: 0, offset: Offset(4, 5)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _numStep(p, 1, 'Open System Settings → Privacy & Security → Screen Recording.'),
                _numStep(p, 2, 'Turn on Capecho.'),
                _numStep(p, 3, 'Reopen Capecho — $captureDisplay then captures in one press.'),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.ink,
                      side: BorderSide(color: p.line),
                      backgroundColor: p.card,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: () => onOpenSettings(),
                    child: Text(
                      'Open System Settings → Privacy & Security → Screen '
                      'Recording  ↗',
                      textAlign: TextAlign.center,
                      style: p.chrome(size: 13, weight: FontWeight.w500),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (notDetectedYet) ...[
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2, right: 8),
                  child: Icon(Icons.info_outline_rounded, size: 15, color: p.warning),
                ),
                Expanded(
                  child: Text(
                    'Not detected yet — quit and reopen Capecho, then try $captureDisplay.',
                    style: p
                        .chrome(size: 12.5, weight: FontWeight.w400, color: p.ink2)
                        .copyWith(height: 1.45),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ObPrimaryButton(
                p: p,
                label: 'I’ve enabled it',
                busy: busy,
                fullWidth: true,
                onPressed: onRecheck,
              ),
              const SizedBox(height: 10),
              ObPrimaryButton(
                p: p,
                label: 'Use copy & paste instead',
                filled: false,
                fullWidth: true,
                onPressed: onSkip,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _numStep(OnboardingPalette p, int n, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: p.primarySoft, shape: BoxShape.circle),
            child: Text(
              '$n',
              style: p.chrome(size: 12, weight: FontWeight.w600, color: p.primary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Text(text, style: p.body(size: 13.5, height: 1.45, color: p.ink2)),
            ),
          ),
        ],
      ),
    );
  }
}
