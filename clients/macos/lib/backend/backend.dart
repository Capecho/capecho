import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart' show HttpClientTransport;

/// The live backend base URL. Override for staging/local with:
///   flutter run --dart-define=CAPECHO_API_BASE=http://localhost:8787
const String kCapechoApiBase = String.fromEnvironment(
  'CAPECHO_API_BASE',
  defaultValue: 'https://api.capecho.com',
);

/// Build the shared API client wired to the real HTTP transport.
CapechoApi buildCapechoApi() =>
    CapechoApi(baseUrl: kCapechoApiBase, transport: HttpClientTransport());

/// Google OAuth client IDs for native sign-in (Google Cloud Console). They default to this project's
/// own clients so EVERY build has them — a plain `flutter run`, a `flutter build`, or an Xcode build
/// carries no `--dart-define`. Override per build with `--dart-define=GOOGLE_NATIVE_CLIENT_ID=…` /
/// `--dart-define=GOOGLE_SERVER_CLIENT_ID=…`.
///
/// [kGoogleNativeClientId]'s reversed id is the Info.plist redirect scheme (GOOGLE_REVERSED_CLIENT_ID
/// in AppInfo.xcconfig). Whichever becomes the ID token's `aud` (the Web client when set, else native)
/// MUST be in the backend's comma-separated `GOOGLE_CLIENT_ID` or verification fails `bad_audience`.
/// Client ids aren't secret (they ship in every binary); blank both → Google reports unavailable.
const String kGoogleNativeClientId = String.fromEnvironment(
  'GOOGLE_NATIVE_CLIENT_ID',
  defaultValue: '1096137361732-7jj4fesli3vctk5ir0o95uncjg1m5kbf.apps.googleusercontent.com',
);
const String kGoogleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
  defaultValue: '1096137361732-vpf31lje0cuojdua129cdf9c0t5t9qip.apps.googleusercontent.com',
);
