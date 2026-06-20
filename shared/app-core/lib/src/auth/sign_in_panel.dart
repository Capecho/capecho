import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../design/chrome.dart';
import 'auth_controller.dart';

/// The shared sign-in panel: Apple / Google provider buttons + an inline email one-time-code flow,
/// driven by [AuthController]. Used by BOTH onboarding step 4 and the signed-out Settings account
/// section so there is ONE sign-in UI (no duplicated provider/email logic).
///
/// It renders only the providers-or-email body plus an inline error; the surrounding chrome
/// (headlines, step dots, "Later", the signed-in confirmation) belongs to each host. It wraps itself
/// in an [AnimatedBuilder] on [auth], so it reflects busy / error / codeSent without the host having
/// to. Apple is offered on iOS and the macOS App Store build (the directly-distributed Developer-ID
/// macOS app can't use Sign in with Apple); Google + email are always shown. An unconfigured provider
/// surfaces a calm "not set up yet" steer to email rather than failing (the controller maps
/// [SocialSignInUnavailable] to that message).
class SignInPanel extends StatefulWidget {
  const SignInPanel({
    super.key,
    required this.p,
    required this.auth,
    this.maxWidth = 360,
    this.appleAvailable,
  });

  final OnboardingPalette p;
  final AuthController auth;

  /// Caps the panel width so the buttons/fields don't stretch edge-to-edge in a wide window.
  final double maxWidth;

  /// Whether to offer "Continue with Apple". When null, defaults to iOS-only (Sign in with Apple is a
  /// native iOS capability). The macOS **App Store** build passes `true` — its provisioning profile
  /// carries the `applesignin` entitlement — while the directly-distributed Developer-ID build passes
  /// `false` (Apple forbids that entitlement there). Google + email are always shown.
  final bool? appleAvailable;

  @override
  State<SignInPanel> createState() => _SignInPanelState();
}

class _SignInPanelState extends State<SignInPanel> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _emailMode = false;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    return AnimatedBuilder(
      animation: widget.auth,
      builder: (context, _) {
        final auth = widget.auth;
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.maxWidth),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _emailMode ? _emailFlow(p, auth) : _providers(context, p, auth),
              if (auth.error != null) ...[const SizedBox(height: 12), _errorRow(p, auth.error!)],
            ],
          ),
        );
      },
    );
  }

  Widget _providers(BuildContext context, OnboardingPalette p, AuthController auth) {
    // Whether to show "Continue with Apple". Defaults to iOS-only; the macOS App Store build passes
    // `appleAvailable: true` (its MAS provisioning profile carries the applesignin entitlement). The
    // directly-distributed Developer-ID macOS build can't use it (Apple forbids that entitlement there),
    // so it passes false. Google + email are always shown.
    final showApple = widget.appleAvailable ?? (Theme.of(context).platform == TargetPlatform.iOS);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showApple) ...[
          // Apple is the emphasized (primary-fill) provider on iOS — the mockup's `.provider--primary`;
          // its monochrome glyph is tinted to the primary foreground.
          _ProviderButton(
            p: p,
            svg: _kAppleGlyph,
            label: 'Continue with Apple',
            primary: true,
            onPressed: auth.busy ? null : auth.signInWithApple,
          ),
          const SizedBox(height: 10),
        ],
        _ProviderButton(
          p: p,
          svg: _kGoogleGlyph,
          tintIcon: false, // keep Google's four brand colors
          label: 'Continue with Google',
          onPressed: auth.busy ? null : auth.signInWithGoogle,
        ),
        const SizedBox(height: 14),
        _orSep(p),
        const SizedBox(height: 14),
        _ProviderButton(
          p: p,
          svg: _kEmailGlyph,
          label: 'Continue with email',
          onPressed: auth.busy
              ? null
              : () {
                  auth.resetEmailFlow();
                  setState(() => _emailMode = true);
                },
        ),
      ],
    );
  }

  Widget _emailFlow(OnboardingPalette p, AuthController auth) {
    if (auth.codeSent) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter the 6-digit code we sent to ${auth.pendingEmail}.',
            style: p.body(size: 14, height: 1.45, color: p.ink2),
          ),
          const SizedBox(height: 12),
          _field(
            p,
            _code,
            hint: '6-digit code',
            keyboardType: TextInputType.number,
            onSubmit: () => auth.verifyEmail(_code.text),
          ),
          const SizedBox(height: 12),
          ObPrimaryButton(
            p: p,
            label: 'Verify & sign in',
            busy: auth.busy,
            fullWidth: true,
            onPressed: () => auth.verifyEmail(_code.text),
          ),
          const SizedBox(height: 8),
          ObQuietButton(
            p: p,
            label: 'Use a different email',
            onPressed: auth.busy
                ? () {}
                : () {
                    _code.clear();
                    auth.resetEmailFlow();
                  },
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _field(
          p,
          _email,
          hint: 'you@example.com',
          keyboardType: TextInputType.emailAddress,
          onSubmit: () => auth.startEmail(_email.text),
        ),
        const SizedBox(height: 12),
        ObPrimaryButton(
          p: p,
          label: 'Send code',
          busy: auth.busy,
          fullWidth: true,
          onPressed: () => auth.startEmail(_email.text),
        ),
        const SizedBox(height: 8),
        ObQuietButton(p: p, label: 'Back', onPressed: () => setState(() => _emailMode = false)),
      ],
    );
  }

  Widget _field(
    OnboardingPalette p,
    TextEditingController controller, {
    required String hint,
    required TextInputType keyboardType,
    required VoidCallback onSubmit,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      autocorrect: false,
      enableSuggestions: false,
      style: p.body(size: 15, color: p.ink),
      onSubmitted: (_) => onSubmit(),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: p.body(size: 15, color: p.ink3),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        filled: true,
        fillColor: p.card,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: p.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: p.primary, width: 1.6),
        ),
      ),
    );
  }

  Widget _orSep(OnboardingPalette p) {
    return Row(
      children: [
        Expanded(child: Divider(color: p.line, height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'OR',
            style: p.chrome(size: 11, color: p.ink3, letterSpacing: 0.08 * 11),
          ),
        ),
        Expanded(child: Divider(color: p.line, height: 1)),
      ],
    );
  }

  Widget _errorRow(OnboardingPalette p, String message) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1, right: 8),
          child: Icon(Icons.error_outline_rounded, size: 16, color: p.warning),
        ),
        Expanded(
          child: Text(
            message,
            style: p
                .chrome(size: 12.5, weight: FontWeight.w400, color: p.warning)
                .copyWith(height: 1.4),
          ),
        ),
      ],
    );
  }
}

/// A full-width provider button matching the mockup `.provider`: a warm card surface (or the primary
/// coffee fill for the emphasized provider) + a hard shadow-edge the press translates into, an 18px
/// brand glyph, and a centered bold label. A null [onPressed] disables + dims it. The native provider
/// sheet is its own progress indicator, so there's no in-button spinner.
class _ProviderButton extends StatefulWidget {
  const _ProviderButton({
    required this.p,
    required this.label,
    required this.onPressed,
    required this.svg,
    this.primary = false,
    this.tintIcon = true,
  });
  final OnboardingPalette p;
  final String label;
  final VoidCallback? onPressed;

  /// The brand glyph as an inline SVG string. [tintIcon] tints it to the label color (Apple/email);
  /// false keeps the source colors (Google's four-color "G").
  final String svg;
  final bool tintIcon;

  /// The emphasized provider (`.provider--primary`): primary fill + primary-fg label + the stronger
  /// edge. The others are the card-surface `.provider`.
  final bool primary;

  @override
  State<_ProviderButton> createState() => _ProviderButtonState();
}

class _ProviderButtonState extends State<_ProviderButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final enabled = widget.onPressed != null;
    final fg = widget.primary ? p.primaryFg : p.ink;
    final bg = widget.primary ? p.primary : p.card;
    final rest = widget.primary ? 3.0 : 2.0;
    final offset = _pressed ? (rest > 2 ? 1.0 : 0.0) : rest;
    void press(bool v) {
      if (enabled) setState(() => _pressed = v);
    }

    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          onTapDown: (_) => press(true),
          onTapUp: (_) => press(false),
          onTapCancel: () => press(false),
          onTap: enabled ? widget.onPressed : null,
          child: Semantics(
            button: true,
            label: widget.label,
            enabled: enabled,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 90),
              transform: Matrix4.translationValues(_pressed ? 2 : 0, _pressed ? 2 : 0, 0),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(8),
                border: widget.primary ? null : Border.all(color: p.line),
                boxShadow: [BoxShadow(color: p.edge, offset: Offset(offset, offset))],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SvgPicture.string(
                    widget.svg,
                    width: 18,
                    height: 18,
                    colorFilter: widget.tintIcon ? ColorFilter.mode(fg, BlendMode.srcIn) : null,
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      widget.label,
                      overflow: TextOverflow.ellipsis,
                      style: p.chrome(size: 15, weight: FontWeight.w600, color: fg),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// Brand glyphs from DESIGN.md (state 1). Apple + email are monochrome
// (tinted to the label color); Google keeps its four brand colors.
const String _kAppleGlyph =
    '<svg viewBox="0 0 22 22" fill="currentColor"><path d="M15.07 11.66c-.02-2 1.63-2.96 1.7-3.01-.93-1.36-2.37-1.54-2.88-1.56-1.23-.12-2.39.72-3.01.72-.62 0-1.58-.7-2.6-.68-1.34.02-2.57.78-3.26 1.97-1.39 2.41-.36 5.98 1 7.94.66.96 1.45 2.03 2.49 1.99 1-.04 1.38-.65 2.59-.65s1.55.65 2.61.63c1.08-.02 1.76-.98 2.42-1.94.76-1.11 1.07-2.19 1.09-2.25-.02-.01-2.09-.8-2.11-3.18zM13.1 5.79c.55-.67.92-1.6.82-2.53-.79.03-1.75.53-2.32 1.2-.51.58-.96 1.53-.84 2.43.88.07 1.79-.45 2.34-1.1z"/></svg>';
const String _kGoogleGlyph =
    '<svg viewBox="0 0 48 48"><path fill="#4285F4" d="M45.12 24.5c0-1.56-.14-3.06-.4-4.5H24v8.51h11.84c-.51 2.75-2.06 5.08-4.39 6.64v5.52h7.11c4.16-3.83 6.56-9.47 6.56-16.17z"/><path fill="#34A853" d="M24 46c5.94 0 10.92-1.97 14.56-5.33l-7.11-5.52c-1.97 1.32-4.49 2.1-7.45 2.1-5.73 0-10.58-3.87-12.31-9.07H4.34v5.7C7.96 41.07 15.4 46 24 46z"/><path fill="#FBBC05" d="M11.69 28.18c-.44-1.32-.69-2.73-.69-4.18s.25-2.86.69-4.18v-5.7H4.34A21.99 21.99 0 0 0 2 24c0 3.55.85 6.91 2.34 9.88l7.35-5.7z"/><path fill="#EA4335" d="M24 10.75c3.23 0 6.13 1.11 8.41 3.29l6.31-6.31C34.91 4.18 29.93 2 24 2 15.4 2 7.96 6.93 4.34 14.12l7.35 5.7c1.73-5.2 6.58-9.07 12.31-9.07z"/></svg>';
const String _kEmailGlyph =
    '<svg viewBox="0 0 22 22" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="4.5" width="17" height="13" rx="2"/><path d="M3 6l8 5.5L19 6"/></svg>';
