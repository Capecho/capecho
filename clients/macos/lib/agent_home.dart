import 'dart:async';

import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'capture_shortcut_scope.dart';

/// The agent's **front door** — what the single Flutter window shows when Capecho is opened with no
/// specific destination. Past onboarding the menu-bar agent has no persistent home window: capture is
/// the native ⌥E overlay, and Review / Word Book / Settings open on demand. But the window IS brought
/// forward bare — landing here — when the user "just opens Capecho" again: a Finder double-click or a
/// Dock-icon click while no window is visible routes through `AppDelegate.applicationShouldHandleReopen`
/// → `showMainWindow()` with no surface request. So this is a real, dwellable hub, not a flash; it
/// carries the brand and routes onward.
///
/// It's a quiet "warm library" hub (DESIGN.md): the wordmark + echo mark, the capture gesture taught
/// with live key caps, a single calm status pulse (words kept · N due today — the 效率 signal), and the
/// three surfaces as clickable rows. All data is best-effort and degrades to brand-only — the front
/// door never blocks on a network read.
class AgentHome extends StatefulWidget {
  const AgentHome({
    super.key,
    required this.signedIn,
    required this.onOpenSurface,
    this.onClose,
    this.loadWordCount,
    this.loadDueCount,
    this.loadShortcutDisplays,
  });

  /// Dismiss the front door the SAME way every other surface does — Esc / ⌘W hides the window back to the
  /// menu-bar agent. The agent app supplies `hideWindow`; null (tests / a nested host) makes Esc a no-op.
  final VoidCallback? onClose;

  /// Best-effort "words kept" source — wired to read the **same catalog as the Word Book** so the two
  /// surfaces can never disagree: signed in, the account's server count (`/words`, active rows); signed
  /// out, the device's anonymous local catalog (the signed-out Word Book's own source). This avoids the
  /// over-count a raw local `activeWords()` produces on a device whose store still holds rows claimed
  /// into other/wiped accounts. Null/failure → the status line just omits the kept figure (the front
  /// door degrades to brand-only and never blocks on the read; a signed-in offline device shows no
  /// count rather than a stale local number).
  final Future<int?> Function()? loadWordCount;

  /// Whether a session is live — gates the account-only "N due" fetch and flips the kept-count source.
  final bool signedIn;

  /// Opens a top-level surface — `'review'` | `'wordBook'` | `'settings'`. Wired to the shell's
  /// surface routing, the same path the menu bar and global ⌥R / ⌥B hotkeys use.
  final void Function(String surface) onOpenSurface;

  /// Best-effort due-count source (`GET /review/due` → `dueCount`). Null when signed out. A failure is
  /// swallowed — the status line just omits the due figure.
  final Future<int?> Function()? loadDueCount;

  /// Best-effort map of `action → display` for the configurable hotkeys (e.g. `{'review': '⌥R'}`), so
  /// the Review / Word Book rows can show live key caps. Missing entries just render no cap.
  final Future<Map<String, String>> Function()? loadShortcutDisplays;

  @override
  State<AgentHome> createState() => _AgentHomeState();
}

class _AgentHomeState extends State<AgentHome> {
  // null = unresolved / failed → the status line omits the kept figure. The source flips with sign-in
  // (account server count ↔ anonymous local), so it's re-fetched whenever `signedIn` changes.
  int? _kept;
  // null = unresolved / signed out / failed → the status line omits the due figure.
  int? _due;
  // Live displays for the Review / Word Book hotkeys; empty until resolved.
  Map<String, String> _shortcuts = const {};

  final FocusNode _focus = FocusNode(debugLabel: 'agentHome');

  @override
  void initState() {
    super.initState();
    _fetchKept();
    _fetchDue();
    _fetchShortcuts();
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  /// Esc / ⌘W → hide the window back to the menu-bar agent, exactly like Review / Word Book / Settings
  /// (this hub was the one surface that trapped the user with no keyboard way out).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.escape ||
        (k == LogicalKeyboardKey.keyW && HardwareKeyboard.instance.isMetaPressed)) {
      final close = widget.onClose;
      if (close != null) {
        close();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void didUpdateWidget(AgentHome old) {
    super.didUpdateWidget(old);
    // Re-fetch only when sign-in actually flips (signed in from another surface, or signed out). The
    // `loadWordCount`/`loadDueCount`/`loadShortcutDisplays` closures are rebuilt with a fresh identity
    // on every parent rebuild, so comparing them would re-fetch (and flicker the counts to null) on
    // unrelated rebuilds — the stable `signedIn` bool is the real trigger. A flip switches BOTH the
    // kept-count source (anonymous local ↔ account server) and the due figure.
    if (old.signedIn != widget.signedIn) {
      setState(() {
        _kept = null;
        _due = null;
      });
      _fetchKept();
      _fetchDue();
    }
  }

  Future<void> _fetchKept() async {
    final load = widget.loadWordCount;
    if (load == null) return;
    try {
      final n = await load();
      if (mounted) setState(() => _kept = n);
    } catch (_) {
      // Best-effort: leave _kept null so the status line omits the kept figure (degrades to brand-only).
    }
  }

  Future<void> _fetchDue() async {
    final load = widget.loadDueCount;
    if (load == null) return;
    try {
      final n = await load();
      if (mounted) setState(() => _due = n);
    } catch (_) {
      // Best-effort: leave _due null so the status line shows only the kept count.
    }
  }

  Future<void> _fetchShortcuts() async {
    final load = widget.loadShortcutDisplays;
    if (load == null) return;
    try {
      final map = await load();
      if (mounted) setState(() => _shortcuts = map);
    } catch (_) {
      // Best-effort: the rows just render without a key cap.
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    final captureDisplay = CaptureShortcutScope.displayOf(context);
    final status = _statusLine(p);
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: p.canvas,
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 44),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Brand lockup: the echo mark broadcasting over the wordmark.
                  Center(child: ObEchoMark(color: p.primary, size: 40)),
                  const SizedBox(height: 16),
                  Center(child: ObWordmark(p: p)),
                  const SizedBox(height: 18),
                  // The product, in one warm line (Capture + echo) — replaces "Capecho lives in your menu bar".
                  Text(
                    'Capture the words you meet while reading.\n'
                    'They echo back when it’s time to remember.',
                    textAlign: TextAlign.center,
                    style: p.body(size: 15.5, height: 1.5, color: p.ink2),
                  ),
                  if (status != null) ...[const SizedBox(height: 18), Center(child: status)],
                  const SizedBox(height: 28),
                  // Hero: the core gesture, taught with the live capture shortcut as real key caps.
                  _CaptureHero(p: p, captureDisplay: captureDisplay),
                  const SizedBox(height: 22),
                  // The three surfaces as clickable rows (was a dead sentence) — each opens on click and
                  // shows its global hotkey.
                  _DestinationRow(
                    p: p,
                    label: 'Review',
                    caps: _capsFor(_shortcuts['review']),
                    onTap: () => widget.onOpenSurface('review'),
                  ),
                  _rule(p),
                  _DestinationRow(
                    p: p,
                    label: 'Word Book',
                    caps: _capsFor(_shortcuts['wordBook']),
                    onTap: () => widget.onOpenSurface('wordBook'),
                  ),
                  _rule(p),
                  _DestinationRow(
                    p: p,
                    label: 'Settings',
                    // Settings has no rebindable global hotkey — it rides the standard app-menu ⌘,.
                    caps: const ['⌘', ','],
                    onTap: () => widget.onOpenSurface('settings'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _rule(OnboardingPalette p) => Divider(height: 1, thickness: 1, color: p.line);

  /// The single calm status pulse under the tagline: `N words kept · M due today` (or `· all caught
  /// up`). Numbers in the data/mono voice; the due figure tints primary when it's a call to action.
  /// Returns null when there's nothing to say (no words yet and no due figure).
  Widget? _statusLine(OnboardingPalette p) {
    final kept = _kept;
    final due = _due;
    final spans = <InlineSpan>[];
    if (kept != null && kept > 0) {
      spans
        ..add(
          TextSpan(
            text: '$kept',
            style: p.mono(size: 13, color: p.ink),
          ),
        )
        ..add(
          TextSpan(
            text: kept == 1 ? ' word kept' : ' words kept',
            style: p.chrome(size: 13, weight: FontWeight.w400, color: p.ink3),
          ),
        );
    }
    if (due != null) {
      if (spans.isNotEmpty) {
        spans.add(
          TextSpan(
            text: '   ·   ',
            style: p.chrome(size: 13, color: p.ink3),
          ),
        );
      }
      if (due > 0) {
        spans
          ..add(
            TextSpan(
              text: '$due',
              style: p.mono(size: 13, color: p.primary),
            ),
          )
          ..add(
            TextSpan(
              text: ' due today',
              style: p.chrome(size: 13, weight: FontWeight.w600, color: p.primary),
            ),
          );
      } else {
        spans.add(
          TextSpan(
            text: 'all caught up',
            style: p.chrome(size: 13, weight: FontWeight.w400, color: p.ink3),
          ),
        );
      }
    }
    if (spans.isEmpty) return null;
    return Text.rich(TextSpan(children: spans), textAlign: TextAlign.center);
  }
}

/// Split a hotkey [display] (e.g. `"⌥E"`, `"⌘⇧F"`) into adjacent [ObKeyCombo] glyph parts. Null/empty
/// → no caps. Mirrors onboarding's `_captureKeyComboParts(withPlus: false)`.
List<String> _capsFor(String? display) {
  if (display == null || display.isEmpty) return const [];
  return display.split('');
}

/// The capture gesture, taught as a card: the live shortcut in key caps beside a one-line how-to. It's
/// instructional, not a button — capture reads the screen under the cursor in whatever app you're
/// reading, so it only ever fires from the global ⌥E hotkey, never from this focused window.
class _CaptureHero extends StatelessWidget {
  const _CaptureHero({required this.p, required this.captureDisplay});
  final OnboardingPalette p;
  final String captureDisplay;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: p.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
        boxShadow: kSoftEdgeShadow,
      ),
      child: Row(
        children: [
          ObKeyCombo(p: p, parts: _capsFor(captureDisplay)),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Capture a word',
                  style: p.chrome(size: 15, weight: FontWeight.w600, color: p.ink),
                ),
                const SizedBox(height: 3),
                Text(
                  'Press it in any app while you read.',
                  style: p.body(size: 13.5, height: 1.35, color: p.ink2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A clickable navigation row: the surface name on the warm canvas, its hotkey in caps on the right, a
/// quiet warm wash + the label going primary on hover. The whole row is the hit target.
class _DestinationRow extends StatefulWidget {
  const _DestinationRow({
    required this.p,
    required this.label,
    required this.caps,
    required this.onTap,
  });
  final OnboardingPalette p;
  final String label;
  final List<String> caps;
  final VoidCallback onTap;

  @override
  State<_DestinationRow> createState() => _DestinationRowState();
}

class _DestinationRowState extends State<_DestinationRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.p;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          label: widget.label,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: _hover ? p.primary.withValues(alpha: 0.06) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Text(
                  widget.label,
                  style: p.chrome(
                    size: 15,
                    weight: FontWeight.w600,
                    color: _hover ? p.primary : p.ink,
                  ),
                ),
                const Spacer(),
                if (widget.caps.isNotEmpty) ObKeyCombo(p: p, parts: widget.caps),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
