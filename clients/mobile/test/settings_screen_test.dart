import 'dart:convert';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:capecho_mobile/notifications/notification_permissions.dart';
import 'package:capecho_mobile/settings/settings_screen.dart';
import 'package:capecho_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A URL-aware fake transport for the Settings surface: answers `/auth/me` (account restore),
/// `PATCH /account` (preference saves), and `/auth/signout`. Records the PATCH bodies so a test can
/// assert which preference was persisted. Mirrors the fake-transport pattern in `widget_test.dart`.
class _FakeTransport implements HttpTransport {
  final List<TransportRequest> reqs = [];

  /// When true, `PATCH /account` hard-rejects (422) so a test can exercise the save-failed UI.
  bool failPatch = false;

  /// The account `/auth/me` and `PATCH /account` return (wrapped in `{user: …}`). A test can mutate
  /// it; the PATCH echoes it back so `applyAccount` keeps the screen authoritative.
  Map<String, Object?> account = {
    'id': 'acct-1',
    'iana_timezone': 'UTC',
    'explanation_language': 'en',
    'explanation_follows_learning': false,
    'learning_language': 'en',
    'provider': 'apple',
    'email': 'reader@example.com',
    'reminder_enabled': false,
    'reminder_time': null,
    'pro': false,
  };

  @override
  Future<TransportResponse> send(TransportRequest r) async {
    reqs.add(r);
    final path = Uri.parse(r.url).path;
    final Object body;
    if (path.endsWith('/auth/me')) {
      body = {'user': account};
    } else if (path.endsWith('/account')) {
      if (failPatch) {
        return TransportResponse(statusCode: 422, body: jsonEncode({'error': 'bad_value'}));
      }
      // PATCH /account — merge the sent fields so the echoed account reflects the change.
      if (r.body != null && r.body!.isNotEmpty) {
        final patch = jsonDecode(r.body!) as Map<String, dynamic>;
        account = {...account, ...patch};
      }
      body = {'user': account};
    } else {
      body = const <String, Object?>{};
    }
    return TransportResponse(statusCode: 200, body: jsonEncode(body));
  }
}

class _FakeStore implements SessionStore {
  String? token = 'test-session';
  @override
  Future<String?> loadToken() async => token;
  @override
  Future<void> saveToken(String t) async => token = t;
  @override
  Future<void> clear() async => token = null;
}

/// A fake notification-permission probe so the Reminders warning can be exercised without the real OS
/// plugin. [granted] drives [hasPermission]/[requestPermission]; [openSettingsCalls] records the jump.
class _FakeNotifications implements NotificationPermissions {
  _FakeNotifications({this.granted = false});
  bool granted;
  int hasPermissionCalls = 0;
  int requestPermissionCalls = 0;
  int openSettingsCalls = 0;
  @override
  Future<bool> hasPermission() async {
    hasPermissionCalls++;
    return granted;
  }

  @override
  Future<bool> requestPermission() async {
    requestPermissionCalls++;
    return granted;
  }

  @override
  Future<void> openSystemSettings() async => openSettingsCalls++;
}

/// A signed-in [AuthController]: restore() succeeds against the fake `/auth/me`, so `isSignedIn` is
/// true and `account` is populated — the state the shell only ever mounts Settings in.
Future<AuthController> _signedInAuth(_FakeTransport t) async {
  final auth = AuthController(
    api: CapechoApi(baseUrl: 'https://api.test', transport: t),
    store: _FakeStore(),
    collectClaimRows: () async => const <ClaimRow>[],
    installId: () async => 'install-1',
  );
  await auth.restore();
  return auth;
}

Future<void> _pumpSettings(WidgetTester tester, AuthController auth) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: capechoTheme(Brightness.light),
      home: Scaffold(
        body: SettingsScreen(auth: auth, appearance: AppearanceController()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the account email, reminders toggle, and sign out when signed in', (
    tester,
  ) async {
    final auth = await _signedInAuth(_FakeTransport());
    addTearDown(auth.dispose);
    await _pumpSettings(tester, auth);

    // Title + the three section headers.
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('REMINDERS'), findsOneWidget);
    expect(find.text('LANGUAGE'), findsOneWidget);
    expect(find.text('APPEARANCE'), findsOneWidget);
    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('REMINDERS')).dy,
      lessThan(tester.getTopLeft(find.text('ACCOUNT')).dy),
    );

    // Appearance: the device-local theme picker (System / Light / Dark).
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);

    // Account identity (provider label + email) + the sign-out + delete rows.
    expect(find.text('reader@example.com'), findsOneWidget);
    expect(find.text('Apple'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Delete account & data'), findsOneWidget);

    // Reminders default OFF: the daily-reminder row + an iOS-style toggle.
    expect(find.text('Daily reminder'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is Semantics && w.properties.toggled == false),
      findsWidgets,
    );

    // Language rows: learning target first, then explanation-language preference.
    expect(find.text('Learning Language'), findsOneWidget);
    expect(find.text('Native language'), findsOneWidget);
    expect(find.text('Current learning language'), findsNothing);
    expect(
      tester.getTopLeft(find.text('Learning Language')).dy,
      lessThan(tester.getTopLeft(find.text('Native language')).dy),
    );
    expect(find.text('English'), findsWidgets);
  });

  testWidgets('About links invoke the open seam; the version sits in a non-tappable footer', (
    tester,
  ) async {
    final opened = <Uri>[];
    final auth = await _signedInAuth(_FakeTransport());
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: capechoTheme(Brightness.light),
        home: Scaffold(
          body: SettingsScreen(
            auth: auth,
            appearance: AppearanceController(),
            loadAppVersion: () async => '0.1.5 (10500)',
            onOpenLink: (u) {
              opened.add(u);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('ABOUT'), findsOneWidget);
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Terms of Service'), findsOneWidget);
    // The version moved out of the About card into a footer at the very bottom (plain text, no row /
    // tap target) — and is no longer the bare label but a branded "Capecho <version>" line.
    expect(find.text('Capecho 0.1.5 (10500)'), findsOneWidget);

    await tester.ensureVisible(find.text('Terms of Service'));
    await tester.tap(find.text('Terms of Service'));
    await tester.pumpAndSettle();
    expect(opened, contains(Uri.parse('https://capecho.com/legal/terms')));
  });

  testWidgets('tapping a different explanation language persists it via PATCH /account', (
    tester,
  ) async {
    final t = _FakeTransport();
    final auth = await _signedInAuth(t);
    addTearDown(auth.dispose);
    await _pumpSettings(tester, auth);

    await tester.tap(find.text('Native language')); // open the language picker sheet
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('简体中文'));
    await tester.tap(find.text('简体中文'));
    await tester.pumpAndSettle();

    // The save flowed through to a PATCH /account carrying the new explanation language, and the
    // controller applied the returned account (so the screen stays authoritative).
    final patch = t.reqs.lastWhere((r) => Uri.parse(r.url).path.endsWith('/account'));
    expect(patch.method, 'PATCH');
    expect(patch.body, contains('explanation_language'));
    expect(patch.body, contains('zh-Hans'));
    expect(auth.account?.explanationLanguage, 'zh-Hans');
  });

  testWidgets('a backend-rejected save shows "Not saved" + a Retry now action, cleared on retry', (
    tester,
  ) async {
    final t = _FakeTransport()..failPatch = true;
    final auth = await _signedInAuth(t);
    addTearDown(auth.dispose);
    await _pumpSettings(tester, auth);

    // Switch the explanation language → the PATCH hard-rejects (422) → the failed UI surfaces.
    await tester.tap(find.text('Native language')); // open the language picker sheet
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('简体中文'));
    await tester.tap(find.text('简体中文'));
    await tester.pumpAndSettle();
    expect(find.text('Not saved'), findsOneWidget);
    expect(find.text('Retry now'), findsOneWidget);
    expect(find.textContaining('Couldn’t save that change.'), findsOneWidget);

    // Backend recovers; Retry now re-saves successfully → the failed UI clears.
    t.failPatch = false;
    await tester.tap(find.text('Retry now'));
    await tester.pumpAndSettle();
    expect(find.text('Not saved'), findsNothing);
    expect(find.text('Retry now'), findsNothing);
    expect(auth.account?.explanationLanguage, 'zh-Hans');
  });

  testWidgets('turning reminder ON requests permission; denial shows warning + Open Settings jump', (
    tester,
  ) async {
    final notifs = _FakeNotifications(granted: false);
    final t = _FakeTransport();
    final auth = await _signedInAuth(t);
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: capechoTheme(Brightness.light),
        home: Scaffold(
          body: SettingsScreen(
            auth: auth,
            appearance: AppearanceController(),
            notifications: notifs,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(notifs.requestPermissionCalls, 0);
    await tester.tap(
      find.byWidgetPredicate((w) => w is Semantics && w.properties.toggled == false),
    );
    await tester.pumpAndSettle();

    final patch = t.reqs.lastWhere((r) => Uri.parse(r.url).path.endsWith('/account'));
    expect(patch.body, contains('"reminder_enabled":true'));
    expect(notifs.requestPermissionCalls, 1);

    // The preference is saved ON but the OS won't deliver — warning + jump to system settings show.
    expect(find.textContaining('Notifications are turned off for Capecho'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);

    await tester.ensureVisible(find.text('Open Settings'));
    await tester.tap(find.text('Open Settings'));
    await tester.pumpAndSettle();
    expect(notifs.openSettingsCalls, 1);
  });

  testWidgets('turning reminder ON with granted permission shows no warning', (tester) async {
    final notifs = _FakeNotifications(granted: true);
    final auth = await _signedInAuth(_FakeTransport());
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: capechoTheme(Brightness.light),
        home: Scaffold(
          body: SettingsScreen(
            auth: auth,
            appearance: AppearanceController(),
            notifications: notifs,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byWidgetPredicate((w) => w is Semantics && w.properties.toggled == false),
    );
    await tester.pumpAndSettle();
    expect(notifs.requestPermissionCalls, 1);
    expect(find.textContaining('Notifications are turned off'), findsNothing);
  });
}
