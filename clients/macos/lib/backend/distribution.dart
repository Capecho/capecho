import 'dart:io';

/// Which distribution channel this macOS build targets — it selects the Pro upgrade's payment rail:
///   • `direct` (default): Developer ID self-distribution → the Pro upgrade uses the **Stripe** web rail
///     ([ProPaywall] → `POST /billing/stripe/checkout` → the system browser).
///   • `mas`: Mac App Store → the Pro upgrade MUST use **Apple IAP**. Apple forbids external/Stripe
///     payment for digital subscriptions, so showing the Stripe paywall in a MAS build is an instant
///     App Review rejection.
///
/// `scripts/macos/build_mas.sh` bakes `--dart-define=CAPECHO_DIST=mas` into the Mac App Store archive;
/// the direct `build_release.sh` passes nothing, so it stays `direct`. A plain `flutter run` / `flutter
/// build` is `direct` too (so dev + the existing direct release are unchanged).
const String kCapechoDist = String.fromEnvironment('CAPECHO_DIST', defaultValue: 'direct');

/// Whether the running app carries a Mac App Store receipt at `Contents/_MASReceipt/receipt`. The receipt
/// is placed in the bundle by the App Store for store + TestFlight installs AND is present during App
/// Review; it's absent for a Developer ID build and for a local `flutter run`.
///
/// Read in pure Dart from the app's OWN bundle — always readable inside the App Sandbox (the sandbox
/// restricts access to other locations, never to the app's own bundle), so this needs no entitlement and
/// no native method channel. `Platform.resolvedExecutable` is `…/Capecho.app/Contents/MacOS/Capecho`, so
/// its grandparent directory is `…/Capecho.app/Contents`.
bool hasMacAppStoreReceipt() {
  if (!Platform.isMacOS) return false;
  try {
    final contents = File(Platform.resolvedExecutable).parent.parent.path;
    return File('$contents/_MASReceipt/receipt').existsSync();
  } catch (_) {
    return false;
  }
}

/// True when the Pro upgrade must use the Apple-IAP rail (Mac App Store). It's the build-time
/// [kCapechoDist] flag OR — as a SAFETY BACKSTOP — the presence of a Mac App Store receipt. The backstop
/// makes "a MAS build shows Stripe" impossible: even if an archive somehow shipped without the
/// `CAPECHO_DIST=mas` flag, the receipt (always present under App Review) forces the IAP rail. A direct
/// build has neither signal, so it keeps the Stripe rail.
bool isMacAppStoreBuild() => kCapechoDist == 'mas' || hasMacAppStoreReceipt();
