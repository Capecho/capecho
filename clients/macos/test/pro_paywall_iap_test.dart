import 'dart:async';

import 'package:capecho/settings/pro_paywall_iap.dart';
import 'package:capecho_api/capecho_api.dart' show AppleVerifyResult;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// A scriptable [PurchaseBackend] for the macOS IAP paywall: a controllable purchase stream + a fixed
/// product set, so the surface is exercised without the StoreKit platform channel.
class _FakeBackend implements PurchaseBackend {
  final StreamController<List<PurchaseDetails>> _stream =
      StreamController<List<PurchaseDetails>>.broadcast();
  bool available = true;
  List<ProductDetails> products = [];
  final List<PurchaseDetails> completed = [];

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _stream.stream;
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) async =>
      ProductDetailsResponse(productDetails: products, notFoundIDs: const []);
  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async => true;
  @override
  Future<void> completePurchase(PurchaseDetails purchase) async => completed.add(purchase);
  @override
  Future<void> restorePurchases() async {}

  void emit(List<PurchaseDetails> p) => _stream.add(p);
  Future<void> close() => _stream.close();
}

ProductDetails _product(String id, String price) => ProductDetails(
  id: id,
  title: 'Capecho Pro',
  description: 'Pro subscription',
  price: price,
  rawPrice: 5.99,
  currencyCode: 'USD',
);

PurchaseDetails _purchased() {
  final d = PurchaseDetails(
    productID: kAppleProductMonthly,
    verificationData: PurchaseVerificationData(
      localVerificationData: 'local',
      serverVerificationData: 'jws',
      source: 'app_store',
    ),
    transactionDate: '0',
    status: PurchaseStatus.purchased,
  );
  d.pendingCompletePurchase = true;
  return d;
}

void main() {
  late _FakeBackend backend;
  late ProPurchaseController controller;

  ProPurchaseController build({AppleVerifyResult? verifyResult}) => ProPurchaseController(
    backend: backend,
    verify: (_) async =>
        verifyResult ??
        const AppleVerifyResult(pro: true, proUntil: 1893456000000, status: 'active'),
    onEntitlementChanged: () async {},
    currentAccountId: () => 'acct-uuid',
  );

  setUp(() => backend = _FakeBackend());
  tearDown(() async {
    controller.dispose();
    await backend.close();
  });

  Future<void> pump(WidgetTester tester, {VoidCallback? onClose}) async {
    // The paywall card is sized for a real window; give the test view room so it doesn't overflow the
    // default 800×600 surface (an overflow would fail the test for a non-bug).
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ProPaywallIap(
              p: OnboardingPalette.lightForTest,
              controller: controller,
              onClose: onClose,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('renders the live plans + prices + Restore when products load', (tester) async {
    backend.products = [
      _product(kAppleProductMonthly, r'$5.99'),
      _product(kAppleProductAnnual, r'$47.99'),
    ];
    controller = build();
    await pump(tester);

    expect(find.text('Monthly'), findsOneWidget);
    expect(find.text('Annual'), findsOneWidget);
    expect(find.text(r'$5.99'), findsOneWidget); // live StoreKit price, never hard-coded
    expect(find.text(r'$47.99'), findsOneWidget);
    expect(find.text('Restore purchase'), findsOneWidget); // guideline 3.1.1, always reachable
    // The shared editorial card renders (no drift from the Stripe paywall).
    expect(find.text('Keep every word you meet.'), findsOneWidget);
    // App Store Review Guideline 3.1.2: the legal links live inside the purchase flow.
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Terms of Use'), findsOneWidget);
  });

  testWidgets('renders a calm not-available state + Restore when no products resolve', (
    tester,
  ) async {
    backend.products = const []; // App Store Connect products not live yet
    controller = build();
    await pump(tester);

    expect(find.textContaining('isn’t available just yet'), findsOneWidget);
    expect(
      find.text('Restore purchase'),
      findsOneWidget,
    ); // a sub bought elsewhere stays restorable
    // No dead buy button.
    expect(find.text('Monthly'), findsNothing);
    // The legal links stay present even when there's nothing to buy (always shown, Guideline 3.1.2).
    expect(find.text('Privacy Policy'), findsOneWidget);
    expect(find.text('Terms of Use'), findsOneWidget);
  });

  testWidgets('a confirmed upgrade closes the paywall (onClose fired)', (tester) async {
    backend.products = [_product(kAppleProductMonthly, r'$5.99')];
    controller = build();
    var closed = false;
    await pump(tester, onClose: () => closed = true);

    // A purchased transaction → verify (pro:true) → justUpgraded → the paywall closes itself.
    backend.emit([_purchased()]);
    await tester.pumpAndSettle();
    expect(closed, isTrue);
  });

  testWidgets('opens under an AnimatedBuilder on the same controller without setState-during-build', (
    tester,
  ) async {
    // Regression: Settings hosts the paywall while ITS OWN AnimatedBuilders listen to the same
    // controller. initState used to call clearError()/loadProducts() — both notify — synchronously,
    // marking that ancestor dirty mid-build → "setState() called during build". They're now deferred to
    // a post-frame callback.
    backend.products = [_product(kAppleProductMonthly, r'$5.99')];
    controller = build();
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: controller, // mirrors Settings' restore-row / subscription AnimatedBuilders
            builder: (context, _) => Center(
              child: ProPaywallIap(p: OnboardingPalette.lightForTest, controller: controller),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull); // no "setState during build"
    expect(find.text('Monthly'), findsOneWidget); // products still load (post-frame)
  });
}
