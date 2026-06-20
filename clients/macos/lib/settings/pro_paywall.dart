import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

/// The shared editorial top of the Pro paywall card (DESIGN.md DT1) — the `Capecho.` masthead + echo
/// mark (with the optional close button), the headline, the subcopy, and the two mono-numbered unlock
/// rows. Shared by the macOS-direct **Stripe** paywall ([ProPaywall]) and the Mac App Store **IAP**
/// paywall ([ProPaywallIap]) so the brand copy + the unlocks can't drift between the two rails; each rail
/// supplies its own action footer (Stripe plan buttons vs StoreKit live-price buttons + Restore).
class ProPaywallEditorial extends StatelessWidget {
  const ProPaywallEditorial({super.key, required this.p, this.onClose});

  final OnboardingPalette p;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Capecho', style: p.display(size: 19, color: p.ink)),
            Text('.', style: p.display(size: 19, color: p.primary)),
            const SizedBox(width: 8),
            ObEchoMark(color: p.primary, size: 24),
            const Spacer(),
            if (onClose != null)
              IconButton(
                onPressed: onClose,
                icon: Icon(Icons.close, size: 18, color: p.ink3),
                splashRadius: 16,
                tooltip: 'Close',
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Keep every word you meet.',
          style: p.display(size: 28, color: p.ink).copyWith(height: 1.15),
        ),
        const SizedBox(height: 8),
        Text(
          'Saving is free and unlimited — keep every word you meet, with no ceiling on your '
          'library. The one metered feature is the in-context explanation; Pro removes its daily cap.',
          style: p.chrome(size: 14, weight: FontWeight.w400, color: p.ink2).copyWith(height: 1.5),
        ),
        const SizedBox(height: 20),
        _unlock(
          p,
          '01',
          'Unlimited in-context explanations',
          'The word as used in your exact sentence, any time — no daily limit.',
        ),
      ],
    );
  }
}

/// One mono-numbered unlock row — shared by the editorial block above. Top-level so both paywall rails
/// render an identical row.
Widget _unlock(OnboardingPalette p, String n, String title, String sub) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 22,
          child: Text(n, style: p.mono(size: 12, color: p.ink3)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: p.chrome(size: 14.5, weight: FontWeight.w500, color: p.ink),
              ),
              const SizedBox(height: 1),
              Text(
                sub,
                style: p
                    .chrome(size: 13, weight: FontWeight.w400, color: p.ink2)
                    .copyWith(height: 1.4),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Privacy Policy + Terms of Use links rendered INSIDE the purchase flow — required for auto-renewable
/// subscriptions (App Store Review Guideline 3.1.2). Shared by both paywall rails so the legal links
/// can't drift between them. [onOpen] is each rail's external-link seam: the Stripe paywall passes its
/// injected `openUrl`; the IAP paywall passes `capechoOpenExternal` (the same opener Settings → About
/// uses). Always shown, regardless of store-availability state.
class ProPaywallLegalLinks extends StatelessWidget {
  const ProPaywallLegalLinks({super.key, required this.p, required this.onOpen});

  final OnboardingPalette p;
  final void Function(Uri url) onOpen;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _link('Privacy Policy', CapechoLinks.privacyPolicy),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '·',
            style: p.chrome(size: 11.5, weight: FontWeight.w400, color: p.ink3),
          ),
        ),
        _link('Terms of Use', CapechoLinks.terms),
      ],
    );
  }

  Widget _link(String label, String url) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onOpen(Uri.parse(url)),
        child: Text(
          label,
          style: p
              .chrome(size: 11.5, weight: FontWeight.w500, color: p.ink2)
              .copyWith(decoration: TextDecoration.underline),
        ),
      ),
    );
  }
}

/// The Pro paywall (DESIGN.md DT1) — the macOS-**direct** Stripe buy surface, shown from Settings' free
/// "Subscription" row. Built 1:1 with the Caffeine library system (`caffeine-paywall.html`): a white
/// stacked-paper card on the warm canvas — Fraunces headline, the echo mark, mono-numbered unlocks (NOT a
/// SaaS card-grid), the coffee CTA. The brand rule "loud reads as cheap" → no gradients, no confetti.
///
/// The buy action calls [startCheckout] (→ `POST /billing/stripe/checkout`) for the chosen plan, then
/// opens the returned Stripe URL via [openUrl]; fulfillment is server-side (the webhook), so this never
/// asserts Pro. Until the backend's price ids + secret key are set it 503s → a calm inline error.
///
/// The Mac App Store build NEVER reaches this surface (Apple forbids external payment for digital
/// subscriptions) — it shows [ProPaywallIap] instead, selected by the distribution gate in Settings.
class ProPaywall extends StatefulWidget {
  const ProPaywall({
    super.key,
    required this.p,
    required this.startCheckout,
    required this.openUrl,
    this.onClose,
  });

  final OnboardingPalette p;

  /// Start a Checkout Session for the plan (`'monthly'` | `'annual'`) and return the Stripe URL.
  final Future<String> Function(String plan) startCheckout;

  /// Open the returned Stripe Checkout URL (the macOS app's external-link seam).
  final void Function(Uri url) openUrl;

  final VoidCallback? onClose;

  @override
  State<ProPaywall> createState() => _ProPaywallState();
}

class _ProPaywallState extends State<ProPaywall> {
  /// The plan whose checkout is in flight (`'monthly'`/`'annual'`), or null when idle.
  String? _busyPlan;
  String? _error;

  Future<void> _buy(String plan) async {
    if (_busyPlan != null) return;
    setState(() {
      _busyPlan = plan;
      _error = null;
    });
    try {
      final url = await widget.startCheckout(plan);
      if (!mounted) return;
      widget.openUrl(Uri.parse(url));
      // Leave the dialog open behind the browser: returning to it after paying, the user can close it;
      // the Settings row flips to "Active" once /auth/me refreshes (the webhook fulfilled the sub).
      setState(() => _busyPlan = null);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busyPlan = null;
        _error = 'Couldn’t start checkout — Pro isn’t available just yet. Try again shortly.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Container(
          decoration: BoxDecoration(
            color: p.card,
            border: Border.all(color: p.edge),
            borderRadius: BorderRadius.circular(3),
            boxShadow: kSoftEdgeShadow,
          ),
          padding: const EdgeInsets.fromLTRB(28, 26, 28, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProPaywallEditorial(p: p, onClose: widget.onClose),
              const SizedBox(height: 18),
              if (_error != null) ...[
                Text(
                  _error!,
                  style: p
                      .chrome(size: 12.5, weight: FontWeight.w500, color: p.error)
                      .copyWith(height: 1.4),
                ),
                const SizedBox(height: 12),
              ],
              Row(
                children: [
                  Expanded(
                    child: _planButton(p, plan: 'monthly', label: 'Monthly', primary: true),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _planButton(p, plan: 'annual', label: 'Annual', primary: false),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                // The price is the one Stripe charges — shown on the secure Checkout page, so the app
                // never displays a number it can't verify (and that could drift from the live Stripe
                // product). Pick a plan to see it.
                'You’ll see the price at secure Stripe checkout · cancel anytime.',
                style: p.chrome(size: 11.5, weight: FontWeight.w400, color: p.ink3),
              ),
              const SizedBox(height: 14),
              ProPaywallLegalLinks(p: p, onOpen: widget.openUrl),
            ],
          ),
        ),
      ),
    );
  }

  Widget _planButton(
    OnboardingPalette p, {
    required String plan,
    required String label,
    required bool primary,
  }) {
    final busy = _busyPlan == plan;
    final disabled = _busyPlan != null;
    final fg = primary ? p.primaryFg : p.ink;
    final bg = primary ? p.primary : p.card;
    return Opacity(
      opacity: disabled && !busy ? 0.6 : 1,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: p.edge),
          borderRadius: BorderRadius.circular(3),
        ),
        child: InkWell(
          onTap: disabled ? null : () => _buy(plan),
          borderRadius: BorderRadius.circular(3),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Center(
              child: busy
                  ? ObEchoLoader(color: fg, size: 20)
                  : Text(
                      label,
                      style: p.chrome(size: 14, weight: FontWeight.w600, color: fg),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
