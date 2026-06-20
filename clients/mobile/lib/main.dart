import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import 'app.dart';
import 'settings/appearance_store.dart';

Future<void> main() async {
  // Hydrate the saved Light/Dark/System choice before the first frame so the app doesn't flash the
  // System default on launch when the user picked a fixed theme.
  WidgetsFlutterBinding.ensureInitialized();
  final appearance = AppearanceController(store: SecureAppearanceStore());
  await appearance.load();
  runApp(CapechoApp(appearance: appearance, timezoneName: await _deviceTimezone()));
}

/// The device's IANA timezone (e.g. "America/New_York"), stamped on the account at first sign-in so the
/// server's review-day boundary matches the phone (US-14.1). Best-effort — a plugin failure resolves to
/// null, which the backend treats as UTC.
Future<String?> _deviceTimezone() async {
  try {
    return (await FlutterTimezone.getLocalTimezone()).identifier;
  } catch (_) {
    return null;
  }
}
