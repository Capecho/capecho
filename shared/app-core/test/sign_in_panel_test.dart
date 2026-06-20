import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal in-memory session store — the panel never signs in here, so it stays empty.
class _MemStore implements SessionStore {
  @override
  Future<String?> loadToken() async => null;
  @override
  Future<void> saveToken(String t) async {}
  @override
  Future<void> clear() async {}
}

/// A transport that never answers — these tests only assert which provider buttons render, never tap
/// them, so no request is ever sent.
class _DeadTransport implements HttpTransport {
  @override
  Future<TransportResponse> send(TransportRequest r) async =>
      throw UnimplementedError('no network in this widget test');
}

void main() {
  AuthController buildAuth() => AuthController(
    api: CapechoApi(baseUrl: 'https://api.test', transport: _DeadTransport()),
    store: _MemStore(),
    collectClaimRows: () async => const [],
    installId: () async => 'inst',
  );

  Future<void> pump(WidgetTester tester, {bool? appleAvailable}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SignInPanel(
            p: OnboardingPalette.lightForTest,
            auth: buildAuth(),
            appleAvailable: appleAvailable,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'appleAvailable: true shows "Continue with Apple" (App Store build / Guideline 4.8)',
    (tester) async {
      await pump(tester, appleAvailable: true);
      expect(find.text('Continue with Apple'), findsOneWidget);
      expect(find.text('Continue with Google'), findsOneWidget); // Google + email always shown
    },
  );

  testWidgets('appleAvailable: false hides Apple (Developer-ID direct macOS build)', (
    tester,
  ) async {
    await pump(tester, appleAvailable: false);
    expect(find.text('Continue with Apple'), findsNothing);
    expect(find.text('Continue with Google'), findsOneWidget);
  });

  testWidgets('appleAvailable: null falls back to platform — hidden on non-iOS host', (
    tester,
  ) async {
    // The default test host is not iOS, so the iOS-only fallback hides Apple. (The iOS app gets it via
    // the platform check; macOS passes an explicit flag.)
    await pump(tester, appleAvailable: null);
    expect(find.text('Continue with Apple'), findsNothing);
  });
}
