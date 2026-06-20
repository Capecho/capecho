import 'dart:async';

import 'package:capecho_api/capecho_api.dart' show CapechoApi, ClaimRow;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'auth/secure_session_store.dart';
import 'backend.dart';
import 'home/home_shell.dart';
import 'notifications/local_notifications_gateway.dart';
import 'sign_in/sign_in_screen.dart';
import 'theme.dart';
import 'widget/widget_sync.dart';

/// The mobile app root. Capecho on the phone is the "echo" half — review + reminders — so the shell is
/// small: build the shared API client + auth controller, restore a persisted session, then route
/// signed-out → sign-in and signed-in → the review tabs. It also owns the daily-reminder wiring
/// (US-14.1): a [ReminderScheduler] over a [LocalNotificationsGateway], re-evaluated on sign-in/out,
/// preference changes, and app resume.
class CapechoApp extends StatelessWidget {
  const CapechoApp({super.key, required this.appearance, this.timezoneName});

  /// Device-local Light/Dark/System controller, owned above [MaterialApp] (in `main`) so a change in
  /// Settings → Appearance flips `themeMode` and repaints every surface live.
  final AppearanceController appearance;

  /// The device's IANA timezone (resolved in `main`), stamped on the account at first sign-in so the
  /// server's review-day boundary matches the phone. Null → the account defaults to UTC.
  final String? timezoneName;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) => MaterialApp(
        title: 'Capecho',
        debugShowCheckedModeBanner: false,
        theme: capechoTheme(Brightness.light),
        darkTheme: capechoTheme(Brightness.dark),
        themeMode: appearance.mode,
        home: _RootGate(appearance: appearance, timezoneName: timezoneName),
      ),
    );
  }
}

class _RootGate extends StatefulWidget {
  const _RootGate({required this.appearance, this.timezoneName});

  final AppearanceController appearance;
  final String? timezoneName;

  @override
  State<_RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<_RootGate> with WidgetsBindingObserver {
  late final CapechoApi _api;
  late final SecureSessionStore _store;
  late final AuthController _auth;
  late final LocalNotificationsGateway _notifications;
  late final ReminderScheduler _reminders;
  late final WidgetSync _widgetSync;

  /// The iOS Apple-IAP Pro buy controller — created only on iOS (Android buys Pro on the web; tests pass
  /// none). App-lifetime so its purchase-stream subscription catches transactions the App Store
  /// redelivers (an interrupted buy, an Ask-to-Buy approval, a restore) even with the upgrade sheet closed.
  ProPurchaseController? _purchases;

  bool _restoring = true;

  /// Tracks the signed-in edge so [_dismissPopoversOnSignOut] only fires on the signed-in → signed-out
  /// transition (not on every auth notify, which would break the signed-out sign-in flow).
  bool _wasSignedIn = false;

  /// A SEPARATE sign-in edge tracker for the review-widget publish/clear — [_wasSignedIn] is consumed
  /// (and reset) by the popover dismissal, so sharing it would make the two listeners order-dependent.
  bool _widgetWasSignedIn = false;

  /// A word a review-widget tap asked to open at — handed to [HomeShell] → [ReviewScreen] → the
  /// controller's `focusWord`, so the app opens at the SAME word the widget showed.
  final ValueNotifier<String?> _pendingReviewWord = ValueNotifier<String?>(null);

  /// Bumped on app resume after the widget grades drain, so the live Review re-syncs its queue to
  /// current server truth (cards reviewed in the widget / on another device drop out). The value is a
  /// monotonic tick — the ReviewScreen reacts to the change, not the number.
  final ValueNotifier<int> _reviewRefreshTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _api = buildCapechoApi();
    _store = SecureSessionStore();
    _auth = AuthController(
      api: _api,
      store: _store,
      // Mobile has no local captures (capture is macOS), so there's nothing to claim on sign-in.
      collectClaimRows: () async => const <ClaimRow>[],
      installId: _store.installId,
      // The native flows live in capecho_app_core/social_credentials.dart; this app supplies the ids.
      // Apple is offered on iOS only (SignInPanel hides it elsewhere, so this is never called there).
      appleCredential: appleIdentityToken,
      googleCredential: () => googleIdToken(
        clientId: kGoogleIosClientId.isEmpty ? null : kGoogleIosClientId,
        serverClientId: kGoogleServerClientId.isEmpty ? null : kGoogleServerClientId,
      ),
      // Stamp the device's IANA timezone on the account at first sign-in so the server's review-day
      // boundary (and thus what counts as "due") matches the phone (US-14.1); null defaults to UTC.
      timezoneName: widget.timezoneName,
    );

    // Daily review reminder (US-14.1): the shared policy over the local-notification gateway. The
    // gateway's tap-through jumps to Review; the scheduler arms/cancels per the account preference +
    // a due look-ahead.
    _notifications = LocalNotificationsGateway();
    _reminders = ReminderScheduler(
      notifications: _notifications,
      loadWords: () => _api.listWords(),
      // Mobile prompts only from Settings when the user turns Daily reminder on. Background auth
      // restore / sync must never surprise-prompt.
      requestPermissionBeforeScheduling: false,
    );
    WidgetsBinding.instance.addObserver(this);
    unawaited(_notifications.init(onSelectNotification: _onReminderTap));
    // Re-evaluate the reminder whenever the session or its preferences change (sign-in/out, a Settings
    // save applied via `applyAccount`). Cheap: unchanged preferences are short-circuited.
    _auth.addListener(_syncReminders);
    // On sign-out, drop any popover (Settings / Word Book) still open over the home so it isn't left
    // floating over the sign-in screen (the home content swaps below the modal, which lives on the root
    // navigator and wouldn't otherwise be dismissed).
    _auth.addListener(_dismissPopoversOnSignOut);

    // The home-screen review widget (iOS): publish a snapshot on sign-in, clear on sign-out, drain its
    // grades + republish on resume, and route its capecho:// taps. No-op on Android (no widget surface).
    _widgetSync = WidgetSync(api: _api, onReviewDeepLink: _onWidgetReview);
    unawaited(_widgetSync.startDeepLinks());
    _auth.addListener(_syncWidget);

    // The Pro buy controller (iOS only): app-lifetime so a StoreKit transaction the App Store redelivers
    // (interrupted buy / Ask-to-Buy / restore) is verified even with Settings closed. verify → POST
    // /billing/apple/verify; on success refresh the account so every surface flips to Pro. Android sells
    // Pro on the web (Play anti-steering), so it has no in-app controller.
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      _purchases = ProPurchaseController(
        backend: InAppPurchaseBackend(),
        verify: _api.verifyApplePurchase,
        onEntitlementChanged: _auth.refreshAccount,
        currentAccountId: () => _auth.account?.id,
      );
    }

    _restore();
  }

  /// Pop any open popovers when the session ends. Modal sheets ([showCapechoSheet], the delete-account
  /// sheet) sit on the root navigator, ABOVE the [_RootGate] home content — so swapping `HomeShell` →
  /// `SignInScreen` doesn't remove them. Fires only on the signed-in → signed-out edge (so it never
  /// interferes with routes the signed-out sign-in flow pushes), covering sign-out, account deletion,
  /// and a 401-triggered sign-out alike.
  void _dismissPopoversOnSignOut() {
    final signedIn = _auth.isSignedIn;
    final justSignedOut = _wasSignedIn && !signedIn;
    _wasSignedIn = signedIn;
    if (!justSignedOut) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      if (navigator.canPop()) navigator.popUntil((r) => r.isFirst);
    });
  }

  /// A tapped reminder opens Review. The home **is** Review now, so there's no tab to select — we just
  /// pop any open popover (Word Book / Settings, and anything pushed above them) back to the first route,
  /// revealing the live Review the OS just foregrounded. (Reminders only fire while signed in, so the
  /// HomeShell — and this navigator — is mounted.)
  void _onReminderTap(String payload) {
    if (payload == 'review' && mounted) {
      Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  void _syncReminders() {
    unawaited(_reminders.sync(signedIn: _auth.isSignedIn, account: _auth.account));
  }

  /// The account's gloss language for the widget snapshot's meanings (English when unset).
  String get _explanationLanguage => _auth.account?.explanationLanguage ?? 'en';

  /// On the sign-in/out EDGE: publish the widget snapshot when signed in, clear it when signed out (so a
  /// different account can't inherit the previous user's words / un-synced grades). Non-edge notifies skip.
  void _syncWidget() {
    final signedIn = _auth.isSignedIn;
    if (signedIn == _widgetWasSignedIn) return;
    _widgetWasSignedIn = signedIn;
    unawaited(signedIn ? _widgetSync.publish(_explanationLanguage) : _widgetSync.clear());
  }

  /// A tapped review widget opens the app at the SAME word it was showing: stash the wordId for the
  /// ReviewScreen to jump to, then pop any open popover to reveal Review (the home) under it.
  void _onWidgetReview(ReviewDeepLink link) {
    if (!mounted) return;
    if (link.wordId != null) _pendingReviewWord.value = link.wordId;
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _restore() async {
    await _auth.restore();
    // A reminder cold-start lands on Review with no extra work: Review is the home now (no tab to
    // select), and nothing is pushed over it on launch.
    if (mounted) setState(() => _restoring = false);
    // Arm/cancel once the restored session is known (restore's notify usually covers this; this is the
    // belt-and-braces call for the no-token path, where restore doesn't notify).
    _syncReminders();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On resume the due picture may have moved (cards came due, or the user reviewed elsewhere) — force
    // a re-check so "no nag when nothing is due" stays honest without spamming the network otherwise.
    if (state == AppLifecycleState.resumed) {
      unawaited(_reminders.sync(signedIn: _auth.isSignedIn, account: _auth.account, force: true));
      // Drain any grades made in the widget while away (which re-publishes a fresh snapshot), then
      // re-sync the live Review so whatever was reviewed there — or on another device — drops out.
      if (_auth.isSignedIn) unawaited(_drainWidgetThenRefreshReview());
    }
  }

  /// Resume routine: flush the widget's grades to the server, THEN ping the Review to re-sync. Ordering
  /// matters — the drain must land on the server before the re-fetch, or a card just graded in the
  /// widget would come back. The refresh runs even if the drain throws (it reflects whatever IS on the
  /// server); a still-unsynced grade stays queued and re-shows until it lands — the correct offline state.
  Future<void> _drainWidgetThenRefreshReview() async {
    try {
      await _widgetSync.onForeground(_explanationLanguage);
    } catch (_) {
      // best-effort — the refresh below still reflects current server truth
    }
    _reviewRefreshTick.value++;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _auth.removeListener(_syncReminders);
    _auth.removeListener(_dismissPopoversOnSignOut);
    _auth.removeListener(_syncWidget);
    _widgetSync.dispose();
    _pendingReviewWord.dispose();
    _reviewRefreshTick.dispose();
    _purchases?.dispose();
    _auth.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    if (_restoring) {
      return Scaffold(
        backgroundColor: p.canvas,
        body: Center(child: ObEchoLoader(color: p.primary, size: 44)),
      );
    }
    return AnimatedBuilder(
      animation: _auth,
      builder: (context, _) => _auth.isSignedIn
          ? HomeShell(
              auth: _auth,
              api: _api,
              appearance: widget.appearance,
              notifications: _notifications,
              purchases: _purchases,
              pendingReviewWord: _pendingReviewWord,
              reviewRefresh: _reviewRefreshTick,
            )
          : SignInScreen(auth: _auth),
    );
  }
}
