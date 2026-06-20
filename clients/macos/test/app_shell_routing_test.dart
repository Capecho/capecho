import 'dart:convert';

import 'package:capecho/onboarding_controller.dart' show OnboardingStep;
import 'package:capecho/review/review_screen.dart';
import 'package:capecho/settings/capture_source_prefs.dart';
import 'package:capecho/settings/settings_screen.dart';
import 'package:capecho/surface_routing.dart';
import 'package:capecho/word_book/word_book_screen.dart';
import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tests the app shell's native-triggered surface routing — `routeSurfaceRequest`, the routing
/// decision behind the menu-bar items + the global ⌥R / ⌥B hotkeys.
///
/// The real `CaptureDevShell` can't be pumped: `_init` builds a live `CapechoApi` (real HTTP
/// transport → api.capecho.com) and a file-backed session with no injection seam, so a pumped
/// shell would hit the network and couldn't be made deterministically signed-in. The routing
/// decision was therefore lifted into the top-level `routeSurfaceRequest`, which takes its
/// collaborators explicitly — and that is what these tests drive, with a fake-transport
/// `AuthController` and a minimal host. No sqlite / path_provider / capture_native is involved.

/// In-memory token store — no disk, no plugins.
class _MemStore implements SessionStore {
  String? _t;
  @override
  Future<String?> loadToken() async => _t;
  @override
  Future<void> saveToken(String token) async => _t = token;
  @override
  Future<void> clear() async => _t = null;
}

/// Answers everything a routed surface touches: `/auth/me` (so a token restores signed-in) plus the
/// empty Review / Word Book reads (`/review/due`, `/words`) so a pushed screen settles to a calm
/// empty state without a network error. These tests assert which *route* is on top, not the
/// screen's contents — per-screen behavior has its own tests (`review_screen_test`, etc.).
class _Fake implements HttpTransport {
  @override
  Future<TransportResponse> send(TransportRequest r) async {
    final path = Uri.parse(r.url).path;
    Object body = const <String, Object?>{};
    if (path.endsWith('/auth/me')) {
      body = {
        'user': {
          'id': 'a',
          'iana_timezone': 'UTC',
          'explanation_language': 'en',
          'explanation_follows_learning': false,
          'learning_language': null,
          'reminder_enabled': false,
          'pro': false,
        },
      };
    } else if (path.endsWith('/review/due')) {
      body = {
        'due': <Object>[],
        'new': <Object>[],
        'counts': {'due': 0, 'new': 0},
      };
    } else if (path.endsWith('/words')) {
      body = {'words': <Object>[]};
    } else if (path.endsWith('/contexts')) {
      body = {'contexts': <Object>[]};
    }
    return TransportResponse(statusCode: 200, body: jsonEncode(body));
  }
}

Future<AuthController> _signedInAuth() async {
  final store = _MemStore();
  await store.saveToken('tok');
  final auth = AuthController(
    api: CapechoApi(baseUrl: 'https://api.test', transport: _Fake()),
    store: store,
    collectClaimRows: () async => const [],
    installId: () async => 'inst',
  );
  await auth.restore(); // /auth/me → signed-in
  return auth;
}

AuthController _signedOutAuth() => AuthController(
  api: CapechoApi(baseUrl: 'https://api.test', transport: _Fake()),
  store: _MemStore(),
  collectClaimRows: () async => const [],
  installId: () async => 'inst',
);

/// Pumps a minimal host — a Navigator + a ScaffoldMessenger, exactly what the real shell sits under
/// — and returns a stable [BuildContext] on the home route to drive [routeSurfaceRequest] with. The
/// home Builder isn't rebuilt across pushes, so the captured context stays valid for repeated calls.
Future<BuildContext> _pumpHost(WidgetTester tester) async {
  late BuildContext homeContext;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) {
            homeContext = context;
            return const Center(child: Text('home'));
          },
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return homeContext;
}

// Settings isn't routed by these tests, but the seams are wired so the 'settings' arm is reachable
// in production-shaped calls (the same way the shell passes the repo's permission seams).
Future<bool> _granted() async => true;
Future<void> _noop() async {}

/// A production-shaped call: past onboarding, shell ready, settings seams wired. Each test overrides
/// only what it's probing (the surface, the gates, or the session via [auth]).
void _route(
  BuildContext context,
  AuthController? auth,
  String surface, {
  bool onboardingDone = true,
  bool ready = true,
}) => routeSurfaceRequest(
  context,
  auth,
  surface,
  onboardingDone: onboardingDone,
  ready: ready,
  appearance: AppearanceController(),
  languagePrefs: LanguagePrefsController(),
  captureSource: CaptureSourceController(),
  checkPermission: _granted,
  openSystemSettings: _noop,
);

void main() {
  test('first-run onboarding resumes at permission only after Screen Recording is granted', () {
    expect(
      firstRunOnboardingInitialStep(onboardingDone: false, screenRecordingGranted: true),
      OnboardingStep.permission,
    );
    expect(
      firstRunOnboardingInitialStep(onboardingDone: false, screenRecordingGranted: false),
      OnboardingStep.howItWorks,
    );
    expect(
      firstRunOnboardingInitialStep(onboardingDone: true, screenRecordingGranted: true),
      OnboardingStep.howItWorks,
    );
  });

  testWidgets('review from home opens exactly one Review route', (tester) async {
    final auth = await _signedInAuth();
    addTearDown(auth.dispose);
    final ctx = await _pumpHost(tester);

    _route(ctx, auth, 'review');
    await tester.pumpAndSettle();

    expect(find.byType(ReviewScreen), findsOneWidget);
  });

  testWidgets('switching surfaces collapses the prior — Word Book replaces Review', (tester) async {
    final auth = await _signedInAuth();
    addTearDown(auth.dispose);
    final ctx = await _pumpHost(tester);

    _route(ctx, auth, 'review');
    await tester.pumpAndSettle();
    expect(find.byType(ReviewScreen), findsOneWidget);

    _route(ctx, auth, 'wordBook');
    await tester.pumpAndSettle();

    expect(find.byType(WordBookScreen), findsOneWidget);
    expect(find.byType(ReviewScreen), findsNothing); // collapsed to home first, not stacked beneath
  });

  testWidgets('a double-fired request never stacks duplicate routes', (tester) async {
    final auth = await _signedInAuth();
    addTearDown(auth.dispose);
    final ctx = await _pumpHost(tester);

    _route(ctx, auth, 'review');
    await tester.pumpAndSettle();
    _route(ctx, auth, 'review'); // fired again (e.g. menu key-equivalent + global hotkey)
    await tester.pumpAndSettle();

    expect(find.byType(ReviewScreen), findsOneWidget); // collapse-then-open kept it to one
  });

  testWidgets('an unknown surface is a clean no-op and never collapses an open surface', (
    tester,
  ) async {
    final auth = await _signedInAuth();
    addTearDown(auth.dispose);
    final ctx = await _pumpHost(tester);

    // From a clean home, an unknown name pushes nothing and leaves home in place.
    _route(ctx, auth, 'nope');
    await tester.pumpAndSettle();
    expect(find.byType(ReviewScreen), findsNothing);
    expect(find.byType(WordBookScreen), findsNothing);
    expect(find.text('home'), findsOneWidget);

    // With Review open, an unknown name must leave it untouched (resolve-before-collapse).
    _route(ctx, auth, 'review');
    await tester.pumpAndSettle();
    expect(find.byType(ReviewScreen), findsOneWidget);

    _route(ctx, auth, 'totally-unknown');
    await tester.pumpAndSettle();
    expect(find.byType(ReviewScreen), findsOneWidget); // still up, not collapsed to home
  });

  testWidgets('signed out: Review and Word Book still OPEN (each handles no-session itself)', (
    tester,
  ) async {
    final auth = _signedOutAuth();
    addTearDown(auth.dispose);
    final ctx = await _pumpHost(tester);

    // Review opens signed-out — no gate, no snackbar. (Here the fake answers /review/due 200, so the
    // route opens and settles to an empty state; we assert the ROUTE opens. The signed-out 401 →
    // "sign in to review" branch itself is covered in review_controller_test.)
    _route(ctx, auth, 'review');
    await tester.pumpAndSettle();
    expect(find.byType(ReviewScreen), findsOneWidget);
    expect(find.text('Sign in to review your words.'), findsNothing); // the old gate is gone

    // Word Book opens signed-out too (the controller renders the pre-login banner on a 401).
    _route(ctx, auth, 'wordBook');
    await tester.pumpAndSettle();
    expect(find.byType(WordBookScreen), findsOneWidget);
    expect(find.text('Sign in to see your Word Book.'), findsNothing);
  });

  testWidgets('signIn opens Settings asking to auto-scroll to the Account section', (tester) async {
    final auth = _signedOutAuth();
    addTearDown(auth.dispose);
    final ctx = await _pumpHost(tester);

    // The capture overlay's "Sign in" button posts the `signIn` surface (vs the menu's plain `settings`).
    _route(ctx, auth, 'signIn');
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.widget<SettingsScreen>(find.byType(SettingsScreen)).scrollToAccount, isTrue);
  });

  testWidgets('the plain settings surface opens at the top (no account auto-scroll)', (
    tester,
  ) async {
    final auth = _signedOutAuth();
    addTearDown(auth.dispose);
    final ctx = await _pumpHost(tester);

    _route(ctx, auth, 'settings');
    await tester.pumpAndSettle();

    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.widget<SettingsScreen>(find.byType(SettingsScreen)).scrollToAccount, isFalse);
  });

  testWidgets('a request during onboarding is ignored', (tester) async {
    final auth = await _signedInAuth();
    addTearDown(auth.dispose);
    final ctx = await _pumpHost(tester);

    _route(ctx, auth, 'review', onboardingDone: false);
    await tester.pump();

    expect(find.byType(ReviewScreen), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('a request before the shell is ready is ignored', (tester) async {
    final auth = await _signedInAuth();
    addTearDown(auth.dispose);
    final ctx = await _pumpHost(tester);

    _route(ctx, auth, 'review', ready: false);
    await tester.pump();

    expect(find.byType(ReviewScreen), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });
}
