import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import 'auth_controller.dart' show SocialSignInCanceled, SocialSignInUnavailable;

/// The real platform credential providers wired into [AuthController] from `main` — the single place
/// that touches the native sign-in plugins, so the controller itself stays plugin-free and unit
/// testable. Each translates the plugin's outcome into the controller's contract: return the OIDC
/// token, throw [SocialSignInCanceled] on user dismissal, or [SocialSignInUnavailable] when the
/// provider isn't configured/supported on this build.

/// Sign in with Apple → the identity token (a JWT whose `aud` is the app bundle id, verified by the
/// backend against APPLE_CLIENT_ID).
Future<String> appleIdentityToken() async {
  final AuthorizationCredentialAppleID credential;
  try {
    credential = await SignInWithApple.getAppleIDCredential(
      // Email only — Capecho never reads or stores the user's name (no name column in the backend
      // accounts table; sign-in forwards only the identity token). Requesting `fullName` would add an
      // unused name-sharing prompt on first Apple sign-in. Data-minimization: keep it to email.
      scopes: const [AppleIDAuthorizationScopes.email],
    );
  } on SignInWithAppleAuthorizationException catch (e) {
    if (e.code == AuthorizationErrorCode.canceled) {
      throw const SocialSignInCanceled();
    }
    rethrow; // a genuine authorization failure → the controller's failure message
  } on SignInWithAppleNotSupportedException {
    throw const SocialSignInUnavailable(); // OS too old / capability missing
  }
  final token = credential.identityToken;
  if (token == null || token.isEmpty) throw const SocialSignInUnavailable();
  return token;
}

bool _googleInitialized = false;

/// Google sign-in → the ID token. [clientId] is the platform (macOS/iOS) OAuth client; [serverClientId]
/// is the optional Web client whose id becomes the token's `aud` — set it to match the backend's
/// GOOGLE_CLIENT_ID. With neither configured the provider reports unavailable (the UI steers to email).
Future<String> googleIdToken({String? clientId, String? serverClientId}) async {
  final hasClient =
      (clientId != null && clientId.isNotEmpty) ||
      (serverClientId != null && serverClientId.isNotEmpty);
  if (!hasClient) throw const SocialSignInUnavailable();

  final google = GoogleSignIn.instance;
  if (!google.supportsAuthenticate()) throw const SocialSignInUnavailable();

  // initialize() is a one-time singleton setup; only latch success so a failed attempt can retry.
  if (!_googleInitialized) {
    await google.initialize(clientId: clientId, serverClientId: serverClientId);
    _googleInitialized = true;
  }

  final GoogleSignInAccount account;
  try {
    account = await google.authenticate();
  } on GoogleSignInException catch (e) {
    if (e.code == GoogleSignInExceptionCode.canceled) {
      throw const SocialSignInCanceled();
    }
    if (e.code == GoogleSignInExceptionCode.clientConfigurationError ||
        e.code == GoogleSignInExceptionCode.providerConfigurationError) {
      throw const SocialSignInUnavailable(); // OAuth client / SDK not set up → steer to email
    }
    rethrow;
  }
  final token = account.authentication.idToken;
  if (token == null || token.isEmpty) throw const SocialSignInUnavailable();
  return token;
}
