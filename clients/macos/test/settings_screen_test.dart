import 'dart:async';

import 'package:capecho/settings/capture_source_prefs.dart';
import 'package:capecho/settings/settings_controller.dart';
import 'package:capecho/settings/settings_screen.dart';
import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

class _MemStore implements SessionStore {
  String? _t;
  @override
  Future<String?> loadToken() async => _t;
  @override
  Future<void> saveToken(String token) async => _t = token;
  @override
  Future<void> clear() async => _t = null;
}

/// Answers `GET /auth/me` with a user so `restore()` lands signed-in; everything else 200 `{}`
/// (covers `signOut`'s POST). [learning] sets the account's learning language (null → unset).
class _MeTransport implements HttpTransport {
  _MeTransport({this.learning});
  final String? learning;

  @override
  Future<TransportResponse> send(TransportRequest r) async {
    if (r.url.endsWith('/auth/me')) {
      final l = learning == null ? 'null' : '"$learning"';
      return TransportResponse(
        statusCode: 200,
        body:
            '{"user":{"id":"a","iana_timezone":"UTC","explanation_language":"en","explanation_follows_learning":false,"reminder_enabled":false,"pro":false,"learning_language":$l}}',
      );
    }
    return const TransportResponse(statusCode: 200, body: '{}');
  }
}

/// Signed-in transport whose `PATCH /account` is controllable: [throwOnPatch] → a true transport
/// failure (offline → "Queued"); else [failPatch] → a 500 (a hard `ApiException` → "Not saved");
/// else a 200 echo (explanation_language → zh-Hans, so success is observable on `auth.account`).
class _PatchTransport implements HttpTransport {
  bool failPatch = true;
  bool throwOnPatch = false;
  int patchCalls = 0;

  @override
  Future<TransportResponse> send(TransportRequest r) async {
    if (r.url.endsWith('/auth/me')) {
      return const TransportResponse(
        statusCode: 200,
        body:
            '{"user":{"id":"a","iana_timezone":"UTC","explanation_language":"en","explanation_follows_learning":false,"reminder_enabled":false,"pro":false,"learning_language":null}}',
      );
    }
    if (r.url.endsWith('/account')) {
      patchCalls++;
      if (throwOnPatch) {
        throw Exception('offline'); // a real transport failure → queued
      }
      if (failPatch) {
        return const TransportResponse(statusCode: 500, body: '{"error":"server_error"}');
      }
      return const TransportResponse(
        statusCode: 200,
        body:
            '{"user":{"id":"a","iana_timezone":"UTC","explanation_language":"zh-Hans","explanation_follows_learning":false,"pro":false,"learning_language":null,'
            '"reminder_enabled":false,"reminder_time":null}}',
      );
    }
    return const TransportResponse(statusCode: 200, body: '{}');
  }
}

Future<AuthController> _signedInAuth({String? learning}) async {
  final store = _MemStore();
  await store.saveToken('tok');
  final auth = AuthController(
    api: CapechoApi(
      baseUrl: 'https://api.test',
      transport: _MeTransport(learning: learning),
    ),
    store: store,
    collectClaimRows: () async => const [],
    installId: () async => 'inst',
  );
  await auth.restore();
  return auth;
}

AuthController _signedOutAuth() => AuthController(
  api: CapechoApi(baseUrl: 'https://api.test', transport: _MeTransport()),
  store: _MemStore(),
  collectClaimRows: () async => const [],
  installId: () async => 'inst',
);

/// A no-op [PurchaseBackend] that records the restore call — enough to prove the Mac App Store Settings
/// "Restore purchases" affordance wires to [ProPurchaseController.restore].
class _FakeBackend implements PurchaseBackend {
  final StreamController<List<PurchaseDetails>> _stream =
      StreamController<List<PurchaseDetails>>.broadcast();
  int restoreCalls = 0;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _stream.stream;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> ids) async =>
      ProductDetailsResponse(productDetails: const [], notFoundIDs: const []);
  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async => true;
  @override
  Future<void> completePurchase(PurchaseDetails purchase) async {}
  @override
  Future<void> restorePurchases() async => restoreCalls++;

  Future<void> close() => _stream.close();
}

ProPurchaseController _purchasesController(_FakeBackend backend) => ProPurchaseController(
  backend: backend,
  verify: (_) async => const AppleVerifyResult(pro: true, proUntil: 0, status: 'active'),
  onEntitlementChanged: () async {},
  currentAccountId: () => 'acct',
);

Widget _host(
  AuthController auth, {
  required Future<bool> Function() check,
  Future<void> Function()? open,
  VoidCallback? onReplay,
  LanguagePrefsController? languagePrefs,
  CaptureSourceController? captureSource,
  Future<String?> Function()? loadAppVersion,
  Future<void> Function(Uri uri)? openExternalUrl,
  ProPurchaseController? purchases,
  bool scrollToAccount = false,
}) => MaterialApp(
  // This is the macOS app (TargetPlatform.macOS). SignInPanel does NOT offer Apple on macOS
  // (Developer ID can't use Sign in with Apple); Google + email are shown.
  theme: ThemeData(platform: TargetPlatform.macOS),
  home: SettingsScreen(
    auth: auth,
    appearance: AppearanceController(),
    languagePrefs: languagePrefs ?? LanguagePrefsController(),
    captureSource: captureSource ?? CaptureSourceController(),
    checkPermission: check,
    openSystemSettings: open ?? () async {},
    onReplayOnboarding: onReplay,
    loadAppVersion: loadAppVersion,
    openExternalUrl: openExternalUrl,
    purchases: purchases,
    scrollToAccount: scrollToAccount,
  ),
);

void main() {
  testWidgets('signed-in renders the masthead + every section', (tester) async {
    final auth = await _signedInAuth();
    await tester.pumpWidget(_host(auth, check: () async => true));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Capecho'),
      findsWidgets,
    ); // masthead wordmark (+ the language desc copy)
    expect(find.text('Daily review reminder'), findsOneWidget); // Reminders section
    expect(find.text('Native language'), findsOneWidget);
    expect(
      find.text('English'),
      findsOneWidget,
    ); // explanation dropdown shows the current value (en); other langs are in the closed menu
    expect(find.text('Not set yet'), findsOneWidget); // learning selectbox (unset)
    // Appearance section: the device-local theme picker (System / Light / Dark).
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('Granted'), findsOneWidget);
    expect(find.text('SHORTCUTS'), findsOneWidget);
    expect(find.text('⌥E'), findsOneWidget);
    expect(find.text('⌥R'), findsOneWidget);
    expect(find.text('⌥B'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Delete account & data'), findsOneWidget); // destructive row
    expect(find.textContaining('Manage your saved words'), findsOneWidget);
  });

  testWidgets('permission off shows the clipboard-mode notice + Open System Settings', (
    tester,
  ) async {
    final auth = await _signedInAuth();
    await tester.pumpWidget(_host(auth, check: () async => false));
    await tester.pumpAndSettle();

    expect(find.text('Off'), findsOneWidget);
    expect(find.textContaining('Clipboard mode is working'), findsOneWidget);
    expect(find.text('Open System Settings…'), findsOneWidget);
  });

  testWidgets('a probe failure shows a neutral status, never a false Off', (tester) async {
    final auth = await _signedInAuth();
    await tester.pumpWidget(_host(auth, check: () async => throw Exception('tcc')));
    await tester.pumpAndSettle();

    expect(find.text('Off'), findsNothing);
    expect(find.text('Unknown'), findsOneWidget);
  });

  testWidgets('Sign out flips Account to signed-out (provider buttons) and hides member sections', (
    tester,
  ) async {
    final auth = await _signedInAuth();
    await tester.pumpWidget(_host(auth, check: () async => true));
    await tester.pumpAndSettle();
    expect(find.text('Sign out'), findsOneWidget);

    // Account sits below the Language/Capture/Shortcuts sections — scroll it into view to tap it.
    await tester.ensureVisible(find.text('Sign out'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(find.text('Sign out'), findsNothing);
    expect(find.textContaining('You’re signed out'), findsOneWidget);
    expect(
      find.text('Continue with Apple'),
      findsNothing,
    ); // Apple not offered on macOS (Developer ID)
    expect(find.text('Continue with email'), findsOneWidget);
    // Reminders + Word Book pointer stay gated on a session; Language now shows signed-out (it reads
    // the device-local prefs, since the learning language governs local captures).
    expect(find.text('Daily review reminder'), findsNothing);
    expect(find.textContaining('Manage your saved words'), findsNothing);
    expect(find.text('Native language'), findsOneWidget);
    // The capture-permission surface stays — it applies signed-out too.
    expect(find.text('Screen Recording'), findsOneWidget);
  });

  testWidgets('signed-out entry: permission surface + provider buttons, no member sections', (
    tester,
  ) async {
    final auth = _signedOutAuth();
    await tester.pumpWidget(_host(auth, check: () async => true));
    await tester.pumpAndSettle();

    expect(find.textContaining('You’re signed out'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Screen Recording'), findsOneWidget);
    // The Language section shows signed-out too (device-local), defaulting to English.
    expect(find.text('Native language'), findsOneWidget);
    expect(find.text('Learning language'), findsOneWidget);
  });

  testWidgets('signed-out: changing a language writes the device-local prefs (no account)', (
    tester,
  ) async {
    final auth = _signedOutAuth();
    final prefs = LanguagePrefsController(); // in-memory store; defaults to English
    await tester.pumpWidget(_host(auth, check: () async => true, languagePrefs: prefs));
    await tester.pumpAndSettle();

    // Pick a new learning language from the signed-out selectbox → it writes straight to the
    // device-local controller (there's no account to PATCH), and the closed box reflects it.
    // (D5: the learning picker offers only generation-enabled targets — en + zh-Hans.)
    await tester.ensureVisible(find.byTooltip('Choose learning language'));
    await tester.tap(find.byTooltip('Choose learning language'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('简体中文').last);
    await tester.pumpAndSettle();

    expect(prefs.learningLanguage, 'zh-Hans');
    expect(find.text('简体中文'), findsOneWidget);
  });

  testWidgets('Capture source toggle reflects + flips the controller', (tester) async {
    final auth = _signedOutAuth();
    final captureSource = CaptureSourceController(); // in-memory, default on
    await tester.pumpWidget(_host(auth, check: () async => true, captureSource: captureSource));
    await tester.pumpAndSettle();

    expect(find.text('CAPTURE SOURCE'), findsOneWidget); // section headers are upper-cased
    expect(find.text('Record where you captured'), findsOneWidget);
    expect(captureSource.enabled, isTrue);

    // Signed out, the source toggle is the only on/off switch on the screen.
    final toggle = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Toggle');
    expect(toggle, findsOneWidget);
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(captureSource.enabled, isFalse); // flips off + persists to the controller
    expect(find.textContaining("won't record the source app"), findsOneWidget);
  });

  testWidgets('signed-out: "Continue with email" reveals the in-app email field (Issue 3a)', (
    tester,
  ) async {
    // The Settings sign-in buttons drive the real SignInPanel in place — no dead "open the
    // menu-bar Welcome" snackbar. Tapping email reveals the email entry right here.
    final auth = _signedOutAuth();
    await tester.pumpWidget(_host(auth, check: () async => true));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Continue with email'));
    await tester.tap(find.text('Continue with email'));
    await tester.pumpAndSettle();

    expect(find.text('Send code'), findsOneWidget); // the email step appeared in Settings itself
    expect(find.textContaining('menu-bar'), findsNothing); // the old fallback is gone
  });

  testWidgets('scrollToAccount pulls the sign-in panel into view on open (overlay entry)', (
    tester,
  ) async {
    // A short window so the Account section (4th, after Language / Capture / Shortcuts) opens below the
    // fold; with scrollToAccount the auto-scroll must bring its email CTA into the visible viewport.
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final auth = _signedOutAuth();
    await tester.pumpWidget(_host(auth, check: () async => true, scrollToAccount: true));
    await tester.pumpAndSettle();

    final emailCta = find.text('Continue with email');
    expect(emailCta, findsOneWidget);
    // Visible (top within the 400px window) WITHOUT any manual ensureVisible — only the auto-scroll
    // could have brought a 4th-section control up here.
    expect(tester.getRect(emailCta).top, lessThan(400));
  });

  testWidgets('Getting started: "Get Started" replays onboarding when wired', (tester) async {
    final auth = await _signedInAuth();
    var replays = 0;
    await tester.pumpWidget(_host(auth, check: () async => true, onReplay: () => replays++));
    await tester.pumpAndSettle();

    final row = find.text('Get Started');
    await tester.ensureVisible(row);
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(replays, 1);
  });

  testWidgets('Getting started row is hidden when replay is not wired', (tester) async {
    final auth = await _signedInAuth();
    await tester.pumpWidget(_host(auth, check: () async => true)); // onReplay null
    await tester.pumpAndSettle();
    expect(find.text('Get Started'), findsNothing);
  });

  testWidgets('Open System Settings… invokes the seam', (tester) async {
    final auth = await _signedInAuth();
    var opened = 0;
    await tester.pumpWidget(_host(auth, check: () async => true, open: () async => opened++));
    await tester.pumpAndSettle();

    final btn = find.text('Open System Settings…');
    await tester.ensureVisible(btn);
    await tester.pumpAndSettle();
    await tester.tap(btn);
    await tester.pumpAndSettle();
    expect(opened, 1);
  });

  testWidgets('a set learning language renders its human name in the selectbox', (tester) async {
    // 'de' (Deutsch) is NOT an explanation segment, so it appears only in the learning selectbox.
    final auth = await _signedInAuth(learning: 'de');
    await tester.pumpWidget(_host(auth, check: () async => true));
    await tester.pumpAndSettle();
    expect(find.text('Deutsch'), findsOneWidget);
  });

  testWidgets('Delete account opens the confirm-gated dialog; Cancel keeps the session', (
    tester,
  ) async {
    final auth = await _signedInAuth();
    await tester.pumpWidget(_host(auth, check: () async => true));
    await tester.pumpAndSettle();

    final deleteBtn = find.text('Delete…');
    await tester.ensureVisible(deleteBtn);
    await tester.tap(deleteBtn);
    await tester.pumpAndSettle();

    expect(find.text('Delete your account & data?'), findsOneWidget); // dialog open
    expect(find.text('I understand — confirm'), findsOneWidget);

    // Confirming arms the destructive button; then Cancel dismisses. (The dialog scrolls, so reveal first.)
    await tester.ensureVisible(find.text('I understand — confirm'));
    await tester.tap(find.text('I understand — confirm'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Confirmed'), findsOneWidget);

    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Delete your account & data?'), findsNothing); // dismissed
    expect(auth.isSignedIn, isTrue); // Cancel → still signed in
  });

  testWidgets('Delete account: confirm + Delete calls DELETE /account → signed out', (
    tester,
  ) async {
    final auth = await _signedInAuth();
    await tester.pumpWidget(_host(auth, check: () async => true));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Delete…'));
    await tester.tap(find.text('Delete…'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('I understand — confirm'));
    await tester.tap(find.text('I understand — confirm'));
    await tester.pumpAndSettle();

    // The danger button label also appears as the section-row title behind the dialog, so scope to the Dialog.
    final deleteNow = find.descendant(
      of: find.byType(Dialog),
      matching: find.text('Delete account & data'),
    );
    await tester.ensureVisible(deleteNow);
    await tester.tap(deleteNow);
    await tester.pumpAndSettle();

    expect(auth.isSignedIn, isFalse); // deleteAccount reset the controller to signed-out
    expect(
      find.textContaining('You’re signed out'),
      findsOneWidget,
    ); // Settings flipped to signed-out
  });

  testWidgets('About links invoke the open seam; the version sits in a footer at the bottom', (
    tester,
  ) async {
    final auth = await _signedInAuth();
    final opened = <Uri>[];
    await tester.pumpWidget(
      _host(
        auth,
        check: () async => true,
        loadAppVersion: () async => '0.1.5 (10500)',
        openExternalUrl: (u) async => opened.add(u),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ABOUT'), findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Terms of Service'), findsOneWidget);
    expect(find.text('Contact support'), findsOneWidget);
    // The version moved out of the About card into a non-interactive footer at the very bottom — and is
    // now a branded "Capecho <version>" line rather than a "Version" row.
    expect(find.text('Version'), findsNothing);
    expect(find.text('Capecho 0.1.5 (10500)'), findsOneWidget);

    // Tapping Privacy Policy opens the legal URL via the injected seam (never url_launcher in a test).
    await tester.ensureVisible(find.text('Privacy Policy'));
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    expect(opened, contains(Uri.parse('https://capecho.com/legal/privacy-policy')));

    // Contact support opens the dedicated web contact page (no longer a mailto).
    await tester.ensureVisible(find.text('Contact support'));
    await tester.tap(find.text('Contact support'));
    await tester.pumpAndSettle();
    expect(opened, contains(Uri.parse('https://capecho.com/contact')));
  });

  group('SettingsController — per-field save state', () {
    SettingsController make(
      Future<void> Function({
        String? explanationLanguage,
        bool? explanationFollowsLearning,
        String? learningLanguage,
        bool? reminderEnabled,
        String? reminderTime,
      })?
      save,
    ) => SettingsController(
      checkPermission: () async => true,
      openSystemSettings: () async {},
      saveAccount: save,
    );

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
        throw Exception('offline');
      });
      c.setReminderTime('21:30');
      await tick();
      expect(c.saveStatusOf(SettingField.reminderTime), SaveStatus.queued);
      expect(c.reminderTimeOverride, '21:30');
      expect(c.anyUnsaved(const [SettingField.reminderTime]), isTrue);
    });

    test('an ApiException → failed', () async {
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
      expect(
        c.saveStatusOf(SettingField.reminderEnabled),
        isNull,
      ); // cleared on the successful retry
    });

    test('signed out (no saveAccount) is UI-local: the value applies, no save attempted', () async {
      final c = make(null);
      c.setExplanationLanguage('zh-Hans');
      await tick();
      expect(c.explanationOverride, 'zh-Hans'); // value still applied locally
      expect(c.saveStatusOf(SettingField.explanation), isNull); // but nothing was sent
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
          await gate.future;
        });
        c.setExplanationLanguage('es'); // starts the first save (sends 'es')
        await tick();
        expect(gates.length, 1); // exactly one save in flight
        c.setExplanationLanguage('zh-Hans'); // coalesced (a save is in flight)
        c.setExplanationLanguage('fr'); // coalesced again → the latest override is 'fr'
        await tick();
        expect(gates.length, 1); // the intermediate changes did NOT spawn concurrent saves
        gates[0].complete(); // the first save settles → re-run once with the latest override
        await tick();
        expect(gates.length, 2); // exactly one re-run (not one per intermediate change)
        expect(order, ['es', 'fr']); // sent in order; the intermediate 'zh-Hans' was coalesced away
        gates[1].complete();
        await tick();
        expect(c.explanationOverride, 'fr');
        expect(c.saveStatusOf(SettingField.explanation), isNull); // settled + cleared
      },
    );
  });

  testWidgets('a save failure surfaces "Not saved" + the retry notice; Retry now clears it', (
    tester,
  ) async {
    final t = _PatchTransport();
    final store = _MemStore();
    await store.saveToken('tok');
    final auth = AuthController(
      api: CapechoApi(baseUrl: 'https://api.test', transport: t),
      store: store,
      collectClaimRows: () async => const [],
      installId: () async => 'inst',
    );
    await auth.restore();

    await tester.pumpWidget(_host(auth, check: () async => true));
    await tester.pumpAndSettle();

    // Change the explanation language → its `PATCH /account` fails (500 → ApiException).
    await tester.tap(find.byTooltip('Choose native language'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('简体中文').last); // pick it from the opened dropdown menu
    await tester.pumpAndSettle();

    expect(t.patchCalls, 1);
    expect(find.text('Not saved'), findsOneWidget); // the per-field savestate pill
    expect(find.textContaining('Couldn’t save that change'), findsOneWidget); // the section notice
    expect(find.text('Retry now'), findsOneWidget);

    // Retry now succeeds → the pill + notice clear.
    t.failPatch = false;
    await tester.ensureVisible(find.text('Retry now'));
    await tester.tap(find.text('Retry now'));
    await tester.pumpAndSettle();

    expect(t.patchCalls, 2);
    expect(find.text('Not saved'), findsNothing);
    expect(find.text('Retry now'), findsNothing);
    // The successful save's returned Account is applied → auth stays authoritative for every surface.
    expect(auth.account?.explanationLanguage, 'zh-Hans');
  });

  testWidgets('an offline (transport) failure shows the "Queued" pill + offline notice + Retry', (
    tester,
  ) async {
    final t = _PatchTransport()..throwOnPatch = true;
    final store = _MemStore();
    await store.saveToken('tok');
    final auth = AuthController(
      api: CapechoApi(baseUrl: 'https://api.test', transport: t),
      store: store,
      collectClaimRows: () async => const [],
      installId: () async => 'inst',
    );
    await auth.restore();

    await tester.pumpWidget(_host(auth, check: () async => true));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Choose native language'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('简体中文').last); // pick it from the opened dropdown menu
    await tester.pumpAndSettle();

    expect(find.text('Queued'), findsOneWidget); // the offline savestate pill
    expect(find.textContaining('You’re offline — this change is queued'), findsOneWidget);
    expect(
      find.text('Retry now'),
      findsOneWidget,
    ); // queued gets a manual affordance too (no dead end)
  });

  testWidgets('Mac App Store build shows "Restore purchases" in Subscription; tapping restores', (
    tester,
  ) async {
    final auth = await _signedInAuth();
    final backend = _FakeBackend();
    final purchases = _purchasesController(backend);
    addTearDown(purchases.dispose);
    addTearDown(backend.close);
    await tester.pumpWidget(_host(auth, check: () async => true, purchases: purchases));
    await tester.pumpAndSettle();

    // Guideline 3.1.1: a Restore affordance reachable from Settings (not only inside the paywall), so a
    // subscriber on a reinstall — or App Review testing an already-subscribed sandbox account — can always
    // restore. Present only in the MAS build (purchases != null); the direct build restores by signing in.
    expect(find.text('Restore purchases'), findsOneWidget);
    // The settings list is taller than the test viewport — scroll the row into view before tapping.
    await tester.ensureVisible(find.text('Restore purchases'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore purchases'));
    await tester.pumpAndSettle();
    expect(backend.restoreCalls, 1);
  });
}
