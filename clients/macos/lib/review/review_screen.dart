import 'package:capecho_api/capecho_api.dart' show CapechoApi, Rating;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../backend/distribution.dart';
import '../capture_shortcut_scope.dart';

/// The macOS Review window (US-1.1): keyboard-first, context-front flashcards over the
/// server-authoritative FSRS. `1/2/3/4` rate (Forget/Hard/Good/Easy), `Space`/`⏎` flip,
/// `Esc` closes. Card behavior mirrors the future mobile sibling; only the entry (a window)
/// and input model (keyboard) differ. Visuals follow `DESIGN.md`.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.api,
    this.auth,
    this.explanationLanguage = 'en',
    this.onClose,
  });

  final CapechoApi api;

  /// The sign-in controller — drives the signed-out gate's inline [SignInPanel] and re-loads the queue
  /// when the user signs in. Null in tests / hosts that don't wire auth (the gate then shows the
  /// explainer with a pointer to Settings instead of the panel).
  final AuthController? auth;

  final String explanationLanguage;

  /// Dismiss the surface. The agent app supplies `hideWindow` (close = hide the window, return to the
  /// menu bar — there is no shell to pop back to). Null falls back to `Navigator.maybePop` (tests / a
  /// nested host).
  final VoidCallback? onClose;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

// The four rating tones are the semantic tokens, all now on the palette:
// again=p.error (oxblood), hard=p.warning, good=p.success, easy=p.info (slate).

class _ReviewScreenState extends State<ReviewScreen> {
  late final ReviewController _c;
  final FocusNode _focus = FocusNode(debugLabel: 'review');

  /// Tracks the auth sign-in state so a flip (signed in via the gate's panel, or signed out) restarts
  /// the session — into the real queue, or back to the gate.
  bool? _wasSignedIn;

  @override
  void initState() {
    super.initState();
    _c = ReviewController(api: widget.api, explanationLanguage: widget.explanationLanguage);
    _c.start();
    _wasSignedIn = widget.auth?.isSignedIn ?? false;
    widget.auth?.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.auth?.removeListener(_onAuthChanged);
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Restart the session when the sign-in state flips (auth fires on busy/error too — the guard keeps
  /// this to genuine sign-in/out transitions).
  void _onAuthChanged() {
    final signedIn = widget.auth?.isSignedIn ?? false;
    if (_wasSignedIn != signedIn) {
      _wasSignedIn = signedIn;
      _c.start();
    }
  }

  void _close() {
    final close = widget.onClose;
    if (close != null) {
      // Agent: collapse this surface back to the hidden host THEN hide the window, so re-opening a
      // DIFFERENT surface doesn't briefly flash this (now stale) one. No shell to return to.
      Navigator.of(context).popUntil((r) => r.isFirst);
      close();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  Rating? _ratingForKey(LogicalKeyboardKey k) {
    if (k == LogicalKeyboardKey.digit1 || k == LogicalKeyboardKey.numpad1) {
      return Rating.again;
    }
    if (k == LogicalKeyboardKey.digit2 || k == LogicalKeyboardKey.numpad2) {
      return Rating.hard;
    }
    if (k == LogicalKeyboardKey.digit3 || k == LogicalKeyboardKey.numpad3) {
      return Rating.good;
    }
    if (k == LogicalKeyboardKey.digit4 || k == LogicalKeyboardKey.numpad4) {
      return Rating.easy;
    }
    return null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    // Esc, or ⌘W (standard macOS close-window) → back to the menu-bar agent (bug #3).
    if (k == LogicalKeyboardKey.escape ||
        (k == LogicalKeyboardKey.keyW && HardwareKeyboard.instance.isMetaPressed)) {
      _close();
      return KeyEventResult.handled;
    }
    final isEnter = k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter;
    final isSpace = k == LogicalKeyboardKey.space;
    switch (_c.phase) {
      case ReviewPhase.card:
        if (isSpace || isEnter) {
          _c.flip();
          return KeyEventResult.handled;
        }
        if (_c.showBack) {
          final r = _ratingForKey(k);
          if (r != null) {
            _c.rate(r);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      case ReviewPhase.done:
      case ReviewPhase.allCaughtUp:
      case ReviewPhase.nothingCaptured:
        if (isEnter) {
          _close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case ReviewPhase.error:
        if (isEnter) {
          _c.retry();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case ReviewPhase.signedOut:
        return KeyEventResult.ignored; // the inline sign-in panel owns its own input
      case ReviewPhase.loading:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: p.canvas,
        body: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            // The card fills the window up to a comfortable reading measure, then centers and holds
            // that width. 680 lets the card breathe on a wide window instead of sitting in a fixed
            // narrow column, while keeping the sentence line length readable.
            // The card phase has no SurfaceHeader (it carries its own progress header), so it must
            // reserve the macOS immersive title bar's traffic-light strip itself — otherwise the
            // progress row sits jammed under the floating lights. Other phases get it via the header.
            final isCard = _c.phase == ReviewPhase.card;
            final body = Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(24, isCard ? 18 + macTitleBarInset : 18, 24, 24),
                  child: _forPhase(p),
                ),
              ),
            );
            // The card phase carries its OWN progress header (index/total + bar) and fills the whole
            // window — stacking the shared brand header above it too would overflow the 640×440
            // minimum. So only the loading / rest / done / error phases wear the SurfaceHeader; the
            // card phase keeps its progress header.
            if (_c.phase == ReviewPhase.card) return body;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SurfaceHeader(p: p, title: 'Review'),
                Expanded(child: body),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _forPhase(OnboardingPalette p) {
    switch (_c.phase) {
      case ReviewPhase.signedOut:
        return _signedOutGate(p);
      case ReviewPhase.loading:
        return _rest(p, echoFaded: false, loading: true, title: 'Bringing your words back…');
      case ReviewPhase.error:
        return _rest(
          p,
          echoFaded: true,
          title: 'Review didn’t load',
          body: _c.error ?? 'Couldn’t load your review.',
          action: ObPrimaryButton(p: p, label: 'Try again', onPressed: _c.retry),
        );
      case ReviewPhase.allCaughtUp:
        return _rest(
          p,
          echoFaded: true,
          title: 'All caught up',
          body: 'Nothing due right now. Your words are resting in memory.',
        );
      case ReviewPhase.nothingCaptured:
        final captureDisplay = CaptureShortcutScope.displayOf(context);
        return _rest(
          p,
          echoFaded: true,
          title: 'Your words will appear here',
          body:
              'Capture words with $captureDisplay while you read on this Mac — '
              'they’ll arrive here to review.',
        );
      case ReviewPhase.done:
        return _rest(
          p,
          echoFaded: true,
          title: 'That’s the set.',
          body: 'Your words are settling back into memory.',
          footnote: '${_c.reviewedCount} reviewed today',
          action: ObQuietButton(p: p, label: 'Done', onPressed: _close),
          closeHint: 'Esc or ⏎ to close',
        );
      case ReviewPhase.card:
        return _session(p);
    }
  }

  /// The signed-out Review gate. Review is server-authoritative (the client never computes FSRS
  /// intervals), so instead of a fetch error we explain — warmly — that the schedule lives in the
  /// cloud (a streak syncs across devices) and offer the shared sign-in panel right here.
  Widget _signedOutGate(OnboardingPalette p) {
    final auth = widget.auth;
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ObEchoMark(color: p.primary, size: 40),
          const SizedBox(height: 18),
          Text(
            'Review syncs across your devices',
            textAlign: TextAlign.center,
            style: p.display(size: 22, color: p.ink),
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Text(
              'Your spaced-repetition schedule lives in the cloud, so each word comes back at the right '
              'time on every device. Sign in to start reviewing — the words you’ve captured stay on '
              'this Mac until you choose to sync them.',
              textAlign: TextAlign.center,
              style: p.body(size: 15, height: 1.6, color: p.ink2),
            ),
          ),
          const SizedBox(height: 24),
          if (auth != null)
            SignInPanel(p: p, auth: auth, appleAvailable: isMacAppStoreBuild())
          else
            Text(
              'Sign in from Settings or the menu bar to begin.',
              textAlign: TextAlign.center,
              style: p.chrome(size: 13, color: p.ink3),
            ),
        ],
      ),
    );
  }

  // ---- card session (front / back) -----------------------------------------

  Widget _session(OnboardingPalette p) {
    final card = _c.current!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(p),
        // A per-rating "saved, will sync" badge when the last rating queued offline. The app advances
        // optimistically the instant you rate, so the rated card is already gone — we surface the
        // confirmation just under the header instead, where it tracks the real offline queue.
        if (_c.offlineRatingLabel != null) ...[
          const SizedBox(height: 12),
          reviewSyncBadge(p, _c.offlineRatingLabel!),
        ],
        const SizedBox(height: 14),
        // Tap anywhere on the card to flip it (the pointer twin of Space / ⏎); the rating buttons on
        // the back keep their own taps (the inner InkWell wins the gesture arena).
        Expanded(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Semantics(
              button: true,
              label: _c.showBack ? 'Show prompt' : 'Reveal meaning',
              child: GestureDetector(
                onTap: _c.flip,
                child: FlipCard(
                  showBack: _c.showBack,
                  cardId: _c.index,
                  front: _front(p, card),
                  back: _back(p, card),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _header(OnboardingPalette p) {
    final pct = _c.total == 0 ? 0.0 : (_c.index / _c.total).clamp(0.0, 1.0);
    return Row(
      children: [
        Text('${_c.index + 1} / ${_c.total}', style: p.mono(size: 12, color: p.ink3)),
        const SizedBox(width: 10),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 4,
              backgroundColor: p.line,
              valueColor: AlwaysStoppedAnimation(p.primary),
            ),
          ),
        ),
        if (_c.pendingSyncCount > 0) ...[
          const SizedBox(width: 10),
          reviewOfflinePill(p, _c.pendingSyncCount),
        ],
      ],
    );
  }

  Widget _front(OnboardingPalette p, ReviewCardModel card) {
    final hasCtx = card.contextLoaded && card.hasContext;
    return reviewCardShell(
      p,
      children: [
        _task(p, hasCtx ? 'Do you know this word here?' : 'Do you know this word?'),
        const SizedBox(height: 18),
        if (hasCtx)
          _sentence(p, card.context!.contextText, card.context!.spanStart, card.context!.spanEnd)
        else ...[
          const Spacer(),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  langName(card.targetLanguage),
                  style: p.chrome(
                    size: 11,
                    weight: FontWeight.w600,
                    color: p.ink3,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  card.unit,
                  textAlign: TextAlign.center,
                  style: p.display(size: 44, color: p.ink, height: 1.1),
                ),
              ],
            ),
          ),
        ],
        const Spacer(),
        _flipHint(p),
      ],
    );
  }

  Widget _back(OnboardingPalette p, ReviewCardModel card) {
    return reviewCardShell(
      p,
      children: [
        _backHead(p, card),
        _readingLine(p, card),
        const SizedBox(height: 12),
        // The answer body scrolls (the meaning + the captured sentence can run long), with the rating
        // row pinned below — mirrors the mobile back.
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _meaning(p, card),
                if (card.contextLoaded && card.hasContext) ...[
                  const SizedBox(height: 14),
                  _yourSentence(
                    p,
                    card.context!.contextText,
                    card.context!.spanStart,
                    card.context!.spanEnd,
                    sourceApp: card.context!.sourceApp,
                    sourceTitle: card.context!.sourceTitle,
                    meaning: card.context!.meaning,
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _ratings(p),
      ],
    );
  }

  Widget _backHead(OnboardingPalette p, ReviewCardModel card) {
    // The headrow is the headword + the flush-right target-language label. The part of speech is no
    // longer a chip here — it sits inline on each sense line (founder request: POS per line, matching
    // the overlay). The Expanded unit owns the slack so the label sits flush right.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(card.unit, style: p.display(size: 30, color: p.ink, height: 1.1)),
        ),
        const SizedBox(width: 12),
        Text(
          langName(card.targetLanguage),
          style: p.chrome(size: 11, weight: FontWeight.w600, color: p.ink3, letterSpacing: 0.4),
        ),
      ],
    );
  }

  /// The word's reading (IPA), mono ink-3, on its own line beneath the head — the primary slot (else
  /// secondary) of a single-reading word. Suppressed for a heteronym (one line can't carry two distinct
  /// pronunciations; the summary covers it) and when the explanation omitted pronunciation.
  Widget _readingLine(OnboardingPalette p, ReviewCardModel card) {
    final readings = card.explanation?.readings ?? const [];
    if (readings.length != 1) return const SizedBox.shrink();
    final r = readings.single;
    final ipa = r.pronunciationPrimary.isNotEmpty
        ? r.pronunciationPrimary
        : (r.pronunciationSecondary.isNotEmpty ? r.pronunciationSecondary : '');
    if (ipa.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text('/$ipa/', style: p.mono(size: 13, color: p.ink3)),
    );
  }

  Widget _meaning(OnboardingPalette p, ReviewCardModel card) {
    switch (card.meaningStatus) {
      case MeaningStatus.ready:
        // The answer body IS the per-POS senses, one line per POS — the SAME format as the capture
        // overlay, the word's senses in full (no cap anywhere); still minimal (E7) — dimmed to ink2,
        // no IPA, no POS column (the head chip carries the POS).
        return SenseModules(
          p: p,
          explanation: card.explanation!,
          targetLanguage: card.targetLanguage,
          senseSize: 17,
          senseColor: p.ink2,
          // The POS sits inline on each line (founder request — matching the overlay), so it's no
          // longer a head chip. The IPA stays in the head; senses dimmed to ink2.
          showPronunciation: false,
          showPosLabels: true,
        );
      case MeaningStatus.unsupported:
        return Text(
          'Meaning not available for this language yet.',
          style: p.body(size: 16, color: p.ink3, fontStyle: FontStyle.italic),
        );
      case MeaningStatus.unavailable:
        return Text(
          'Meaning unavailable right now — the word is still reviewable.',
          style: p.body(size: 16, color: p.ink3, fontStyle: FontStyle.italic),
        );
      case MeaningStatus.loading:
        return Text(
          'Preparing the meaning…',
          style: p.body(size: 16, color: p.ink3, fontStyle: FontStyle.italic),
        );
    }
  }

  Widget _yourSentence(
    OnboardingPalette p,
    String text,
    int? start,
    int? end, {
    String? sourceApp,
    String? sourceTitle,
    String? meaning,
  }) {
    final source = captureSourceCaption(p, sourceApp: sourceApp, sourceTitle: sourceTitle);
    final gloss = (meaning != null && meaning.trim().isNotEmpty) ? meaning : null;
    return Container(
      padding: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'YOUR SENTENCE',
            style: p.chrome(size: 10, weight: FontWeight.w600, color: p.ink3, letterSpacing: 0.6),
          ),
          const SizedBox(height: 5),
          _sentence(p, text, start, end, size: 15, italic: true),
          // Capture provenance ("where I met this word"), quiet under the sentence.
          if (source != null) ...[const SizedBox(height: 8), source],
          // The saved "Explain here" gloss (word-in-context + whole sentence) — a warm left-rule callout
          // attached to the sentence, mirroring the Word Book detail. Shown only when one was generated.
          if (gloss != null) ...[const SizedBox(height: 10), reviewGlossCallout(p, gloss)],
        ],
      ),
    );
  }

  Widget _ratings(OnboardingPalette p) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Row(
        children: [
          Expanded(child: _rateBtn(p, p.error, '1', 'Forget', Rating.again)),
          const SizedBox(width: 8),
          Expanded(child: _rateBtn(p, p.warning, '2', 'Hard', Rating.hard)),
          const SizedBox(width: 8),
          Expanded(child: _rateBtn(p, p.success, '3', 'Good', Rating.good)),
          const SizedBox(width: 8),
          Expanded(child: _rateBtn(p, p.info, '4', 'Easy', Rating.easy)),
        ],
      ),
    );
  }

  Widget _rateBtn(OnboardingPalette p, Color tone, String key, String label, Rating rating) {
    final fg = p.dark ? Color.lerp(tone, Colors.white, 0.45)! : tone;
    return Semantics(
      button: true,
      label: '$label (key $key)',
      child: Material(
        color: Color.alphaBlend(tone.withValues(alpha: 0.14), p.card),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          // Non-focusable: the screen's top-level Focus is the sole keyboard authority, so Tab can't
          // land on a rate button and let Space/⏎ activate it instead of flipping the card. Mouse taps
          // still work; keys are 1/2/3/4 (rate) + Space/⏎ (flip) handled at the top.
          canRequestFocus: false,
          onTap: () => _c.rate(rating),
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: tone.withValues(alpha: 0.35)),
            ),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            // The key cap + label sit on ONE row (gap 6), centered — not stacked. Flexible + ellipsis
            // keeps the four buttons from overflowing a narrow window.
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _keycap(p, key, color: fg),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: p.chrome(size: 13, weight: FontWeight.w600, color: fg),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- small parts ----------------------------------------------------------

  Widget _task(OnboardingPalette p, String text) => Text(
    text.toUpperCase(),
    style: p.chrome(size: 11, weight: FontWeight.w600, color: p.ink3, letterSpacing: 0.55),
  );

  Widget _sentence(
    OnboardingPalette p,
    String text,
    int? start,
    int? end, {
    double size = 21,
    bool italic = false,
  }) {
    final base = p.body(
      size: size,
      height: italic ? 1.55 : 1.6,
      color: italic ? p.ink3 : p.ink,
      fontStyle: italic ? FontStyle.italic : null,
    );
    final valid = start != null && end != null && start >= 0 && end <= text.length && start < end;
    if (!valid) return Text(text, style: base);
    final hl = base.copyWith(
      color: p.chipFg,
      backgroundColor: p.chip,
      fontWeight: FontWeight.w600,
      fontStyle: FontStyle.normal,
      decoration: TextDecoration.underline,
      decorationColor: p.primary,
    );
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          TextSpan(text: text.substring(0, start)),
          TextSpan(text: text.substring(start, end), style: hl),
          TextSpan(text: text.substring(end)),
        ],
      ),
    );
  }

  Widget _keycap(OnboardingPalette p, String label, {Color? color}) {
    // Single glyphs (1–4, ⏎) are fixed 24×24 squares; multi-char caps (Space, Esc) keep the min-width
    // + side padding. Pinning the square keeps every cap uniform regardless of the glyph's own width.
    final single = label.runes.length == 1;
    return Container(
      height: 24,
      width: single ? 24 : null,
      constraints: single ? null : const BoxConstraints(minWidth: 24),
      alignment: Alignment.center,
      padding: single ? null : const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: p.card,
        border: Border.all(color: (color ?? p.edge).withValues(alpha: 0.45)),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(label, style: p.mono(size: 12, color: color ?? p.ink)),
    );
  }

  Widget _flipHint(OnboardingPalette p) => Container(
    margin: const EdgeInsets.only(top: 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // A DASHED hairline separates it from the card body (not a solid rule).
        _DashedLine(color: p.line),
        const SizedBox(height: 22),
        // Just `Press [Space] to flip` — ⏎ still flips (see `_onKey`), it's only dropped from the
        // hint to keep the line quiet; Space is the one key worth teaching.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Press ', style: p.chrome(size: 12.5, color: p.ink2)),
            _keycap(p, 'Space'),
            Text(' to flip', style: p.chrome(size: 12.5, color: p.ink2)),
          ],
        ),
      ],
    ),
  );

  // ---- rest states (loading / done / caught-up / nothing / error) ----------

  Widget _rest(
    OnboardingPalette p, {
    required bool echoFaded,
    required String title,
    bool loading = false,
    String? body,
    String? footnote,
    Widget? action,
    String closeHint = 'Esc to close',
  }) {
    // The rest + loading states center their content below the shared SurfaceHeader (the card phase
    // shows the progress header instead). The header is drawn by the screen's build, not here.
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Loading = the animated echo sweep ("working"); the resting states (done /
        // caught-up / nothing / error) keep the STATIC mark (faded = memory at rest) —
        // the disambiguation rule (DESIGN.md): motion only ever means "working".
        if (loading)
          ObEchoLoader(color: p.primary, size: 52)
        else
          ObEchoMark(
            color: p.primary,
            size: 52,
            ringOpacities: echoFaded ? const [0.34, 0.34, 0.34] : const [1, 1, 1],
          ),
        const SizedBox(height: 20),
        Text(
          title,
          textAlign: TextAlign.center,
          style: p.display(size: 24, color: p.ink),
        ),
        if (body != null) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              body,
              textAlign: TextAlign.center,
              style: p.body(size: 15.5, color: p.ink2),
            ),
          ),
        ],
        if (footnote != null) ...[
          const SizedBox(height: 14),
          Text(footnote, style: p.mono(size: 13, color: p.primary)),
        ],
        if (action != null) ...[const SizedBox(height: 18), action],
        const SizedBox(height: 22),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _keycap(p, 'Esc'),
            const SizedBox(width: 7),
            Text(closeHint.replaceFirst('Esc ', ''), style: p.chrome(size: 11.5, color: p.ink3)),
          ],
        ),
      ],
    );
  }
}

/// A card that flips on its Y axis between [front] and [back] when [showBack] toggles — the click /
/// Space / ⏎ "flip" given a physical card turn instead of an instant swap. Changing [cardId]
/// (advancing to the next card) snaps straight to the front with no animation, so a rate → advance
/// never plays a confusing reverse spin through the next card's back.
/// A 1px DASHED hairline — Flutter has no dashed `BorderSide`, so it's painted: short dashes with
/// gaps, in [color].
class _DashedLine extends StatelessWidget {
  const _DashedLine({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 1,
    width: double.infinity,
    child: CustomPaint(painter: _DashPainter(color)),
  );
}

class _DashPainter extends CustomPainter {
  _DashPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const dash = 4.0, gap = 3.0;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, 0.5), Offset((x + dash).clamp(0.0, size.width), 0.5), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_DashPainter old) => old.color != color;
}
