import 'dart:async';

import 'package:capecho_api/capecho_api.dart' show AppleVerifyResult;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

/// A scriptable [PurchaseBackend] — a controllable purchase stream + recorded buy/complete/restore calls,
/// so the controller's verify-then-finish logic is exercised without the StoreKit platform channel.
class _FakeBackend implements PurchaseBackend {
  final StreamController<List<PurchaseDetails>> _stream =
      StreamController<List<PurchaseDetails>>.broadcast();

  bool available = true;
  List<ProductDetails> products = [];
  final List<PurchaseParam> bought = [];
  final List<PurchaseDetails> completed = [];
  int restoreCalls = 0;
  bool throwOnBuy = false;
  Object? buyThrows; // when set, buyNonConsumable throws THIS (e.g. a StoreKit PlatformException)
  bool buyReturns = true; // StoreKit can return false (declined start) without throwing or emitting

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _stream.stream;
  @override
  Future<bool> isAvailable() async => available;
  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) async =>
      ProductDetailsResponse(productDetails: products, notFoundIDs: const []);
  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) async {
    if (buyThrows != null) throw buyThrows!;
    if (throwOnBuy) throw StateError('buy failed');
    if (!buyReturns) return false;
    bought.add(purchaseParam);
    return true;
  }

  @override
  Future<void> completePurchase(PurchaseDetails purchase) async => completed.add(purchase);
  @override
  Future<void> restorePurchases() async => restoreCalls++;

  void emit(List<PurchaseDetails> purchases) => _stream.add(purchases);
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

PurchaseDetails _purchase(
  PurchaseStatus status, {
  String jws = 'jws.signed.tx',
  bool pending = true,
}) {
  final d = PurchaseDetails(
    productID: kAppleProductMonthly,
    verificationData: PurchaseVerificationData(
      localVerificationData: 'local',
      serverVerificationData: jws,
      source: 'app_store',
    ),
    transactionDate: '0',
    status: status,
  );
  d.pendingCompletePurchase = pending;
  return d;
}

void main() {
  late _FakeBackend backend;
  late String? accountId;
  late int refreshes;
  late String? verifiedJws;
  late bool throwOnVerify;
  late bool throwOnRefresh;
  late AppleVerifyResult verifyResult;
  late ProPurchaseController c;

  setUp(() {
    backend = _FakeBackend();
    accountId = 'acct-uuid-1';
    refreshes = 0;
    verifiedJws = null;
    throwOnVerify = false;
    throwOnRefresh = false;
    verifyResult = const AppleVerifyResult(pro: true, proUntil: 1893456000000, status: 'active');
    c = ProPurchaseController(
      backend: backend,
      verify: (jws) async {
        verifiedJws = jws;
        if (throwOnVerify) throw StateError('verify down');
        return verifyResult;
      },
      onEntitlementChanged: () async {
        refreshes++;
        if (throwOnRefresh) throw StateError('refresh down');
      },
      currentAccountId: () => accountId,
    );
  });

  tearDown(() async {
    c.dispose();
    await backend.close();
  });

  group('loadProducts', () {
    test('populates plans + live prices when the store is available', () async {
      backend.products = [
        _product(kAppleProductMonthly, r'$5.99'),
        _product(kAppleProductAnnual, r'$47.99'),
      ];
      await c.loadProducts();
      expect(c.available, isTrue);
      expect(c.priceOf(ProPlan.monthly), r'$5.99');
      expect(c.priceOf(ProPlan.annual), r'$47.99');
    });

    test('not available when the store is unreachable', () async {
      backend.available = false;
      await c.loadProducts();
      expect(c.available, isFalse);
    });

    test('not available when none of our products come back', () async {
      backend.products = [_product('com.someone.else', r'$1')];
      await c.loadProducts();
      expect(c.available, isFalse); // a foreign id never resolves a plan
    });
  });

  group('buy', () {
    setUp(() {
      backend.products = [_product(kAppleProductMonthly, r'$5.99')];
    });

    test(
      'stamps the Capecho account id as applicationUserName (the appAccountToken linkage)',
      () async {
        await c.loadProducts();
        await c.buy(ProPlan.monthly);
        expect(backend.bought, hasLength(1));
        // THE load-bearing assertion: without this the server can't attribute the sub to the account.
        expect(backend.bought.single.applicationUserName, 'acct-uuid-1');
        expect(backend.bought.single.productDetails.id, kAppleProductMonthly);
      },
    );

    test('refuses to buy when signed out (no account id)', () async {
      await c.loadProducts();
      accountId = null;
      await c.buy(ProPlan.monthly);
      expect(backend.bought, isEmpty);
      expect(c.error, contains('Sign in'));
    });

    test('a failed buy call clears busy + surfaces an error', () async {
      await c.loadProducts();
      backend.throwOnBuy = true;
      await c.buy(ProPlan.monthly);
      expect(c.busyPlan, isNull);
      expect(c.error, isNotNull);
    });

    test('a StoreKit start error surfaces the platform message, not a generic', () async {
      await c.loadProducts();
      // e.g. re-buying a subscription the same Apple ID already owns — StoreKit refuses to start it.
      backend.buyThrows = PlatformException(
        code: 'storekit_duplicate_product_object',
        message: 'You’re currently subscribed to this.',
      );
      await c.buy(ProPlan.monthly);
      expect(c.busyPlan, isNull);
      expect(c.error, 'You’re currently subscribed to this.'); // the REAL reason, surfaced
    });

    test('buyNonConsumable returning false (no throw, no event) clears the spinner', () async {
      await c.loadProducts();
      backend.buyReturns = false; // StoreKit declined to start, silently
      await c.buy(ProPlan.monthly);
      expect(
        c.busyPlan,
        isNull,
      ); // not stuck spinning forever waiting for a transaction that never comes
      expect(c.error, isNotNull);
    });
  });

  group('purchase stream', () {
    test(
      'a purchased event verifies the JWS, refreshes entitlement, finishes the transaction',
      () async {
        backend.emit([_purchase(PurchaseStatus.purchased, jws: 'the.jws')]);
        await pumpEventQueue();
        expect(verifiedJws, 'the.jws'); // the App Store-signed JWS went to /billing/apple/verify
        expect(refreshes, 1); // /auth/me re-pulled so every surface reflects Pro
        expect(backend.completed, hasLength(1)); // transaction finished (server has it)
        expect(c.justUpgraded, isTrue);
        expect(c.error, isNull);
      },
    );

    test('a restored event runs the same verify + finish path', () async {
      backend.emit([_purchase(PurchaseStatus.restored)]);
      await pumpEventQueue();
      expect(verifiedJws, isNotNull);
      expect(refreshes, 1);
      expect(backend.completed, hasLength(1));
    });

    test('a failed verify leaves the transaction UNFINISHED for redelivery', () async {
      throwOnVerify = true;
      backend.emit([_purchase(PurchaseStatus.purchased)]);
      await pumpEventQueue();
      expect(backend.completed, isEmpty); // not finished → the App Store redelivers + we retry
      expect(c.justUpgraded, isFalse);
      expect(c.error, isNotNull);
    });

    test('a verified-but-inactive entitlement does not claim an upgrade', () async {
      verifyResult = const AppleVerifyResult(pro: false, proUntil: null, status: 'expired');
      backend.emit([_purchase(PurchaseStatus.purchased)]);
      await pumpEventQueue();
      expect(refreshes, 1);
      expect(backend.completed, hasLength(1)); // server processed it → safe to finish
      expect(c.justUpgraded, isFalse);
    });

    test('a sub attributed to ANOTHER Capecho account surfaces the cross-account message', () async {
      // Same Apple ID, different Capecho account: the verify returns pro:false + attributedToOtherAccount,
      // because Apple bound the sub to its first purchaser. The user must hear that, not a bare "not active".
      verifyResult = const AppleVerifyResult(
        pro: false,
        proUntil: null,
        status: 'noop',
        attributedToOtherAccount: true,
      );
      backend.emit([_purchase(PurchaseStatus.purchased)]);
      await pumpEventQueue();
      expect(c.justUpgraded, isFalse);
      expect(
        backend.completed,
        hasLength(1),
      ); // server processed it → finish (don't redeliver forever)
      expect(c.error, contains('different Capecho account'));
    });

    test('a successful verify is NOT reported as failed when the account refresh throws', () async {
      // The grant is already server-recorded after verify; a transient /auth/me refresh failure must not
      // turn the confirmed purchase into a "couldn't confirm" error or suppress justUpgraded.
      throwOnRefresh = true;
      backend.emit([_purchase(PurchaseStatus.purchased)]);
      await pumpEventQueue();
      expect(refreshes, 1); // the refresh WAS attempted
      expect(c.justUpgraded, isTrue); // success stands despite the refresh throw
      expect(c.error, isNull);
      expect(backend.completed, hasLength(1)); // verify landed → transaction finished
    });

    test('a success is not clobbered by a stale error row in the SAME batch', () async {
      // StoreKit can deliver a mixed batch (e.g. a restore surfacing an old error alongside the current
      // purchased). A success earlier in the batch must win — no error banner over a confirmed upgrade.
      backend.emit([
        _purchase(PurchaseStatus.purchased, jws: 'ok'),
        _purchase(PurchaseStatus.error),
      ]);
      await pumpEventQueue();
      expect(c.justUpgraded, isTrue);
      expect(c.error, isNull); // the sibling error did not overwrite the success
      expect(backend.completed, hasLength(2)); // both rows finished
    });

    test('a RESTORED-but-expired sub finishes the txn without claiming an upgrade', () async {
      // The reinstall/Ask-to-Buy path: a restored transaction whose sub has lapsed. The server
      // processed it (verify returned), so the txn is finished — but no upgrade is claimed.
      verifyResult = const AppleVerifyResult(pro: false, proUntil: null, status: 'expired');
      backend.emit([_purchase(PurchaseStatus.restored)]);
      await pumpEventQueue();
      expect(verifiedJws, isNotNull);
      expect(refreshes, 1);
      expect(backend.completed, hasLength(1));
      expect(c.justUpgraded, isFalse);
    });

    test('finishes every transaction in a single multi-item stream batch', () async {
      // StoreKit can deliver several transactions at once (e.g. a restore). Each must be verified + finished.
      backend.emit([
        _purchase(PurchaseStatus.restored, jws: 'a'),
        _purchase(PurchaseStatus.restored, jws: 'b'),
      ]);
      await pumpEventQueue();
      expect(backend.completed, hasLength(2));
    });

    test('a canceled event clears busy and finishes the transaction', () async {
      backend.emit([_purchase(PurchaseStatus.canceled)]);
      await pumpEventQueue();
      expect(c.busyPlan, isNull);
      expect(backend.completed, hasLength(1));
      expect(verifiedJws, isNull); // never sent to the backend
    });
  });

  group('restore', () {
    test('calls through to the store', () async {
      await c.restore();
      expect(backend.restoreCalls, 1);
    });
  });
}
