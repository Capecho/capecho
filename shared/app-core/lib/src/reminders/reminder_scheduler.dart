import 'package:capecho_api/capecho_api.dart' show Account, Word;

import 'reminder_notifications.dart';

/// Turns the account's stored reminder preference into an armed (or canceled) OS notification — ONCE,
/// for BOTH clients (US-14.1). The reminder is a CLIENT-FIRED local notification (the account only
/// stores `reminderEnabled` / `reminderTime` so the choice syncs across devices); this is the policy
/// that decides what to do with that preference, delegating the OS plumbing to a [ReminderNotifications]
/// gateway.
///
/// Policy, evaluated on [sync]:
///  - signed out / reminders off / no time set → cancel.
///  - otherwise → look ahead to the NEXT occurrence of the reminder time and count how many cards would
///    be reviewable then; arm a daily-repeating reminder when ≥1, else cancel ("no nag when nothing is
///    due"). A look-ahead that can't be computed (offline / a transient failure) errs toward ARMING —
///    a network blip must never silence the nudge.
///
/// The host re-runs [sync] on the events that can change the answer: a sign-in/out or a preference save
/// (via its `AuthController` listener — cheap, short-circuited when the preference is unchanged) and an
/// app resume or review-session end (`force: true`, which re-checks the due look-ahead). A [DateTime]
/// clock is injected so the look-ahead is deterministic in tests; the OS owns the actual firing.
///
/// Pure Dart on `capecho_api` + the injected [ReminderNotifications] — no Flutter/plugin deps — so it
/// unit-tests with a fake gateway and a stub word list.
class ReminderScheduler {
  ReminderScheduler({
    required this.notifications,
    required this.loadWords,
    this.requestPermissionBeforeScheduling = true,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final ReminderNotifications notifications;

  /// Whether this policy should request OS notification permission before scheduling.
  ///
  /// Desktop keeps the historical shared behavior. Mobile sets this to false so the OS prompt only
  /// appears from Settings when the user explicitly turns Daily reminder on.
  final bool requestPermissionBeforeScheduling;

  /// Loads the account's active words (the app wires `api.listWords`) for the due look-ahead. Its
  /// failure is swallowed here (errs toward arming), so the caller need not guard it.
  final Future<List<Word>> Function() loadWords;

  final DateTime Function() _now;

  /// Default reminder copy — warm, and deliberately WITHOUT a hard count: a daily-repeating
  /// notification keeps its baked-in body, so a "3 words due" would go stale on later days.
  static const String reminderTitle = 'Time to review';
  static const String reminderBody = 'A few of your words are ready for a quick review.';

  /// Copy for the one-time confirmation shown the moment reminders are turned ON (US-14.1), so the
  /// feature visibly fires right away instead of silently waiting for the next day's scheduled time.
  static const String reminderEnabledTitle = 'Reminders on';
  static String reminderEnabledBody(String hhmm) =>
      'You’ll get a daily nudge at $hhmm when words are ready to review.';

  /// Sentinel "signed-in but reminders OFF" signature, so the off→off case skips a redundant cancel and
  /// re-enabling re-arms. DISTINCT from [_signedOutSignature]: only THIS one is the baseline a later
  /// enable confirms against. A signed-out baseline must NOT count as off→on, or the "Reminders on"
  /// confirmation fires on every cold launch and on sign-in for an account that already had reminders on.
  static const String _offSignature = '__off__';

  /// Sentinel "signed out / no account" signature, kept separate from [_offSignature] so the
  /// signed-out→signed-in transition (the macOS host runs the first sync while `auth.restore()` is still
  /// pending, then again once it resolves; or a plain sign-in) is NOT mistaken for a user enabling.
  static const String _signedOutSignature = '__signed_out__';

  // The last-applied signature ("$accountId|$reminderTime"): lets the frequent, unforced (auth
  // listener) path skip the network look-ahead when nothing relevant changed. `force` bypasses it.
  String? _lastSignature;

  // Single-flight: never two evaluations at once (an auth notification + a resume can race, and each
  // does a `loadWords` fetch). A call arriving mid-run records the LATEST inputs and re-runs once the
  // in-flight evaluation settles — so the final state always reflects the most recent inputs.
  bool _running = false;
  bool _pending = false;
  bool _pendingSignedIn = false;
  Account? _pendingAccount;
  bool _pendingForce = false;

  /// Re-evaluate and arm/cancel the reminder for [account]. [signedIn] gates the whole feature.
  /// [force] re-checks the due look-ahead even when the preference is unchanged — pass it when the DUE
  /// picture (not the preference) may have moved: an app resume or the end of a review session.
  Future<void> sync({required bool signedIn, required Account? account, bool force = false}) async {
    // Record the latest requested inputs; the in-flight run (if any) picks these up.
    _pendingSignedIn = signedIn;
    _pendingAccount = account;
    _pendingForce = _pendingForce || force;
    if (_running) {
      _pending = true;
      return;
    }
    _running = true;
    try {
      do {
        _pending = false;
        final f = _pendingForce;
        _pendingForce = false;
        await _evaluate(signedIn: _pendingSignedIn, account: _pendingAccount, force: f);
      } while (_pending);
    } finally {
      _running = false;
    }
  }

  Future<void> _evaluate({
    required bool signedIn,
    required Account? account,
    required bool force,
  }) async {
    // SIGNED OUT (or no account) → cancel, under a DISTINCT sentinel. This must NOT be the "off"
    // baseline an enable confirms against: on macOS the host runs the first sync while `auth.restore()`
    // is still pending (signed out), so treating signed-out as "off" would make the next signed-in sync
    // look like a fresh off→on enable and fire the confirmation on every cold launch / sign-in.
    if (!signedIn || account == null) {
      if (force || _lastSignature != _signedOutSignature) {
        _lastSignature = _signedOutSignature;
        await notifications.cancelReminder();
      }
      return;
    }
    // Signed in but reminders OFF / no time → cancel under the off sentinel (the real "off" baseline a
    // later enable confirms against).
    if (!account.reminderEnabled || account.reminderTime == null) {
      if (force || _lastSignature != _offSignature) {
        _lastSignature = _offSignature;
        await notifications.cancelReminder();
      }
      return;
    }
    final time = parseHhmm(account.reminderTime!);
    if (time == null) {
      // A malformed stored time can't be scheduled — treat as off.
      if (force || _lastSignature != _offSignature) {
        _lastSignature = _offSignature;
        await notifications.cancelReminder();
      }
      return;
    }

    final signature = '${account.id}|${account.reminderTime}';
    // Unchanged preference + not forced → the daily repeat already armed still covers it; skip the
    // network look-ahead (this is the hot path: the auth listener fires often).
    if (!force && signature == _lastSignature) return;

    // A fresh user-enable is the signed-in OFF→ON transition: the previous evaluated state was the
    // signed-in-but-reminders-off baseline ([_offSignature]). Drives the one-time confirmation below. NOT
    // fired when the previous state was signed-out ([_signedOutSignature] — cold launch / sign-in), null
    // (never evaluated / just-denied), or a real signature (time change / forced resume).
    final justEnabled = _lastSignature == _offSignature;

    if (requestPermissionBeforeScheduling) {
      // Ask for permission the moment reminders are ENABLED — before the due look-ahead — so the OS
      // prompt reliably appears when the user opts in (US-14.1: its own moment), not only when something
      // happens to be due. Idempotent (no re-prompt once decided), so forced re-syncs stay cheap.
      final granted = await notifications.requestPermission();
      if (!granted) {
        // Denied → cancel any previously-armed daily reminder (canceling needs no authorization), so a
        // stale request can't fire with out-of-date state once permission is restored. Leave the
        // signature unset so a later grant re-evaluates and re-arms.
        _lastSignature = null;
        await notifications.cancelReminder();
        return;
      }
    }

    // Confirm right when the user turns it on, so the reminder visibly fires immediately instead of
    // silently waiting for the day's scheduled time (founder-directed "开启即确认"). Once per enable,
    // even when nothing is due yet — the copy speaks to the daily schedule, not "now".
    if (justEnabled) {
      await notifications.showImmediate(
        title: reminderEnabledTitle,
        body: reminderEnabledBody(account.reminderTime!),
      );
    }

    // Look ahead to the next fire and gate the DAILY arm on whether anything would be reviewable by then.
    final next = nextOccurrence(_now(), time.$1, time.$2);
    int? due;
    try {
      due = countReviewableAt(await loadWords(), next);
    } catch (_) {
      due = null; // offline / transient → arm anyway (never silence the nudge on a blip)
    }

    if (due == 0) {
      // Nothing due at the next fire → stay quiet (the daily arm). Remember the signature so the
      // unforced path skips; a later forced sync (resume / post-review) re-checks and can re-arm.
      _lastSignature = signature;
      await notifications.cancelReminder();
      return;
    }

    _lastSignature = signature;
    await notifications.scheduleDailyReminder(
      hour: time.$1,
      minute: time.$2,
      title: reminderTitle,
      body: reminderBody,
    );
  }

  // ---- pure helpers (unit-tested directly) ----------------------------------

  /// Parse a stored "HH:mm" (24-hour) time → `(hour, minute)`, or null when malformed / out of range.
  static (int, int)? parseHhmm(String hhmm) {
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return (hour, minute);
  }

  /// The next [DateTime] strictly after [from] whose local time is [hour]:[minute] — today if it's
  /// still ahead, else tomorrow. Used only for the due look-ahead instant (the OS schedules the actual
  /// fire by wall-clock time), so a ±1h DST drift in the look-ahead is immaterial.
  static DateTime nextOccurrence(DateTime from, int hour, int minute) {
    var candidate = DateTime(from.year, from.month, from.day, hour, minute);
    if (!candidate.isAfter(from)) {
      candidate = candidate.add(const Duration(days: 1));
    }
    return candidate;
  }

  /// How many of [words] would be reviewable at [instant]: a never-reviewed (new) card — `fsrs == null`
  /// — or a scheduled card whose FSRS due time is at/before [instant]. Tombstoned words are excluded.
  /// This is the look-ahead the reminder gates on (US-14.1's "no nag when nothing is due"). New cards
  /// are counted whenever any exist: the per-day new-card cap resets at the local day boundary, so by
  /// the next reminder (typically the following day) the daily allotment is fresh.
  static int countReviewableAt(List<Word> words, DateTime instant) {
    final ms = instant.millisecondsSinceEpoch;
    return words
        .where((w) => w.deletedAt == null && (w.fsrs == null || w.fsrs!.dueAt <= ms))
        .length;
  }
}
