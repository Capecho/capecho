import 'dart:async';

import 'package:capecho_api/capecho_api.dart' show ApiException;
import 'package:flutter/foundation.dart';

/// Which account preference a save targets (drives the per-field save state — the
/// `Queued` / `Not saved` pills).
enum SettingField { explanation, learning, reminderEnabled, reminderTime }

/// Per-field persistence status. Absent = saved/idle. `saving` is transient (no pill either);
/// `queued` = offline (the value is kept locally + will retry); `failed` = a hard backend
/// rejection (a Retry is offered).
enum SaveStatus { saving, queued, failed }

// TODO(consolidate): the macOS `SettingsController`
// (clients/macos/lib/settings/settings_controller.dart) still owns its own copy of this
// preference-save engine + the `SettingField` / `SaveStatus` enums, because that controller is also
// entangled with capture_native (global shortcuts) + the Screen-Recording permission and can't move
// wholesale. A later PR should migrate macOS onto THIS shared engine (composing it with the
// macOS-only seams) and delete the duplicated half there.

/// The platform-agnostic half of Capecho's Settings: the account-preference save engine. It holds
/// each control's OPTIMISTIC override (so a change feels live + is never dropped), persists it to the
/// signed-in account via [saveAccount] (`PATCH /account`), and exposes the per-field [SaveStatus] that
/// drives the `Saving` (transient) / `Queued` (offline) / `Not saved` (backend reject) pills.
///
/// The effective displayed value of a preference = `override ?? account.value` — computed by the
/// screen, which on a successful save applies the returned [Account] to the auth controller, keeping
/// every surface authoritative. When [saveAccount] is null (signed out) changes stay UI-local.
///
/// This is pure Dart on `capecho_api` — NO capture, shortcuts, or permission code (those are
/// macOS-only and stay in the macOS `SettingsController`) — so it's shared by both clients and
/// unit-testable with a stub [saveAccount] and no plugins.
class AccountSettingsController extends ChangeNotifier {
  AccountSettingsController({this.saveAccount});

  /// Persists a preference change to the signed-in account (`PATCH /account`). Null when signed out —
  /// changes then stay UI-local (the server 401s without a session). Throws an [ApiException] on a
  /// backend rejection, or another error on a transport/offline failure.
  final Future<void> Function({
    String? explanationLanguage,
    // `explanationFollowsLearning` is retained as a back-compat wire seam (a follow-state account still
    // reads it); nothing here sets it any more — the immersion write-affordance is gone.
    bool? explanationFollowsLearning,
    String? learningLanguage,
    bool? reminderEnabled,
    String? reminderTime,
  })?
  saveAccount;

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

  /// Retry persisting a queued/failed [field] (the "Retry now" affordance).
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

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// notifyListeners that is inert after dispose — a save can resolve after the screen that owns this
  /// controller is torn down.
  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
