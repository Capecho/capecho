import 'dart:async';

import 'package:capecho_api/capecho_api.dart' show ApiException, CapechoApi, ClaimRow, ClaimContext;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:capecho_local_store/capecho_local_store.dart' show WordRow;
import 'package:capture_native/capture_native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'agent_home.dart';
import 'auth/session_store.dart';
import 'backend/backend.dart';
import 'backend/distribution.dart';
import 'capture_debug.dart';
import 'capture_repository.dart';
import 'capture_shortcut_scope.dart';
import 'notifications/native_reminders_gateway.dart';
import 'onboarding.dart';
import 'onboarding_controller.dart';
import 'overlay_context_preview_controller.dart';
import 'overlay_explanation_controller.dart';
import 'repo_word_book.dart';
import 'settings/appearance_store.dart';
import 'settings/capture_source_prefs.dart';
import 'settings/language_prefs_store.dart';
import 'settings/shortcut_recorder_dialog.dart';
import 'surface_routing.dart';
import 'surface_transitions.dart';

Future<void> main() async {
  // Touch path_provider (the appearance + language stores) before runApp, so the first frame already
  // reflects a saved Light/Dark choice instead of flashing System, and the first ⌥E captures in the
  // saved (signed-out) learning language instead of English.
  WidgetsFlutterBinding.ensureInitialized();
  final appearance = AppearanceController(store: await _openAppearanceStore());
  await appearance.load();
  final languagePrefs = LanguagePrefsController(store: await _openLanguagePrefsStore());
  await languagePrefs.load();
  final captureSource = CaptureSourceController(store: await _openCaptureSourceStore());
  await captureSource.load();
  runApp(
    CapechoApp(appearance: appearance, languagePrefs: languagePrefs, captureSource: captureSource),
  );
}

/// Best-effort open of the on-disk appearance store: a sandbox/disk failure falls back to the
/// in-memory default (System) so the app always starts (mirrors the calm fallbacks elsewhere).
Future<AppearanceStore?> _openAppearanceStore() async {
  try {
    return await FileAppearanceStore.open();
  } catch (_) {
    return null;
  }
}

/// Best-effort open of the on-disk language-prefs store: a sandbox/disk failure falls back to the
/// in-memory default (English) so the app always starts (mirrors [_openAppearanceStore]).
Future<LanguagePrefsStore?> _openLanguagePrefsStore() async {
  try {
    // Seed the first-run default NATIVE (explanation) language from the OS locale, so a Chinese-locale
    // Mac explains in 中文 with zero config (Lane C). Learning defaults to English (the user picks what
    // they're learning); the account takes over once signed in.
    final loc = WidgetsBinding.instance.platformDispatcher.locale;
    final tag = [
      loc.languageCode,
      loc.scriptCode,
      loc.countryCode,
    ].where((s) => s != null && s.isNotEmpty).join('-');
    final defaultPrefs = LanguagePrefs(
      learningLanguage: 'en',
      explanationLanguage: resolveNativeLanguage(tag),
      explanationFollowsLearning: false,
    );
    return await FileLanguagePrefsStore.open(defaultPrefs: defaultPrefs);
  } catch (_) {
    return null;
  }
}

/// Best-effort open of the capture-source store: a failure falls back to the default (ON).
Future<CaptureSourceStore?> _openCaptureSourceStore() async {
  try {
    return await FileCaptureSourceStore.open();
  } catch (_) {
    return null;
  }
}

class CapechoApp extends StatefulWidget {
  const CapechoApp({
    super.key,
    required this.appearance,
    required this.languagePrefs,
    required this.captureSource,
  });

  /// The app-wide Light/Dark/System controller, owned above [MaterialApp] so a change in Settings →
  /// Appearance repaints every surface (and pushed route) live.
  final AppearanceController appearance;

  /// The device-local signed-out capture language defaults (target + gloss), owned at the root so the
  /// capture path reads one source and a signed-out Settings → Language change is honored immediately.
  final LanguagePrefsController languagePrefs;

  /// Whether a capture records its source app + window title (device-local, default on).
  final CaptureSourceController captureSource;

  @override
  State<CapechoApp> createState() => _CapechoAppState();
}

class _CapechoAppState extends State<CapechoApp> {
  // Owned here (not in [CaptureDevShell]) so [CaptureShortcutScope] sits ABOVE
  // [MaterialApp.home] — otherwise pushed routes (Settings, Word Book, Review,
  // and the onboarding REPLAY) are siblings of `home` in the Navigator's
  // Overlay and never see the scope, leaving every replay surface stuck on the
  // fallback "⌥E".
  String _captureShortcutDisplay = '⌥E';

  void _setCaptureShortcutDisplay(String display) {
    if (display == _captureShortcutDisplay) return;
    setState(() => _captureShortcutDisplay = display);
  }

  @override
  Widget build(BuildContext context) {
    return CaptureShortcutScope(
      display: _captureShortcutDisplay,
      // Rebuild MaterialApp when the appearance choice changes so `themeMode` (and the whole tree's
      // brightness) flips live. The warm surfaces repaint via `OnboardingPalette.of(context)`, which
      // reads `Theme.of(context).brightness`.
      child: ListenableBuilder(
        listenable: widget.appearance,
        builder: (context, _) => MaterialApp(
          title: 'Capecho',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF7A5C3E)),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF7A5C3E),
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          themeMode: widget.appearance.mode,
          home: CaptureDevShell(
            onCaptureShortcutChanged: _setCaptureShortcutDisplay,
            appearance: widget.appearance,
            languagePrefs: widget.languagePrefs,
            captureSource: widget.captureSource,
          ),
        ),
      ),
    );
  }
}

/// Developer shell for M2-PR3a: proves the capture → durable journal → drain →
/// local store loop end-to-end. The agent shell, the native capture overlay,
/// and the real Word Book / Review UI come in later milestones. The target
/// language is hard-coded to `en` here; the real per-capture `Learning ▾`
/// selector is part of the overlay (M2-PR3b).
class CaptureDevShell extends StatefulWidget {
  const CaptureDevShell({
    super.key,
    required this.onCaptureShortcutChanged,
    required this.appearance,
    required this.languagePrefs,
    required this.captureSource,
  });

  /// Republishes the live Capture display to [CaptureShortcutScope], owned by
  /// [_CapechoAppState] (above MaterialApp). Called once after init and after
  /// every successful Settings save — keeping pushed surfaces (Settings,
  /// Word Book, Review, onboarding replay) in lockstep with the binding.
  final void Function(String display) onCaptureShortcutChanged;

  /// The app-wide Light/Dark/System controller, threaded to the Settings → Appearance surface this
  /// shell opens.
  final AppearanceController appearance;

  /// The device-local signed-out capture language defaults (target + gloss). Read as the fallback when
  /// there's no account (capture target + explanation), set by onboarding's step-5 pick, and threaded
  /// into Settings → Language so a signed-out change persists on this Mac.
  final LanguagePrefsController languagePrefs;

  /// Whether a capture records its source app + window title. Read per-capture to gate the source
  /// fields, and threaded into Settings → Capture so the toggle persists on this Mac.
  final CaptureSourceController captureSource;

  @override
  State<CaptureDevShell> createState() => _CaptureDevShellState();
}

class _CaptureDevShellState extends State<CaptureDevShell> {
  // The signed-out capture-target + gloss languages now live in `widget.languagePrefs` (device-local,
  // persisted, set by onboarding step 5 / Settings → Language while signed out). Signed in, the account
  // wins; signed out, the capture path falls back to that controller — recomputed per capture.

  CaptureRepository? _repo;
  AuthController? _auth;
  // The Apple-IAP Pro buy controller — non-null ONLY in the Mac App Store build (the distribution gate).
  // App-lifetime so a redelivered StoreKit transaction (interrupted buy / Ask-to-Buy / restore) verifies
  // even with Settings closed.
  ProPurchaseController? _purchases;
  // Daily review reminder (US-14.1): the shared scheduling policy over the native notification gateway.
  ReminderScheduler? _reminders;
  StreamSubscription<CaptureResult>? _sub;
  StreamSubscription<SavedRef>? _savedSub;
  StreamSubscription<void>? _showOnboardingSub;
  StreamSubscription<String>? _showSurfaceSub;
  StreamSubscription<OverlayExplainRequest>? _overlayExplainSub;
  StreamSubscription<OverlayContextPreviewRequest>? _overlayContextPreviewSub;
  // Holds the last overlay in-context preview's adoptable handle so the immediate post-save auto-claim
  // can carry it (E2 adopt-on-save — the Word Book entry then already shows the paid gloss, no recharge).
  OverlayContextPreviewController? _overlayContextPreview;
  // null = not yet known (show a spinner); false = run onboarding first.
  bool? _onboardingDone;
  OnboardingStep _firstRunInitialOnboardingStep = OnboardingStep.howItWorks;
  // Set when `_init` fails (store open / channel) so we show a retry instead of
  // an indefinite spinner (CR #5).
  String? _initError;

  @override
  void initState() {
    super.initState();
    _init();
  }

  /// The overlay's free-explanation controller, wired to the device-local explanation cache (RFC
  /// §B.3.1) over the repo's store-free record port — a re-capture shows its meaning offline and skips
  /// /explain; a fresh result is cached for next time.
  OverlayExplanationController _buildOverlayExplain(CapechoApi api, CaptureRepository repo) {
    // Wire the device-local per-POS sense cache (Lane E): a re-capture of a known unit shows its meaning
    // OFFLINE and skips `/explain`; a fresh result is persisted so next time is offline-instant. The
    // repo converts the store rows to/from the controller's store-free records, so this controller keeps
    // no `capecho_local_store` dependency.
    return OverlayExplanationController(
      api: api,
      capture: repo.capture,
      readCache:
          ({
            required String surfaceUnit,
            required String targetLanguage,
            required String explanationLanguage,
          }) => repo.cachedExplanation(
            surfaceUnit: surfaceUnit,
            targetLanguage: targetLanguage,
            explanationLanguage: explanationLanguage,
          ),
      writeCache:
          ({
            required String surfaceUnit,
            required String targetLanguage,
            required String explanationLanguage,
            required List<CachedReading> readings,
          }) => repo.cacheExplanation(
            surfaceUnit: surfaceUnit,
            targetLanguage: targetLanguage,
            explanationLanguage: explanationLanguage,
            readings: readings,
          ),
    );
  }

  Future<void> _init() async {
    final CaptureRepository repo;
    final bool onboardingDone;
    final OnboardingStep firstRunInitialOnboardingStep;
    try {
      repo = await CaptureRepository.open();
      onboardingDone = await repo.capture.onboardingComplete();
      var screenRecordingGranted = false;
      if (!onboardingDone) {
        try {
          screenRecordingGranted = await repo.capture.hasScreenRecordingPermission();
        } catch (_) {
          // Permission preflight is only a resume hint; a channel hiccup should not block launch.
        }
      }
      firstRunInitialOnboardingStep = firstRunOnboardingInitialStep(
        onboardingDone: onboardingDone,
        screenRecordingGranted: screenRecordingGranted,
      );
    } catch (e) {
      if (mounted) setState(() => _initError = e.toString());
      return;
    }
    if (!mounted) {
      repo.close();
      return;
    }
    // One shared API client for the account layer + the overlay's free-explanation fetch, so a signed-in
    // session (restored below) also authenticates the overlay's `/explain`.
    final api = buildCapechoApi();
    // §14 metrics (CEO-10): start the recorder so the native capture-lifecycle signals (capture-time,
    // lookup→save funnel, context-fill, language-override) flow to /metrics. Anonymous-safe — it sends
    // without a session so the pre-login first capture is measured.
    await repo.startMetrics(api: api, appVersion: (await capechoAppVersion())?.version);
    final overlayExplain = _buildOverlayExplain(api, repo);
    // The opt-in in-context preview (E2): the SAME shared API client, so the metered
    // POST /explain/context/preview authenticates with the signed-in session (it's account-only).
    final overlayContextPreview = OverlayContextPreviewController(api: api, capture: repo.capture);
    _overlayContextPreview = overlayContextPreview;
    // Opt-in capture diagnostic (sentence-reconstruction tuning): dumps each
    // capture's raw snapshot + reconstructed sentence to JSONL when the
    // CAPTURE_DEBUG sentinel exists. No-op (and no overhead) otherwise.
    await CaptureDebug.maybeEnable(repo.capture);
    _sub = repo.capture.captures.listen(
      (result) {
        // Capture is ALWAYS completable (capture issue 1): even when the cascade found nothing usable
        // (no OCR, no fresh clipboard), present the SAME editable overlay with empty fields so the user
        // can finish by typing the word + sentence themselves — never a dead-end "Nothing found" popup.
        // The empty path is fully handled downstream: `explainFor` early-returns on an empty unit (no
        // wasted /explain call), the overlay focuses the empty unit field with its placeholder, and Save
        // stays blocked until a unit is typed.
        // Capture in the user's CURRENT languages: the signed-in account's learning/explanation
        // language wins (so a Settings change takes effect on the next ⌥E — bug #1), else the
        // device-local signed-out default. Recomputed per capture, never captured once.
        final configuredTarget =
            _auth?.account?.learningLanguage ?? widget.languagePrefs.learningLanguage;
        final explainLang =
            _auth?.account?.explanationLanguage ??
            widget.languagePrefs.effectiveExplanationLanguage;
        final unit = result.word ?? '';
        // Recognition is language-agnostic now, so a unit can be in a language the
        // user didn't configure. Auto-switch THIS capture's target to the unit's own
        // language when its writing system is provably incompatible with the
        // configured learning language (e.g. a 中文 unit captured while learning
        // English) — a deterministic, 100%-certain "different language", never a
        // probabilistic guess. Same-script differences (English vs Spanish) stay on
        // the configured target (the pre-save confirm prompt, a follow-up). The
        // user's configured learning language is unchanged; only this capture's
        // attribution + explanation + dedup scope follow the captured script.
        final target = effectiveTargetLanguage(unit: unit, learningLanguage: configuredTarget);
        // When the captured SPAN reads as a different (same-script) language than the effective
        // target — reading a Spanish passage while learning English, or a Latin word while learning
        // Chinese — suggest switching. The overlay surfaces it on the target chip as a one-tap switch
        // the user confirms; it is never auto-applied.
        final suggestedTarget = suggestedTargetLanguage(
          unit: unit,
          effectiveTarget: target,
          spanLanguage: result.detectedSpanLanguage,
          spanLanguageConfidence: result.detectedSpanLanguageConfidence,
        );
        // Route the reconstructed capture to the native overlay (the save surface), flagging whether
        // the unit is already in the Word Book (bug #6), then fetch the free explanation and stream it
        // into the overlay's slot (loading → meaning/failed).
        // Scope the "already saved" cue to what THIS viewer can see: signed out → the anonymous catalog
        // only (never reveal an account-only word); signed in → anonymous + words synced into THIS
        // account, never another account's words on a shared device (the local store keys claimed rows
        // by owner). A null account id (signed out) restricts the match to the anonymous rows.
        final account = (_auth?.isSignedIn ?? false) ? _auth?.account : null;
        // Resolve the app's Light/Dark/System theme to a concrete brightness so the NATIVE overlay matches
        // the Capecho app rather than the OS (#2). System collapses to the live OS brightness here, so a
        // System app on a dark Mac still gets a dark overlay. Recomputed per capture (theme can change).
        final overlayDark = switch (widget.appearance.mode) {
          ThemeMode.dark => true,
          ThemeMode.light => false,
          ThemeMode.system =>
            WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark,
        };
        repo.capture.showOverlay(
          result,
          targetLanguage: target,
          // The CONFIGURED learning language (pre script-auto-switch). The overlay re-derives the capture
          // target from this when the unit changes (set as word / edit), so attribution follows the word.
          learningLanguage: configuredTarget,
          // The gloss language, from the user's setting; there is no per-capture picker.
          explanationLanguage: explainLang,
          alreadySaved:
              unit.isNotEmpty && repo.isAlreadySaved(unit, target, accountId: account?.id),
          brightness: overlayDark ? 'dark' : 'light',
          suggestedTargetLanguage: suggestedTarget,
          // The span's detected language + confidence, cached by the overlay to re-evaluate the same-script
          // suggestion when the unit changes — no re-detection needed.
          detectedSpanLanguage: result.detectedSpanLanguage,
          detectedSpanLanguageConfidence: result.detectedSpanLanguageConfidence,
          // Capture-source provenance ("where I met this word"): the app + window the capture came from,
          // carried silently through to the native Save. Gated by the Settings toggle — when off, nothing
          // is recorded. Read per-capture so the choice always reflects the current setting.
          sourceApp: widget.captureSource.enabled ? result.sourceApp : null,
          sourceTitle: widget.captureSource.enabled ? result.sourceTitle : null,
        );
        unawaited(
          overlayExplain.explainFor(
            unit: unit,
            targetLanguage: target,
            explanationLanguage: explainLang,
          ),
        );
      },
      // A capture-stream error is non-fatal — that one capture just doesn't surface an overlay. Record
      // it as a pre-overlay capture failure (the one §14 phase emitted Dart-side, not by the overlay).
      onError: (Object _) => repo.metrics?.recordCaptureFailed('unknown'),
    );
    // The overlay asks for a fresh explanation when the user switches `Explain in ▾` to another gloss
    // language, edits the unit, or taps Retry on a failed slot. The overlay carries the (fixed) target +
    // the chosen gloss language, so re-run /explain for exactly those and stream it back into the slot
    // (the initial fetch is fired above on capture; this keeps it live).
    _overlayExplainSub = repo.capture.overlayExplainRequests.listen(
      (req) => unawaited(
        overlayExplain.explainFor(
          unit: req.unit,
          targetLanguage: req.targetLanguage,
          explanationLanguage: req.explanationLanguage,
        ),
      ),
    );
    // The overlay's opt-in "Explain in this sentence" tap → run the metered in-context preview for the
    // carried unit + sentence and stream the gloss / quota / failure back into the overlay's ready card.
    _overlayContextPreviewSub = repo.capture.overlayContextPreviewRequests.listen(
      (req) => unawaited(
        overlayContextPreview.previewFor(
          unit: req.unit,
          contextText: req.contextText,
          targetLanguage: req.targetLanguage,
          explanationLanguage: req.explanationLanguage,
          contextLanguage: req.contextLanguage,
          spanStart: req.spanStart,
          spanEnd: req.spanEnd,
        ),
      ),
    );
    // Drain the local store when the overlay durably saves. Best-effort: the
    // journal write already succeeded, so a drain failure must not error out.
    _savedSub = repo.capture.saved.listen((ref) async {
      // Drain the durable journal into the local store when the overlay saves. Best-effort: the
      // journal write already succeeded, so a drain failure must not error out (it retries on the
      // next save or the launch drain). `createdByContext` maps each just-CREATED word to the save
      // event that created it.
      Map<String, String> createdByContext = const {};
      try {
        createdByContext = await repo.drain();
      } catch (_) {}
      // Cache the overlay's in-sentence "Explain here" gloss onto the just-saved context row (its PK is
      // this save event's clientRowId) so the Word Book renders it without re-generating. Matched on the
      // saved row's exact (unit, sentence) — the overlay only yields a gloss for that same pair, so an
      // edited unit/sentence after the preview never adopts a stale one. Runs regardless of auth (signed
      // in ALSO adopts it server-side via the claim handle below); best-effort, never fails the save.
      final preview = _overlayContextPreview;
      if (preview != null) {
        final key = repo.contextGlossKey(ref.clientRowId);
        if (key != null) {
          final gloss = preview.adoptableGlossFor(unit: key.unit, contextText: key.contextText);
          if (gloss != null) repo.setContextGloss(ref.clientRowId, gloss);
        }
      }
      // When signed in, upload THIS capture to the account IMMEDIATELY (bug #5) so a post-login capture
      // never waits for the manual backlog Sync. Claim ONLY the word tied to this save event's journal
      // row (`ref.clientRowId`), and only if it was newly created — never the pre-login backlog, and
      // never another entry that happened to drain in the same pass (e.g. a pre-login entry whose
      // earlier drain failed). Best-effort + idempotent; a failure leaves it anonymous for the next sync.
      final auth = _auth;
      if (auth == null || !auth.isSignedIn) return;
      final wordId = createdByContext[ref.clientRowId];
      if (wordId == null) return;
      final rows = _claimRowsForWordIds(repo, {wordId});
      if (rows.isNotEmpty) unawaited(auth.claimRows(rows));
    });
    // The menu-bar "Welcome" item (and Settings → "Get Started") re-open
    // the flow on demand. This is a REPLAY: it pushes onboarding as a surface over
    // the agent host, exactly like Review / Word Book / Settings, and must NOT flip
    // `_onboardingDone` to false — doing so would re-gate the whole app (every menu-bar
    // surface request checks `onboardingDone`), making every other page unopenable.
    _showOnboardingSub = repo.capture.showOnboardingRequests.listen((_) => _openReplayOnboarding());
    // The menu-bar Review / Word Book / Settings items + the global ⌥R / ⌥B
    // hotkeys ask the app to open a top-level surface.
    _showSurfaceSub = repo.capture.showSurfaceRequests.listen(_openSurfaceRequest);
    // The account/sync layer (M3): one API client + the sign-in controller. Built here so a
    // returning user's session is restored before onboarding (or the Word Book) even renders.
    final auth = AuthController(
      api: api,
      store: await FileSessionStore.open(),
      collectClaimRows: () async => _collectClaimRows(repo),
      installId: repo.capture.installId,
      // The explicit sync path (`syncLocalCaptures`): stamp claimed rows + count the still-anonymous
      // ones for the Word Book "Sync N" affordance.
      markClaimed: repo.markClaimed,
      anonymousCount: () => repo.anonymousWords().length,
      // §14 chain-completeness (CEO-10): the sync funnel — one sync_attempted per submitted row, one
      // sync_accepted per row the server acknowledged (reconciled server-side against the live word).
      onSyncAttempted: (ids) => repo.metrics?.recordSyncAttempted(ids),
      onSyncAccepted: (ids) => repo.metrics?.recordSyncAccepted(ids),
      // TODO(M3): pass the device's IANA timezone (flutter_timezone) for the review day boundary;
      // null defaults the account to UTC, which is fine for the first sign-in / verification.
      timezoneName: null,
      // Native provider flows live in social_credentials.dart (the only file touching the plugins).
      appleCredential: appleIdentityToken,
      googleCredential: () => googleIdToken(
        clientId: kGoogleNativeClientId.isEmpty ? null : kGoogleNativeClientId,
        serverClientId: kGoogleServerClientId.isEmpty ? null : kGoogleServerClientId,
      ),
    );
    unawaited(auth.restore());

    // The Apple-IAP Pro buy controller — created ONLY in the Mac App Store build (the distribution gate;
    // the direct build sells Pro on the Stripe web rail). App-lifetime so a StoreKit transaction the App
    // Store redelivers (interrupted buy / Ask-to-Buy / restore) is verified even with Settings closed:
    // verify → POST /billing/apple/verify; on success refresh the account so every surface flips to Pro.
    final purchases = isMacAppStoreBuild()
        ? ProPurchaseController(
            backend: InAppPurchaseBackend(),
            verify: api.verifyApplePurchase,
            onEntitlementChanged: auth.refreshAccount,
            currentAccountId: () => auth.account?.id,
          )
        : null;

    // Daily review reminder (US-14.1): the shared scheduling policy over the native
    // UNUserNotificationCenter gateway (capture_native). Re-evaluated on every auth change (below) and
    // when a surface opens; a tap is routed natively to Review.
    final reminders = ReminderScheduler(
      notifications: NativeRemindersGateway(repo.capture),
      loadWords: () => api.listWords(),
    );

    setState(() {
      _repo = repo;
      _auth = auth;
      _purchases = purchases;
      _reminders = reminders;
      _onboardingDone = onboardingDone;
      _firstRunInitialOnboardingStep = firstRunInitialOnboardingStep;
    });
    // Match the NATIVE app-wide appearance to the app's Light/Dark/System theme so the menu-bar status
    // dropdown + the capture overlay follow it rather than the OS — push now + on every theme change (#5).
    widget.appearance.addListener(_pushAppearanceMode);
    _pushAppearanceMode();
    // Arm/cancel the daily reminder on every session/preference change, and once now for the restoring
    // session (restore's notify usually covers this; the explicit call handles the no-session path).
    auth.addListener(_syncReminders);
    _syncReminders();
    unawaited(_refreshCaptureShortcutDisplay());
  }

  /// Re-evaluate the daily review reminder against the live session + account preference (US-14.1).
  /// Unforced: the shared scheduler short-circuits when the preference is unchanged, so the frequent
  /// `auth` notifications (busy/error ticks) are cheap.
  void _syncReminders() {
    final reminders = _reminders;
    final auth = _auth;
    if (reminders == null || auth == null) return;
    unawaited(reminders.sync(signedIn: auth.isSignedIn, account: auth.account));
  }

  /// Push the app's theme mode to native so app-wide native chrome — the menu-bar status dropdown
  /// (resolves NSApp.effectiveAppearance on open) + the capture overlay — matches the Capecho
  /// Light/Dark/System choice rather than the OS (#5). 'system' lets native follow the OS.
  void _pushAppearanceMode() {
    final repo = _repo;
    if (repo == null) return;
    unawaited(repo.capture.setAppearanceMode(themeModeToString(widget.appearance.mode)));
  }

  /// Pulls the persisted Capture shortcut from the native plugin and forwards
  /// it to [_CapechoAppState] so [CaptureShortcutScope] sits ABOVE MaterialApp
  /// and pushed routes (Settings / Word Book / Review / onboarding replay)
  /// see the live binding. Called once after [_init] and again after every
  /// successful save that touches the Capture action.
  Future<void> _refreshCaptureShortcutDisplay() async {
    final repo = _repo;
    if (repo == null) return;
    try {
      final shortcuts = await repo.capture.shortcuts();
      if (!mounted) return;
      for (final shortcut in shortcuts) {
        if (shortcut.action == 'capture') {
          widget.onCaptureShortcutChanged(shortcut.display);
          break;
        }
      }
    } catch (_) {
      // Keep the previous (or default) display — a transient native read failure
      // must not knock the UI off-screen.
    }
  }

  /// Onboarding rehearsal → "Change…": open the SAME recorder Settings uses, on the Capture binding.
  /// On Save, persist it via the native plugin — which republishes the live display to
  /// [CaptureShortcutScope], so the rehearsal coachmark + the on-card shortcut caps update together.
  /// A no-op without the repo; Cancel / Esc just returns without changing anything.
  Future<void> _editCaptureShortcut() async {
    final repo = _repo;
    if (repo == null || !mounted) return;
    final list = await repo.capture.shortcuts();
    if (!mounted) return;
    CapechoShortcut? found;
    for (final s in list) {
      if (s.action == 'capture') {
        found = s;
        break;
      }
    }
    if (found == null) return;
    final capture = found; // non-null + closure-safe for the dialog builder
    final draft = await showDialog<ShortcutDraft>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.34),
      builder: (dialogContext) =>
          ShortcutRecorderDialog(p: OnboardingPalette.of(dialogContext), shortcut: capture),
    );
    if (draft == null) return;
    await repo.capture.setShortcut(action: 'capture', key: draft.key, modifiers: draft.modifiers);
    unawaited(_refreshCaptureShortcutDisplay());
  }

  /// Build the claim payload from the device's ANONYMOUS local captures (each word + its most recent
  /// context; `contextsFor` returns newest-first, and the claim row carries a single context).
  /// Anonymous-only so a re-sync never re-claims rows already synced into the account.
  List<ClaimRow> _collectClaimRows(CaptureRepository repo) =>
      repo.anonymousWords().map((w) => _claimRowFor(repo, w)).toList();

  /// Build claim rows for a SPECIFIC set of anonymous word ids — the just-captured words the host
  /// claims immediately while signed in (bug #5). Filters to the still-anonymous rows among [wordIds]
  /// (an already-claimed id is silently dropped), so it never touches the pre-login backlog.
  List<ClaimRow> _claimRowsForWordIds(CaptureRepository repo, Set<String> wordIds) => repo
      .anonymousWords()
      .where((w) => wordIds.contains(w.clientRowId))
      .map((w) => _claimRowFor(repo, w, attachPreviewHandle: true))
      .toList();

  /// One claim row for [w] (its most recent context, if any). Shared by the full backlog sync and the
  /// targeted post-login auto-claim. [attachPreviewHandle] is set ONLY by the targeted post-save path so
  /// the overlay preview's paid handle binds to the word the user just previewed + saved — never to a
  /// backlog row that happens to share the same unit+sentence (which a later manual Sync would otherwise
  /// let consume the paid preview).
  ClaimRow _claimRowFor(CaptureRepository repo, WordRow w, {bool attachPreviewHandle = false}) {
    final contexts = repo.contextsFor(w.clientRowId);
    final c = contexts.isNotEmpty ? contexts.first : null;
    final text = c?.contextText;
    return ClaimRow(
      clientRowId: w.clientRowId,
      surfaceUnit: w.surfaceUnit,
      targetLanguage: w.targetLanguage,
      context: (text != null && text.isNotEmpty)
          ? ClaimContext(
              text: text,
              contextLanguage: c?.contextLanguage,
              spanStart: c?.spanStart,
              spanEnd: c?.spanEnd,
              // Capture-source provenance synced with the context: sourceApp + detectedLanguage stay
              // plaintext at rest; sourceTitle is encrypted server-side like the sentence.
              sourceApp: c?.sourceApp,
              sourceTitle: c?.sourceTitle,
              detectedLanguage: c?.detectedLanguage,
              detectedLanguageConfidence: c?.detectedLanguageConfidence,
              // E2 adopt-on-save: on the targeted post-save path only, carry the overlay preview's paid
              // gloss handle when this row IS the word the user just previewed + saved (matched on
              // unit+sentence). Null on the backlog path and on rows captured before any preview. The
              // backend re-checks owner + unit + sentence + TTL before adopting.
              previewHandle: attachPreviewHandle
                  ? _overlayContextPreview?.adoptableHandleFor(
                      unit: w.surfaceUnit,
                      contextText: text,
                    )
                  : null,
            )
          : null,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    _savedSub?.cancel();
    _showOnboardingSub?.cancel();
    _showSurfaceSub?.cancel();
    _overlayExplainSub?.cancel();
    _overlayContextPreviewSub?.cancel();
    _auth?.removeListener(_syncReminders);
    widget.appearance.removeListener(_pushAppearanceMode);
    _purchases?.dispose();
    _auth?.dispose();
    _repo?.close();
    super.dispose();
  }

  /// Persist the step-5 onboarding language choice. It's written to the device-local language prefs
  /// first, so the next ⌥E captures in it AND it survives a relaunch (covers signed-out onboarding,
  /// where there's no account). When signed in (onboarding replay), both languages are ALSO pushed to
  /// the account via `PATCH /account` — mirroring Settings → `updateAccount` — so the choice re-glosses
  /// existing words; the account then wins as the capture source while signed in.
  Future<void> _applyOnboardingLanguages({
    required String explanationLanguage,
    required bool explanationFollowsLearning,
    required String learningLanguage,
  }) async {
    // Persist on-device (survives relaunch) — this notifies synchronously, so the `languagePrefs`
    // listener re-pushes the recognition languages for the next capture's OCR. Signed-in re-pushes again
    // via the `auth` listener once `applyAccount` lands the persisted languages.
    widget.languagePrefs.setAll(
      learningLanguage: learningLanguage,
      explanationLanguage: explanationLanguage,
      explanationFollowsLearning: explanationFollowsLearning,
    );
    final auth = _auth;
    if (auth == null || !auth.isSignedIn) return;
    // Best-effort: the OnboardingController awaits this inside a try/catch, so a failed persist never
    // blocks finishing onboarding. On success apply the returned account so every surface stays
    // authoritative; on a 401 the session died server-side, so sign out (mirrors Settings'
    // `_saveAccount`) rather than leave the app rendering as signed-in with a revoked token.
    final epoch = auth.sessionEpoch;
    try {
      // When the explanation follows the learning language (the default), persist the flag — NOT an
      // explicit language — so the account keeps auto-following; an explicit pick sends the language
      // (which turns the flag off server-side).
      final updated = await auth.api.updateAccount(
        explanationLanguage: explanationFollowsLearning ? null : explanationLanguage,
        explanationFollowsLearning: explanationFollowsLearning ? true : null,
        learningLanguage: learningLanguage,
      );
      // Don't re-apply a stale account if the session ended or switched mid-flight (mirrors Settings).
      if (auth.sessionEpoch != epoch || !auth.isSignedIn) return;
      auth.applyAccount(updated);
    } on ApiException catch (e) {
      if (e.isUnauthorized) unawaited(auth.signOut());
      rethrow;
    }
  }

  void _retryInit() {
    setState(() => _initError = null);
    _init();
  }

  /// Open a top-level surface in response to a native request — a menu-bar item or
  /// the global ⌥R / ⌥B hotkey (`showSurfaceRequests`). The routing decision itself
  /// (resolve → collapse any open surface → open, with the session/onboarding gates)
  /// lives in the top-level [routeSurfaceRequest] so it's unit-testable without
  /// standing up the shell — which builds a live API client + session and so can't be
  /// driven deterministically in a widget test. This method only supplies the shell's
  /// current state (mounted / onboarding done / repo+auth constructed).
  void _openSurfaceRequest(String surface) {
    if (!mounted) return;
    final auth = _auth;
    final repo = _repo;
    // The user is active (opened Review / Word Book / Settings) → re-check the daily reminder against
    // the current due picture (e.g. they may have just cleared their cards). Forced, to bypass the
    // unchanged-preference short-circuit.
    final reminders = _reminders;
    if (reminders != null && auth != null) {
      unawaited(reminders.sync(signedIn: auth.isSignedIn, account: auth.account, force: true));
    }
    routeSurfaceRequest(
      context,
      auth,
      surface,
      onboardingDone: _onboardingDone == true,
      ready: auth != null && repo != null,
      appearance: widget.appearance,
      languagePrefs: widget.languagePrefs,
      captureSource: widget.captureSource,
      // Null until the repo is built; the `ready` gate returns before these are read.
      checkPermission: repo?.capture.hasScreenRecordingPermission,
      openSystemSettings: repo?.capture.openScreenRecordingSettings,
      // Closing a surface hides this window (back to the menu-bar agent) — no shell to pop to.
      hideWindow: repo?.capture.hideWindow,
      // Settings → "Get Started" replays onboarding through the native
      // present path (which resizes the window first), exactly like the menu-bar
      // "Welcome" item — a pushed surface, not a first-run flag flip.
      onReplayOnboarding: _requestReplayOnboarding,
      loadShortcuts: repo?.capture.shortcuts,
      // Wrap the native save so a successful change to the Capture binding
      // republishes the live display to [CaptureShortcutScope] — onboarding's
      // replay, the agent splash and the Settings copy then reflect it
      // immediately. Review/Word Book saves don't refetch (their display
      // isn't shown outside Settings, which already updates reactively).
      saveShortcut: repo == null
          ? null
          : ({required String action, required String key, required List<String> modifiers}) async {
              final updated = await repo.capture.setShortcut(
                action: action,
                key: key,
                modifiers: modifiers,
              );
              if (action == 'capture') {
                unawaited(_refreshCaptureShortcutDisplay());
              }
              return updated;
            },
      // The signed-out Word Book's data source (the device-local anonymous catalog).
      localWordBook: repo == null ? null : RepoWordBook(repo),
      // Word Book → Export downloads a real file (CSV / Anki .apkg) via the native save panel.
      saveExportFile: repo?.capture.saveExportFile,
      // The Apple-IAP buy controller (MAS build only) → Settings' Upgrade opens the StoreKit paywall.
      purchases: _purchases,
    );
  }

  /// Settings → "Get Started": ask the native agent to present the
  /// onboarding window. Going through native (rather than pushing the route
  /// directly) resizes + centers the window to the onboarding height first — a
  /// replay entered from another surface would otherwise render at whatever size
  /// that surface left the window. Native then re-posts `showOnboardingRequests`,
  /// landing in [_openReplayOnboarding] — the same path as the menu-bar "Welcome".
  void _requestReplayOnboarding() {
    final repo = _repo;
    if (repo == null) return;
    unawaited(repo.capture.requestOnboarding());
  }

  /// Re-open onboarding as a REPLAY surface — a pushed route over the agent host,
  /// dismissible back to the menu bar (Esc / "Start capturing") — WITHOUT touching
  /// `_onboardingDone`. Used by the menu-bar "Welcome" item and Settings → "How
  /// Capecho works". (First-run onboarding is the `_onboardingDone == false` home
  /// branch; this is the already-done re-run, so it must leave the flag — and the
  /// menu-bar surface routing it gates — intact.)
  void _openReplayOnboarding() {
    if (!mounted) return;
    final repo = _repo;
    final auth = _auth;
    // Only past first-run: during first run the flow already owns the window.
    if (repo == null || auth == null || _onboardingDone != true) return;
    final nav = Navigator.of(context);
    // Collapse any open surface (or a prior replay) back to the host first, so a
    // repeated request never stacks duplicate onboarding routes.
    nav.popUntil((route) => route.isFirst);

    void closeReplay() {
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      unawaited(repo.capture.hideWindow());
    }

    // A REPLAY is a root surface (it sits directly over the host after the collapse above), so it
    // appears instantly with no slide — same as Review / Word Book / Settings from the menu bar.
    nav.push(
      rootSurfaceRoute(
        Focus(
          autofocus: true,
          // Esc — or ⌘W (standard macOS close) — dismisses the replay (back to the menu bar),
          // matching the other surfaces (bug #3).
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.escape ||
                    (event.logicalKey == LogicalKeyboardKey.keyW &&
                        HardwareKeyboard.instance.isMetaPressed))) {
              closeReplay();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: OnboardingFlow(
            requestPermission: repo.capture.requestScreenRecordingPermission,
            checkPermission: repo.capture.hasScreenRecordingPermission,
            openScreenRecordingSettings: repo.capture.openScreenRecordingSettings,
            completeOnboarding: repo.capture.completeOnboarding,
            authController: auth,
            savedSignal: repo.capture.saved.map<void>((_) {}),
            chooseLanguages: _applyOnboardingLanguages,
            initialNativeLanguage: widget.languagePrefs.explanationLanguage,
            onEditCaptureShortcut: () => unawaited(_editCaptureShortcut()),
            onDone: closeReplay,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_initError != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Couldn’t open the local store.'),
                const SizedBox(height: 8),
                Text(
                  _initError!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _retryInit, child: const Text('Retry')),
              ],
            ),
          ),
        ),
      );
    }
    final repo = _repo;
    final auth = _auth;
    if (repo == null || auth == null || _onboardingDone == null) {
      return Scaffold(
        body: Center(child: ObEchoLoader(color: OnboardingPalette.of(context).primary, size: 56)),
      );
    }
    // First run: the progressive onboarding flow (US-ON.1/2). The capture →
    // overlay → save orchestration is already wired in `_init`, so the step-3
    // rehearsal is a REAL ⌥E capture; the flow advances off the same `saved`
    // stream the drain listens to.
    if (_onboardingDone == false) {
      return OnboardingFlow(
        requestPermission: repo.capture.requestScreenRecordingPermission,
        checkPermission: repo.capture.hasScreenRecordingPermission,
        openScreenRecordingSettings: repo.capture.openScreenRecordingSettings,
        completeOnboarding: repo.capture.completeOnboarding,
        initialStep: _firstRunInitialOnboardingStep,
        authController: auth,
        savedSignal: repo.capture.saved.map<void>((_) {}),
        chooseLanguages: _applyOnboardingLanguages,
        initialNativeLanguage: widget.languagePrefs.explanationLanguage,
        onEditCaptureShortcut: () => unawaited(_editCaptureShortcut()),
        onDone: () {
          setState(() => _onboardingDone = true);
          // "Start capturing" → back to the menu-bar agent (press ⌥E in any app). The surfaces open
          // on demand from the menu / hotkeys; there is no persistent home window.
          repo.capture.hideWindow();
        },
      );
    }
    // Past onboarding the agent has NO persistent home window: capture happens via the native ⌥E
    // overlay, and Review / Word Book / Settings open ON DEMAND from the menu bar / global hotkeys as
    // full-window surfaces, each of which closes (hides the window) back to the menu-bar agent. The
    // window is ALSO brought forward bare — landing on [AgentHome] — when the user reopens Capecho with
    // no destination (Finder / Dock → `applicationShouldHandleReopen` → `showMainWindow`), so this is a
    // real, dwellable hub: the brand front door that carries the live "N due" pulse and routes onward.
    return AgentHome(
      signedIn: auth.isSignedIn,
      // "Words kept" must match the Word Book, so it reads the SAME catalog the Word Book does rather
      // than a raw local `activeWords()` (which also counts rows claimed into other/wiped accounts —
      // the 35-vs-6 over-count). Signed in: the account's server count (`/words`, active rows), exactly
      // what the signed-in Word Book lists. Signed out: the device's anonymous local catalog (the
      // signed-out Word Book's source). Best-effort — a failure/offline read just omits the figure.
      loadWordCount: () async => auth.isSignedIn
          ? (await auth.api.listWords()).where((w) => w.deletedAt == null).length
          : repo.anonymousWords().length,
      // Best-effort "N due today" (the `/review/due` count is account-only); a failure or signed-out
      // state just omits the figure from the status pulse.
      loadDueCount: auth.isSignedIn ? () async => (await auth.api.dueReviews()).dueCount : null,
      // Live `action → display` map so the Review / Word Book rows show the user's actual hotkeys.
      loadShortcutDisplays: () async {
        final list = await repo.capture.shortcuts();
        return {for (final s in list) s.action: s.display};
      },
      // Open a surface the same way a menu click / global hotkey does (the window is already forward).
      onOpenSurface: _openSurfaceRequest,
      // Esc / ⌘W hides the window back to the menu-bar agent — the front door closes like every surface.
      onClose: () => unawaited(repo.capture.hideWindow()),
    );
  }
}
