import 'dart:async';

import 'package:capecho_api/capecho_api.dart' show ApiException;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:capture_native/capture_native.dart' show CapechoShortcut;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../backend/distribution.dart';
import '../surface_transitions.dart';
import '../word_book/word_book_screen.dart';
import '../word_book/word_book_widgets.dart' show ExportFileSaver;
import 'capture_source_prefs.dart';
import 'delete_account_dialog.dart';
import 'pro_paywall.dart';
import 'pro_paywall_iap.dart';
import 'settings_controller.dart';
import 'settings_skeleton.dart';
import 'settings_widgets.dart';
import 'shortcut_recorder_dialog.dart';

/// Two axes (§9). The explanation (gloss) set keeps all nine; the learning (capture-target) set shows
/// ONLY the generation-ENABLED targets (the lang registry's `enabled` set — en + zh-Hans). A target
/// outside it is saveable + reviewable but gets no explanations (`language_unsupported`), so offering it
/// here would break the core loop; ko/es/… join only as each passes its paid eval gate
/// (docs/adding-a-target-language.md — segmentation is the OS's job + the user can adjust the selection
/// before saving, so it is not the blocker). Too many for a segmented control, so both use the same
/// dropdown ([settingsSelectbox]); the codes come from app-core's shared [learningLanguages] /
/// [explanationLanguages] (one list for settings + onboarding), and [langName] renders the human label.
const List<String> _learningLangs = learningLanguages;

/// The macOS Settings surface (US-SET.1), built **1:1 with `DESIGN.md`**: the
/// `Capecho.` masthead, then Reminders · Language · Capture permission · Account · Word Book pointer,
/// plus the loading skeleton, the reminders-off state, and the delete-account confirm dialog.
///
/// What's genuinely wired: the Screen-Recording **capture permission**, **Sign out**, the Word Book
/// pointer, and — now — the **Reminders + Language controls persist to the account** via `PATCH /account`
/// (`capecho_api.updateAccount`): each control updates optimistically then saves, with the per-field
/// save states ("Queued" offline / "Not saved" + Retry). Reminders read
/// `override ?? account.reminderEnabled / reminderTime` (account-authoritative; default off, opt-in).
/// The account **identity block** reads provider + email from `/auth/me`, and **delete account** is
/// wired to `DELETE /account` (the confirm dialog → [AuthController.deleteAccount], which resets to
/// signed-out on success). Still backend-blocked: a display **name** — no provider returns one, so the
/// row shows the provider + email only.
///
/// Deliberate divergences (the savestate pill + section notice carry the same meaning, so these are
/// minor): the per-row desc does NOT swap to "Changed to {value} — kept on this Mac…" (8a/8b). True
/// **auto-flush-on-reconnect** (8a's "syncs automatically") is a §12 follow-up — until then "Retry now"
/// is offered on the queued state too. A 401 mid-session signs out (hiding these sections); a narrow
/// edge remains where an in-flight save that 401s leaves stale controller state on the now-hidden
/// section until the next sign-in.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.auth,
    required this.appearance,
    required this.languagePrefs,
    required this.captureSource,
    required this.checkPermission,
    required this.openSystemSettings,
    this.loadShortcuts,
    this.saveShortcut,
    this.onClose,
    this.onReplayOnboarding,
    this.saveExportFile,
    this.loadAppVersion,
    this.openExternalUrl,
    this.purchases,
    this.scrollToAccount = false,
  });

  /// When true, Settings auto-scrolls the **Account** section into view on open (and signed-out, the
  /// SignInPanel it holds). Set by the capture overlay's "Sign in" entry point so a signed-out user lands
  /// on the sign-in controls instead of the top of the page. Default false (every other entry opens at
  /// the top).
  final bool scrollToAccount;

  /// Threaded into the nested Word Book opened from Settings, so its Export downloads a file via the
  /// native save panel (same seam as the root Word Book). Null → export degrades gracefully.
  final ExportFileSaver? saveExportFile;

  /// The Apple-IAP purchase controller — non-null ONLY in the Mac App Store build (the distribution gate
  /// constructs it in the app shell). When present, the "Upgrade" affordance opens the StoreKit
  /// [ProPaywallIap]; when null (the direct build) it opens the Stripe [ProPaywall].
  final ProPurchaseController? purchases;

  final AuthController auth;

  /// Device-local Light/Dark/System controller, surfaced in the Appearance section and driving the
  /// root `MaterialApp.themeMode`.
  final AppearanceController appearance;

  /// Device-local signed-out capture language defaults (target + gloss). Signed in, the Language
  /// section reads/writes the account (`PATCH /account`); signed out it reads/writes this controller,
  /// so the choice persists on this Mac and is honored by local captures.
  final LanguagePrefsController languagePrefs;

  /// Whether a capture records its source app + window title (device-local). Surfaced as the Capture
  /// source toggle; read per-capture by the host.
  final CaptureSourceController captureSource;

  /// Screen-Recording permission seams (the app wires `capture_native`; tests pass stubs).
  final Future<bool> Function() checkPermission;
  final Future<void> Function() openSystemSettings;
  final LoadShortcuts? loadShortcuts;
  final SaveShortcut? saveShortcut;

  /// Dismiss Settings. The agent app supplies `hideWindow` (close = hide the window, return to the
  /// menu bar). Null falls back to `Navigator.maybePop` (tests / a nested host).
  final VoidCallback? onClose;

  /// Re-open the onboarding walkthrough (Settings → "Get Started"). Null hides the row —
  /// e.g. in tests, or a host that doesn't wire replay.
  final VoidCallback? onReplayOnboarding;

  /// Settings → About: loads the app version label (e.g. "0.1.5 (10500)"). Injected so widget tests
  /// pass a literal; defaults to reading the platform bundle via [capechoAppVersion]. A null result
  /// shows a calm placeholder.
  final Future<String?> Function()? loadAppVersion;

  /// Settings → About: opens an external link / mailto. Injected so tests record the target; defaults
  /// to [capechoOpenExternal] (url_launcher, best-effort).
  final Future<void> Function(Uri uri)? openExternalUrl;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final SettingsController _c;
  final FocusNode _focus = FocusNode(debugLabel: 'settings');

  /// Drives the section scroll view so [widget.scrollToAccount] can bring the Account section into view.
  final ScrollController _scroll = ScrollController();

  /// Anchors the Account section for the [widget.scrollToAccount] auto-scroll (`Scrollable.ensureVisible`).
  final GlobalKey _accountKey = GlobalKey();

  /// The bundle version label for the About section, loaded async in [initState]; null while loading
  /// (or when unavailable, e.g. in a widget test).
  String? _appVersion;

  @override
  void initState() {
    super.initState();
    // Land a signed-out user (arriving from the capture overlay's "Sign in") on the Account section's
    // sign-in controls rather than the top of the page. One post-frame hop so the section is laid out
    // (and the key attached) before we scroll; guarded on the still-mounted context.
    if (widget.scrollToAccount) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _accountKey.currentContext;
        if (target == null) return;
        unawaited(
          Scrollable.ensureVisible(
            target,
            alignment: 0.08, // just below the top edge — a hair of breathing room above the card
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeInOut,
          ),
        );
      });
    }
    _c = SettingsController(
      checkPermission: widget.checkPermission,
      openSystemSettings: widget.openSystemSettings,
      loadShortcuts: widget.loadShortcuts,
      saveShortcut: widget.saveShortcut,
      // Always non-null + reactive: `_saveAccount` gates on the LIVE session, so a sign-in while
      // Settings is open begins persisting (and a sign-out stops) — unlike a value captured once.
      saveAccount: _saveAccount,
    );
    _c.refreshPermission();
    unawaited(_c.refreshShortcuts());
    // Pull the latest account on open so a change made on another device/client (e.g. mobile) shows
    // here without a relaunch — the two clients otherwise only see their own last write (bug #4).
    unawaited(widget.auth.refreshAccount());
    unawaited(_loadAppVersion());
  }

  /// Resolve the About section's version label — the injected loader, else the bundle reader.
  Future<void> _loadAppVersion() async {
    final load = widget.loadAppVersion ?? () async => (await capechoAppVersion())?.label;
    final v = await load();
    if (mounted) setState(() => _appVersion = v);
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _close() {
    final close = widget.onClose;
    if (close != null) {
      // Agent: collapse Settings back to the hidden host THEN hide the window, so re-opening a
      // DIFFERENT surface doesn't briefly flash this (now stale) one. No shell to return to.
      Navigator.of(context).popUntil((r) => r.isFirst);
      close();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// Open an About link / mailto — the injected opener, else [capechoOpenExternal] (url_launcher).
  void _openExternal(Uri uri) => unawaited((widget.openExternalUrl ?? capechoOpenExternal)(uri));

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && _isCloseChord(event)) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Esc, or ⌘W (the standard macOS "close window") — both close this surface
  /// back to the menu-bar agent (bug #3: ⌘W did nothing on the surface windows).
  static bool _isCloseChord(KeyDownEvent event) =>
      event.logicalKey == LogicalKeyboardKey.escape ||
      (event.logicalKey == LogicalKeyboardKey.keyW && HardwareKeyboard.instance.isMetaPressed);

  void _openWordBook() {
    final auth = widget.auth;
    if (!auth.isSignedIn) return;
    // Opened FROM Settings → a nested page: it slides in over Settings (which stays fixed) and its
    // shared header shows a "Settings" back button rather than the brand.
    Navigator.of(context).push(
      nestedSurfaceRoute(
        WordBookScreen(
          api: auth.api,
          // Settings opens the Word Book only when signed in (server-backed), so no local source is
          // needed; `auth` drives the "Sync N words" banner when local captures await sync.
          auth: auth,
          explanationLanguage: auth.account?.explanationLanguage ?? 'en',
          onBack: () => Navigator.of(context).maybePop(),
          backLabel: 'Settings',
          saveExportFile: widget.saveExportFile,
        ),
      ),
    );
  }

  /// Bridges [SettingsController.saveAccount] to the live `PATCH /account`. Only the changed (non-null)
  /// field is sent. Reactive: a no-op without a live session (signed out → UI-local; the member
  /// sections aren't shown anyway). On success the returned [Account] is applied to [AuthController] so
  /// every surface stays authoritative. A 401 means the session died server-side → sign out (which
  /// hides these sections) rather than leaving an endlessly-failing "Retry now". Other errors rethrow
  /// so the controller can mark the field queued (transport) / failed (backend).
  Future<void> _saveAccount({
    String? explanationLanguage,
    bool? explanationFollowsLearning,
    String? learningLanguage,
    bool? reminderEnabled,
    String? reminderTime,
  }) async {
    if (!widget.auth.isSignedIn) return;
    final epoch = widget.auth.sessionEpoch;
    try {
      final updated = await widget.auth.api.updateAccount(
        explanationLanguage: explanationLanguage,
        explanationFollowsLearning: explanationFollowsLearning,
        learningLanguage: learningLanguage,
        reminderEnabled: reminderEnabled,
        reminderTime: reminderTime,
      );
      // The session may have ended OR switched to a different account while the PATCH was in flight —
      // don't apply account A's response onto account B (the epoch distinguishes them; `isSignedIn`
      // alone can't, since both are signed in).
      if (widget.auth.sessionEpoch != epoch || !widget.auth.isSignedIn) return;
      widget.auth.applyAccount(updated);
    } on ApiException catch (e) {
      if (e.isUnauthorized) unawaited(widget.auth.signOut());
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: p.canvas,
        // Full-bleed like the Word Book: a fixed shared header, the scrolling sections below it.
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SurfaceHeader(p: p, title: 'Settings'),
            Expanded(
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  widget.auth,
                  _c,
                  widget.appearance,
                  widget.languagePrefs,
                ]),
                builder: (context, _) => _content(p),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(OnboardingPalette p) {
    // Signed in but the account hasn't resolved yet → the calm syncing skeleton.
    if (widget.auth.isSignedIn && widget.auth.account == null) {
      return _loadingSkeleton(p);
    }
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
      child: Center(
        // Fill the window like the Word Book catalog (same 900 cap) — the full-bleed header above spans
        // the whole width, so the sections widen to match instead of stranding a narrow centered column.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _sections(p)),
        ),
      ),
    );
  }

  // Ordered by user priority (parity with mobile on the shared sections — same relative order):
  // core capture controls → identity → engagement/plan → cosmetic → navigation/help → legal.
  // Language always leads (it shapes every capture + explanation and shows in BOTH auth states);
  // Account precedes the signed-in-only Reminders/Subscription it unlocks (signed out it IS the
  // sign-in CTA). Reminders stay account-gated (a reminder nudges you to clear synced, server-
  // scheduled due cards — nothing to remind about signed out).
  List<Widget> _sections(OnboardingPalette p) {
    final signedIn = widget.auth.isSignedIn;
    return [
      // 1. Language — the heart of a vocab tool; shown signed-in (account) AND signed-out (device-local).
      _languageSection(p),
      // 2. Capture permission (macOS) — the capability that makes ⌥E work; urgent when it's off.
      const SizedBox(height: 16),
      _captureSection(p),
      // 2b. Capture source — whether captures record where the word was met (app + window title).
      const SizedBox(height: 16),
      _captureSourceSection(p),
      // 3. Shortcuts — how the core actions (capture / review / Word Book) are invoked.
      const SizedBox(height: 16),
      _shortcutsSection(p),
      // 4. Account — identity + sync; the only section shown signed-out (the sign-in CTA), so it
      //    precedes the signed-in-only Reminders/Subscription/Word Book it unlocks. Keyed so the
      //    overlay's "Sign in" entry can auto-scroll it into view ([widget.scrollToAccount]).
      const SizedBox(height: 16),
      KeyedSubtree(key: _accountKey, child: _accountSection(p)),
      // 5. Reminders (signed-in only) — the daily-review habit loop.
      if (signedIn) ...[const SizedBox(height: 16), _remindersSection(p)],
      // 6. Subscription (signed-in only) — plan + upgrade.
      if (signedIn) ...[const SizedBox(height: 16), _subscriptionSection(p)],
      // 7. Appearance — cosmetic, device-local; drops below the functional + identity sections.
      const SizedBox(height: 16),
      _appearanceSection(p),
      // 8. Your words (signed-in only) — a navigation pointer into the Word Book.
      if (signedIn) ...[const SizedBox(height: 16), _wordBookPointer(p)],
      // 9. Getting started — replay onboarding (only when the host wires it).
      if (widget.onReplayOnboarding != null) ...[
        const SizedBox(height: 16),
        _gettingStartedSection(p),
      ],
      // 10. About — legal + contact, pinned last (above the version footer).
      const SizedBox(height: 16),
      _aboutSection(p),
      const SizedBox(height: 20),
      _versionFooter(p),
    ];
  }

  // ---- Reminders -----------------------------------------------------------

  Widget _remindersSection(OnboardingPalette p) {
    final account = widget.auth.account;
    final on = _c.remindersOnOverride ?? account?.reminderEnabled ?? false;
    final time = _c.reminderTimeOverride ?? account?.reminderTime ?? '20:00';
    const fields = [SettingField.reminderEnabled, SettingField.reminderTime];
    return settingsSection(p, 'Reminders', [
      settingRow(
        p,
        title: 'Daily review reminder',
        desc: on
            ? 'A nudge to clear your due cards.'
            : 'Off — no daily nudge. Turn this on to set a time.',
        control: _withSaveState(
          p,
          SettingField.reminderEnabled,
          _Toggle(p: p, value: on, onChanged: _c.setRemindersOn),
        ),
      ),
      settingRow(
        p,
        title: 'Reminder time',
        desc: on ? 'Default 20:00, your local time' : 'Re-enables when the reminder is on',
        descMuted: true,
        disabled: !on, // the time row stays visible but greyed when reminders are off
        control: _withSaveState(p, SettingField.reminderTime, _timefield(p, time, enabled: on)),
      ),
      if (_c.anyUnsaved(fields)) _saveNoticeRow(p, fields),
    ]);
  }

  // ---- Language ------------------------------------------------------------
  // Shown signed-in AND signed-out. Signed in, both controls read/write the account (`PATCH /account`,
  // server-authoritative) with the Queued/Not-saved save pills. Signed OUT there's no account, but the
  // learning language still governs LOCAL captures — so both controls read/write the device-local
  // [SettingsScreen.languagePrefs] instead (instant + persisted on this Mac, so no save pill).
  Widget _languageSection(OnboardingPalette p) {
    final signedIn = widget.auth.isSignedIn;
    final account = widget.auth.account;
    final prefs = widget.languagePrefs;

    // The native (explanation) language the picker shows — a DIRECT pick now (Lane C: the "Same as
    // learning language" immersion option is gone). Signed in it's the optimistic override → the
    // account's server-resolved value; signed out the device-local effective value.
    final String explanationChoice;
    final String? learning;
    if (signedIn) {
      explanationChoice = _c.explanationOverride ?? (account?.explanationLanguage ?? 'en');
      learning = _c.learningOverride ?? account?.learningLanguage;
    } else {
      explanationChoice = prefs.effectiveExplanationLanguage;
      learning = prefs.learningLanguage;
    }
    final explanationLabel = langName(explanationChoice);

    void selectExplanation(String v) =>
        signedIn ? _c.setExplanationLanguage(v) : prefs.setExplanationLanguage(v);

    void selectLearning(String v) =>
        signedIn ? _c.setLearningLanguage(v) : prefs.setLearningLanguage(v);

    const fields = [SettingField.explanation, SettingField.learning];
    final unsaved = signedIn && _c.anyUnsaved(fields);
    // The save-state pill is the signed-in account-save affordance; signed-out device-local writes are
    // instant + reliable, so the bare control is shown.
    Widget withSave(SettingField field, Widget control) =>
        signedIn ? _withSaveState(p, field, control) : control;

    return settingsSection(p, 'Language', [
      // Both rows use the SAME inline layout (desc left, control right) — consistent with each other and
      // with the rest of the page, rather than one stacked + one inline.
      settingRow(
        p,
        title: 'Learning language',
        desc: 'The default target for new captures.',
        control: withSave(
          SettingField.learning,
          settingsSelectbox(
            p,
            codes: _learningLangs,
            label: learning == null ? 'Not set yet' : langName(learning),
            tooltip: 'Choose learning language',
            onSelect: selectLearning,
          ),
        ),
      ),
      settingRow(
        p,
        title: 'Native language',
        desc: 'Your language — Capecho explains or translates words into it.',
        control: withSave(
          SettingField.explanation,
          settingsSelectbox(
            p,
            codes: explanationLanguages,
            label: explanationLabel,
            tooltip: 'Choose native language',
            onSelect: selectExplanation,
          ),
        ),
      ),
      // The save notice (signed-in, when a change is queued/failed) takes precedence; otherwise the
      // standing note that consolidates what changing each language does.
      if (unsaved) _saveNoticeRow(p, fields) else _languageNoteRow(p),
    ]);
  }

  /// The Language section's foot note: explanations re-gloss lazily as words are opened, and switching
  /// the learning language only affects FUTURE captures (the captured unit is immutable — saved words
  /// keep theirs). One note for both rows, replacing the old per-row notice so the section reads as one
  /// consistent list.
  Widget _languageNoteRow(OnboardingPalette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
      child: settingsNotice(
        p,
        // the ⓘ glyph stays muted; the fill is the coffee primary-soft wash (base .notice)
        tone: p.ink3,
        background: p.primarySoft,
        icon: Icons.info_outline,
        body: Text(
          'Existing explanations refresh in the new language as you open words. '
          'Changing the learning language only affects future captures.',
          style: p.chrome(size: 13, weight: FontWeight.w400, color: p.ink2).copyWith(height: 1.5),
        ),
      ),
    );
  }

  // ---- Appearance (device-local) -------------------------------------------
  // The control is built from the shared design tokens and persists on this Mac (path_provider),
  // separate from the account — appearance is a per-device choice.
  Widget _appearanceSection(OnboardingPalette p) {
    return settingsSection(p, 'Appearance', [
      settingStackRow(
        p,
        title: 'Theme',
        desc:
            'Match your system appearance, or keep Capecho always light or dark — saved on this Mac.',
        control: AppearanceControl(
          p: p,
          mode: widget.appearance.mode,
          onChanged: (m) => widget.appearance.setMode(m),
        ),
      ),
    ]);
  }

  // ---- Capture permission (macOS) ------------------------------------------

  Widget _captureSection(OnboardingPalette p) {
    final captureDisplay = _c.shortcutFor('capture').display;
    return settingsSection(p, 'Capture permission', [
      settingRow(
        p,
        title: 'Screen Recording',
        desc: 'Read by OCR only the instant you press $captureDisplay.',
        control: _statusPill(p),
      ),
      ..._captureFollowUp(p),
    ]);
  }

  Widget _captureSourceSection(OnboardingPalette p) {
    return ListenableBuilder(
      listenable: widget.captureSource,
      builder: (context, _) {
        final on = widget.captureSource.enabled;
        return settingsSection(p, 'Capture source', [
          settingRow(
            p,
            title: 'Record where you captured',
            desc: on
                ? 'Saves the source app + window title with each capture — shown on the Review card and in your Word Book.'
                : "Off — captures won't record the source app or window title.",
            control: _Toggle(p: p, value: on, onChanged: widget.captureSource.setEnabled),
          ),
        ]);
      },
    );
  }

  List<Widget> _captureFollowUp(OnboardingPalette p) {
    switch (_c.permission) {
      case CapturePermission.granted:
        return [
          settingRow(
            p,
            desc: 'Need to change it? macOS manages this permission in System Settings.',
            descMuted: true,
            control: ObQuietButton(
              p: p,
              label: 'Open System Settings…',
              onPressed: _c.openCaptureSettings,
            ),
          ),
        ];
      case CapturePermission.off:
        return [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 14, 24, 4),
            child: settingsNotice(
              p,
              tone: p.info,
              body: Text.rich(
                TextSpan(
                  style: p
                      .chrome(size: 13, weight: FontWeight.w400, color: p.ink2)
                      .copyWith(height: 1.5),
                  children: [
                    TextSpan(
                      text: 'Clipboard mode is working.',
                      style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
                    ),
                    TextSpan(
                      text:
                          ' Select a word, copy it (⌘C), then press '
                          '${_c.shortcutFor('capture').display} — Capecho parses the word and '
                          'its sentence for you. Enabling Screen Recording just removes the copy step.',
                    ),
                  ],
                ),
              ),
            ),
          ),
          settingRow(
            p,
            title: 'Enable hotkey OCR',
            desc:
                'Grant Screen Recording in System Settings → Privacy & Security, then return here.',
            descMuted: true,
            control: ObPrimaryButton(
              p: p,
              label: 'Open System Settings…',
              onPressed: _c.openCaptureSettings,
            ),
          ),
        ];
      case CapturePermission.unknown:
        return [
          settingRow(
            p,
            desc: _c.checking
                ? 'Checking permission…'
                : 'Permission status is unavailable right now.',
            descMuted: true,
            control: ObQuietButton(
              p: p,
              label: 'Open System Settings…',
              onPressed: _c.openCaptureSettings,
            ),
          ),
        ];
    }
  }

  Widget _statusPill(OnboardingPalette p) {
    switch (_c.permission) {
      case CapturePermission.granted:
        return settingsPill(p, 'Granted', p.success);
      case CapturePermission.off:
        return settingsPill(p, 'Off', p.warning);
      case CapturePermission.unknown:
        return settingsPill(p, _c.checking ? 'Checking…' : 'Unknown', p.ink3);
    }
  }

  // ---- Shortcuts (local device) -------------------------------------------

  Widget _shortcutsSection(OnboardingPalette p) {
    return settingsSection(p, 'Shortcuts', [
      if (_c.shortcutsLoading) settingRow(p, desc: 'Loading shortcuts…', descMuted: true),
      for (final action in kShortcutActionOrder) _shortcutRow(p, action),
      if (_c.shortcutsError != null) _shortcutLoadNotice(p),
    ]);
  }

  Widget _shortcutRow(OnboardingPalette p, String action) {
    final shortcut = _c.shortcutFor(action);
    return settingRow(
      p,
      title: shortcut.title,
      desc: switch (action) {
        'capture' => 'Run capture from anywhere on your Mac.',
        'review' => 'Open Review from any app.',
        'wordBook' => 'Open Word Book from any app.',
        _ => 'Global shortcut',
      },
      control: _shortcutControl(p, shortcut),
    );
  }

  Widget _shortcutControl(OnboardingPalette p, CapechoShortcut shortcut) {
    final saving = _c.shortcutSaving(shortcut.action);
    final error = _c.shortcutErrorOf(shortcut.action);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: p.ink,
            side: BorderSide(color: p.line),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            textStyle: p.mono(size: 14, color: p.ink),
          ),
          onPressed: saving ? null : () => _editShortcut(shortcut),
          child: Text(saving ? 'Saving…' : shortcut.display),
        ),
        if (error != null) ...[
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              error,
              textAlign: TextAlign.right,
              style: p
                  .chrome(size: 12, weight: FontWeight.w500, color: p.error)
                  .copyWith(height: 1.35),
            ),
          ),
        ],
      ],
    );
  }

  Widget _shortcutLoadNotice(OnboardingPalette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
      child: settingsNotice(
        p,
        tone: p.warning,
        icon: Icons.warning_amber_rounded,
        body: Text(
          _c.shortcutsError!,
          style: p.chrome(size: 13, weight: FontWeight.w400, color: p.ink2).copyWith(height: 1.5),
        ),
      ),
    );
  }

  Future<void> _editShortcut(CapechoShortcut shortcut) async {
    final draft = await showDialog<ShortcutDraft>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.34),
      builder: (dialogContext) {
        final p = OnboardingPalette.of(dialogContext);
        return ShortcutRecorderDialog(p: p, shortcut: shortcut);
      },
    );
    if (draft == null) return;
    await _c.setShortcut(action: shortcut.action, key: draft.key, modifiers: draft.modifiers);
  }

  // ---- Account -------------------------------------------------------------

  Widget _accountSection(OnboardingPalette p) {
    if (!widget.auth.isSignedIn) return _signedOutAccount(p);
    // Identity from /auth/me (provider + email). `name` isn't exposed (Apple shares it unreliably), so
    // the row is email + a "Signed in with {provider}" line. A null email (e.g. Apple private relay)
    // falls back to a calm "Signed in".
    final account = widget.auth.account;
    final email = account?.email;
    final providerLabel = _providerLabel(account?.provider);
    return settingsSection(p, 'Account', [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(color: p.primary, shape: BoxShape.circle),
              alignment: Alignment.center,
              child: (email != null && email.isNotEmpty)
                  ? Text(
                      email[0].toUpperCase(),
                      style: p.chrome(size: 17, weight: FontWeight.w600, color: p.primaryFg),
                    )
                  : Icon(Icons.person_outline, size: 20, color: p.primaryFg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    email ?? 'Signed in',
                    style: p.chrome(size: 14, weight: FontWeight.w600, color: p.ink),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    providerLabel != null
                        ? 'Signed in with $providerLabel · synced across your devices'
                        : 'Your Word Book and review are saved to your account.',
                    style: p
                        .chrome(size: 13, weight: FontWeight.w400, color: p.ink2)
                        .copyWith(height: 1.45),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            ObQuietButton(p: p, label: 'Sign out', onPressed: widget.auth.signOut),
          ],
        ),
      ),
      // Delete account & data — the destructive row opens a confirm dialog.
      settingRow(
        p,
        title: 'Delete account & data',
        titleColor: p.error,
        desc: 'Permanently erases your words, contexts, and review history. This can’t be undone.',
        descMuted: true,
        control: dangerButton(p, 'Delete…', onPressed: _showDeleteDialog),
      ),
    ]);
  }

  /// Human label for the sign-in provider badge; null for an unknown/absent value.
  String? _providerLabel(String? provider) => switch (provider) {
    'apple' => 'Apple',
    'google' => 'Google',
    'email' => 'Email',
    _ => null,
  };

  /// Signed out: a sync-paused notice + a single-provider sign-in invite.
  Widget _signedOutAccount(OnboardingPalette p) {
    return settingsSection(p, 'Account', [
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            settingsNotice(
              p,
              tone: p.info,
              body: Text.rich(
                TextSpan(
                  style: p
                      .chrome(size: 13, weight: FontWeight.w400, color: p.ink2)
                      .copyWith(height: 1.5),
                  children: [
                    TextSpan(
                      text: 'You’re signed out.',
                      style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
                    ),
                    const TextSpan(
                      text:
                          ' Sync and review are paused. Anything you capture now stays on this Mac — '
                          'after you sign in, you can sync it to your account whenever you like.',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Sign in with one provider to sync your Word Book and review across devices.',
              textAlign: TextAlign.center,
              style: p
                  .chrome(size: 13, weight: FontWeight.w400, color: p.ink3)
                  .copyWith(height: 1.45),
            ),
            const SizedBox(height: 14),
            // The real in-app sign-in (Apple / Google / email one-time code), driven by the shared
            // AuthController via SignInPanel — the same panel onboarding step 4 uses. Replaces the old
            // dead "open the menu-bar Welcome" fallback (Issue 3a); busy/error/codeSent come from auth.
            Center(
              child: SignInPanel(p: p, auth: widget.auth, appleAvailable: isMacAppStoreBuild()),
            ),
          ],
        ),
      ),
    ]);
  }

  // ---- Subscription (Pro status) -------------------------------------------
  // The server-authoritative Pro state (read from /auth/me via [AuthController.isPro] + account.proUntil).
  // Pro shows an "Active" pill + the horizon; free shows a calm informational line. The Upgrade/buy
  // affordance (paywall → Stripe Checkout / IAP) is a separate slice — no dead button here.
  Widget _subscriptionSection(OnboardingPalette p) {
    final pro = widget.auth.isPro;
    final until = widget.auth.account?.proUntil;
    final purchases = widget.purchases;
    return settingsSection(p, 'Subscription', [
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          settingRow(
            p,
            title: pro ? 'Capecho Pro' : 'Free plan',
            desc: pro
                ? (until != null ? 'Active through ${_formatDate(until)}.' : 'Active.')
                : 'Saving, review, and the word explanation stay free and unlimited. Pro lifts the '
                      'one per-use limit — the daily cap on in-context explanations.',
            descMuted: !pro,
            control: pro
                ? settingsPill(p, 'Active', p.success)
                : ObPrimaryButton(p: p, label: 'Upgrade', onPressed: _showPaywall),
          ),
          // Mac App Store only: a Restore affordance directly below the row so a subscriber on a
          // reinstall / new device — or an App Review tester whose sandbox account is already subscribed
          // ("Active", no Upgrade button) — can always reach restore (App Store guideline 3.1.1) without
          // going through the Upgrade paywall. The direct/Stripe build restores by simply signing in (the
          // entitlement is account-scoped server-side), so it shows no button.
          if (purchases != null) _restoreRow(p, purchases),
        ],
      ),
    ]);
  }

  /// The Mac App Store "Restore purchases" affordance (guideline 3.1.1). Triggers
  /// [ProPurchaseController.restore]; a restored, still-active subscription flows through verify →
  /// account refresh, so the row above flips to "Active" on its own (this section sits in an
  /// `AnimatedBuilder` on `auth`). Listens to the controller for the in-flight spinner + any error.
  Widget _restoreRow(OnboardingPalette p, ProPurchaseController purchases) {
    return AnimatedBuilder(
      animation: purchases,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: purchases.isBusy ? null : () => unawaited(purchases.restore()),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: purchases.restoring
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ObEchoLoader(color: p.primary, size: 17),
                          const SizedBox(width: 8),
                          Text(
                            'Restoring…',
                            style: p.chrome(size: 13, weight: FontWeight.w500, color: p.primary),
                          ),
                        ],
                      )
                    : Text(
                        'Restore purchases',
                        style: p.chrome(size: 13, weight: FontWeight.w500, color: p.primary),
                      ),
              ),
            ),
            if (purchases.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
                child: Text(
                  purchases.error!,
                  style: p
                      .chrome(size: 12, weight: FontWeight.w400, color: p.error)
                      .copyWith(height: 1.3),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Open the Pro paywall (DT1). The distribution rail decides which: the **Mac App Store** build shows
  /// the Apple-IAP [ProPaywallIap] (StoreKit live prices → `buy` → `/billing/apple/verify`), required
  /// because Apple forbids external payment for digital subscriptions; the **direct** build shows the
  /// Stripe [ProPaywall] (`POST /billing/stripe/checkout` → the browser). Either way the Subscription row
  /// flips to "Active" once `/auth/me` refreshes after fulfillment (the IAP verify / the Stripe webhook).
  void _showPaywall() {
    final purchases = widget.purchases;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.34),
      builder: (dialogContext) {
        final dp = OnboardingPalette.of(dialogContext);
        if (purchases != null) {
          return ProPaywallIap(
            p: dp,
            controller: purchases,
            onClose: () => Navigator.of(dialogContext).maybePop(),
          );
        }
        return ProPaywall(
          p: dp,
          startCheckout: (plan) => widget.auth.api.startCheckout(plan: plan),
          openUrl: _openExternal,
          onClose: () => Navigator.of(dialogContext).maybePop(),
        );
      },
    );
  }

  /// A calm "Mon D, YYYY" label for the Pro horizon (no intl dependency — the date is informational).
  static String _formatDate(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  // ---- Word Book pointer ---------------------------------------------------

  Widget _wordBookPointer(OnboardingPalette p) {
    return settingsSection(p, 'Your words', [
      InkWell(
        onTap: _openWordBook,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Manage your saved words',
                      style: p.chrome(size: 14, weight: FontWeight.w500, color: p.ink),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Browse, search, and export your words in the Word Book.',
                      style: p
                          .chrome(size: 13, weight: FontWeight.w400, color: p.ink3)
                          .copyWith(height: 1.45),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.arrow_forward, size: 18, color: p.ink3),
            ],
          ),
        ),
      ),
    ]);
  }

  // ---- Getting started (replay onboarding) ---------------------------------

  /// A tappable row that re-opens the onboarding walkthrough, so a user can
  /// re-learn capture → save → review any time (the flow is otherwise first-run
  /// only). Wired by the host via [SettingsScreen.onReplayOnboarding]; the section
  /// is hidden when that's null. Available signed-in or out.
  Widget _gettingStartedSection(OnboardingPalette p) {
    return settingsSection(p, 'Getting started', [
      InkWell(
        onTap: widget.onReplayOnboarding,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Get Started',
                      style: p.chrome(size: 14, weight: FontWeight.w500, color: p.ink),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      'Replay the welcome walkthrough — capture, save, and review.',
                      style: p
                          .chrome(size: 13, weight: FontWeight.w400, color: p.ink3)
                          .copyWith(height: 1.45),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.arrow_forward, size: 18, color: p.ink3),
            ],
          ),
        ),
      ),
    ]);
  }

  // ---- About (version + legal + contact) -----------------------------------

  /// The legal pages + a support contact. Universal — shown signed-in or out. The links open in the
  /// browser / mail client via [SettingsScreen.openExternalUrl]. The version sits on its own at the very
  /// bottom of Settings ([_versionFooter]).
  Widget _aboutSection(OnboardingPalette p) {
    return settingsSection(p, 'About', [
      _linkRow(p, 'Privacy Policy', () => _openExternal(Uri.parse(CapechoLinks.privacyPolicy))),
      _linkRow(p, 'Terms of Service', () => _openExternal(Uri.parse(CapechoLinks.terms))),
      _linkRow(p, 'Contact support', () => _openExternal(Uri.parse(CapechoLinks.contactPage))),
      _linkRow(p, 'capecho.com', () => _openExternal(Uri.parse(CapechoLinks.website))),
    ]);
  }

  /// The app version, alone at the very bottom of Settings — quiet, centered, NON-interactive (support
  /// info, not a destination; read from the bundle so a release shows its real
  /// CFBundleShortVersionString). A null label (still loading / unavailable) renders nothing.
  Widget _versionFooter(OnboardingPalette p) {
    final v = _appVersion;
    if (v == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Center(
        child: Text('Capecho $v', style: p.mono(size: 12, color: p.ink3)),
      ),
    );
  }

  /// A tappable About row: title (+ optional sub) on the left, an "opens externally" glyph on the
  /// right. Mirrors the Word Book / Getting-started pointer rows (InkWell over the row padding).
  Widget _linkRow(OnboardingPalette p, String title, VoidCallback onTap, {String? sub}) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: p.chrome(size: 14, weight: FontWeight.w500, color: p.ink),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      sub,
                      style: p
                          .chrome(size: 13, weight: FontWeight.w400, color: p.ink3)
                          .copyWith(height: 1.45),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(Icons.open_in_new, size: 16, color: p.ink3),
          ],
        ),
      ),
    );
  }

  // ---- Delete-account confirm dialog ---------------------------------------

  void _showDeleteDialog() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.34),
      builder: (dialogContext) {
        final p = OnboardingPalette.of(dialogContext);
        return DeleteAccountDialog(p: p, auth: widget.auth);
      },
    );
  }

  // ---- loading skeleton ----------------------------------------------------

  Widget _loadingSkeleton(OnboardingPalette p) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 32),
      child: Center(
        // Match the loaded content's fill width (900) so the skeleton doesn't jump narrower→wider.
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: const SettingsSkeleton(),
        ),
      ),
    );
  }

  // ---- controls ------------------------------------------------------------

  Widget _timefield(OnboardingPalette p, String hhmm, {required bool enabled}) {
    final box = Container(
      constraints: const BoxConstraints(minWidth: 92),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: p.card,
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(8),
        boxShadow: enabled ? [BoxShadow(color: p.edge, offset: const Offset(2, 2))] : null,
      ),
      alignment: Alignment.center,
      child: Text(hhmm, style: p.mono(size: 14, color: enabled ? p.ink : p.ink3)),
    );
    if (!enabled) return box;
    return InkWell(borderRadius: BorderRadius.circular(8), onTap: _pickTime, child: box);
  }

  Future<void> _pickTime() async {
    final current = _c.reminderTimeOverride ?? widget.auth.account?.reminderTime ?? '20:00';
    final parts = current.split(':');
    final initial = TimeOfDay(
      hour: int.tryParse(parts.first) ?? 20,
      minute: parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0,
    );
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null) return;
    _c.setReminderTime(
      '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}',
    );
  }

  /// Prepends a save-state pill to [control] when [field] is queued/failed. The
  /// transient `saving` shows nothing (optimistic — the value is already applied), so a fast save is
  /// invisible and only the error/queued states surface.
  Widget _withSaveState(OnboardingPalette p, SettingField field, Widget control) {
    final status = _c.saveStatusOf(field);
    if (status == null || status == SaveStatus.saving) return control;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [savePill(p, status), const SizedBox(width: 10), control],
    );
  }

  /// A section-foot notice for an offline-queued (8a, `--warning`) or save-failed (8b, `--error` +
  /// Retry) change. [fields] are the section's savable fields; a failure takes precedence over queued.
  Widget _saveNoticeRow(OnboardingPalette p, List<SettingField> fields) {
    final failed = fields.where((f) => _c.saveStatusOf(f) == SaveStatus.failed).toList();
    final queued = fields.where((f) => _c.saveStatusOf(f) == SaveStatus.queued).toList();
    final isFailed = failed.isNotEmpty;
    final tone = isFailed ? p.error : p.warning;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          settingsNotice(
            p,
            tone: tone,
            icon: isFailed ? Icons.error_outline : Icons.warning_amber_rounded,
            body: Text.rich(
              TextSpan(
                style: p
                    .chrome(size: 13, weight: FontWeight.w400, color: p.ink2)
                    .copyWith(height: 1.5),
                children: isFailed
                    ? [
                        TextSpan(
                          text: 'Couldn’t save that change.',
                          style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
                        ),
                        const TextSpan(
                          text:
                              ' Your choice is kept on this Mac. We’ll keep trying — or retry now.',
                        ),
                      ]
                    : [
                        TextSpan(
                          text: 'You’re offline — this change is queued.',
                          style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
                        ),
                        const TextSpan(
                          text:
                              ' It’ll sync automatically the next time you’re online. Nothing is lost.',
                        ),
                      ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            // Always offer a manual "Retry now" — queued (offline) included, toned to the notice — so
            // an offline change is never a dead end; true auto-flush-on-reconnect is a §12 follow-up.
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: tone,
                side: BorderSide(color: tone),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                textStyle: p.chrome(size: 14, weight: FontWeight.w600),
              ),
              onPressed: () {
                for (final f in [...failed, ...queued]) {
                  _c.retry(f);
                }
              },
              child: const Text('Retry now'),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// A custom iOS-style toggle: 42×25 pill, primary track when on.
// ════════════════════════════════════════════════════════════════════════════

class _Toggle extends StatelessWidget {
  const _Toggle({required this.p, required this.value, required this.onChanged});
  final OnboardingPalette p;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      button: true,
      child: GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          width: 42,
          height: 25,
          decoration: BoxDecoration(
            color: value ? p.primary : p.line,
            border: Border.all(color: value ? p.primary : p.line),
            borderRadius: BorderRadius.circular(999),
          ),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          padding: const EdgeInsets.all(2),
          child: Container(
            width: 19,
            height: 19,
            decoration: BoxDecoration(
              color: p.dark && value ? p.primaryFg : Colors.white,
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(color: Color(0x47000000), blurRadius: 2, offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
