import 'package:capecho_api/capecho_api.dart' show CapechoApi;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import '../notifications/notification_permissions.dart';
import '../review/review_screen.dart';
import '../settings/settings_screen.dart';
import '../word_book/word_book_screen.dart';
import 'capecho_sheet.dart';

/// The signed-in home. Capecho on the phone is the "echo" half — review on the couch — so the home **is**
/// the live [ReviewScreen]: it's always the main surface, never a tab. Settings and the Word Book are
/// reached from two floating glass buttons in the top corners (top-left Settings · top-right Word Book),
/// and each opens as a near-full-screen bottom popover ([showCapechoSheet]) over the dimmed Review. This
/// replaces the old three-tab `NavigationBar` shell.
///
/// Rebuilds under `app.dart`'s `AnimatedBuilder(animation: auth)`, so `explanationLanguage` and the corner
/// destinations stay current as the account changes (sign-in, a Settings save). The Review's own
/// `ReviewController` is created once and survives those rebuilds (its [State] persists), exactly as it
/// did inside the old `IndexedStack`.
class HomeShell extends StatelessWidget {
  const HomeShell({
    super.key,
    required this.auth,
    required this.api,
    required this.appearance,
    this.notifications,
    this.purchases,
    this.pendingReviewWord,
    this.reviewRefresh,
  });

  final AuthController auth;
  final CapechoApi api;

  /// The iOS Apple-IAP buy controller (app-lifetime, owned in `app.dart`), forwarded to Settings →
  /// Subscription so a free user can upgrade. Null on Android / in tests (no in-app buy entry there).
  final ProPurchaseController? purchases;

  /// A word the review widget deep-linked to, forwarded to [ReviewScreen] so it opens at the same word
  /// the widget showed. Null in tests / when there's no widget.
  final ValueNotifier<String?>? pendingReviewWord;

  /// Pinged on app resume (after widget grades drain) so the live [ReviewScreen] re-syncs its queue.
  /// Null in tests / when there's no resume wiring.
  final Listenable? reviewRefresh;

  /// Device-local Light/Dark/System controller, handed to the Settings popover's Appearance picker.
  final AppearanceController appearance;

  /// The notification-permission probe, forwarded to Settings → Reminders so it can warn (and offer a
  /// jump to the OS settings) when the daily reminder is on but notifications are disabled at the OS
  /// level. Null in tests / hosts without the gateway → the warning is simply never shown.
  final NotificationPermissions? notifications;

  /// Height of the top strip reserved for the floating corner buttons, so the Review's header (the `i / n`
  /// + progress row, when a card session is live) and its rest-state illustrations clear them.
  static const double _cornerStrip = 56;

  void _openWordBook(BuildContext context, String explanationLanguage) {
    showCapechoSheet(
      context,
      semanticLabel: 'Word Book',
      builder: (_) => WordBookScreen(api: api, explanationLanguage: explanationLanguage),
    );
  }

  void _openSettings(BuildContext context) {
    showCapechoSheet(
      context,
      semanticLabel: 'Settings',
      builder: (_) => SettingsScreen(
        auth: auth,
        appearance: appearance,
        notifications: notifications,
        purchases: purchases,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    final explanationLanguage = auth.account?.explanationLanguage ?? 'en';
    return Scaffold(
      backgroundColor: p.canvas,
      // Inset all edges: unlike the old tab shell, there's no bottom bar to sit under the home indicator,
      // so the Review's rating row needs the bottom safe inset itself.
      body: SafeArea(
        child: Stack(
          children: [
            // The live Review is the home, inset below the corner-button strip.
            Padding(
              padding: const EdgeInsets.only(top: _cornerStrip),
              child: ReviewScreen(
                api: api,
                explanationLanguage: explanationLanguage,
                pendingReviewWord: pendingReviewWord,
                reviewRefresh: reviewRefresh,
              ),
            ),
            Positioned(
              top: 8,
              left: 12,
              child: _CornerButton(
                p: p,
                icon: Icons.settings_outlined,
                tooltip: 'Settings',
                onTap: () => _openSettings(context),
              ),
            ),
            Positioned(
              top: 8,
              right: 12,
              child: _CornerButton(
                p: p,
                icon: Icons.menu_book_outlined,
                tooltip: 'Word Book',
                onTap: () => _openWordBook(context, explanationLanguage),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A floating circular glass button (warm card + hairline + the stacked-paper soft-edge shadow) — the
/// home's corner navigation. 44×44 touch target, circular ripple, tooltip + button semantics.
class _CornerButton extends StatelessWidget {
  const _CornerButton({
    required this.p,
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final OnboardingPalette p;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Container(
          decoration: BoxDecoration(
            color: p.card,
            shape: BoxShape.circle,
            border: Border.all(color: p.line),
            boxShadow: kSoftEdgeShadow,
          ),
          child: Material(
            color: Colors.transparent,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: SizedBox(width: 44, height: 44, child: Icon(icon, size: 20, color: p.ink2)),
            ),
          ),
        ),
      ),
    );
  }
}
