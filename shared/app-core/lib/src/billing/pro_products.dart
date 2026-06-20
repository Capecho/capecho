/// App Store product identifiers for the Pro subscription (the Apple-IAP rail, shared by the iOS and
/// macOS clients).
///
/// These must match the auto-renewable subscription products created in App Store Connect — one
/// subscription GROUP ("Capecho Pro") with two durations (monthly + annual). iOS and macOS bill against
/// the SAME App Store Connect product ids (one app record, two platforms), so this lives in app-core and
/// both clients query the identical set. They default to `capecho.pro.monthly` / `capecho.pro.annual`
/// (the ids created in App Store Connect — a product id needs no bundle-id prefix), and can be overridden
/// per build:
///   flutter build … --dart-define=APPLE_PRODUCT_MONTHLY=… --dart-define=APPLE_PRODUCT_ANNUAL=…
///
/// Until those products exist + are "Approved"/"Ready to Submit" in App Store Connect, StoreKit returns
/// them as not-found and the upgrade surface shows a calm "not available yet" — never a dead buy button.
/// The price shown to the user always comes from StoreKit at runtime (never hard-coded here), so it can't
/// drift from what App Store Connect charges.
library;

/// The two purchasable durations. The wire/plan strings (`'monthly'`/`'annual'`) match the Stripe rail's
/// plan param, so both rails speak the same vocabulary.
enum ProPlan {
  monthly,
  annual;

  String get wire => this == ProPlan.annual ? 'annual' : 'monthly';
}

const String kAppleProductMonthly = String.fromEnvironment(
  'APPLE_PRODUCT_MONTHLY',
  defaultValue: 'capecho.pro.monthly',
);
const String kAppleProductAnnual = String.fromEnvironment(
  'APPLE_PRODUCT_ANNUAL',
  defaultValue: 'capecho.pro.annual',
);

/// The full product-id set queried from StoreKit.
const Set<String> kProProductIds = {kAppleProductMonthly, kAppleProductAnnual};

/// The App Store product id for a plan.
String productIdForPlan(ProPlan plan) =>
    plan == ProPlan.annual ? kAppleProductAnnual : kAppleProductMonthly;

/// The plan a StoreKit product id maps to, or null if it isn't one of ours.
ProPlan? planForProductId(String id) {
  if (id == kAppleProductMonthly) return ProPlan.monthly;
  if (id == kAppleProductAnnual) return ProPlan.annual;
  return null;
}
