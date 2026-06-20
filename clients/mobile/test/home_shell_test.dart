import 'dart:convert';

import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:capecho_mobile/home/home_shell.dart';
import 'package:capecho_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A URL-aware fake transport covering every endpoint the home touches at once: `/auth/me` (account
/// restore), `/review/due` (the live Review base), `/words` + `/contexts` + `/explain` (the Word Book
/// popover), and `PATCH /account` (the Settings popover). Empty bodies → the cold rest states. Mirrors the
/// fake-transport pattern in the screen tests.
class _FakeTransport implements HttpTransport {
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
    final path = Uri.parse(r.url).path;
    final Object body;
    if (path.endsWith('/auth/me') || path.endsWith('/account')) {
      body = {'user': account};
    } else if (path.endsWith('/review/due')) {
      body = {
        'due': [],
        'new': [],
        'counts': {'due': 0, 'new': 0},
      };
    } else if (path.endsWith('/words')) {
      body = {'words': []};
    } else if (path.endsWith('/contexts')) {
      body = {'contexts': []};
    } else if (path.endsWith('/explain')) {
      body = {'status': 'language_unsupported'};
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

void main() {
  testWidgets('home is the live Review with two corner buttons; each opens its popover', (
    tester,
  ) async {
    final auth = await _signedInAuth(_FakeTransport());
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: capechoTheme(Brightness.light),
        home: HomeShell(auth: auth, api: auth.api, appearance: AppearanceController()),
      ),
    );
    await tester.pumpAndSettle();

    // The two floating corner buttons sit over the live Review home (empty queue + empty Word Book → the
    // cold "nothing captured" rest state). No bottom tab bar.
    expect(find.byTooltip('Settings'), findsOneWidget);
    expect(find.byTooltip('Word Book'), findsOneWidget);
    expect(find.text('Your words will appear here'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);

    // Top-right raises the Word Book popover (its masthead + first-run invite).
    await tester.tap(find.byTooltip('Word Book'));
    await tester.pumpAndSettle();
    expect(find.text('Word Book'), findsWidgets);
    expect(find.text('Your Word Book is ready for its first word.'), findsOneWidget);

    // The popover's Close button dismisses it back to the Review home.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Your Word Book is ready for its first word.'), findsNothing);

    // Top-left raises the Settings popover (its title + section headers).
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('REMINDERS'), findsOneWidget);
    expect(find.text('ACCOUNT'), findsOneWidget);
    expect(find.text('reader@example.com'), findsOneWidget);
  });

  testWidgets('signing out from the Settings popover dismisses it', (tester) async {
    final auth = await _signedInAuth(_FakeTransport());
    addTearDown(auth.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: capechoTheme(Brightness.light),
        home: HomeShell(auth: auth, api: auth.api, appearance: AppearanceController()),
      ),
    );
    await tester.pumpAndSettle();

    // Open Settings, then sign out.
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out'), findsOneWidget);

    await tester.ensureVisible(
      find.text('Sign out'),
    ); // it sits below the fold in the 800×600 test view
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    // The popover is gone (it must not be left floating over the sign-in screen) — its rows are no
    // longer in the tree.
    expect(find.text('Sign out'), findsNothing);
    expect(find.text('REMINDERS'), findsNothing);
    expect(auth.isSignedIn, isFalse);
  });
}
