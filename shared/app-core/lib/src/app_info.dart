import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Canonical Capecho web links + the public contact address, shared by both clients (and onboarding)
/// so the URLs live in ONE place rather than being re-typed per surface. The marketing site already
/// serves every page below; the contact address mirrors `web/lib/site.ts`.
class CapechoLinks {
  CapechoLinks._();

  /// Marketing site home.
  static const String website = 'https://capecho.com';

  /// The dedicated contact page — Settings → About's "Contact support" row opens this (the page itself
  /// offers the support email + what to write about). Preferred over a raw mailto so the in-app row and
  /// the website point at the same place.
  static const String contactPage = 'https://capecho.com/contact';

  /// The formal privacy policy (Settings → About). Distinct from [privacyExplainer].
  static const String privacyPolicy = 'https://capecho.com/legal/privacy-policy';

  /// Terms of service (Settings → About).
  static const String terms = 'https://capecho.com/legal/terms';

  /// The capture privacy *explainer* — onboarding's "Why does macOS call this 'Screen Recording'?"
  /// link. A plain-language page about the capture flow, separate from the legal [privacyPolicy].
  static const String privacyExplainer = 'https://capecho.com/how-it-works#why-screen-recording';
}

/// The running app's version, read from the platform bundle (package_info_plus). [version] is the
/// marketing string (CFBundleShortVersionString / Android versionName, e.g. `0.1.5`) and [build] the
/// build number (CFBundleVersion / versionCode). On a macOS release both are derived from the repo
/// `/VERSION` by `scripts/macos/version.sh` at build time, so this reflects the shipped version with
/// no constant to keep in sync.
class AppVersionInfo {
  const AppVersionInfo({required this.version, required this.build});

  final String version;
  final String build;

  /// `0.1.5 (10500)` — the marketing version with the build number appended for support; the build is
  /// omitted when empty.
  String get label => build.isEmpty ? version : '$version ($build)';
}

/// Read the running app's version from the bundle. Best-effort: returns null when the platform channel
/// isn't available (e.g. a widget test with no plugin registrar), so callers render a calm placeholder
/// rather than crashing.
Future<AppVersionInfo?> capechoAppVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    return AppVersionInfo(version: info.version, build: info.buildNumber);
  } catch (_) {
    return null;
  }
}

/// Open an external URL or `mailto:` in the user's browser / mail client. Best-effort: a launch
/// failure — or a missing plugin in a widget test — is swallowed so a Settings tap never throws.
Future<void> capechoOpenExternal(Uri uri) async {
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
}
