import 'dart:async';

import 'package:flutter/foundation.dart';

/// Device-local persistence seam for the signed-OUT capture language defaults — the default capture
/// **target** (learning) language and the **explanation** (gloss) language. Mirrors [AppearanceStore]
/// (and `SessionStore`): the interface lives here in the shared core; each client supplies the concrete
/// impl over a backend it already ships (a file on macOS via path_provider).
///
/// Why device-local: signed in these ride the account (`PATCH /account`, server-authoritative — the
/// account's `explanationLanguage` is the already-*resolved* effective value). Signed OUT there is no
/// account, but capture still runs locally and needs a target + gloss language, so the choice lives on
/// the device and the capture path falls back to it (`account?.X ?? prefs.X`). On sign-in the account
/// takes over; this is the pre-account default (and what onboarding's step-5 pick persists into).
abstract class LanguagePrefsStore {
  /// The saved prefs, or [LanguagePrefs.fallback] when nothing has been chosen yet.
  Future<LanguagePrefs> read();

  /// Persist the chosen prefs.
  Future<void> write(LanguagePrefs prefs);
}

/// The signed-out language choice: the default capture **target** (learning) language, the
/// **explanation** (gloss) language, and whether the explanation **follows** the learning language (the
/// immersion default — Settings renders this as "Same as learning language"). Codes are canonical
/// BCP-47-ish tags from the allowlists (`lang`). [fallback] is English-following-learning, matching a
/// fresh account's server defaults so signed-out and a brand-new account read the same.
@immutable
class LanguagePrefs {
  const LanguagePrefs({
    required this.learningLanguage,
    required this.explanationLanguage,
    required this.explanationFollowsLearning,
  });

  // The native (explanation) language is a DIRECT pick, not "follows learning" — so the fallback is
  // explicit English, follows=false. macOS seeds a locale-derived default at the store
  // layer (FileLanguagePrefsStore), so this bare English fallback only applies to the in-memory store
  // (tests) and corrupt reads.
  static const LanguagePrefs fallback = LanguagePrefs(
    learningLanguage: 'en',
    explanationLanguage: 'en',
    explanationFollowsLearning: false,
  );

  final String learningLanguage;
  final String explanationLanguage;
  final bool explanationFollowsLearning;

  /// The **effective** gloss language — the resolved value the capture/explain path reads, mirroring
  /// the account's server-resolved `explanationLanguage`: when [explanationFollowsLearning] it equals
  /// the learning language (every learning-language code is also a valid gloss code), else the explicit
  /// pick.
  String get effectiveExplanationLanguage =>
      explanationFollowsLearning ? learningLanguage : explanationLanguage;

  LanguagePrefs copyWith({
    String? learningLanguage,
    String? explanationLanguage,
    bool? explanationFollowsLearning,
  }) => LanguagePrefs(
    learningLanguage: learningLanguage ?? this.learningLanguage,
    explanationLanguage: explanationLanguage ?? this.explanationLanguage,
    explanationFollowsLearning: explanationFollowsLearning ?? this.explanationFollowsLearning,
  );

  @override
  bool operator ==(Object other) =>
      other is LanguagePrefs &&
      other.learningLanguage == learningLanguage &&
      other.explanationLanguage == explanationLanguage &&
      other.explanationFollowsLearning == explanationFollowsLearning;

  @override
  int get hashCode =>
      Object.hash(learningLanguage, explanationLanguage, explanationFollowsLearning);
}

/// In-memory [LanguagePrefsStore] — the default when a [LanguagePrefsController] is built without one
/// (keeps the controller usable standalone + tests trivial). It doesn't survive a relaunch, so
/// production passes a persistent store.
class _InMemoryLanguagePrefsStore implements LanguagePrefsStore {
  LanguagePrefs _prefs = LanguagePrefs.fallback;
  @override
  Future<LanguagePrefs> read() async => _prefs;
  @override
  Future<void> write(LanguagePrefs prefs) async => _prefs = prefs;
}

/// Holds the signed-out capture language choice and persists it on-device. Owned at the app root,
/// [load]ed before the first capture, read as the capture/explain fallback when there's no account, and
/// exposed in Settings → Language while signed out — where each change writes straight through
/// (device-local, instant, so no Queued/Not-saved save-state pill, unlike the signed-in `PATCH /account`
/// path). Onboarding's step-5 language pick also writes here ([setAll]), so it survives a relaunch.
/// Defaults to [LanguagePrefs.fallback] (English) until [load] resolves a saved choice.
class LanguagePrefsController extends ChangeNotifier {
  LanguagePrefsController({LanguagePrefsStore? store})
    : _store = store ?? _InMemoryLanguagePrefsStore();

  final LanguagePrefsStore _store;

  LanguagePrefs _prefs = LanguagePrefs.fallback;
  LanguagePrefs get prefs => _prefs;

  String get learningLanguage => _prefs.learningLanguage;
  String get explanationLanguage => _prefs.explanationLanguage;
  bool get explanationFollowsLearning => _prefs.explanationFollowsLearning;
  String get effectiveExplanationLanguage => _prefs.effectiveExplanationLanguage;

  /// Hydrate from the store. Best-effort: a read failure (missing / unreadable / corrupt) leaves the
  /// English fallback rather than throwing into app startup. Call once at launch; safe to call again.
  Future<void> load() async {
    try {
      _prefs = await _store.read();
    } catch (_) {
      _prefs = LanguagePrefs.fallback;
    }
    notifyListeners();
  }

  /// Set the default capture **target** (learning) language and persist. A no-op when unchanged.
  void setLearningLanguage(String code) => _update(_prefs.copyWith(learningLanguage: code));

  /// Pick an explicit **explanation** language — this turns OFF "follows learning" (an explicit choice,
  /// mirroring `PATCH /account`, where sending a language clears the follow flag server-side).
  void setExplanationLanguage(String code) =>
      _update(_prefs.copyWith(explanationLanguage: code, explanationFollowsLearning: false));

  /// Apply a full language choice at once (onboarding's step-5 pick) — one notify + one persist.
  void setAll({
    required String learningLanguage,
    required String explanationLanguage,
    required bool explanationFollowsLearning,
  }) => _update(
    LanguagePrefs(
      learningLanguage: learningLanguage,
      explanationLanguage: explanationLanguage,
      explanationFollowsLearning: explanationFollowsLearning,
    ),
  );

  /// Optimistic + best-effort: update + notify synchronously (the UI updates immediately + the value
  /// holds for this session), then fire-and-forget the persist — a failed write only means the choice
  /// doesn't survive a relaunch, never an error in the user's face. Mirrors the void-setter shape of the
  /// account [SettingsController] so the Settings screen drives both uniformly.
  void _update(LanguagePrefs next) {
    if (next == _prefs) return;
    _prefs = next;
    notifyListeners();
    unawaited(_persist(next));
  }

  Future<void> _persist(LanguagePrefs next) async {
    try {
      await _store.write(next);
    } catch (_) {
      // Best-effort persistence; the in-memory choice still holds for this session.
    }
  }
}
