import 'dart:async';

import 'package:capecho_api/capecho_api.dart' show AppleVerifyResult;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:in_app_purchase/in_app_purchase.dart';

import 'pro_products.dart';

/// The narrow slice of `in_app_purchase` the controller uses, behind an interface so the purchase logic
/// is unit-testable without the StoreKit platform channel (tests pass a fake with a scriptable stream).
abstract class PurchaseBackend {
  Stream<List<PurchaseDetails>> get purchaseStream;
  Future<bool> isAvailable();
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers);
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam});
  Future<void> completePurchase(PurchaseDetails purchase);
  Future<void> restorePurchases();
}

/// The real backend, delegating to the `InAppPurchase` singleton.
class InAppPurchaseBackend implements PurchaseBackend {
  InAppPurchaseBackend([InAppPurchase? iap]) : _iap = iap ?? InAppPurchase.instance;

  final InAppPurchase _iap;

  @override
  Stream<List<PurchaseDetails>> get purchaseStream => _iap.purchaseStream;
  @override
  Future<bool> isAvailable() => _iap.isAvailable();
  @override
  Future<ProductDetailsResponse> queryProductDetails(Set<String> identifiers) =>
      _iap.queryProductDetails(identifiers);
  @override
  Future<bool> buyNonConsumable({required PurchaseParam purchaseParam}) =>
      _iap.buyNonConsumable(purchaseParam: purchaseParam);
  @override
  Future<void> completePurchase(PurchaseDetails purchase) => _iap.completePurchase(purchase);
  @override
  Future<void> restorePurchases() => _iap.restorePurchases();
}

/// Drives the Apple-IAP Pro purchase from Settings on the App Store rail (iOS + macOS Mac App Store).
/// App-lifetime (created in each client's app shell) so its `purchaseStream` subscription catches
/// transactions the App Store REDELIVERS — an interrupted buy, an Ask-to-Buy approval, or a restore — and
/// finishes them even when the upgrade surface is closed.
///
/// Flow: load products from StoreKit (live prices) → [buy] → on a purchased/restored transaction, POST
/// its signed JWS to `/billing/apple/verify` (the backend re-checks with Apple and updates the
/// server-authoritative entitlement) → refresh the account so every surface flips to Pro → finish the
/// transaction. The purchase carries the Capecho account id as `applicationUserName`, which the
/// StoreKit-2 layer sets as the transaction's `appAccountToken` (our account ids are v4 UUIDs, the format
/// Apple requires) — the linkage the backend attributes the subscription by, including for the
/// server-to-server renewal notifications that arrive without a session.
///
/// The same App Store Connect product ids back both platforms, so iOS and macOS share this controller and
/// only differ in their buy surface (the mobile bottom sheet vs the macOS paywall dialog).
class ProPurchaseController extends ChangeNotifier {
  ProPurchaseController({
    required this.backend,
    required this.verify,
    required this.onEntitlementChanged,
    required this.currentAccountId,
  }) {
    _sub = backend.purchaseStream.listen(
      _onPurchaseUpdates,
      onError: (_) {
        _busyPlan = null;
        _restoring = false;
        _error = 'The purchase couldn’t be completed. Please try again.';
        _notify();
      },
    );
  }

  /// The StoreKit seam (the real one delegates to `InAppPurchase.instance`; tests pass a fake).
  final PurchaseBackend backend;

  /// Submits a signed transaction's JWS to `POST /billing/apple/verify` and returns the entitlement.
  final Future<AppleVerifyResult> Function(String signedTransaction) verify;

  /// Re-pulls the account (`/auth/me`) so every surface reflects a just-applied entitlement.
  final Future<void> Function() onEntitlementChanged;

  /// The current Capecho account id (the appAccountToken linkage), or null when signed out.
  final String? Function() currentAccountId;

  StreamSubscription<List<PurchaseDetails>>? _sub;

  bool _loadingProducts = false;
  bool _loaded = false;
  bool _storeAvailable = false;
  final Map<ProPlan, ProductDetails> _products = {};
  ProPlan? _busyPlan;
  bool _restoring = false;
  String? _error;
  bool _justUpgraded = false;
  bool _disposed = false;

  bool get loadingProducts => _loadingProducts;

  /// True once products have loaded, the store is reachable, and at least one plan resolved — i.e. there
  /// is something real to buy. False keeps the sheet on a calm "not available yet".
  bool get available => _loaded && _storeAvailable && _products.isNotEmpty;

  ProductDetails? productFor(ProPlan plan) => _products[plan];

  /// The localized App Store price string for a plan (e.g. "$5.99"), or null if it didn't load.
  String? priceOf(ProPlan plan) => _products[plan]?.price;

  ProPlan? get busyPlan => _busyPlan;
  bool get restoring => _restoring;
  bool get isBusy => _busyPlan != null || _restoring;
  String? get error => _error;

  /// Set true when a verify confirms Pro — the sheet consumes it to show success + dismiss.
  bool get justUpgraded => _justUpgraded;

  /// Query StoreKit for the products + their live prices. Called lazily when the upgrade sheet opens (no
  /// store round-trip for users who never open it). A second call refreshes.
  Future<void> loadProducts() async {
    if (_loadingProducts) return;
    _loadingProducts = true;
    _error = null;
    _notify();
    try {
      _storeAvailable = await backend.isAvailable();
      if (_storeAvailable) {
        final resp = await backend.queryProductDetails(kProProductIds);
        _products.clear();
        for (final pd in resp.productDetails) {
          final plan = planForProductId(pd.id);
          if (plan != null) _products[plan] = pd;
        }
      }
    } catch (_) {
      _storeAvailable = false;
    } finally {
      _loaded = true;
      _loadingProducts = false;
      _notify();
    }
  }

  /// Begin a purchase. The result arrives asynchronously on the purchase stream ([_onPurchaseUpdates]).
  Future<void> buy(ProPlan plan) async {
    if (isBusy) return;
    final product = _products[plan];
    if (product == null) {
      _error = 'That plan isn’t available right now.';
      _notify();
      return;
    }
    final accountId = currentAccountId();
    if (accountId == null || accountId.isEmpty) {
      _error = 'Sign in to subscribe.';
      _notify();
      return;
    }
    _busyPlan = plan;
    _error = null;
    _justUpgraded = false;
    _notify();
    try {
      // applicationUserName carries the Capecho account id → the StoreKit-2 layer sets it as the
      // transaction's appAccountToken (a UUID; our ids are v4 UUIDs), the linkage the backend reads.
      final param = PurchaseParam(productDetails: product, applicationUserName: accountId);
      final started = await backend.buyNonConsumable(purchaseParam: param);
      if (!started) {
        // StoreKit declined to START the purchase without throwing or emitting a stream event — clear the
        // spinner so it can't get stuck forever waiting for a transaction that will never arrive.
        _busyPlan = null;
        _error = 'Couldn’t start the purchase. Please try again.';
        _notify();
      }
    } catch (e) {
      _busyPlan = null;
      _error = _describeStartError(e);
      _notify();
    }
  }

  /// A human message for a purchase the store wouldn't even START (a synchronous throw from
  /// `buyNonConsumable`). Surfaces the platform's REAL reason when there is one — StoreKit messages like
  /// "You're currently subscribed to this" or a pending duplicate transaction ARE user-meaningful and
  /// shouldn't be hidden behind a generic — falling back to a calm generic only when there's nothing.
  static String _describeStartError(Object e) {
    if (e is PlatformException) {
      final message = (e.message ?? '').trim();
      if (message.isNotEmpty) return message;
      final code = e.code.trim();
      if (code.isNotEmpty) return 'Couldn’t start the purchase ($code).';
    }
    return 'Couldn’t start the purchase. Please try again.';
  }

  /// Restore a prior purchase (App Store guideline 3.1.1). Restored transactions arrive on the stream and
  /// are verified + finished there; because the entitlement is account-scoped server-side, signing in on
  /// a new device already grants Pro without this — it's the belt-and-braces affordance.
  Future<void> restore() async {
    if (isBusy) return;
    _restoring = true;
    _error = null;
    _notify();
    try {
      // No applicationUserName here on purpose: a restored StoreKit-2 transaction carries the
      // appAccountToken its ORIGINAL purchase set, so attribution still works from the JWS the backend
      // re-checks — the restore path neither needs nor accepts a fresh account id.
      await backend.restorePurchases();
    } catch (_) {
      _error = 'Couldn’t restore purchases. Please try again.';
    } finally {
      // restorePurchases only TRIGGERS the stream; the actual restored events verify asynchronously.
      // Clear the spinner now so it can't get stuck when there's nothing to restore.
      _restoring = false;
      _notify();
    }
  }

  Future<void> _onPurchaseUpdates(List<PurchaseDetails> purchases) async {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case PurchaseStatus.pending:
          break; // keep the spinner; nothing to finish yet.
        case PurchaseStatus.canceled:
          _busyPlan = null;
          _restoring = false;
          _notify();
          await _finish(purchase);
        case PurchaseStatus.error:
          _busyPlan = null;
          _restoring = false;
          // Don't let a stale error row clobber a success already confirmed earlier in THIS batch (a
          // restore can surface an old error alongside the current purchased transaction).
          if (!_justUpgraded) {
            _error = purchase.error?.message ?? 'The purchase didn’t go through.';
          }
          _notify();
          await _finish(purchase);
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _verifyPurchase(purchase);
      }
    }
  }

  Future<void> _verifyPurchase(PurchaseDetails purchase) async {
    final jws = purchase.verificationData.serverVerificationData;
    var verified = false;
    try {
      final result = await verify(jws);
      verified = true;
      // Resolve the outcome from the (server-authoritative) verify result BEFORE refreshing the account,
      // so a failure of the best-effort refresh below can't turn a CONFIRMED purchase into a "couldn't
      // confirm" error — the grant is already recorded server-side at this point.
      _justUpgraded = result.pro;
      if (result.pro) {
        _error = null;
      } else if (result.attributedToOtherAccount) {
        // Same Apple ID, different Capecho account: Apple bound this subscription to its first purchaser,
        // so re-buying it here can't move it. Tell the user plainly instead of a bare "not active".
        _error =
            'This Apple ID’s subscription is already linked to a different Capecho account. Sign in '
            'with that account, or use a different Apple ID to subscribe here.';
      } else {
        _error = 'That subscription isn’t active right now.';
      }
      // Refresh every surface to reflect the new entitlement — best-effort: a refresh blip just means
      // /auth/me catches up later; it must NOT overwrite the outcome resolved above.
      try {
        await onEntitlementChanged();
      } catch (_) {}
    } catch (_) {
      // Verify didn't land — leave the transaction UNFINISHED so the App Store redelivers it (the
      // app-lifetime listener retries next launch). The entitlement is server-authoritative and is also
      // backstopped by the App Store server-to-server notification + the reconcile cron.
      _error = 'Couldn’t confirm the purchase just now — it’ll finish automatically.';
    } finally {
      _busyPlan = null;
      _restoring = false;
      _notify();
      // Finish only once the server has the transaction (a successful verify); otherwise let it redeliver.
      if (verified) await _finish(purchase);
    }
  }

  Future<void> _finish(PurchaseDetails purchase) async {
    if (!purchase.pendingCompletePurchase) return;
    try {
      await backend.completePurchase(purchase);
    } catch (_) {
      // best-effort: a still-pending transaction redelivers and is finished next time.
    }
  }

  /// Consume the one-shot success signal (the sheet pops itself on it).
  void clearJustUpgraded() => _justUpgraded = false;

  void clearError() {
    if (_error == null) return; // nothing to clear → no spurious notify (safe to call during init)
    _error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    super.dispose();
  }
}
