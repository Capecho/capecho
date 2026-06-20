import 'dart:async';

import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import 'pro_paywall.dart' show ProPaywallEditorial, ProPaywallLegalLinks;

/// The Mac App Store Pro paywall — the **Apple-IAP** buy surface shown from Settings'
/// "Subscription" row in the MAS build (the direct build shows the Stripe [ProPaywall] instead; the
/// distribution gate picks). The card chrome + the editorial copy/unlocks are the SHARED
/// [ProPaywallEditorial]; only the action footer differs: the two plans at their LIVE StoreKit prices, a
/// Restore action (App Store guideline 3.1.1), and the Apple-billing fine print.
///
/// It's driven by the app-lifetime [ProPurchaseController] (owned by the app shell so a redelivered
/// transaction verifies even with this closed). On open it lazily [ProPurchaseController.loadProducts];
/// on a confirmed upgrade ([ProPurchaseController.justUpgraded]) it closes itself — the Subscription row
/// flips to "Active" off the account refresh the controller already triggered. Prices come from StoreKit
/// at runtime (never hard-coded), so they can't drift from what App Store Connect charges.
class ProPaywallIap extends StatefulWidget {
  const ProPaywallIap({super.key, required this.p, required this.controller, this.onClose});

  final OnboardingPalette p;

  /// The shared, app-lifetime purchase controller. This surface only LISTENS to it (and triggers
  /// buy/restore/load) — it never disposes it (the shell owns its lifetime).
  final ProPurchaseController controller;

  final VoidCallback? onClose;

  @override
  State<ProPaywallIap> createState() => _ProPaywallIapState();
}

class _ProPaywallIapState extends State<ProPaywallIap> {
  @override
  void initState() {
    super.initState();
    // Clear a lingering `justUpgraded` one-shot (e.g. set by a Settings-level Restore on a still-active
    // sub) BEFORE subscribing — otherwise `_onChange` would close this paywall the instant it opens.
    // This does NOT notify, so it's safe to run synchronously during the build.
    widget.controller.clearJustUpgraded();
    widget.controller.addListener(_onChange);
    // `clearError()` + `loadProducts()` NOTIFY the shared controller, and Settings' AnimatedBuilders
    // listen to it too — notifying synchronously here (during the dialog's build) would mark them dirty
    // mid-build → "setState() called during build". Defer past this frame. `clearError` first because
    // `loadProducts` early-returns while a load is already in flight (so it can't be relied on to clear a
    // stale error — parity with the mobile sheet).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.clearError();
      unawaited(widget.controller.loadProducts());
    });
  }

  void _onChange() {
    if (!mounted) return;
    // A confirmed upgrade closes the paywall; the Subscription row flips to "Active" off the account
    // refresh the controller already kicked off. Consume the one-shot flag so it can't re-fire.
    if (widget.controller.justUpgraded) {
      widget.controller.clearJustUpgraded();
      widget.onClose?.call();
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final c = widget.controller;
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
              if (c.error != null) ...[
                Text(
                  c.error!,
                  style: p
                      .chrome(size: 12.5, weight: FontWeight.w500, color: p.error)
                      .copyWith(height: 1.4),
                ),
                const SizedBox(height: 12),
              ],
              _actionArea(p, c),
              const SizedBox(height: 14),
              // Legal links inside the purchase flow (Guideline 3.1.2). `capechoOpenExternal` is the same
              // opener Settings → About uses on macOS.
              ProPaywallLegalLinks(p: p, onOpen: capechoOpenExternal),
            ],
          ),
        ),
      ),
    );
  }

  /// The plan buttons (when there's something to buy), a calm loading row while StoreKit answers, or the
  /// "not available yet" line — plus the Restore action + Apple-billing fine print once loaded.
  Widget _actionArea(OnboardingPalette p, ProPurchaseController c) {
    if (c.available) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _planButton(
                  p,
                  c,
                  plan: ProPlan.monthly,
                  label: 'Monthly',
                  price: c.priceOf(ProPlan.monthly),
                  primary: true,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _planButton(
                  p,
                  c,
                  plan: ProPlan.annual,
                  label: 'Annual',
                  price: c.priceOf(ProPlan.annual),
                  primary: false,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _restoreRow(p, c),
          const SizedBox(height: 10),
          Text(
            'Billed through your Apple ID · cancel anytime in the App Store.',
            style: p.chrome(size: 11.5, weight: FontWeight.w400, color: p.ink3),
          ),
        ],
      );
    }
    if (c.loadingProducts) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            ObEchoLoader(color: p.ink3, size: 20),
            const SizedBox(width: 12),
            Text(
              'Loading plans…',
              style: p.chrome(size: 13, weight: FontWeight.w400, color: p.ink2),
            ),
          ],
        ),
      );
    }
    // Loaded but nothing to buy (the products aren't live in App Store Connect yet, or the store is
    // unreachable) — a calm line, never a dead button. Restore stays reachable (a sub bought elsewhere).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pro isn’t available just yet — please check back shortly.',
          style: p
              .chrome(size: 13.5, weight: FontWeight.w400, color: p.ink2)
              .copyWith(height: 1.45),
        ),
        const SizedBox(height: 12),
        _restoreRow(p, c),
      ],
    );
  }

  Widget _restoreRow(OnboardingPalette p, ProPurchaseController c) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: c.isBusy ? null : () => unawaited(c.restore()),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: c.restoring
            ? ObEchoLoader(color: p.primary, size: 18)
            : Text(
                'Restore purchase',
                style: p.chrome(size: 12.5, weight: FontWeight.w500, color: p.primary),
              ),
      ),
    );
  }

  Widget _planButton(
    OnboardingPalette p,
    ProPurchaseController c, {
    required ProPlan plan,
    required String label,
    required String? price,
    required bool primary,
  }) {
    final busy = c.busyPlan == plan;
    final disabled = c.isBusy;
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
          onTap: disabled ? null : () => unawaited(c.buy(plan)),
          borderRadius: BorderRadius.circular(3),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Center(
              child: busy
                  ? ObEchoLoader(color: fg, size: 20)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: p.chrome(size: 14, weight: FontWeight.w600, color: fg),
                        ),
                        if (price != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            price,
                            style: p
                                .chrome(size: 12, weight: FontWeight.w400, color: fg)
                                .copyWith(color: fg.withValues(alpha: primary ? 0.92 : 0.7)),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
