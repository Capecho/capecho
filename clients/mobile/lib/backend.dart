import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';

/// The live backend base URL. Override for staging/local with:
///   flutter run --dart-define=CAPECHO_API_BASE=http://localhost:8787
const String kCapechoApiBase = String.fromEnvironment(
  'CAPECHO_API_BASE',
  defaultValue: 'https://api.capecho.com',
);

/// Build the shared API client wired to the real HTTP transport (HttpClientTransport lives in
/// capecho_app_core, shared with macOS).
CapechoApi buildCapechoApi() =>
    CapechoApi(baseUrl: kCapechoApiBase, transport: HttpClientTransport());

/// Google OAuth client ids for native sign-in. Both default to this project's existing clients, so a
/// plain `flutter run` carries no `--dart-define`. Client ids aren't secret (they ship in every
/// binary); blank both → Google reports unavailable and the UI steers to email.
///
/// [kGoogleServerClientId] is the shared WEB client — its id becomes the ID token's `aud`, which the
/// backend verifies against its comma-separated `GOOGLE_CLIENT_ID`.
/// [kGoogleIosClientId] is the **iOS** client, registered for bundle id `com.capecho.app` (which this
/// app shares with the macOS build — see ios/Runner.xcodeproj); its reversed id is wired as the iOS
/// URL scheme in ios/Runner/Info.plist. Override per build with --dart-define=GOOGLE_IOS_CLIENT_ID=… /
/// --dart-define=GOOGLE_SERVER_CLIENT_ID=…
const String kGoogleServerClientId = String.fromEnvironment(
  'GOOGLE_SERVER_CLIENT_ID',
  defaultValue: '1096137361732-vpf31lje0cuojdua129cdf9c0t5t9qip.apps.googleusercontent.com',
);
const String kGoogleIosClientId = String.fromEnvironment(
  'GOOGLE_IOS_CLIENT_ID',
  defaultValue: '1096137361732-7jj4fesli3vctk5ir0o95uncjg1m5kbf.apps.googleusercontent.com',
);
