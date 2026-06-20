import 'dart:async';

import 'package:capecho/settings/settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

SettingsController make({required Future<bool> Function() check, Future<void> Function()? open}) =>
    SettingsController(checkPermission: check, openSystemSettings: open ?? () async {});

void main() {
  test('refreshPermission: granted → CapturePermission.granted', () async {
    final c = make(check: () async => true);
    await c.refreshPermission();
    expect(c.permission, CapturePermission.granted);
    expect(c.checking, isFalse);
  });

  test('refreshPermission: not granted → off', () async {
    final c = make(check: () async => false);
    await c.refreshPermission();
    expect(c.permission, CapturePermission.off);
  });

  test('a probe failure resolves to unknown — never a false Off', () async {
    final c = make(check: () async => throw Exception('tcc unavailable'));
    await c.refreshPermission();
    expect(c.permission, CapturePermission.unknown);
    expect(c.checking, isFalse);
  });

  test('checking is true mid-probe and false after', () async {
    final gate = Completer<bool>();
    final c = make(check: () => gate.future);
    final probe = c.refreshPermission();
    expect(c.checking, isTrue);
    gate.complete(true);
    await probe;
    expect(c.checking, isFalse);
    expect(c.permission, CapturePermission.granted);
  });

  test('openCaptureSettings opens System Settings then re-probes (catches a fast grant)', () async {
    var opened = 0;
    var granted = false;
    final c = make(
      check: () async => granted,
      // Simulate the user granting the permission while in System Settings.
      open: () async {
        opened++;
        granted = true;
      },
    );
    await c.openCaptureSettings();
    expect(opened, 1);
    expect(c.permission, CapturePermission.granted);
  });

  test('openCaptureSettings still re-probes if opening the pane throws', () async {
    final c = make(check: () async => false, open: () async => throw Exception('no pane'));
    await c.openCaptureSettings(); // must not throw
    expect(c.permission, CapturePermission.off);
  });

  test('notifies listeners across a probe (checking on, then resolved)', () async {
    var notifications = 0;
    final c = make(check: () async => true)..addListener(() => notifications++);
    await c.refreshPermission();
    expect(notifications, greaterThanOrEqualTo(2));
  });

  test('is inert after dispose (a late probe does not throw)', () async {
    final gate = Completer<bool>();
    final c = make(check: () => gate.future);
    final probe = c.refreshPermission();
    c.dispose();
    gate.complete(true);
    await probe; // resolving after dispose must not throw
  });

  test(
    'reminder overrides: null until set, then mutators flip + notify (no-op when unchanged)',
    () async {
      var notifications = 0;
      // No saveAccount → signed-out / UI-local: the mutators set the override + notify but never persist.
      final c = make(check: () async => true)..addListener(() => notifications++);
      expect(
        c.remindersOnOverride,
        isNull,
      ); // no baked-in default — the effective value comes from the account
      expect(c.reminderTimeOverride, isNull);

      c.setRemindersOn(false);
      expect(c.remindersOnOverride, isFalse);
      c.setReminderTime('21:30');
      expect(c.reminderTimeOverride, '21:30');
      expect(notifications, 2);

      c.setRemindersOn(false); // unchanged → no extra notify
      c.setReminderTime('21:30');
      expect(notifications, 2);
    },
  );

  test('language UI-local overrides: null until set, then reflect the choice + notify', () async {
    var notifications = 0;
    final c = make(check: () async => true)..addListener(() => notifications++);
    expect(c.explanationOverride, isNull);
    expect(c.learningOverride, isNull);

    c.setExplanationLanguage('zh-Hans');
    c.setLearningLanguage('de');
    expect(c.explanationOverride, 'zh-Hans');
    expect(c.learningOverride, 'de');
    expect(notifications, 2);
  });

  test('shortcuts load defaults and can be changed locally', () async {
    final c = make(check: () async => true);
    await c.refreshShortcuts();
    expect(c.shortcutFor('capture').display, '⌥E');

    await c.setShortcut(action: 'capture', key: 'K', modifiers: ['option']);
    expect(c.shortcutFor('capture').display, '⌥K');
    expect(c.shortcutErrorOf('capture'), isNull);
  });

  test('shortcuts reject duplicate combinations before saving', () async {
    final c = make(check: () async => true);
    await c.refreshShortcuts();

    await c.setShortcut(action: 'capture', key: 'R', modifiers: ['option']);
    expect(c.shortcutFor('capture').display, '⌥E');
    expect(c.shortcutErrorOf('capture'), contains('Review'));
  });
}
