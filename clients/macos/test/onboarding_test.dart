import 'dart:async';

import 'package:capecho/onboarding.dart';
import 'package:capecho/onboarding_controller.dart';
import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A no-op transport/store for a signed-out [AuthController] in the widget tests (the sign-in step
/// renders provider buttons + "Later"; these flows never actually authenticate).
class _NoopTransport implements HttpTransport {
  @override
  Future<TransportResponse> send(TransportRequest request) async =>
      const TransportResponse(statusCode: 200, body: '{}');
}

class _MemStore implements SessionStore {
  String? _t;
  @override
  Future<String?> loadToken() async => _t;
  @override
  Future<void> saveToken(String token) async => _t = token;
  @override
  Future<void> clear() async => _t = null;
}

/// A transport that answers `GET /auth/me` with a user, so `restore()` lands signed-in.
class _MeTransport implements HttpTransport {
  @override
  Future<TransportResponse> send(TransportRequest request) async {
    if (request.url.endsWith('/auth/me')) {
      return const TransportResponse(
        statusCode: 200,
        body:
            '{"user":{"id":"a","iana_timezone":"UTC","explanation_language":"en","explanation_follows_learning":false,"reminder_enabled":false,"pro":false,"learning_language":null}}',
      );
    }
    return const TransportResponse(statusCode: 200, body: '{}');
  }
}

/// Drives a full email sign-in: start → verify (session) → claim.
class _EmailSignInTransport implements HttpTransport {
  @override
  Future<TransportResponse> send(TransportRequest r) async {
    if (r.url.contains('/auth/email/start')) {
      return const TransportResponse(statusCode: 200, body: '{"status":"sent"}');
    }
    if (r.url.contains('/auth/email/verify')) {
      return const TransportResponse(
        statusCode: 200,
        body:
            '{"token":"t","expires_at":1,"user":{"id":"a","iana_timezone":"UTC","explanation_language":"en","explanation_follows_learning":false,"reminder_enabled":false,"pro":false,"learning_language":null}}',
      );
    }
    if (r.url.contains('/words/claim')) {
      return const TransportResponse(statusCode: 200, body: '{"results":[]}');
    }
    return const TransportResponse(statusCode: 200, body: '{}');
  }
}

/// Answers `POST /auth/session` (Apple/Google) with a session, so a provider tap lands signed-in.
class _SocialSignInTransport implements HttpTransport {
  @override
  Future<TransportResponse> send(TransportRequest r) async {
    if (r.url.contains('/auth/session')) {
      return const TransportResponse(
        statusCode: 200,
        body:
            '{"token":"t","expires_at":1,"user":{"id":"a","iana_timezone":"UTC","explanation_language":"en","explanation_follows_learning":false,"reminder_enabled":false,"pro":false,"learning_language":null}}',
      );
    }
    if (r.url.contains('/words/claim')) {
      return const TransportResponse(statusCode: 200, body: '{"results":[]}');
    }
    return const TransportResponse(statusCode: 200, body: '{}');
  }
}

AuthController _stubAuth() => AuthController(
  api: CapechoApi(baseUrl: 'https://api.test', transport: _NoopTransport()),
  store: _MemStore(),
  collectClaimRows: () async => const [],
  installId: () async => 'inst',
  appleCredential: () async => 'tok',
  googleCredential: () async => 'tok',
);

/// A no-op `chooseLanguages` for the widget tests that don't assert the language choice.
Future<void> _noopChoose({
  required String explanationLanguage,
  required bool explanationFollowsLearning,
  required String learningLanguage,
}) async {}

/// Pins a deterministic, deliberately-tall canvas for the layout tests so there
/// is ample vertical slack to tell a top-anchored step apart from a vertically-
/// centered one. It is NOT the real window height — the app's fonts aren't
/// bundled, so a widget test can't measure the native fit; these tests verify
/// the centering BEHAVIOR, and the native height is checked visually.
void _pinLayoutCanvas(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('OnboardingController step logic', () {
    late bool completed;
    late int openSettingsCalls;
    late int chooseLanguagesCalls;
    late String? chosenExplanation;
    late bool? chosenFollows;
    late String? chosenLearning;
    OnboardingController make({
      required bool grantPermission,
      bool preflightGranted = false,
      OnboardingStep initialStep = OnboardingStep.howItWorks,
    }) {
      completed = false;
      openSettingsCalls = 0;
      chooseLanguagesCalls = 0;
      chosenExplanation = null;
      chosenFollows = null;
      chosenLearning = null;
      return OnboardingController(
        requestPermission: () async => grantPermission,
        checkPermission: () async => preflightGranted,
        openSettings: () async => openSettingsCalls++,
        complete: () async => completed = true,
        initialStep: initialStep,
        chooseLanguages:
            ({
              required String explanationLanguage,
              required bool explanationFollowsLearning,
              required String learningLanguage,
            }) async {
              chooseLanguagesCalls++;
              chosenExplanation = explanationLanguage;
              chosenFollows = explanationFollowsLearning;
              chosenLearning = learningLanguage;
            },
      );
    }

    // continueFromLanguage() fires an async preflight on entering permission; let it settle so an
    // already-granted Mac flips to the "ready" variant before we assert on it.
    Future<void> settle() => Future<void>.delayed(Duration.zero);

    // Walk past the new language step to the permission step the short way (getStarted → language →
    // continueFromLanguage → permission, which fires the no-prompt preflight).
    OnboardingController atPermission({
      required bool grantPermission,
      bool preflightGranted = false,
    }) => make(grantPermission: grantPermission, preflightGranted: preflightGranted)
      ..getStarted()
      ..continueFromLanguage();

    test('starts at how-it-works', () {
      expect(make(grantPermission: true).step, OnboardingStep.howItWorks);
    });

    test('can resume directly at permission and preflight the ready variant', () async {
      final c = make(
        grantPermission: false,
        preflightGranted: true,
        initialStep: OnboardingStep.permission,
      );
      expect(c.step, OnboardingStep.permission);
      await settle();
      expect(c.permissionGranted, isTrue);
      await c.enableScreenRecording();
      expect(c.step, OnboardingStep.rehearsal);
      expect(c.ocrArmed, isTrue);
    });

    test('Get started → language → permission', () {
      final c = make(grantPermission: true)..getStarted();
      expect(c.step, OnboardingStep.language); // language now precedes the capture steps
      c.continueFromLanguage();
      expect(c.step, OnboardingStep.permission);
    });

    test('Enable → granted → rehearsal (and busy clears)', () async {
      final c = atPermission(grantPermission: true);
      await c.enableScreenRecording();
      expect(c.step, OnboardingStep.rehearsal);
      expect(c.busy, isFalse);
    });

    test('Enable → prompt shown (request false) → pending, NOT clipboard', () async {
      // CGRequestScreenCaptureAccess returns false the instant it shows the
      // system prompt; that is not a decline, so we must not drop to clipboard.
      final c = atPermission(grantPermission: false);
      await c.enableScreenRecording();
      expect(c.step, OnboardingStep.permissionPending);
      expect(c.busy, isFalse);
    });

    test('Enable → already granted (preflight) → straight to rehearsal', () async {
      final c = atPermission(grantPermission: false, preflightGranted: true);
      await settle(); // preflight resolves → "ready" variant
      expect(c.permissionGranted, isTrue);
      await c.enableScreenRecording();
      expect(c.step, OnboardingStep.rehearsal);
      expect(c.ocrArmed, isTrue);
    });

    test('pending → recheck finds it granted → rehearsal (OCR armed)', () async {
      // Preflight flips false → true once the user enables it in Settings.
      completed = false;
      var preflight = false;
      final c =
          OnboardingController(
              requestPermission: () async => false,
              checkPermission: () async => preflight,
              openSettings: () async {},
              complete: () async => completed = true,
            )
            ..getStarted()
            ..continueFromLanguage();
      await c.enableScreenRecording();
      expect(c.step, OnboardingStep.permissionPending);
      preflight = true;
      await c.recheckPermission();
      expect(c.step, OnboardingStep.rehearsal);
      expect(c.ocrArmed, isTrue);
    });

    test('pending → recheck still not granted → stays, shows relaunch hint', () async {
      final c = atPermission(grantPermission: false);
      await c.enableScreenRecording();
      expect(c.step, OnboardingStep.permissionPending);
      await c.recheckPermission();
      expect(c.step, OnboardingStep.permissionPending);
      expect(c.recheckedNotGranted, isTrue);
    });

    test('use copy & paste skips straight to the rehearsal (clipboard), no interstitial', () {
      final c = atPermission(grantPermission: false);
      c.useClipboardCapture();
      expect(c.step, OnboardingStep.rehearsal);
      expect(c.ocrArmed, isFalse);
    });

    test('Skip → clipboard capture → rehearsal', () {
      final c = atPermission(grantPermission: true)..useClipboardCapture();
      expect(c.step, OnboardingStep.rehearsal);
      expect(c.ocrArmed, isFalse);
    });

    test('first capture saved advances rehearsal → sign-in', () {
      final c = make(grantPermission: true)..getStarted();
      // not in rehearsal yet (on the language step): a stray save is a no-op
      c.onFirstCaptureSaved();
      expect(c.step, OnboardingStep.language);
      c.continueFromLanguage();
      c.useClipboardCapture(); // → rehearsal
      c.onFirstCaptureSaved();
      expect(c.step, OnboardingStep.signIn);
    });

    test('skipRehearsal advances only from rehearsal → sign-in', () {
      final c = make(grantPermission: true);
      c.skipRehearsal();
      expect(c.step, OnboardingStep.howItWorks); // no-op off rehearsal
      c.getStarted();
      c.continueFromLanguage();
      c.useClipboardCapture();
      c.skipRehearsal();
      expect(c.step, OnboardingStep.signIn);
    });

    test('the guided capture lands on the terminal sign-in/finish step (for everyone)', () {
      // The post-capture sign-in now lives on the terminal `signIn` step; the language axes moved to
      // their own step ahead of capture, so reaching the terminal is the same whether you save or skip.
      final viaSave = make(grantPermission: true)
        ..getStarted()
        ..continueFromLanguage()
        ..useClipboardCapture()
        ..onFirstCaptureSaved();
      expect(viaSave.step, OnboardingStep.signIn);

      final viaSkip = make(grantPermission: true)
        ..getStarted()
        ..continueFromLanguage()
        ..useClipboardCapture()
        ..skipRehearsal();
      expect(viaSkip.step, OnboardingStep.signIn);
    });

    test('openScreenRecordingSettings + finish delegate', () async {
      final c = make(grantPermission: false);
      await c.openScreenRecordingSettings();
      expect(openSettingsCalls, 1);
      await c.finish();
      expect(completed, isTrue);
    });

    test('ocrArmed tracks the branch (CR #2)', () async {
      final granted = atPermission(grantPermission: true);
      await granted.enableScreenRecording();
      expect(granted.ocrArmed, isTrue);

      final skipped = atPermission(grantPermission: true)..useClipboardCapture();
      expect(skipped.ocrArmed, isFalse);

      final pending = atPermission(grantPermission: false);
      await pending.enableScreenRecording();
      expect(pending.ocrArmed, isFalse);
    });

    test('a thrown permission call falls back to clipboard capture (rehearsal, CR #8)', () async {
      completed = false;
      openSettingsCalls = 0;
      final c =
          OnboardingController(
              requestPermission: () async => throw StateError('boom'),
              checkPermission: () async => false,
              openSettings: () async {},
              complete: () async => completed = true,
            )
            ..getStarted()
            ..continueFromLanguage();
      await c.enableScreenRecording();
      expect(c.step, OnboardingStep.rehearsal); // no separate clipboard screen any more
      expect(c.ocrArmed, isFalse);
    });

    test('completion persists on reaching the end of the required flow (sign-in), '
        'not just the final tap (CR #10)', () {
      final c = make(grantPermission: true)
        ..getStarted()
        ..continueFromLanguage()
        ..useClipboardCapture();
      expect(completed, isFalse);
      c.onFirstCaptureSaved(); // rehearsal → sign-in (the guided capture is done)
      expect(c.step, OnboardingStep.signIn);
      expect(completed, isTrue); // persisted in _go on entering sign-in (sign-in is optional)
    });

    // --- Bottom navigation (← / →) ------------------------------------------

    test('goBack folds steps back one at a time (pending/rehearsal → permission)', () {
      final c = atPermission(grantPermission: false); // on permission
      expect(c.canGoBack, isTrue);
      c.goBack();
      expect(c.step, OnboardingStep.language);
      c.goBack();
      expect(c.step, OnboardingStep.howItWorks);
      expect(c.canGoBack, isFalse); // nothing before the first step
      c.goBack();
      expect(c.step, OnboardingStep.howItWorks); // no-op
    });

    test('goBack from the terminal returns to the rehearsal (and keeps completion persisted)', () {
      final c = make(grantPermission: true)
        ..getStarted()
        ..continueFromLanguage()
        ..useClipboardCapture()
        ..onFirstCaptureSaved(); // → signIn (persists completion)
      expect(completed, isTrue);
      c.goBack();
      expect(c.step, OnboardingStep.rehearsal);
      expect(completed, isTrue); // back-navigation never un-persists
    });

    test('goForward mirrors each step’s advance/skip path', () {
      final c = make(grantPermission: true);
      c.goForward(); // howItWorks → language
      expect(c.step, OnboardingStep.language);
      c.goForward(); // language → permission (applies languages)
      expect(c.step, OnboardingStep.permission);
      c.goForward(); // permission (not granted) → rehearsal in clipboard mode
      expect(c.step, OnboardingStep.rehearsal);
      expect(c.ocrArmed, isFalse);
      c.goForward(); // rehearsal → signIn (skip)
      expect(c.step, OnboardingStep.signIn);
    });

    // --- Language (now its own step, ahead of capture; US-ON.1 §9) -----------

    /// Walk a controller to the (terminal) sign-in/finish step the short way.
    OnboardingController toFinish() => make(grantPermission: true)
      ..getStarted()
      ..continueFromLanguage()
      ..useClipboardCapture()
      ..onFirstCaptureSaved(); // → signIn (terminal)

    test('language defaults to learning=English + native language English (test seed)', () {
      final c = toFinish();
      expect(c.step, OnboardingStep.signIn);
      // Native language is a direct pick (no "follows learning"); the test seed is English.
      expect(c.explanationFollowsLearning, isFalse);
      expect(c.explanationLanguage, 'en');
      expect(c.learningLanguage, 'en');
    });

    test('language step: setters update each axis independently', () {
      final c = make(grantPermission: true);
      c.setExplanationLanguage('zh-Hans');
      c.setLearningLanguage('es');
      expect(c.explanationLanguage, 'zh-Hans');
      expect(
        c.explanationFollowsLearning,
        isFalse,
      ); // native is a direct pick; the flag stays false
      expect(c.learningLanguage, 'es');
    });

    test(
      'languages are applied on leaving the language step AND re-committed at the terminal',
      () async {
        final c = make(grantPermission: true)..getStarted(); // on the language step
        c.setExplanationLanguage('es');
        c.setLearningLanguage('fr');
        c.continueFromLanguage(); // applies to the session (call #1) → permission
        expect(
          chooseLanguagesCalls,
          1,
        ); // eager apply so the rehearsal capture uses the choice (§8)
        c.useClipboardCapture();
        c.onFirstCaptureSaved(); // → signIn
        await c.commitLanguages();
        expect(
          chooseLanguagesCalls,
          2,
        ); // re-applied at the terminal (catches a sign-in that happened here)
        expect(chosenExplanation, 'es');
        expect(chosenFollows, isFalse); // an explicit explanation pick → not following
        expect(chosenLearning, 'fr');
        expect(completed, isTrue); // finish() persisted onboarding-done
      },
    );

    test('commitLanguages is a no-op off the terminal step', () async {
      final c = make(grantPermission: true)..getStarted(); // on the language step
      await c.commitLanguages();
      expect(chooseLanguagesCalls, 0);
    });

    test('a thrown chooseLanguages still finishes (best-effort persistence)', () async {
      var done = false;
      final c =
          OnboardingController(
              requestPermission: () async => true,
              checkPermission: () async => false,
              openSettings: () async {},
              complete: () async => done = true,
              chooseLanguages:
                  ({
                    required String explanationLanguage,
                    required bool explanationFollowsLearning,
                    required String learningLanguage,
                  }) async => throw StateError('offline'),
            )
            ..getStarted()
            ..continueFromLanguage() // an eager apply throws here — must not trap the user
            ..useClipboardCapture()
            ..onFirstCaptureSaved(); // → signIn (terminal)
      await c.commitLanguages();
      expect(done, isTrue); // a persist failure must not trap the user in onboarding
    });

    test(
      'commitLanguages is re-entrancy-safe + one-shot (committing latch, single fire)',
      () async {
        final gate = Completer<void>();
        var calls = 0;
        final c =
            OnboardingController(
                requestPermission: () async => true,
                checkPermission: () async => false,
                openSettings: () async {},
                complete: () async {},
                chooseLanguages:
                    ({
                      required String explanationLanguage,
                      required bool explanationFollowsLearning,
                      required String learningLanguage,
                    }) async {
                      calls++;
                      await gate
                          .future; // hold the persist open so the in-flight window is observable
                    },
              )
              ..getStarted()
              ..continueFromLanguage() // the eager apply fires once (then waits on the gate)
              ..useClipboardCapture()
              ..onFirstCaptureSaved(); // → signIn (terminal)
        expect(calls, 1); // the eager apply on leaving the language step
        final first = c.commitLanguages();
        expect(c.committing, isTrue); // spinner up while the persist is in flight
        await c.commitLanguages(); // a second tap mid-flight is ignored
        expect(calls, 2); // eager apply + the single terminal commit; the re-tap added none
        gate.complete();
        await first;
        expect(c.committing, isFalse); // spinner cleared once it settles
        await c.commitLanguages(); // a tap AFTER completion is also a no-op (terminal latch)
        expect(calls, 2);
      },
    );
  });

  // Walk a flow widget by visible button label.
  Future<void> tapText(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('OnboardingFlow renders step 1, advances through language to permission', (
    tester,
  ) async {
    final saved = StreamController<void>.broadcast();
    addTearDown(saved.close);
    var done = false;
    var openedPrivacy = false;
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingFlow(
          requestPermission: () async => true,
          checkPermission: () async => false,
          openScreenRecordingSettings: () async {},
          completeOnboarding: () async {},
          authController: _stubAuth(),
          savedSignal: saved.stream,
          chooseLanguages: _noopChoose,
          openPrivacyInfo: () async => openedPrivacy = true,
          onDone: () => done = true,
        ),
      ),
    );

    expect(find.text('Get started'), findsOneWidget);
    await tapText(tester, 'Get started');
    // The language step now sits between the overview and the permission ask.
    expect(find.text('Which language are you learning?'), findsOneWidget);
    expect(find.text('I’m learning'), findsOneWidget);
    await tapText(tester, 'Continue');

    expect(find.text('Allow on-device capture'), findsOneWidget);
    expect(find.text('Use copy & paste instead'), findsOneWidget);
    // The trimmed step drops the verbose lede; it keeps the no-upload promise (privacy fact card)
    // and the "why Screen Recording" disclosure link below the CTAs.
    expect(find.textContaining('screen image never reaches Capecho'), findsOneWidget);
    expect(find.textContaining('Capecho reads the screen'), findsNothing);

    // The "why Screen Recording" link opens the privacy explainer (injected here).
    await tapText(tester, 'Why does macOS call this “Screen Recording”?  ↗');
    expect(openedPrivacy, isTrue);
    expect(done, isFalse);
  });

  testWidgets('OnboardingFlow can resume directly at the permission step', (tester) async {
    final saved = StreamController<void>.broadcast();
    addTearDown(saved.close);
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingFlow(
          requestPermission: () async => false,
          checkPermission: () async => true,
          openScreenRecordingSettings: () async {},
          completeOnboarding: () async {},
          initialStep: OnboardingStep.permission,
          authController: _stubAuth(),
          savedSignal: saved.stream,
          chooseLanguages: _noopChoose,
          onDone: () {},
        ),
      ),
    );

    expect(find.text('Get started'), findsNothing);
    // Constructor preflight resolves → ready variant (the relaunch-after-grant resume skips the intro
    // + language steps, which were already passed in the prior run).
    await tester.pumpAndSettle();
    expect(find.text('On-device capture is ready.'), findsOneWidget);
    expect(find.text('Use copy & paste instead'), findsNothing);
  });

  testWidgets('how-it-works (step 1) is vertically centered in the step region', (tester) async {
    _pinLayoutCanvas(tester);
    final saved = StreamController<void>.broadcast();
    addTearDown(saved.close);

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingFlow(
          requestPermission: () async => true,
          checkPermission: () async => false,
          openScreenRecordingSettings: () async {},
          completeOnboarding: () async {},
          authController: _stubAuth(),
          savedSignal: saved.stream,
          chooseLanguages: _noopChoose,
          onDone: () {},
        ),
      ),
    );

    // Every step centers vertically in the scroll region above the bottom nav bar (asserted by
    // geometry, not pixels, so the unbundled app fonts can't make it flaky).
    final region = tester.getRect(find.byKey(onboardingScrollRegionKey));
    final content = tester.getRect(find.byKey(onboardingStepContentKey));
    expect(content.center.dy, closeTo(region.center.dy, 1.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('later onboarding steps are vertically centered in the step region', (tester) async {
    _pinLayoutCanvas(tester);
    final saved = StreamController<void>.broadcast();
    addTearDown(saved.close);

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingFlow(
          requestPermission: () async => true,
          checkPermission: () async => false,
          openScreenRecordingSettings: () async {},
          completeOnboarding: () async {},
          authController: _stubAuth(),
          savedSignal: saved.stream,
          chooseLanguages: _noopChoose,
          onDone: () {},
        ),
      ),
    );

    // Walk to the language step (a shorter, centered screen).
    await tapText(tester, 'Get started');
    expect(find.text('Which language are you learning?'), findsOneWidget);

    final region = tester.getRect(find.byKey(onboardingScrollRegionKey));
    final content = tester.getRect(find.byKey(onboardingStepContentKey));
    expect(content.center.dy, closeTo(region.center.dy, 1.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('full clipboard flow: language → skip permission → ⌘C rehearsal → saved → '
      'terminal finish → start capturing → onDone + persist', (tester) async {
    final saved = StreamController<void>.broadcast();
    addTearDown(saved.close);
    var done = false;
    var persisted = false;

    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingFlow(
          requestPermission: () async => true,
          checkPermission: () async => false,
          openScreenRecordingSettings: () async {},
          completeOnboarding: () async => persisted = true,
          authController: _stubAuth(),
          savedSignal: saved.stream,
          chooseLanguages: _noopChoose,
          onDone: () => done = true,
        ),
      ),
    );

    await tapText(tester, 'Get started');
    await tapText(tester, 'Continue'); // language → permission
    // "Use copy & paste instead" now skips straight to the rehearsal — no clipboard interstitial.
    await tapText(tester, 'Use copy & paste instead');
    // Clipboard-mode rehearsal must instruct copy-then-⌥E, not OCR-hover.
    expect(find.textContaining('Copy a word'), findsOneWidget);

    // The real first capture lands → advance to the post-save sign-in step + persist there.
    saved.add(null);
    await tester.pumpAndSettle();
    // The terminal finish screen is now sign-in only (the language axes moved to their own step).
    expect(find.text('Your first word is saved to this Mac'), findsNothing);
    expect(find.text('Sync your Word Book'), findsOneWidget);
    expect(persisted, isTrue); // persisted on reaching the end of the required flow
    expect(done, isFalse);

    // "Start capturing" commits the (default English) languages + finishes onboarding.
    await tapText(tester, 'Start capturing');
    expect(done, isTrue);
  });

  testWidgets('sign-in step renders providers; email toggle reveals the email field + Back returns', (
    tester,
  ) async {
    final saved = StreamController<void>.broadcast();
    addTearDown(saved.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS), // an Apple platform → Apple offered
        home: OnboardingFlow(
          requestPermission: () async => false,
          checkPermission: () async => false,
          openScreenRecordingSettings: () async {},
          completeOnboarding: () async {},
          authController: _stubAuth(),
          savedSignal: saved.stream,
          chooseLanguages: _noopChoose,
          onDone: () {},
        ),
      ),
    );

    // Walk to the sign-in step via the language step + a skipped permission + a (simulated) first save.
    await tapText(tester, 'Get started');
    await tapText(tester, 'Continue'); // language → permission
    await tapText(tester, 'Use copy & paste instead'); // → rehearsal
    saved.add(null);
    await tester.pumpAndSettle();

    // Provider buttons present. Apple is hidden on macOS (Developer ID can't use Sign in with Apple);
    // Google + email always show.
    expect(find.text('Continue with Apple'), findsNothing);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with email'), findsOneWidget);

    // Email toggle → the email entry (Send code) appears; Back returns to providers.
    await tapText(tester, 'Continue with email');
    expect(find.text('Send code'), findsOneWidget);
    await tapText(tester, 'Back');
    expect(find.text('Continue with email'), findsOneWidget);
  });

  testWidgets(
    'first-run email sign-in collapses the provider panel in place (no confirmation card)',
    (tester) async {
      final auth = AuthController(
        api: CapechoApi(baseUrl: 'https://api.test', transport: _EmailSignInTransport()),
        store: _MemStore(),
        collectClaimRows: () async => const [],
        installId: () async => 'i',
      );
      final saved = StreamController<void>.broadcast();
      addTearDown(saved.close);
      await tester.pumpWidget(
        MaterialApp(
          home: OnboardingFlow(
            requestPermission: () async => false,
            checkPermission: () async => false,
            openScreenRecordingSettings: () async {},
            completeOnboarding: () async {},
            authController: auth,
            savedSignal: saved.stream,
            chooseLanguages: _noopChoose,
            onDone: () {},
          ),
        ),
      );

      await tapText(tester, 'Get started');
      await tapText(tester, 'Continue'); // language → permission
      await tapText(tester, 'Use copy & paste instead'); // → rehearsal
      await tapText(tester, 'I’ll try this later'); // → signIn (terminal, signed out)
      await tapText(tester, 'Continue with email');
      await tester.enterText(find.byType(TextField), 'a@b.co');
      await tapText(tester, 'Send code');
      await tester.enterText(find.byType(TextField), '123456');
      await tapText(tester, 'Verify & sign in');
      // No "You're signed in." card — a fresh in-flow sign-in just collapses the
      // provider panel; the finish screen (now headed "You're all set") stays put.
      expect(find.text("You're signed in."), findsNothing);
      expect(find.text('Continue with email'), findsNothing);
      expect(find.text('You’re all set'), findsOneWidget);
      expect(find.text('Start capturing'), findsOneWidget);
    },
  );

  testWidgets('signed-in user re-running onboarding sees the finish screen '
      'without provider buttons', (tester) async {
    final store = _MemStore();
    await store.saveToken('tok');
    final auth = AuthController(
      api: CapechoApi(baseUrl: 'https://api.test', transport: _MeTransport()),
      store: store,
      collectClaimRows: () async => const [],
      installId: () async => 'i',
    );
    await auth.restore();
    expect(auth.isSignedIn, isTrue);

    final saved = StreamController<void>.broadcast();
    addTearDown(saved.close);
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingFlow(
          requestPermission: () async => false,
          checkPermission: () async => true, // already granted (the re-run scenario)
          openScreenRecordingSettings: () async {},
          completeOnboarding: () async {},
          authController: auth,
          savedSignal: saved.stream,
          chooseLanguages: _noopChoose,
          onDone: () {},
        ),
      ),
    );

    await tapText(tester, 'Get started'); // → language
    await tapText(tester, 'Continue'); // language → permission (preflight: granted)
    await tester.pumpAndSettle(); // preflight resolves → ready variant
    await tapText(tester, 'Continue'); // permission(ready) → rehearsal
    await tapText(tester, 'I’ll try this later'); // rehearsal → terminal finish step
    // A signed-in user sees the finish screen with NO provider buttons — just the
    // "all set" confirmation and "Start capturing".
    expect(find.text("You're signed in."), findsNothing);
    expect(find.text('Continue with Google'), findsNothing);
    expect(find.text('You’re all set'), findsOneWidget);
    expect(find.text('Start capturing'), findsOneWidget);
  });

  testWidgets('a request that only shows the prompt routes to the pending '
      'screen, not the clipboard wall', (tester) async {
    final saved = StreamController<void>.broadcast();
    addTearDown(saved.close);
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingFlow(
          requestPermission: () async => false, // prompt shown, not yet applied
          checkPermission: () async => false,
          openScreenRecordingSettings: () async {},
          completeOnboarding: () async {},
          authController: _stubAuth(),
          savedSignal: saved.stream,
          chooseLanguages: _noopChoose,
          onDone: () {},
        ),
      ),
    );

    await tapText(tester, 'Get started');
    await tapText(tester, 'Continue'); // language → permission
    await tapText(tester, 'Allow on-device capture');
    expect(find.text('Turn on Screen Recording'), findsOneWidget);
    expect(find.text('I’ve enabled it'), findsOneWidget);
    // The pending screen keeps a clipboard escape, but there is no clipboard-mode interstitial.
    expect(find.text('Use copy & paste instead'), findsOneWidget);
  });

  testWidgets('an already-granted Mac shows the ready variant and skips the '
      'prompt', (tester) async {
    final saved = StreamController<void>.broadcast();
    addTearDown(saved.close);
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingFlow(
          requestPermission: () async => false, // must NOT be needed
          checkPermission: () async => true, // preflight: already on
          openScreenRecordingSettings: () async {},
          completeOnboarding: () async {},
          authController: _stubAuth(),
          savedSignal: saved.stream,
          chooseLanguages: _noopChoose,
          onDone: () {},
        ),
      ),
    );

    await tapText(tester, 'Get started'); // → language
    await tapText(tester, 'Continue'); // language → permission (fires the preflight)
    await tester.pumpAndSettle(); // preflight resolves → ready variant
    expect(find.text('On-device capture is ready.'), findsOneWidget);
    // Granted → the clipboard fallback is hidden (it's only for not-yet-armed capture).
    expect(find.text('Use copy & paste instead'), findsNothing);
    // The CTA arms OCR and goes straight to the (OCR) rehearsal — no re-prompt.
    await tapText(tester, 'Continue');
    expect(find.text('I’ll try this later'), findsOneWidget);
  });

  testWidgets('Apple is hidden off iOS; Google + email always show', (tester) async {
    final saved = StreamController<void>.broadcast();
    addTearDown(saved.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
        ), // a non-Apple platform → no Apple button
        home: OnboardingFlow(
          requestPermission: () async => false,
          checkPermission: () async => false,
          openScreenRecordingSettings: () async {},
          completeOnboarding: () async {},
          authController: _stubAuth(),
          savedSignal: saved.stream,
          chooseLanguages: _noopChoose,
          onDone: () {},
        ),
      ),
    );

    await tapText(tester, 'Get started');
    await tapText(tester, 'Continue'); // language → permission
    await tapText(tester, 'Use copy & paste instead'); // → rehearsal
    saved.add(null);
    await tester.pumpAndSettle();

    expect(find.text('Continue with Apple'), findsNothing); // hidden off Apple platforms
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Continue with email'), findsOneWidget);
  });

  testWidgets('Google sign-in collapses the provider panel in place', (tester) async {
    final auth = AuthController(
      api: CapechoApi(baseUrl: 'https://api.test', transport: _SocialSignInTransport()),
      store: _MemStore(),
      collectClaimRows: () async => const [],
      installId: () async => 'i',
      googleCredential: () async => 'g-id-token',
    );
    final saved = StreamController<void>.broadcast();
    addTearDown(saved.close);
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingFlow(
          requestPermission: () async => false,
          checkPermission: () async => false,
          openScreenRecordingSettings: () async {},
          completeOnboarding: () async {},
          authController: auth,
          savedSignal: saved.stream,
          chooseLanguages: _noopChoose,
          onDone: () {},
        ),
      ),
    );

    await tapText(tester, 'Get started');
    await tapText(tester, 'Continue'); // language → permission
    await tapText(tester, 'Use copy & paste instead'); // → rehearsal
    await tapText(tester, 'I’ll try this later'); // → signIn (terminal)
    await tapText(tester, 'Continue with Google');
    // A fresh sign-in just collapses the provider panel (no confirmation card).
    expect(find.text("You're signed in."), findsNothing);
    expect(find.text('You’re all set'), findsOneWidget);
    expect(find.text('Start capturing'), findsOneWidget);
  });

  testWidgets('language step: the compact language strip commits a chosen explanation '
      'language and the flow finishes', (tester) async {
    final saved = StreamController<void>.broadcast();
    addTearDown(saved.close);
    var done = false;
    String? explanation;
    String? learning;
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingFlow(
          requestPermission: () async => false,
          checkPermission: () async => false,
          openScreenRecordingSettings: () async {},
          completeOnboarding: () async {},
          authController: _stubAuth(),
          savedSignal: saved.stream,
          chooseLanguages:
              ({
                required String explanationLanguage,
                required bool explanationFollowsLearning,
                required String learningLanguage,
              }) async {
                explanation = explanationLanguage;
                learning = learningLanguage;
              },
          onDone: () => done = true,
        ),
      ),
    );

    // The two-axis language strip lives on the language step now (ahead of capture).
    await tapText(tester, 'Get started');
    expect(find.text('I’m learning'), findsOneWidget);
    expect(find.text('My language'), findsOneWidget);

    // Open the native-language picker (a direct pick, seeded to English in tests) and choose a
    // non-default language (简体中文).
    await tester.ensureVisible(find.byTooltip('Choose your native language'));
    await tester.tap(find.byTooltip('Choose your native language'));
    await tester.pumpAndSettle();
    // Regression guard: ja/ko stay valid GLOSS languages — deferred only as capture targets, never
    // from the explanation picker (§9). A shared learning/explanation list once dropped them here.
    expect(find.text('日本語'), findsWidgets);
    expect(find.text('한국어'), findsWidgets);
    await tester.tap(find.text('简体中文').last);
    await tester.pumpAndSettle();

    // Continue → skip permission → skip rehearsal → terminal → Start capturing.
    await tapText(tester, 'Continue');
    await tapText(tester, 'Use copy & paste instead');
    await tapText(tester, 'I’ll try this later');
    expect(done, isFalse);
    await tapText(tester, 'Start capturing');

    expect(done, isTrue);
    expect(explanation, 'zh-Hans'); // the chosen explanation language
    expect(learning, 'en'); // learning left at the English default
  });

  testWidgets('language step: the learning selectbox commits a non-English target language', (
    tester,
  ) async {
    final saved = StreamController<void>.broadcast();
    addTearDown(saved.close);
    String? learning;
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingFlow(
          requestPermission: () async => false,
          checkPermission: () async => false,
          openScreenRecordingSettings: () async {},
          completeOnboarding: () async {},
          authController: _stubAuth(),
          savedSignal: saved.stream,
          chooseLanguages:
              ({
                required String explanationLanguage,
                required bool explanationFollowsLearning,
                required String learningLanguage,
              }) async {
                learning = learningLanguage;
              },
          onDone: () {},
        ),
      ),
    );

    await tapText(tester, 'Get started'); // → language

    // Open the learning selectbox (by tooltip — the explanation axis is also a popup) + pick 中文.
    await tester.ensureVisible(find.byTooltip('Choose learning language'));
    await tester.tap(find.byTooltip('Choose learning language'));
    await tester.pumpAndSettle();
    // Regression guard: the learning picker shows ONLY generation-ENABLED targets (en + zh-Hans + ja);
    // a target without explanations would onboard the user into a broken core loop (§9). ja is enabled
    // now (its eval gate passed), so 日本語 appears; ko/fr/de stay explanation-only, never learning targets.
    expect(find.text('日本語'), findsWidgets);
    expect(find.text('한국어'), findsNothing);
    expect(find.text('Français'), findsNothing);
    expect(find.text('Deutsch'), findsNothing);
    await tester.tap(find.text('简体中文').last);
    await tester.pumpAndSettle();
    expect(find.text('简体中文'), findsOneWidget); // the closed selectbox reflects the choice

    await tapText(tester, 'Continue');
    await tapText(tester, 'Use copy & paste instead');
    await tapText(tester, 'I’ll try this later');
    await tapText(tester, 'Start capturing');
    expect(learning, 'zh-Hans');
  });
}
