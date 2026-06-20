import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:capture_native/capture_native.dart' show CapechoShortcut;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'settings_controller.dart' show shortcutDisplay;

/// An immutable captured key combination (the [key] + its [modifiers]) with a human-readable
/// [display]. The recorder builds one from the next keypress; Settings persists it via `setShortcut`.
class ShortcutDraft {
  const ShortcutDraft({required this.key, required this.modifiers});

  final String key;
  final List<String> modifiers;

  String get display => shortcutDisplay(key, modifiers);
}

/// The modal that records a new key combination for a [CapechoShortcut]: it captures the next
/// modifier+key press, validates it (a real key, at least one modifier), previews the resulting
/// [ShortcutDraft], and pops it on Save. Esc / Cancel dismiss without changing anything.
class ShortcutRecorderDialog extends StatefulWidget {
  const ShortcutRecorderDialog({super.key, required this.p, required this.shortcut});

  final OnboardingPalette p;
  final CapechoShortcut shortcut;

  @override
  State<ShortcutRecorderDialog> createState() => _ShortcutRecorderDialogState();
}

class _ShortcutRecorderDialogState extends State<ShortcutRecorderDialog> {
  final FocusNode _focus = FocusNode(debugLabel: 'shortcut-recorder');
  ShortcutDraft? _draft;
  String? _error;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    final key = _shortcutKey(event.logicalKey);
    if (key == null) {
      setState(() => _error = 'Press a letter, number, or punctuation key.');
      return KeyEventResult.handled;
    }
    final modifiers = _pressedModifiers();
    if (modifiers.isEmpty) {
      setState(() => _error = 'Use at least one modifier key.');
      return KeyEventResult.handled;
    }
    setState(() {
      _draft = ShortcutDraft(key: key, modifiers: modifiers);
      _error = null;
    });
    return KeyEventResult.handled;
  }

  List<String> _pressedModifiers() {
    final keyboard = HardwareKeyboard.instance;
    return [
      if (keyboard.isControlPressed) 'control',
      if (keyboard.isAltPressed) 'option',
      if (keyboard.isShiftPressed) 'shift',
      if (keyboard.isMetaPressed) 'command',
    ];
  }

  String? _shortcutKey(LogicalKeyboardKey key) {
    final mapped = {
      LogicalKeyboardKey.keyA: 'A',
      LogicalKeyboardKey.keyB: 'B',
      LogicalKeyboardKey.keyC: 'C',
      LogicalKeyboardKey.keyD: 'D',
      LogicalKeyboardKey.keyE: 'E',
      LogicalKeyboardKey.keyF: 'F',
      LogicalKeyboardKey.keyG: 'G',
      LogicalKeyboardKey.keyH: 'H',
      LogicalKeyboardKey.keyI: 'I',
      LogicalKeyboardKey.keyJ: 'J',
      LogicalKeyboardKey.keyK: 'K',
      LogicalKeyboardKey.keyL: 'L',
      LogicalKeyboardKey.keyM: 'M',
      LogicalKeyboardKey.keyN: 'N',
      LogicalKeyboardKey.keyO: 'O',
      LogicalKeyboardKey.keyP: 'P',
      LogicalKeyboardKey.keyQ: 'Q',
      LogicalKeyboardKey.keyR: 'R',
      LogicalKeyboardKey.keyS: 'S',
      LogicalKeyboardKey.keyT: 'T',
      LogicalKeyboardKey.keyU: 'U',
      LogicalKeyboardKey.keyV: 'V',
      LogicalKeyboardKey.keyW: 'W',
      LogicalKeyboardKey.keyX: 'X',
      LogicalKeyboardKey.keyY: 'Y',
      LogicalKeyboardKey.keyZ: 'Z',
      LogicalKeyboardKey.digit0: '0',
      LogicalKeyboardKey.digit1: '1',
      LogicalKeyboardKey.digit2: '2',
      LogicalKeyboardKey.digit3: '3',
      LogicalKeyboardKey.digit4: '4',
      LogicalKeyboardKey.digit5: '5',
      LogicalKeyboardKey.digit6: '6',
      LogicalKeyboardKey.digit7: '7',
      LogicalKeyboardKey.digit8: '8',
      LogicalKeyboardKey.digit9: '9',
      LogicalKeyboardKey.comma: ',',
      LogicalKeyboardKey.period: '.',
      LogicalKeyboardKey.slash: '/',
      LogicalKeyboardKey.semicolon: ';',
      LogicalKeyboardKey.quote: "'",
      LogicalKeyboardKey.bracketLeft: '[',
      LogicalKeyboardKey.bracketRight: ']',
      LogicalKeyboardKey.backslash: '\\',
      LogicalKeyboardKey.minus: '-',
      LogicalKeyboardKey.equal: '=',
      LogicalKeyboardKey.backquote: '`',
    };
    final mappedKey = mapped[key];
    if (mappedKey != null) return mappedKey;

    const punctuation = {',', '.', '/', ';', "'", '[', ']', '\\', '-', '=', '`'};
    final label = key.keyLabel;
    if (label.length != 1) return null;
    if (RegExp(r'^[A-Za-z0-9]$').hasMatch(label)) {
      return label.toUpperCase();
    }
    if (punctuation.contains(label)) return label;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    final draft = _draft;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Dialog(
        backgroundColor: p.card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Change ${widget.shortcut.title} shortcut',
                  style: p.chrome(size: 17, weight: FontWeight.w600, color: p.ink),
                ),
                const SizedBox(height: 8),
                Text(
                  'Press the new key combination.',
                  style: p
                      .chrome(size: 13, weight: FontWeight.w400, color: p.ink2)
                      .copyWith(height: 1.45),
                ),
                const SizedBox(height: 16),
                Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: p.primarySoft,
                    border: Border.all(color: p.line),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    draft?.display ?? widget.shortcut.display,
                    style: p.mono(size: 20, color: p.ink).copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 9),
                  Text(
                    _error!,
                    style: p
                        .chrome(size: 12, weight: FontWeight.w500, color: p.error)
                        .copyWith(height: 1.35),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    ObQuietButton(
                      p: p,
                      label: 'Cancel',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 10),
                    ObPrimaryButton(
                      p: p,
                      label: 'Save',
                      onPressed: draft == null ? null : () => Navigator.of(context).pop(draft),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
