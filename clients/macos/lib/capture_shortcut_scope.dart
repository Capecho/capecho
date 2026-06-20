import 'package:flutter/widgets.dart';

/// Publishes the user's current Capture global-shortcut display (e.g. "⌥E",
/// "⌘⇧F") to widgets that show shortcut hints — onboarding, the agent splash,
/// the Settings copy. Settings ALSO reads through its own controller so the
/// preview updates while the user is editing; everywhere else reads via [of].
///
/// The host (`_CaptureDevShellState`) loads the current display from the
/// native plugin at startup, refreshes after a successful save in Settings,
/// and rebuilds with a new scope — descendants subscribe via [of] and rebuild
/// automatically.
class CaptureShortcutScope extends InheritedWidget {
  const CaptureShortcutScope({super.key, required this.display, required super.child});

  /// Full display string for the Capture shortcut, e.g. "⌥E".
  final String display;

  /// The modifier-glyph prefix of [display] — "⌥" for "⌥E", "⌘⇧" for "⌘⇧F".
  /// Returns the whole string if it contains no recognizable key suffix.
  String get modifierGlyphs {
    const modSet = {'⌃', '⌥', '⇧', '⌘'};
    for (var i = display.length - 1; i >= 0; i--) {
      if (!modSet.contains(display[i])) return display.substring(0, i);
    }
    return display;
  }

  /// Capture display from the nearest scope. Falls back to "⌥E" so widgets
  /// hosted outside the shell (golden tests, isolated previews) still render.
  static String displayOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CaptureShortcutScope>()?.display ?? '⌥E';

  /// Modifier-glyph prefix from the nearest scope. Falls back to "⌥".
  static String modifiersOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CaptureShortcutScope>()?.modifierGlyphs ?? '⌥';

  @override
  bool updateShouldNotify(CaptureShortcutScope old) => old.display != display;
}
