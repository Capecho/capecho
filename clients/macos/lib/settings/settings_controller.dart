import 'dart:async';

import 'package:capecho_api/capecho_api.dart' show ApiException;
import 'package:capecho_app_core/capecho_app_core.dart' show SaveStatus, SettingField;
import 'package:capture_native/capture_native.dart' show CapechoShortcut;
import 'package:flutter/foundation.dart';

/// The macOS Screen-Recording permission, as Settings sees it. `unknown` is the honest
/// pre-probe (and probe-failed) state — the UI shows a neutral "Checking…" rather than a
/// false "Off" that would wrongly imply capture is broken.
enum CapturePermission { unknown, granted, off }

// SettingField and SaveStatus are the shared settings-save vocabulary — defined once in
// capecho_app_core (account_settings_controller) and imported above, so the macOS SettingsController
// and the shared AccountSettingsController stay in lockstep.

typedef LoadShortcuts = Future<List<CapechoShortcut>> Function();
typedef SaveShortcut =
    Future<CapechoShortcut> Function({
      required String action,
      required String key,
      required List<String> modifiers,
    });

const List<String> kShortcutActionOrder = ['capture', 'review', 'wordBook'];
const List<CapechoShortcut> kDefaultShortcuts = [
  CapechoShortcut(
    action: 'capture',
    title: 'Capture',
    key: 'E',
    modifiers: ['option'],
    display: '⌥E',
  ),
  CapechoShortcut(
    action: 'review',
    title: 'Review',
    key: 'R',
    modifiers: ['option'],
    display: '⌥R',
  ),
  CapechoShortcut(
    action: 'wordBook',
    title: 'Word Book',
    key: 'B',
    modifiers: ['option'],
    display: '⌥B',
  ),
];

Future<List<CapechoShortcut>> _defaultLoadShortcuts() async => kDefaultShortcuts;

String normalizeShortcutKey(String key) {
  final trimmed = key.trim();
  return trimmed.length == 1 ? trimmed.toUpperCase() : trimmed;
}

List<String> normalizeShortcutModifiers(List<String> modifiers) {
  final input = modifiers.map((m) => m.toLowerCase()).toSet();
  return [
    for (final modifier in ['control', 'option', 'shift', 'command'])
      if (input.contains(modifier)) modifier,
  ];
}

String shortcutDisplay(String key, List<String> modifiers) {
  final normalized = normalizeShortcutModifiers(modifiers);
  final buffer = StringBuffer();
  if (normalized.contains('control')) buffer.write('⌃');
  if (normalized.contains('option')) buffer.write('⌥');
  if (normalized.contains('shift')) buffer.write('⇧');
  if (normalized.contains('command')) buffer.write('⌘');
  buffer.write(normalizeShortcutKey(key));
  return buffer.toString();
}

bool _sameModifiers(List<String> a, List<String> b) {
  final normalizedA = normalizeShortcutModifiers(a);
  final normalizedB = normalizeShortcutModifiers(b);
  if (normalizedA.length != normalizedB.length) return false;
  for (var i = 0; i < normalizedA.length; i++) {
    if (normalizedA[i] != normalizedB[i]) return false;
  }
  return true;
}

/// Drives the macOS Settings surface. Genuinely wired: the Screen-Recording capture permission
/// (status + the open-System-Settings deep link), Sign out (through [AuthController]), and the
/// Reminders + Language controls, which persist to the signed-in account via [saveAccount] →
/// `PATCH /account`.
///
/// Each control updates OPTIMISTICALLY (so it feels live + the value is never dropped), then saves;
/// the per-field [SaveStatus] drives the `Saving` / `Queued` (offline) / `Not saved` (backend reject)
/// pills. When signed out [saveAccount] is null and changes stay UI-local (the member sections
/// aren't shown anyway).
///
/// Both platform seams are injected (the app wires `capture_native`; tests pass stubs) so the
/// whole controller is pure Dart and unit-testable with no plugins.
class SettingsController extends ChangeNotifier {
  SettingsController({
    required this.checkPermission,
    required this.openSystemSettings,
    LoadShortcuts? loadShortcuts,
    this.saveShortcut,
    this.saveAccount,
  }) : loadShortcuts = loadShortcuts ?? _defaultLoadShortcuts;

  /// Whether macOS Screen Recording is currently granted (`capture_native`). Probed, never
  /// assumed.
  final Future<bool> Function() checkPermission;

  /// Opens macOS System Settings → Privacy & Security → Screen Recording.
  final Future<void> Function() openSystemSettings;

  /// Reads the local device shortcuts from native UserDefaults.
  final LoadShortcuts loadShortcuts;

  /// Persists and re-registers one local device shortcut. Null in tests/fallback mode: changes remain
  /// UI-local.
  final SaveShortcut? saveShortcut;

  /// Persists a preference change to the signed-in account (`PATCH /account`). Null when signed out —
  /// changes then stay UI-local (the server 401s without a session). Throws an [ApiException] on a
  /// backend rejection, or another error on a transport/offline failure.
  final Future<void> Function({
    String? explanationLanguage,
    bool? explanationFollowsLearning,
    String? learningLanguage,
    bool? reminderEnabled,
    String? reminderTime,
  })?
  saveAccount;

  CapturePermission _permission = CapturePermission.unknown;
  CapturePermission get permission => _permission;

  bool _shortcutsLoading = true;
  bool get shortcutsLoading => _shortcutsLoading;

  String? _shortcutsError;
  String? get shortcutsError => _shortcutsError;

  List<CapechoShortcut> _shortcuts = kDefaultShortcuts;
  List<CapechoShortcut> get shortcuts => List.unmodifiable(_shortcuts);

  final Set<String> _shortcutSaving = {};
  final Map<String, String> _shortcutErrors = {};

  bool shortcutSaving(String action) => _shortcutSaving.contains(action);
  String? shortcutErrorOf(String action) => _shortcutErrors[action];

  CapechoShortcut shortcutFor(String action) => _shortcuts.firstWhere(
    (s) => s.action == action,
    orElse: () => kDefaultShortcuts.firstWhere((s) => s.action == action),
  );

  // ---- Preference overrides + per-field save state -------------------------------------------
  // Each control updates its override OPTIMISTICALLY (so it feels live + the value is never dropped),
  // then persists to the account via [saveAccount]. The effective displayed value = override ?? the
  // account's value (computed in the screen; on a successful save the host applies the returned account
  // via `AuthController.applyAccount`, so it stays authoritative). When signed out [saveAccount] is null
  // and changes stay UI-local (server `/account` 401s without a session).
  bool? _remindersOnOverride;
  bool? get remindersOnOverride => _remindersOnOverride;
  String? _reminderTimeOverride; // 24h "HH:mm"
  String? get reminderTimeOverride => _reminderTimeOverride;
  String? _explanationOverride;
  String? get explanationOverride => _explanationOverride;
  String? _learningOverride;
  String? get learningOverride => _learningOverride;

  final Map<SettingField, SaveStatus> _saveStatus = {};
  // Per-field serialization: never run two PATCHes for the same field at once (so the server can't
  // persist them out of order). A change arriving mid-save is coalesced via `_dirty`; the in-flight
  // save re-runs with the LATEST override when it settles → ordered, last-write-wins server-side.
  final Set<SettingField> _inFlight = {};
  final Set<SettingField> _dirty = {};

  /// The persistence status of [field] (null = saved/idle; `saving` is transient — neither shows a pill).
  SaveStatus? saveStatusOf(SettingField field) => _saveStatus[field];

  /// Whether any of [fields] is queued or failed (drives a section's offline/failed notice + Retry).
  bool anyUnsaved(List<SettingField> fields) =>
      fields.any((f) => _saveStatus[f] == SaveStatus.queued || _saveStatus[f] == SaveStatus.failed);

  void setRemindersOn(bool on) {
    if (on == _remindersOnOverride) return;
    _remindersOnOverride = on;
    _notify();
    _scheduleSave(SettingField.reminderEnabled);
  }

  void setReminderTime(String hhmm) {
    if (hhmm == _reminderTimeOverride) return;
    _reminderTimeOverride = hhmm;
    _notify();
    _scheduleSave(SettingField.reminderTime);
  }

  // NOTE(issue #8): switching the explanation language also lazily re-fetches existing explanations in
  // the new language — that re-fetch happens in the Word Book when words are opened, not here.
  // NOTE(issue #15): switching the learning (target) language must NOT re-key existing units; PATCH
  // /account only stores the default target, so it doesn't.
  void setExplanationLanguage(String code) {
    if (code == _explanationOverride) return;
    _explanationOverride = code;
    _notify();
    _scheduleSave(SettingField.explanation);
  }

  void setLearningLanguage(String code) {
    if (code == _learningOverride) return;
    _learningOverride = code;
    _notify();
    _scheduleSave(SettingField.learning);
  }

  Future<void> refreshShortcuts() async {
    _shortcutsLoading = true;
    _shortcutsError = null;
    _notify();
    try {
      _shortcuts = _mergeShortcuts(await loadShortcuts());
    } catch (_) {
      _shortcuts = kDefaultShortcuts;
      _shortcutsError = 'Couldn’t load shortcuts.';
    } finally {
      _shortcutsLoading = false;
      _notify();
    }
  }

  Future<void> setShortcut({
    required String action,
    required String key,
    required List<String> modifiers,
  }) async {
    final normalizedKey = normalizeShortcutKey(key);
    final normalizedModifiers = normalizeShortcutModifiers(modifiers);
    _shortcutErrors.remove(action);

    if (normalizedModifiers.isEmpty) {
      _shortcutErrors[action] = 'Use at least one modifier key.';
      _notify();
      return;
    }

    CapechoShortcut? conflict;
    for (final shortcut in _shortcuts) {
      if (shortcut.action != action &&
          normalizeShortcutKey(shortcut.key) == normalizedKey &&
          _sameModifiers(shortcut.modifiers, normalizedModifiers)) {
        conflict = shortcut;
        break;
      }
    }
    if (conflict != null) {
      _shortcutErrors[action] = 'Already used by ${conflict.title}.';
      _notify();
      return;
    }

    _shortcutSaving.add(action);
    _notify();
    try {
      final save = saveShortcut;
      final updated = save == null
          ? _localShortcut(action, normalizedKey, normalizedModifiers)
          : await save(action: action, key: normalizedKey, modifiers: normalizedModifiers);
      _upsertShortcut(updated);
      _shortcutErrors.remove(action);
    } catch (e) {
      _shortcutErrors[action] = _shortcutErrorMessage(e);
    } finally {
      _shortcutSaving.remove(action);
      _notify();
    }
  }

  List<CapechoShortcut> _mergeShortcuts(List<CapechoShortcut> loaded) {
    return [
      for (final fallback in kDefaultShortcuts)
        _loadedShortcut(loaded, fallback.action) ?? fallback,
    ];
  }

  CapechoShortcut? _loadedShortcut(List<CapechoShortcut> loaded, String action) {
    for (final shortcut in loaded) {
      if (shortcut.action == action) return shortcut;
    }
    return null;
  }

  CapechoShortcut _localShortcut(String action, String key, List<String> modifiers) {
    final current = shortcutFor(action);
    return CapechoShortcut(
      action: current.action,
      title: current.title,
      key: normalizeShortcutKey(key),
      modifiers: normalizeShortcutModifiers(modifiers),
      display: shortcutDisplay(key, modifiers),
    );
  }

  void _upsertShortcut(CapechoShortcut updated) {
    _shortcuts = [
      for (final shortcut in _shortcuts) shortcut.action == updated.action ? updated : shortcut,
    ];
  }

  String _shortcutErrorMessage(Object error) {
    final text = error.toString();
    if (text.contains('shortcut_conflict')) {
      return 'Already used by another shortcut.';
    }
    if (text.contains('hotkey_unavailable')) {
      return 'macOS or another app is already using that shortcut.';
    }
    if (text.contains('missing_modifier')) {
      return 'Use at least one modifier key.';
    }
    return 'Couldn’t save that shortcut.';
  }

  /// Retry persisting a queued/failed [field] ("Retry now").
  void retry(SettingField field) => _scheduleSave(field);

  /// Schedule a save for [field]. No-op when signed out. If a save is already in flight for this
  /// field, coalesce — mark it dirty so the in-flight save re-runs with the latest override once it
  /// settles (never two concurrent PATCHes for one field → the server can't store them out of order).
  void _scheduleSave(SettingField field) {
    if (saveAccount == null) return;
    if (_inFlight.contains(field)) {
      _dirty.add(field);
      return;
    }
    unawaited(_runSave(field));
  }

  /// Persist [field]'s current override to the account. Optimistic — the value is already applied;
  /// this only moves the save status (saving → cleared / queued / failed). A transport failure →
  /// `queued` (offline, kept + retriable); an [ApiException] → `failed` (a hard backend rejection).
  Future<void> _runSave(SettingField field) async {
    final save = saveAccount;
    if (save == null) return;
    _inFlight.add(field);
    _dirty.remove(field);
    _saveStatus[field] = SaveStatus.saving;
    _notify();
    try {
      switch (field) {
        case SettingField.explanation:
          await save(explanationLanguage: _explanationOverride);
        case SettingField.learning:
          await save(learningLanguage: _learningOverride);
        case SettingField.reminderEnabled:
          await save(reminderEnabled: _remindersOnOverride);
        case SettingField.reminderTime:
          await save(reminderTime: _reminderTimeOverride);
      }
      if (!_disposed) {
        _saveStatus.remove(field);
      }
    } on ApiException {
      if (!_disposed) {
        _saveStatus[field] = SaveStatus.failed; // a hard backend rejection
      }
    } catch (_) {
      if (!_disposed) {
        _saveStatus[field] = SaveStatus.queued; // transport/offline → kept, retriable
      }
    } finally {
      _inFlight.remove(field);
    }
    if (_disposed) return;
    _notify();
    // A change arrived mid-save → persist the latest value now (ordered, last-write-wins).
    if (_dirty.remove(field)) unawaited(_runSave(field));
  }

  /// True while a probe is in flight — the status row shows a calm "Checking…" instead of
  /// flickering between Off and Granted.
  bool _checking = false;
  bool get checking => _checking;

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// notifyListeners that is inert after dispose — a probe can resolve after the screen that
  /// owns this controller is torn down.
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Initial + on-demand permission probe. Never throws: a failed probe resolves to
  /// [CapturePermission.unknown] (a neutral "Checking…"), never a false "Off".
  Future<void> refreshPermission() async {
    _checking = true;
    _notify();
    try {
      final granted = await checkPermission();
      _permission = granted ? CapturePermission.granted : CapturePermission.off;
    } catch (_) {
      _permission = CapturePermission.unknown;
    } finally {
      _checking = false;
      _notify();
    }
  }

  /// Open System Settings, then re-probe. macOS usually requires relaunching the app for a
  /// freshly-granted Screen Recording permission to take effect, so the immediate re-probe is a
  /// best-effort catch — it costs nothing and occasionally reflects a fast grant. Opening the
  /// pane is best-effort; a failure still leaves the user with the visible status + retry path.
  Future<void> openCaptureSettings() async {
    try {
      await openSystemSettings();
    } catch (_) {
      // The deep link is best-effort; the status row still shows where things stand.
    }
    await refreshPermission();
  }
}
