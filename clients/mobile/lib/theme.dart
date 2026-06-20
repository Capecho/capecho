import 'package:flutter/material.dart';

/// The app-wide Material theme. Capecho's surfaces paint their own warm palette via
/// `OnboardingPalette.of(context)` (resolved by brightness), so this theme mainly carries the
/// brightness + a seeded color scheme for default-styled Material widgets — and deliberately lets the
/// platform default stand, so `SignInPanel` offers "Continue with Apple" on iOS (and not on Android).
ThemeData capechoTheme(Brightness brightness) {
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF7A5C3E), // warm coffee — matches the macOS client's seed
      brightness: brightness,
    ),
  );
}
