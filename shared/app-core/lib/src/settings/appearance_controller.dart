import 'package:flutter/material.dart';

/// Device-local persistence seam for the app's [ThemeMode] (Light / Dark / System). Mirrors the
/// [SessionStore] pattern: the interface lives here in the shared core, each client supplies the
/// concrete impl over a backend it already ships — a file on macOS (path_provider, SwiftPM-pure), the
/// Keychain / EncryptedSharedPreferences on mobile (flutter_secure_storage) — so no new persistence
/// plugin is added for one small value. Appearance is per-device on purpose (not an account setting),
/// so it never rides `PATCH /account`.
abstract class AppearanceStore {
  /// The saved mode, or [ThemeMode.system] when nothing has been chosen yet.
  Future<ThemeMode> read();

  /// Persist the chosen mode.
  Future<void> write(ThemeMode mode);
}

/// Serialize a [ThemeMode] to its stable on-disk token. Exhaustive (no default) so a new enum value
/// is a compile error here rather than silently persisting as `system`.
String themeModeToString(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'system',
  ThemeMode.light => 'light',
  ThemeMode.dark => 'dark',
};

/// Parse a stored token back to a [ThemeMode]; anything unknown / null → [ThemeMode.system] (the safe
/// default, so a corrupt or empty value never wedges the app on a fixed brightness).
ThemeMode themeModeFromString(String? raw) => switch (raw) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  _ => ThemeMode.system,
};

/// In-memory [AppearanceStore] — the default when an [AppearanceController] is built without one. It
/// doesn't survive a relaunch, so production passes a persistent store; this just keeps the controller
/// usable (and tests trivial) on its own.
class _InMemoryAppearanceStore implements AppearanceStore {
  ThemeMode _mode = ThemeMode.system;
  @override
  Future<ThemeMode> read() async => _mode;
  @override
  Future<void> write(ThemeMode mode) async => _mode = mode;
}

/// Holds the app-wide [ThemeMode] and drives the root `MaterialApp.themeMode`, so changing it repaints
/// every surface live — the warm palette already resolves per `Theme.of(context).brightness` (see
/// [OnboardingPalette.of]). Both clients own one at the root, [load] it before the first frame, and
/// expose it in Settings → Appearance. Defaults to [ThemeMode.system] (follow the OS) until [load]
/// resolves a saved choice.
class AppearanceController extends ChangeNotifier {
  AppearanceController({AppearanceStore? store}) : _store = store ?? _InMemoryAppearanceStore();

  final AppearanceStore _store;

  ThemeMode _mode = ThemeMode.system;
  ThemeMode get mode => _mode;

  /// Hydrate from the store. Best-effort: a read failure (missing / unreadable) leaves the
  /// [ThemeMode.system] default rather than throwing into app startup. Call once at launch; safe to
  /// call again.
  Future<void> load() async {
    try {
      _mode = await _store.read();
    } catch (_) {
      _mode = ThemeMode.system;
    }
    notifyListeners();
  }

  /// Apply [mode] and persist it. Optimistic: the UI updates immediately (notify first); the write is
  /// best-effort, so a failed persist only means the choice doesn't survive a relaunch — never an
  /// error in the user's face. A no-op when unchanged.
  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    _mode = mode;
    notifyListeners();
    try {
      await _store.write(mode);
    } catch (_) {
      // Best-effort persistence; the in-memory choice still holds for this session.
    }
  }
}
