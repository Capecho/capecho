import 'dart:async';

import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import '../web/in_app_browser.dart';

/// The compact mobile "Upgrade to Pro" buy surface — a content-sized bottom sheet opened from
/// Settings → Subscription. Deliberately NOT the full editorial paywall (DESIGN DT6): a calm, functional
/// purchase entry with the two plans at their LIVE App Store prices, a Restore action, and the App Store
/// fine print. Prices come from StoreKit at runtime — never hard-coded — so they can't drift from what
/// App Store Connect charges. Built on the Caffeine library tokens (the warm card, coffee CTA, echo mark).
Future<void> showUpgradeSheet(BuildContext context, ProPurchaseController controller) {
  final p = OnboardingPalette.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: p.dark ? 0.52 : 0.34),
    builder: (sheetContext) => _UpgradeSheet(controller: controller),
  );
}

class _UpgradeSheet extends StatefulWidget {
  const _UpgradeSheet({required this.controller});

  final ProPurchaseController controller;

  @override
  State<_UpgradeSheet> createState() => _UpgradeSheetState();
}

class _UpgradeSheetState extends State<_UpgradeSheet> {
  @override
  void initState() {
    super.initState();
    // Clear a lingering justUpgraded one-shot (e.g. set by a Settings-level restore on an active sub)
    // BEFORE subscribing — otherwise it would pop this sheet the instant it opens. This does NOT notify,
    // so it's safe to run synchronously during the build.
    widget.controller.clearJustUpgraded();
    widget.controller.addListener(_onChange);
    // `clearError()` + `loadProducts()` NOTIFY the shared controller, which Settings also listens to —
    // notifying synchronously here (during this sheet's build) would mark those listeners dirty mid-build
    // → "setState() called during build". Defer past this frame (parity with the macOS paywall).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.controller.clearError();
      unawaited(widget.controller.loadProducts());
    });
  }

  void _onChange() {
    // A confirmed upgrade pops the sheet; the Settings row behind it now reads "Active".
    if (widget.controller.justUpgraded && mounted) {
      widget.controller.clearJustUpgraded();
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    final c = widget.controller;
    return AnimatedBuilder(
      animation: c,
      builder: (context, _) => Container(
        decoration: BoxDecoration(
          color: p.canvas,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: p.line),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: p.dark ? 0.5 : 0.16),
              blurRadius: 30,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _grabber(p),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Text('Capecho', style: p.display(size: 18, color: p.ink)),
                    Text('.', style: p.display(size: 18, color: p.primary)),
                    const SizedBox(width: 8),
                    ObEchoMark(color: p.primary, size: 22),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'Keep every word you meet.',
                  style: p.display(size: 25, color: p.ink).copyWith(height: 1.15),
                ),
                const SizedBox(height: 8),
                Text(
                  'Saving is free and unlimited. Pro lifts the one daily cap — unlimited in-context explanations, the word read inside your sentence.',
                  style: p
                      .chrome(size: 13.5, weight: FontWeight.w400, color: p.ink2)
                      .copyWith(height: 1.5),
                ),
                const SizedBox(height: 18),
                _body(p, c),
                const SizedBox(height: 14),
                // Privacy Policy + Terms of Use (EULA) inside the purchase flow itself — required for
                // auto-renewable subscriptions (App Store Review Guideline 3.1.2). Open in the in-app
                // browser, same as Settings → About. Always shown, regardless of store-availability state.
                _legalLinks(p),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _grabber(OnboardingPalette p) => Center(
    child: Container(
      width: 40,
      height: 4,
      decoration: BoxDecoration(
        color: p.ink3.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );

  Widget _body(OnboardingPalette p, ProPurchaseController c) {
    if (c.loadingProducts && !c.available) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(child: ObEchoMark(color: p.primary, size: 30)),
      );
    }
    if (!c.available) {
      // Store unreachable or the products aren't live in App Store Connect yet — never a dead button.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Pro isn’t available just yet. Please check back shortly.',
            style: p.chrome(size: 13, weight: FontWeight.w400, color: p.ink3).copyWith(height: 1.5),
          ),
          const SizedBox(height: 14),
          _closeButton(p),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (c.error != null) ...[
          Text(
            c.error!,
            style: p
                .chrome(size: 12.5, weight: FontWeight.w500, color: p.error)
                .copyWith(height: 1.4),
          ),
          const SizedBox(height: 12),
        ],
        Row(
          children: [
            if (c.productFor(ProPlan.monthly) != null)
              Expanded(
                child: _planButton(p, c, plan: ProPlan.monthly, label: 'Monthly', primary: true),
              ),
            if (c.productFor(ProPlan.monthly) != null && c.productFor(ProPlan.annual) != null)
              const SizedBox(width: 10),
            if (c.productFor(ProPlan.annual) != null)
              Expanded(
                child: _planButton(p, c, plan: ProPlan.annual, label: 'Annual', primary: false),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Center(
          child: TextButton(
            onPressed: c.isBusy ? null : () => unawaited(c.restore()),
            child: Text(
              'Restore purchases',
              style: p.chrome(size: 12.5, weight: FontWeight.w500, color: p.ink2),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Billed through the App Store · cancel anytime in Settings.',
          textAlign: TextAlign.center,
          style: p.chrome(size: 11, weight: FontWeight.w400, color: p.ink3),
        ),
      ],
    );
  }

  Widget _planButton(
    OnboardingPalette p,
    ProPurchaseController c, {
    required ProPlan plan,
    required String label,
    required bool primary,
  }) {
    final busy = c.busyPlan == plan;
    final disabled = c.isBusy;
    final fg = primary ? p.primaryFg : p.ink;
    final bg = primary ? p.primary : p.card;
    final price = c.priceOf(plan);
    return Opacity(
      opacity: disabled && !busy ? 0.6 : 1,
      child: Material(
        color: bg,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: p.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: InkWell(
          onTap: disabled ? null : () => unawaited(c.buy(plan)),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Center(
              child: busy
                  ? ObEchoLoader(color: fg, size: 22)
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: p.chrome(size: 14, weight: FontWeight.w600, color: fg),
                        ),
                        if (price != null) ...[
                          const SizedBox(height: 2),
                          Text(price, style: p.mono(size: 12.5, color: fg.withValues(alpha: 0.85))),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _legalLinks(OnboardingPalette p) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      _legalLink(p, label: 'Privacy Policy', url: CapechoLinks.privacyPolicy),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          '·',
          style: p.chrome(size: 11, weight: FontWeight.w400, color: p.ink3),
        ),
      ),
      _legalLink(p, label: 'Terms of Use', url: CapechoLinks.terms),
    ],
  );

  Widget _legalLink(OnboardingPalette p, {required String label, required String url}) => InkWell(
    onTap: () => openInAppBrowser(context, url: Uri.parse(url), title: label),
    borderRadius: BorderRadius.circular(4),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      child: Text(
        label,
        style: p
            .chrome(size: 11, weight: FontWeight.w500, color: p.ink2)
            .copyWith(decoration: TextDecoration.underline),
      ),
    ),
  );

  Widget _closeButton(OnboardingPalette p) => Align(
    alignment: Alignment.centerRight,
    child: OutlinedButton(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        side: BorderSide(color: p.line),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: p.chrome(size: 13, weight: FontWeight.w600),
      ),
      onPressed: () => Navigator.of(context).maybePop(),
      child: const Text('Close'),
    ),
  );
}
