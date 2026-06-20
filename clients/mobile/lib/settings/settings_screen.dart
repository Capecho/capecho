import 'dart:async';

import 'package:capecho_api/capecho_api.dart' show ApiException;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import '../billing/upgrade_sheet.dart';
import '../notifications/notification_permissions.dart';
import '../web/in_app_browser.dart';
import 'delete_account_sheet.dart';
import 'language_sheet.dart';
import 'settings_widgets.dart';
import 'toggle.dart';

/// The mobile Settings surface (US-SET.1, mobile subset): **Reminders** (daily on/off + time),
/// **Language** (learning language + explanation language), and **Account** (identity, sign out, delete
/// account + data). It has **no capture-permission or shortcuts section** — those are macOS-only; the
/// phone has neither.
///
/// Touch-first: ≥44px targets, an iOS-style toggle, a segmented explanation-language control, and a
/// learning-language picker. Returns a plain scrollable widget (no Scaffold) — it's presented as a
/// near-full-screen bottom popover (`showCapechoSheet`) from the home's top-left corner button, on the
/// warm canvas, like `word_book_screen.dart`.
///
/// Reached only when signed in (the home opens it as a popover), so there's no signed-out invite and no
/// loading skeleton (the account is already in memory from sign-in / restore). Reminders + languages are
/// real account settings persisted via `PATCH /account`. Saving the reminder preference is load-bearing:
/// the app's `ReminderScheduler` (wired in `app.dart`) re-arms or cancels the actual daily local
/// notification off the saved value (US-14.1); this screen still only persists the preference — the
/// scheduling reacts to it.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.auth,
    required this.appearance,
    this.notifications,
    this.purchases,
    this.loadAppVersion,
    this.onOpenLink,
  });

  final AuthController auth;

  /// The iOS Apple-IAP buy controller (app-lifetime, owned in `app.dart`). Non-null only where in-app
  /// purchase is offered (iOS); null on Android (Pro is bought on the web — Play anti-steering) and in
  /// tests, where the Subscription group renders status-only with no buy row.
  final ProPurchaseController? purchases;

  /// Device-local Light/Dark/System controller, surfaced in the Appearance group and driving the root
  /// `MaterialApp.themeMode`.
  final AppearanceController appearance;

  /// Notification-permission probe for the Reminders section: when the daily reminder is on but the OS
  /// permission is denied, the section shows a warning + an "Open Settings" jump (the toggle alone can't
  /// fire anything). Null → the warning is never shown (e.g. a test that doesn't exercise it).
  final NotificationPermissions? notifications;

  /// Settings → About: loads the app version label (e.g. "0.1.5 (10500)"). Injected so widget tests
  /// pass a literal; defaults to reading the platform bundle via [capechoAppVersion]. A null result
  /// shows a calm placeholder.
  final Future<String?> Function()? loadAppVersion;

  /// Settings → About: opens a legal/contact link. Injected so tests record the target; defaults to the
  /// in-app browser ([openInAppBrowser]) so the reader never leaves Capecho (the pages open in a WebView,
  /// not the system browser).
  final void Function(Uri uri)? onOpenLink;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

/// Two axes (§9). The explanation (gloss) set keeps all nine backend-supported gloss languages; the
/// learning (capture-target) set shows ONLY the generation-ENABLED targets (the lang registry's
/// `enabled` set — en + zh-Hans): a target outside it gets no explanations at all, so offering it would
/// break the core loop. Both code lists are owned in app-core ([learningLanguages] /
/// [explanationLanguages]); [langName] renders the human label. Extend the learning set ONLY when a new
/// language passes its paid eval gate (docs/adding-a-target-language.md).
const List<String> _learningLangs = learningLanguages;

class _SettingsScreenState extends State<SettingsScreen> with WidgetsBindingObserver {
  late final AccountSettingsController _c;

  /// The bundle version label for the About footer, loaded async in [initState]; null while loading
  /// (or when unavailable, e.g. in a widget test).
  String? _appVersion;

  /// Current OS notification permission, for the Reminders warning. Null = unknown / not probed (no
  /// [SettingsScreen.notifications] seam, or the check is still in flight) → no warning shown.
  bool? _notifGranted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _c = AccountSettingsController(
      // Always non-null + reactive: `_saveAccount` gates on the LIVE session, so it persists while
      // signed in (and becomes a no-op the instant a sign-out drops the session) — unlike a value
      // captured once.
      saveAccount: _saveAccount,
    );
    // Pull the latest account on open so a change made on another device/client (e.g. macOS) shows
    // here without a relaunch — the two clients otherwise only see their own last write (bug #4).
    unawaited(widget.auth.refreshAccount());
    unawaited(_loadAppVersion());
    unawaited(_refreshNotifPermission());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check on resume so a user who flipped notifications on in the OS Settings (via the warning's
    // "Open Settings") returns to a cleared warning without a relaunch.
    if (state == AppLifecycleState.resumed) unawaited(_refreshNotifPermission());
  }

  /// Resolve the About footer's version label — the injected loader, else the bundle reader.
  Future<void> _loadAppVersion() async {
    final load = widget.loadAppVersion ?? () async => (await capechoAppVersion())?.label;
    final v = await load();
    if (mounted) setState(() => _appVersion = v);
  }

  /// Probe the current OS notification permission (no prompt) for the Reminders warning.
  Future<void> _refreshNotifPermission() async {
    final probe = widget.notifications;
    if (probe == null) return;
    final granted = await probe.hasPermission();
    if (mounted) setState(() => _notifGranted = granted);
  }

  /// Toggle the daily reminder. Beyond persisting the preference, turning it ON requests the OS
  /// permission so a denial surfaces immediately (the warning), instead of the toggle silently
  /// "succeeding" while nothing can ever fire.
  Future<void> _onToggleReminders(bool on) async {
    _c.setRemindersOn(on);
    final probe = widget.notifications;
    if (probe == null) return;
    if (on) {
      final granted = await probe.requestPermission();
      if (mounted) setState(() => _notifGranted = granted);
    } else if (mounted) {
      setState(() => _notifGranted = null); // off → no warning to show
    }
  }

  /// Open a legal/contact link — the injected recorder (tests), else the in-app browser so the page
  /// opens in a WebView inside Capecho rather than bouncing to the system browser.
  void _openLink(Uri uri, String title) {
    final injected = widget.onOpenLink;
    if (injected != null) {
      injected(uri);
      return;
    }
    openInAppBrowser(context, url: uri, title: title);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _c.dispose();
    super.dispose();
  }

  /// Bridges [AccountSettingsController.saveAccount] to the live `PATCH /account`. Only the changed
  /// (non-null) field is sent. A no-op without a live session. On success the returned [Account] is
  /// applied to [AuthController] so every surface stays authoritative. A 401 means the session died
  /// server-side → sign out (the shell returns to sign-in) rather than leaving an endlessly-failing
  /// "Retry". Other errors rethrow so the controller marks the field queued (transport) / failed
  /// (backend).
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
    return AnimatedBuilder(
      animation: Listenable.merge([widget.auth, _c, widget.appearance]),
      builder: (context, _) => _content(p),
    );
  }

  Widget _content(OnboardingPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _titleBar(p),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 24),
            // Ordered by user priority: Language leads (it shapes every capture + explanation), then
            // Reminders, Account, Subscription, cosmetic Appearance, and About pinned last.
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _languageGroup(p),
                _remindersGroup(p),
                _accountGroup(p),
                _subscriptionGroup(p),
                _appearanceGroup(p),
                _aboutGroup(p),
                _versionFooter(p),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// A centered editorial-serif "Settings" title (no echo/back — the popover is dismissed by closing it).
  Widget _titleBar(OnboardingPalette p) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 12, 0, 10),
    child: Center(
      child: Text('Settings', style: p.display(size: 19, color: p.ink)),
    ),
  );

  // ---- Reminders -----------------------------------------------------------

  Widget _remindersGroup(OnboardingPalette p) {
    final account = widget.auth.account;
    final on = _c.remindersOnOverride ?? account?.reminderEnabled ?? false;
    final time = _c.reminderTimeOverride ?? account?.reminderTime ?? '20:00';
    const fields = [SettingField.reminderEnabled, SettingField.reminderTime];
    return _group(
      p,
      'Reminders',
      card: settingsCard(p, [
        // Daily reminder toggle.
        settingsRow(
          p,
          label: 'Daily reminder',
          sub: 'Only when words are due',
          trailing: _withSavePill(
            p,
            SettingField.reminderEnabled,
            Toggle(p: p, value: on, onChanged: _onToggleReminders),
          ),
        ),
        // Time control — disabled/greyed when reminders are off, not removed.
        settingsRow(
          p,
          label: 'Time',
          disabled: !on,
          onTap: on ? _pickTime : null,
          trailing: _withSavePill(
            p,
            SettingField.reminderTime,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(time, style: p.mono(size: 13, color: on ? p.ink2 : p.ink3)),
                const SizedBox(width: 6),
                settingsChevron(p, disabled: !on),
              ],
            ),
          ),
        ),
      ]),
      // Helper line when off; the save notice takes precedence when unsaved.
      note: _c.anyUnsaved(fields)
          ? null
          : (on ? null : 'Reminders are off. Turn the toggle on to set a time.'),
      saveNoticeFields: fields,
      // When reminders are ON but the OS permission is denied, nothing can fire — warn + offer the jump
      // to system settings (shown below the card regardless of the save notice).
      footer: (on && widget.notifications != null && _notifGranted == false)
          ? _permissionWarning(p)
          : null,
    );
  }

  /// Reminders are on, but the OS won't deliver them — the toggle alone is a no-op. A calm warning with
  /// an "Open Settings" jump to Capecho's notification settings (the only place the user can re-grant).
  Widget _permissionWarning(OnboardingPalette p) {
    final tone = p.warning;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: p.dark ? 0.16 : 0.10),
              border: Border.all(color: p.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    '▲',
                    style: p.chrome(size: 14, weight: FontWeight.w700, color: tone),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: p
                          .chrome(size: 12, weight: FontWeight.w400, color: p.ink2)
                          .copyWith(height: 1.55),
                      children: [
                        TextSpan(
                          text: 'Notifications are turned off for Capecho.',
                          style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
                        ),
                        const TextSpan(
                          text:
                              ' Your daily reminder is saved, but the phone won’t show it until you turn '
                              'notifications on in Settings.',
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: tone,
                side: BorderSide(color: tone),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                textStyle: p.chrome(size: 13, weight: FontWeight.w600),
              ),
              onPressed: () => unawaited(widget.notifications!.openSystemSettings()),
              child: const Text('Open Settings'),
            ),
          ),
        ],
      ),
    );
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

  // ---- Language ------------------------------------------------------------

  Widget _languageGroup(OnboardingPalette p) {
    final account = widget.auth.account;
    // Native (explanation) language is a DIRECT pick — the account's server-resolved value.
    final explanationChoice = _c.explanationOverride ?? (account?.explanationLanguage ?? 'en');
    final learning = _c.learningOverride ?? account?.learningLanguage;
    const fields = [SettingField.explanation, SettingField.learning];
    return _group(
      p,
      'Language',
      card: settingsCard(p, [
        // Learning language: a tap-to-pick row (value + chevron → a language menu).
        settingsRow(
          p,
          label: 'Learning Language',
          sub: 'Default target for new captures',
          onTap: _pickLearningLanguage,
          trailing: _withSavePill(
            p,
            SettingField.learning,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  learning == null ? 'Not set' : langName(learning),
                  style: p.chrome(size: 13, color: p.ink2),
                ),
                const SizedBox(width: 6),
                settingsChevron(p),
              ],
            ),
          ),
        ),
        // Native language: a tap-to-pick row (value + chevron → the language sheet).
        settingsRow(
          p,
          label: 'Native language',
          sub: 'Your language — explanations or translations',
          onTap: _pickExplanationLanguage,
          trailing: _withSavePill(
            p,
            SettingField.explanation,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(langName(explanationChoice), style: p.chrome(size: 13, color: p.ink2)),
                const SizedBox(width: 6),
                settingsChevron(p),
              ],
            ),
          ),
        ),
      ]),
      note: _c.anyUnsaved(fields)
          ? null
          : 'Existing explanations refresh in the new language as you open words. '
                'Learning language only changes the default for future captures.',
      saveNoticeFields: fields,
    );
  }

  Future<void> _pickLearningLanguage() async {
    final p = OnboardingPalette.of(context);
    final current = _c.learningOverride ?? widget.auth.account?.learningLanguage;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: p.card,
      constraints: const BoxConstraints(maxWidth: double.infinity), // fill the full width
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) =>
          LanguageSheet(p: p, title: 'Learning Language', codes: _learningLangs, current: current),
    );
    if (picked != null) _c.setLearningLanguage(picked);
  }

  Future<void> _pickExplanationLanguage() async {
    final p = OnboardingPalette.of(context);
    final account = widget.auth.account;
    final current = _c.explanationOverride ?? account?.explanationLanguage;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: p.card,
      constraints: const BoxConstraints(maxWidth: double.infinity), // fill the full width
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) => LanguageSheet(
        p: p,
        title: 'Native language',
        codes: explanationLanguages,
        current: current,
      ),
    );
    if (picked != null) _c.setExplanationLanguage(picked);
  }

  // ---- Appearance (device-local) -------------------------------------------
  // The control is built from the shared design tokens and persists on this device (secure storage),
  // separate from the account — appearance is a per-device choice.
  Widget _appearanceGroup(OnboardingPalette p) {
    return _group(
      p,
      'Appearance',
      card: settingsCard(p, [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: AppearanceControl(
            p: p,
            mode: widget.appearance.mode,
            onChanged: (m) => widget.appearance.setMode(m),
          ),
        ),
      ]),
      note: 'System follows your phone. Light or Dark keeps Capecho fixed — saved on this device.',
    );
  }

  // ---- Account -------------------------------------------------------------

  Widget _accountGroup(OnboardingPalette p) {
    // Identity from /auth/me (provider + email). `name` isn't exposed (Apple shares it unreliably), so
    // the row is the provider label + email. A null email (e.g. Apple private relay) falls back to a
    // calm "Signed in".
    final account = widget.auth.account;
    final email = account?.email;
    final providerLabel = _providerLabel(account?.provider);
    return _group(
      p,
      'Account',
      card: settingsCard(p, [
        // Identity row: provider initial avatar + provider label + email.
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: p.primary, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: (email != null && email.isNotEmpty)
                    ? Text(
                        email[0].toUpperCase(),
                        style: p.chrome(size: 15, weight: FontWeight.w600, color: p.primaryFg),
                      )
                    : Icon(Icons.person_outline, size: 18, color: p.primaryFg),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      providerLabel ?? 'Signed in',
                      style: p.chrome(size: 14, weight: FontWeight.w500, color: p.ink),
                    ),
                    if (email != null && email.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        email,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: p.chrome(size: 11.5, color: p.ink3),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        // Sign out. Dismiss the Settings popover first so it isn't left floating over the sign-in
        // screen while the (async) sign-out completes (app.dart also dismisses on the signed-out edge as
        // a backstop for the delete-account / 401 paths).
        settingsRow(
          p,
          label: 'Sign out',
          onTap: widget.auth.busy
              ? null
              : () {
                  Navigator.of(context).maybePop();
                  unawaited(widget.auth.signOut());
                },
          trailing: settingsChevron(p),
        ),
        // Delete account & data — the destructive row (opens a confirm sheet).
        settingsRow(
          p,
          label: 'Delete account & data',
          labelColor: p.error,
          onTap: widget.auth.busy ? null : _showDeleteSheet,
          trailing: settingsChevron(p),
        ),
      ]),
      note: 'Manage your saved words in the Word Book.',
    );
  }

  /// Human label for the sign-in provider; null for an unknown/absent value.
  String? _providerLabel(String? provider) => switch (provider) {
    'apple' => 'Apple',
    'google' => 'Google',
    'email' => 'Email',
    _ => null,
  };

  /// The delete-account confirm, drawn as an iOS bottom sheet over the dimmed screen.
  void _showDeleteSheet() {
    final p = OnboardingPalette.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: double.infinity), // fill the full width
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: p.dark ? 0.55 : 0.40),
      builder: (sheetContext) => DeleteAccountSheet(p: p, auth: widget.auth),
    );
  }

  // ---- Subscription (Pro status) -------------------------------------------
  // Server-authoritative Pro state (read from /auth/me via [AuthController.isPro] + account.proUntil).
  // Pro shows an "Active" pill + the horizon; free a calm informational line. The Upgrade/buy affordance
  // (paywall → IAP) is a separate slice — no dead control here.
  Widget _subscriptionGroup(OnboardingPalette p) {
    final pro = widget.auth.isPro;
    final until = widget.auth.account?.proUntil;
    // The in-app buy entry is iOS-only: Android buys Pro on the web (Play anti-steering), and tests pass
    // no controller. Pro users see status only.
    final canBuy =
        !pro && widget.purchases != null && Theme.of(context).platform == TargetPlatform.iOS;
    return _group(
      p,
      'Subscription',
      card: settingsCard(p, [
        settingsRow(
          p,
          label: pro ? 'Capecho Pro' : 'Free plan',
          sub: pro
              ? (until != null ? 'Active through ${_formatDate(until)}' : 'Active')
              : 'A daily in-context-explanation cap applies on the free plan',
          trailing: settingsStatusPill(p, pro ? 'Active' : 'Free', pro ? p.success : p.ink3),
        ),
        // Free + iOS: the buy entry. Opens the compact upgrade sheet with the live App Store prices.
        if (canBuy)
          settingsRow(
            p,
            label: 'Upgrade to Pro',
            sub: 'Unlimited in-context explanations',
            labelColor: p.primary,
            onTap: () => unawaited(showUpgradeSheet(context, widget.purchases!)),
            trailing: settingsChevron(p),
          ),
      ]),
      note: pro
          ? null
          : 'Saving, review, and the word explanation stay free and unlimited. Pro lifts the '
                'one per-use limit — the daily cap on in-context explanations.',
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

  // ---- About (legal + contact) ---------------------------------------------

  /// The legal pages + a support contact. Each opens IN-APP (a WebView via [_openLink]) so the reader
  /// stays inside Capecho. The version sits in its own footer at the very bottom ([_versionFooter]).
  Widget _aboutGroup(OnboardingPalette p) {
    return _group(
      p,
      'About',
      card: settingsCard(p, [
        settingsRow(
          p,
          label: 'Privacy Policy',
          onTap: () => _openLink(Uri.parse(CapechoLinks.privacyPolicy), 'Privacy Policy'),
          trailing: settingsChevron(p),
        ),
        settingsRow(
          p,
          label: 'Terms of Service',
          onTap: () => _openLink(Uri.parse(CapechoLinks.terms), 'Terms of Service'),
          trailing: settingsChevron(p),
        ),
        settingsRow(
          p,
          label: 'Contact support',
          onTap: () => _openLink(Uri.parse(CapechoLinks.contactPage), 'Contact support'),
          trailing: settingsChevron(p),
        ),
        settingsRow(
          p,
          label: 'capecho.com',
          onTap: () => _openLink(Uri.parse(CapechoLinks.website), 'Capecho'),
          trailing: settingsChevron(p),
        ),
      ]),
    );
  }

  /// The app version, alone at the very bottom of Settings — quiet, centered, NON-interactive (it's
  /// support info, not a destination). A null label (still loading / unavailable) renders nothing.
  Widget _versionFooter(OnboardingPalette p) {
    final v = _appVersion;
    if (v == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Center(
        child: Text('Capecho $v', style: p.mono(size: 12, color: p.ink3)),
      ),
    );
  }

  // ---- shared group / card / row primitives --------------------------------

  /// A settings group: an uppercase label, a card, then an optional contextual note and/or a save-status
  /// notice for the group's savable [saveNoticeFields].
  Widget _group(
    OnboardingPalette p,
    String label, {
    required Widget card,
    String? note,
    List<SettingField> saveNoticeFields = const [],
    Widget? footer,
  }) {
    final showSaveNotice = saveNoticeFields.isNotEmpty && _c.anyUnsaved(saveNoticeFields);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 7),
            child: Text(
              label.toUpperCase(),
              style: p.chrome(
                size: 10.5,
                weight: FontWeight.w600,
                color: p.ink3,
                letterSpacing: 0.07 * 10.5,
              ),
            ),
          ),
          card,
          if (showSaveNotice) _saveNotice(p, saveNoticeFields),
          if (note != null && !showSaveNotice)
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 16, 6, 0),
              child: Text(
                note,
                style: p
                    .chrome(size: 11, weight: FontWeight.w400, color: p.ink3)
                    .copyWith(height: 1.5),
              ),
            ),
          ?footer,
        ],
      ),
    );
  }

  /// Prepends a save-state pill to [control] when [field] is queued/failed. The transient `saving` shows
  /// nothing (optimistic — the value is already applied), so a fast save is invisible and only the
  /// queued/failed states surface.
  Widget _withSavePill(OnboardingPalette p, SettingField field, Widget control) {
    final status = _c.saveStatusOf(field);
    if (status == null || status == SaveStatus.saving) return control;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [savePill(p, status), const SizedBox(width: 8), control],
    );
  }

  /// A calm inline status notice with a standard alert glyph (never the echo) for an offline-queued
  /// (warning) or save-failed (error) change. A failure takes precedence over queued; a manual Retry is
  /// always offered (offline included) so a queued change is never a dead end — true
  /// auto-flush-on-reconnect is a §12 follow-up.
  Widget _saveNotice(OnboardingPalette p, List<SettingField> fields) {
    final failed = fields.where((f) => _c.saveStatusOf(f) == SaveStatus.failed).toList();
    final queued = fields.where((f) => _c.saveStatusOf(f) == SaveStatus.queued).toList();
    final isFailed = failed.isNotEmpty;
    final tone = isFailed ? p.error : p.warning;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: tone.withValues(alpha: p.dark ? 0.16 : 0.10),
              border: Border.all(color: p.line),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    isFailed ? '⚠' : '▲',
                    style: p.chrome(size: 14, weight: FontWeight.w700, color: tone),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: p
                          .chrome(size: 12, weight: FontWeight.w400, color: p.ink2)
                          .copyWith(height: 1.55),
                      children: isFailed
                          ? [
                              TextSpan(
                                text: 'Couldn’t save that change.',
                                style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
                              ),
                              const TextSpan(
                                text:
                                    ' Your choice is kept on this device. We’ll keep trying — or retry now.',
                              ),
                            ]
                          : [
                              TextSpan(
                                text: 'You’re offline — this change is kept on this device.',
                                style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
                              ),
                              const TextSpan(
                                text: ' Tap Retry when you’re back online to save it.',
                              ),
                            ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: tone,
                side: BorderSide(color: tone),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                textStyle: p.chrome(size: 13, weight: FontWeight.w600),
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
