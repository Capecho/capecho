import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the shared daily-reminder POLICY [ReminderScheduler] (US-14.1) — the one piece both
/// clients share, with only the OS plumbing ([ReminderNotifications]) differing per platform. Pure
/// Dart: a fake gateway + a stub word list, an injected clock, no plugins/transport.
void main() {
  // A signed-in account with reminders configured (or not). `learningLanguage` is required-but-nullable.
  Account account({bool enabled = true, String? time = '20:00'}) => Account(
    id: 'acc-1',
    ianaTimezone: 'America/New_York',
    explanationLanguage: 'en',
    explanationFollowsLearning: false,
    learningLanguage: 'en',
    reminderEnabled: enabled,
    reminderTime: time,
    pro: false,
  );

  // A Word that is either a never-reviewed new card (fsrs null) or has an FSRS due time. Only the
  // fields the look-ahead reads (`deletedAt`, `fsrs.dueAt`) matter; the rest are filler.
  Word word({int? dueAtMs, int? deletedAt}) => Word(
    id: 'w',
    userId: 'u',
    targetLanguage: 'en',
    surfaceUnit: 'x',
    normalizedUnit: 'x',
    targetNormalizationVersion: 'v1',
    isPhrase: false,
    explanationState: ExplanationState.ready,
    explanationCacheKey: null,
    fsrsEpoch: 0,
    createdAt: 0,
    updatedAt: 0,
    deletedAt: deletedAt,
    fsrs: dueAtMs == null
        ? null
        : WordFsrs(
            stability: 1,
            difficulty: 5,
            dueAt: dueAtMs,
            state: CardState.review,
            reps: 1,
            lapses: 0,
            lastReviewAt: 0,
          ),
  );

  // 10:00 local on a fixed day, so a 20:00 reminder's next fire is THIS day at 20:00.
  DateTime fixedNow() => DateTime(2026, 6, 4, 10, 0);
  final next20 = ReminderScheduler.nextOccurrence(fixedNow(), 20, 0);

  group('parseHhmm', () {
    test('valid 24h times parse', () {
      expect(ReminderScheduler.parseHhmm('20:00'), (20, 0));
      expect(ReminderScheduler.parseHhmm('00:00'), (0, 0));
      expect(ReminderScheduler.parseHhmm('23:59'), (23, 59));
      expect(ReminderScheduler.parseHhmm('07:05'), (7, 5));
    });
    test('malformed / out-of-range → null', () {
      expect(ReminderScheduler.parseHhmm('24:00'), isNull);
      expect(ReminderScheduler.parseHhmm('20:60'), isNull);
      expect(ReminderScheduler.parseHhmm('8pm'), isNull);
      expect(ReminderScheduler.parseHhmm('20'), isNull);
      expect(ReminderScheduler.parseHhmm(''), isNull);
    });
  });

  group('nextOccurrence', () {
    test('later today when the time is still ahead', () {
      final n = ReminderScheduler.nextOccurrence(DateTime(2026, 6, 4, 10), 20, 0);
      expect(n, DateTime(2026, 6, 4, 20, 0));
    });
    test('tomorrow when the time has already passed', () {
      final n = ReminderScheduler.nextOccurrence(DateTime(2026, 6, 4, 21), 20, 0);
      expect(n, DateTime(2026, 6, 5, 20, 0));
    });
  });

  group('countReviewableAt', () {
    test('counts new cards, due cards; excludes future-due and deleted', () {
      final words = [
        word(dueAtMs: null), // new (never reviewed) → reviewable
        word(dueAtMs: next20.millisecondsSinceEpoch - 1), // due before the fire → reviewable
        word(dueAtMs: next20.millisecondsSinceEpoch + 1), // due after the fire → not yet
        word(dueAtMs: next20.millisecondsSinceEpoch - 1, deletedAt: 123), // tombstoned → excluded
      ];
      expect(ReminderScheduler.countReviewableAt(words, next20), 2);
    });
  });

  group('sync policy', () {
    test('signed out → cancel, never schedules', () async {
      final fake = _FakeNotifications();
      final s = ReminderScheduler(
        notifications: fake,
        loadWords: () async => [word(dueAtMs: null)],
        now: fixedNow,
      );
      await s.sync(signedIn: false, account: null);
      expect(fake.scheduleCalls, 0);
      expect(fake.cancelCalls, 1);
    });

    test('reminders off → cancel', () async {
      final fake = _FakeNotifications();
      final s = ReminderScheduler(
        notifications: fake,
        loadWords: () async => [word(dueAtMs: null)],
        now: fixedNow,
      );
      await s.sync(signedIn: true, account: account(enabled: false));
      expect(fake.scheduleCalls, 0);
      expect(fake.cancelCalls, 1);
    });

    test('no reminder time set → cancel', () async {
      final fake = _FakeNotifications();
      final s = ReminderScheduler(
        notifications: fake,
        loadWords: () async => [word(dueAtMs: null)],
        now: fixedNow,
      );
      await s.sync(signedIn: true, account: account(time: null));
      expect(fake.scheduleCalls, 0);
      expect(fake.cancelCalls, 1);
    });

    test('enabled + something due → requests permission + schedules at the chosen time', () async {
      final fake = _FakeNotifications();
      final s = ReminderScheduler(
        notifications: fake,
        loadWords: () async => [word(dueAtMs: null)], // a new card is reviewable
        now: fixedNow,
      );
      await s.sync(signedIn: true, account: account());
      expect(fake.permissionRequests, 1);
      expect(fake.scheduleCalls, 1);
      expect(fake.cancelCalls, 0);
      expect((fake.lastHour, fake.lastMinute), (20, 0));
      // A fresh scheduler syncing with reminders already on = an app launch, not a fresh enable → no
      // confirmation (we don't nag on every launch; that's reserved for the off→on transition).
      expect(fake.immediateCalls, 0);
    });

    test('enabled but NOTHING due at the next fire → cancel (no nag)', () async {
      final fake = _FakeNotifications();
      final s = ReminderScheduler(
        notifications: fake,
        // Everything is scheduled past the 20:00 fire and there are no new cards.
        loadWords: () async => [word(dueAtMs: next20.millisecondsSinceEpoch + 3600000)],
        now: fixedNow,
      );
      await s.sync(signedIn: true, account: account());
      expect(fake.scheduleCalls, 0);
      expect(fake.cancelCalls, 1);
      // Permission is now requested eagerly the moment reminders are enabled — before (and regardless
      // of) the due look-ahead — so the OS prompt always appears when the user opts in.
      expect(fake.permissionRequests, 1);
    });

    test(
      'turning reminders ON (off → on) fires a one-time confirmation, then never re-fires',
      () async {
        final fake = _FakeNotifications();
        final s = ReminderScheduler(
          notifications: fake,
          loadWords: () async => [word(dueAtMs: null)],
          now: fixedNow,
        );
        // Signed in with reminders OFF → the genuine "off" baseline (a user disable, not a launch).
        await s.sync(signedIn: true, account: account(enabled: false));
        expect(fake.immediateCalls, 0);
        // The user turns reminders on → ONE confirmation fires (so it visibly works right away), permission
        // is requested, and the daily reminder arms.
        await s.sync(signedIn: true, account: account(enabled: true));
        expect(fake.immediateCalls, 1);
        expect(fake.lastImmediateBody, contains('20:00')); // copy shows the chosen time
        expect(fake.permissionRequests, 1);
        expect(fake.scheduleCalls, 1);
        // A later forced re-sync (resume / post-review) does NOT re-confirm.
        await s.sync(signedIn: true, account: account(enabled: true), force: true);
        expect(fake.immediateCalls, 1);
      },
    );

    test(
      'does NOT confirm on the launch / sign-in sequence (signed-out baseline, not a user enable)',
      () async {
        final fake = _FakeNotifications();
        final s = ReminderScheduler(
          notifications: fake,
          loadWords: () async => [word(dueAtMs: null)],
          now: fixedNow,
        );
        // macOS host order: the first sync runs while `auth.restore()` is still pending → SIGNED OUT.
        await s.sync(signedIn: false, account: null);
        // restore() resolves → signed in with an account whose reminders were already ON (e.g. set on
        // another device). This is NOT the user toggling reminders on this session.
        await s.sync(signedIn: true, account: account(enabled: true));
        // The daily reminder still arms, but NO confirmation fires (signed-out is not the off baseline).
        expect(fake.scheduleCalls, 1);
        expect(fake.immediateCalls, 0);
      },
    );

    test('permission denied → does not schedule (and does not throw)', () async {
      final fake = _FakeNotifications(permissionGranted: false);
      final s = ReminderScheduler(
        notifications: fake,
        loadWords: () async => [word(dueAtMs: null)],
        now: fixedNow,
      );
      await s.sync(signedIn: true, account: account());
      expect(fake.permissionRequests, 1);
      expect(fake.scheduleCalls, 0);
      // Denied also cancels any previously-armed daily reminder (cancel needs no authorization), so a
      // stale request can't fire with out-of-date state once permission is restored.
      expect(fake.cancelCalls, 1);
    });

    test('mobile mode schedules without requesting permission during background sync', () async {
      final fake = _FakeNotifications(permissionGranted: false);
      final s = ReminderScheduler(
        notifications: fake,
        loadWords: () async => [word(dueAtMs: null)],
        requestPermissionBeforeScheduling: false,
        now: fixedNow,
      );
      await s.sync(signedIn: true, account: account());
      expect(fake.permissionRequests, 0);
      expect(fake.scheduleCalls, 1);
      expect(fake.cancelCalls, 0);
    });

    test('a look-ahead failure errs toward arming (never silences on a blip)', () async {
      final fake = _FakeNotifications();
      final s = ReminderScheduler(
        notifications: fake,
        loadWords: () async => throw Exception('offline'),
        now: fixedNow,
      );
      await s.sync(signedIn: true, account: account());
      expect(fake.scheduleCalls, 1); // armed despite the failed due check
      expect(fake.cancelCalls, 0);
    });

    test(
      'unchanged preference + unforced → skips the look-ahead (no re-schedule, no fetch)',
      () async {
        var loads = 0;
        final fake = _FakeNotifications();
        final s = ReminderScheduler(
          notifications: fake,
          loadWords: () async {
            loads++;
            return [word(dueAtMs: null)];
          },
          now: fixedNow,
        );
        await s.sync(signedIn: true, account: account());
        await s.sync(signedIn: true, account: account()); // same prefs, unforced
        expect(loads, 1); // second call short-circuited before the fetch
        expect(fake.scheduleCalls, 1);
      },
    );

    test('force re-checks the due picture and cancels when it has emptied (post-review)', () async {
      var hasDue = true;
      final fake = _FakeNotifications();
      final s = ReminderScheduler(
        notifications: fake,
        loadWords: () async => hasDue ? [word(dueAtMs: null)] : <Word>[],
        now: fixedNow,
      );
      await s.sync(signedIn: true, account: account());
      expect(fake.scheduleCalls, 1);
      // The user clears their cards, then the app resumes / the session ends → a forced re-sync.
      hasDue = false;
      await s.sync(signedIn: true, account: account(), force: true);
      expect(fake.cancelCalls, 1);
      expect(fake.scheduleCalls, 1); // not re-armed
    });
  });
}

class _FakeNotifications implements ReminderNotifications {
  _FakeNotifications({this.permissionGranted = true});

  final bool permissionGranted;
  int permissionRequests = 0;
  int scheduleCalls = 0;
  int cancelCalls = 0;
  int immediateCalls = 0;
  int? lastHour;
  int? lastMinute;
  String? lastImmediateBody;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permissionGranted;
  }

  @override
  Future<void> scheduleDailyReminder({
    required int hour,
    required int minute,
    required String title,
    required String body,
  }) async {
    scheduleCalls++;
    lastHour = hour;
    lastMinute = minute;
  }

  @override
  Future<void> cancelReminder() async {
    cancelCalls++;
  }

  @override
  Future<void> showImmediate({required String title, required String body}) async {
    immediateCalls++;
    lastImmediateBody = body;
  }
}
