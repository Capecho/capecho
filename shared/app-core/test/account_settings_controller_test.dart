import 'dart:async';

import 'package:capecho_api/capecho_api.dart' show ApiException;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Direct unit tests for the SHARED preference-save engine [AccountSettingsController] — the one piece
/// of Settings that macOS does NOT yet reuse (it keeps a duplicate engine; see the TODO(consolidate)).
/// These mirror the macOS `SettingsController — per-field save state` group against the shared class so
/// the optimistic-save / per-field status / coalescing semantics are proven for the engine both clients
/// will eventually share. Pure Dart: a stub [saveAccount], no plugins, no transport.
void main() {
  // A controller whose `saveAccount` runs [save] (or is null = signed out).
  AccountSettingsController make([
    Future<void> Function({
      String? explanationLanguage,
      bool? explanationFollowsLearning,
      String? learningLanguage,
      bool? reminderEnabled,
      String? reminderTime,
    })?
    save,
  ]) => AccountSettingsController(saveAccount: save);

  // The save is `unawaited` inside a setX call; one microtask-tick lets it run.
  Future<void> tick() => Future<void>.delayed(Duration.zero);

  test('a successful save clears the field status; the value is retained', () async {
    var calls = 0;
    final c = make(({
      explanationLanguage,
      explanationFollowsLearning,
      learningLanguage,
      reminderEnabled,
      reminderTime,
    }) async {
      calls++;
    });

    c.setExplanationLanguage('es');
    expect(c.saveStatusOf(SettingField.explanation), SaveStatus.saving);
    await tick();

    expect(calls, 1);
    expect(c.saveStatusOf(SettingField.explanation), isNull); // cleared on success
    expect(c.explanationOverride, 'es'); // value retained
  });

  test('a transport failure → queued (value kept, retriable)', () async {
    final c = make(({
      explanationLanguage,
      explanationFollowsLearning,
      learningLanguage,
      reminderEnabled,
      reminderTime,
    }) async {
      throw Exception('offline'); // a real transport failure, not an ApiException
    });

    c.setReminderTime('21:30');
    await tick();

    expect(c.saveStatusOf(SettingField.reminderTime), SaveStatus.queued);
    expect(c.reminderTimeOverride, '21:30'); // override kept so the value isn't lost
    expect(c.anyUnsaved(const [SettingField.reminderTime]), isTrue);
  });

  test('an ApiException → failed (a hard backend rejection)', () async {
    final c = make(({
      explanationLanguage,
      explanationFollowsLearning,
      learningLanguage,
      reminderEnabled,
      reminderTime,
    }) async {
      throw ApiException(statusCode: 500, error: 'server_error');
    });

    c.setLearningLanguage('fr');
    await tick();

    expect(c.saveStatusOf(SettingField.learning), SaveStatus.failed);
    expect(c.anyUnsaved(const [SettingField.learning]), isTrue);
  });

  test('retry re-attempts a failed field (fails, then succeeds → cleared)', () async {
    var fail = true;
    final c = make(({
      explanationLanguage,
      explanationFollowsLearning,
      learningLanguage,
      reminderEnabled,
      reminderTime,
    }) async {
      if (fail) throw ApiException(statusCode: 503, error: 'unavailable');
    });

    c.setRemindersOn(true);
    await tick();
    expect(c.saveStatusOf(SettingField.reminderEnabled), SaveStatus.failed);

    fail = false;
    c.retry(SettingField.reminderEnabled);
    await tick();
    expect(c.saveStatusOf(SettingField.reminderEnabled), isNull); // cleared on the successful retry
  });

  test('signed out (no saveAccount) is UI-local: the value applies, no save attempted', () async {
    final c = make(); // saveAccount == null
    c.setExplanationLanguage('zh-Hans');
    await tick();

    expect(c.explanationOverride, 'zh-Hans'); // applied locally
    expect(c.saveStatusOf(SettingField.explanation), isNull); // but nothing was sent
  });

  test('setting the same value is a no-op: no save, no extra notify', () async {
    var calls = 0;
    var notifies = 0;
    final c = make(({
      explanationLanguage,
      explanationFollowsLearning,
      learningLanguage,
      reminderEnabled,
      reminderTime,
    }) async {
      calls++;
    })..addListener(() => notifies++);

    c.setExplanationLanguage('es');
    await tick();
    expect(calls, 1);
    final notifiesAfterFirst = notifies; // saving→cleared produced some notifies

    c.setExplanationLanguage('es'); // identical → guarded no-op
    await tick();
    expect(calls, 1); // no second PATCH
    expect(notifies, notifiesAfterFirst); // and no further notify
  });

  test(
    'rapid same-field changes serialize: one PATCH at a time, sent in order, last value wins',
    () async {
      final order = <String>[];
      final gates = <Completer<void>>[];
      final c = make(({
        explanationLanguage,
        explanationFollowsLearning,
        learningLanguage,
        reminderEnabled,
        reminderTime,
      }) async {
        order.add(explanationLanguage ?? '?');
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future; // hold the save open until the test releases it
      });

      c.setExplanationLanguage('es'); // starts the first save (sends 'es')
      await tick();
      expect(gates.length, 1); // exactly one save in flight

      c.setExplanationLanguage('zh-Hans'); // coalesced (a save is in flight)
      c.setExplanationLanguage('fr'); // coalesced again → latest override is 'fr'
      await tick();
      expect(gates.length, 1); // the intermediate changes did NOT spawn concurrent saves

      gates[0].complete(); // first save settles → re-run once with the latest override
      await tick();
      expect(gates.length, 2); // exactly one re-run (not one per intermediate change)
      expect(order, ['es', 'fr']); // in order; the intermediate 'zh-Hans' was coalesced away

      gates[1].complete();
      await tick();
      expect(c.explanationOverride, 'fr');
      expect(c.saveStatusOf(SettingField.explanation), isNull); // settled + cleared
    },
  );

  test('a save that resolves after dispose does not throw (notify is inert)', () async {
    final gate = Completer<void>();
    final c = make(({
      explanationLanguage,
      explanationFollowsLearning,
      learningLanguage,
      reminderEnabled,
      reminderTime,
    }) async {
      await gate.future;
    });

    c.setExplanationLanguage('es');
    await tick();
    c.dispose(); // tear the controller down while the save is still in flight
    gate.complete(); // now let it settle — must not call notifyListeners after dispose
    await tick();
    // No assertion needed: the test passes iff no "used after dispose" error is thrown.
  });
}
