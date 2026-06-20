import 'dart:async';

import 'package:capecho_api/capecho_api.dart' show CapechoApi, Rating;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import 'illustrations.dart';

/// The mobile Review session (US-1.1 context-front review · US-1.2 server FSRS · US-12.1 offline),
/// tap-driven. It shares [ReviewController] and the card rendering semantics with the macOS Review
/// window — only the input model (tap vs keyboard) and layout (portrait vs window) differ. Built 1:1
/// against DESIGN.md, states 6–14.
///
/// Returns a plain widget (no Scaffold): it's the home — it lives inside `HomeShell`'s Scaffold + SafeArea,
/// on the warm canvas, beneath the two floating corner buttons (Settings · Word Book).
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.api,
    this.explanationLanguage = 'en',
    this.pendingReviewWord,
    this.reviewRefresh,
  });

  final CapechoApi api;
  final String explanationLanguage;

  /// A word the review widget deep-linked to (set by the root on a `capecho://review?word=…` tap). The
  /// screen jumps its controller to it and consumes it (resets to null). Null in tests / no widget.
  final ValueNotifier<String?>? pendingReviewWord;

  /// Pinged on app resume (after widget grades drain) so the session re-syncs to current server truth —
  /// cards reviewed in the widget / on another device drop out. Null in tests / when there's no widget.
  final Listenable? reviewRefresh;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  late final ReviewController _c;

  @override
  void initState() {
    super.initState();
    _c = ReviewController(api: widget.api, explanationLanguage: widget.explanationLanguage);
    _c.start();
    widget.pendingReviewWord?.addListener(_onPendingWord);
    _onPendingWord(); // a deep link that arrived before this screen mounted (cold start)
    widget.reviewRefresh?.addListener(_onReviewRefresh);
  }

  /// App resumed (the root drained the widget's grades first): re-sync the queue so anything reviewed
  /// in the widget — or on another device — drops out. Gentle by design (see [ReviewController.refresh]).
  void _onReviewRefresh() => unawaited(_c.refresh());

  /// Jump the session to the widget deep-link's word, then consume it (reset to null so a repeat tap of
  /// the SAME word re-fires). [ReviewController.focusWord] is a no-op until its queue is loaded, then
  /// applies, so this is safe to call any time.
  void _onPendingWord() {
    final wordId = widget.pendingReviewWord?.value;
    if (wordId == null) return;
    _c.focusWord(wordId);
    widget.pendingReviewWord!.value = null;
  }

  @override
  void dispose() {
    widget.pendingReviewWord?.removeListener(_onPendingWord);
    widget.reviewRefresh?.removeListener(_onReviewRefresh);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        switch (_c.phase) {
          case ReviewPhase.card:
            return _session(p);
          case ReviewPhase.loading:
            // Card-prep state: the animated echo sweep ("working"). The resting states below keep the
            // STATIC mark (disambiguation rule).
            return _centerCol(
              p,
              faded: false,
              title: 'Bringing your words back…',
              art: ObEchoLoader(color: p.primary, size: 52),
            );
          case ReviewPhase.signedOut:
            // Unreachable in practice (the shell only mounts Review when signed in); kept calm.
            return _centerCol(
              p,
              faded: true,
              title: 'Sign in to review',
              body:
                  'Your review schedule lives in the cloud. Sign in to bring your words to this phone.',
            );
          case ReviewPhase.error:
            return _centerCol(
              p,
              faded: true,
              title: 'Review didn’t load',
              body: _c.error ?? 'Couldn’t load your review.',
              action: ObPrimaryButton(p: p, label: 'Try again', onPressed: _c.retry),
            );
          case ReviewPhase.allCaughtUp:
            return _centerCol(
              p,
              faded: true,
              art: const ReviewedStackIllustration(),
              title: 'All caught up',
              body: 'Nothing due right now. Your words are resting in memory.',
              action: ObQuietButton(p: p, label: 'Review again', onPressed: _c.start),
            );
          case ReviewPhase.nothingCaptured:
            return _centerCol(
              p,
              faded: true,
              art: const WordBookEmptyArt(width: 184),
              title: 'Your words will appear here',
              body:
                  'Capture words with ⌥E while you read on your Mac — they’ll arrive here to review.',
            );
          case ReviewPhase.done:
            return _centerCol(
              p,
              faded: true,
              title: 'That’s the set.',
              body: 'Your words are settling back into memory.',
              footnote: '${_c.reviewedCount} reviewed today',
              action: ObQuietButton(p: p, label: 'Review again', onPressed: _c.start),
            );
        }
      },
    );
  }

  // ---- card session (front / back) -----------------------------------------

  Widget _session(OnboardingPalette p) {
    final card = _c.current!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _head(p),
          if (_c.offlineRatingLabel != null) ...[
            const SizedBox(height: 12),
            reviewSyncBadge(p, _c.offlineRatingLabel!),
          ],
          const SizedBox(height: 12),
          // A 3D flip between the prompt (front) and the answer (back), using the shared FlipCard. Only
          // the FRONT is tap-to-flip (via `_frontTappable`); the back has no flip-back tap — review is
          // forward-only (you rate to advance), unlike macOS which wraps the whole card so a back-tap
          // toggles. The session index is the card identity, so advancing jumps straight to the next
          // front with no turn across the swap.
          Expanded(
            child: FlipCard(
              showBack: _c.showBack,
              cardId: _c.index,
              front: _frontTappable(p, card),
              back: _back(p, card),
            ),
          ),
        ],
      ),
    );
  }

  /// Session header: "i / n" + progress bar + (offline) queued pill.
  Widget _head(OnboardingPalette p) {
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

  /// The front, made tappable to flip ("Tap to reveal meaning"). Exposed to screen readers as a button —
  /// the tap is the only flip affordance on the phone (no keyboard), so it must be labeled.
  Widget _frontTappable(OnboardingPalette p, ReviewCardModel card) => Semantics(
    button: true,
    label: 'Reveal meaning',
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _c.flip,
      child: _front(p, card),
    ),
  );

  Widget _front(OnboardingPalette p, ReviewCardModel card) {
    final hasCtx = card.contextLoaded && card.hasContext;
    // Has-context: the captured sentence sits at the top and scrolls if long. Bare: the unit is
    // centered. Either way the flip hint is pinned to the bottom of the card (Expanded fills between).
    final Widget middle = hasCtx
        ? SingleChildScrollView(
            child: _sentence(
              p,
              card.context!.contextText,
              card.context!.spanStart,
              card.context!.spanEnd,
            ),
          )
        : Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${langName(card.targetLanguage)} · learning',
                  style: p.chrome(
                    size: 11,
                    weight: FontWeight.w600,
                    color: p.ink3,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  card.unit,
                  textAlign: TextAlign.center,
                  style: p.display(size: 38, color: p.ink, height: 1.1),
                ),
              ],
            ),
          );
    return reviewCardShell(
      p,
      radius: 14,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
      children: [
        _task(p, hasCtx ? 'Do you know this word here?' : 'Do you know this word?'),
        const SizedBox(height: 16),
        Expanded(child: middle),
        _flipHint(p),
      ],
    );
  }

  Widget _back(OnboardingPalette p, ReviewCardModel card) {
    return reviewCardShell(
      p,
      radius: 14,
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
      children: [
        _backHead(p, card),
        _readingLine(p, card),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _meaning(p, card),
                if (card.contextLoaded && card.hasContext)
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
            ),
          ),
        ),
        const SizedBox(height: 12),
        _ratings(p),
      ],
    );
  }

  Widget _backHead(OnboardingPalette p, ReviewCardModel card) {
    // Headword + flush-right target-language label. The part of speech is not a chip here — it sits
    // inline on each sense line, matching the overlay.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: FittedBox(
            alignment: Alignment.centerLeft,
            fit: BoxFit.scaleDown,
            child: Text(
              card.unit,
              maxLines: 1,
              overflow: TextOverflow.visible,
              softWrap: false,
              style: p.display(size: 30, color: p.ink, height: 1.05),
            ),
          ),
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
        // The answer body is the per-POS senses, one line per POS — the SAME format as the capture
        // overlay, the word's senses in full (no cap); still minimal (E7), dimmed to ink2. POS sits
        // inline on each line; IPA stays in the head, so pronunciation is suppressed here.
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: SenseModules(
            p: p,
            explanation: card.explanation!,
            targetLanguage: card.targetLanguage,
            senseSize: 16,
            senseColor: p.ink2,
            showPronunciation: false,
            showPosLabels: true,
          ),
        );
      case MeaningStatus.unsupported:
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Meaning not available for this language yet.',
            style: p.body(size: 15.5, color: p.ink3, fontStyle: FontStyle.italic),
          ),
        );
      case MeaningStatus.unavailable:
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Meaning unavailable right now — the word is still reviewable.',
            style: p.body(size: 15.5, color: p.ink3, fontStyle: FontStyle.italic),
          ),
        );
      case MeaningStatus.loading:
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Preparing the meaning…',
            style: p.body(size: 15.5, color: p.ink3, fontStyle: FontStyle.italic),
          ),
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
      margin: const EdgeInsets.only(top: 14),
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
          _sentence(p, text, start, end, size: 14, italic: true),
          // Capture provenance ("where I met this word"), quiet under the sentence.
          if (source != null) ...[const SizedBox(height: 8), source],
          // The saved "Explain here" gloss (word-in-context + whole sentence) — same warm left-rule
          // callout as the Word Book detail. Shown only when one was generated.
          if (gloss != null) ...[
            const SizedBox(height: 10),
            reviewGlossCallout(p, gloss, size: 13.5),
          ],
        ],
      ),
    );
  }

  Widget _ratings(OnboardingPalette p) => Row(
    children: [
      Expanded(child: _rateBtn(p, p.error, 'Forget', Rating.again)),
      const SizedBox(width: 7),
      Expanded(child: _rateBtn(p, p.warning, 'Hard', Rating.hard)),
      const SizedBox(width: 7),
      Expanded(child: _rateBtn(p, p.success, 'Good', Rating.good)),
      const SizedBox(width: 7),
      Expanded(child: _rateBtn(p, p.info, 'Easy', Rating.easy)),
    ],
  );

  Widget _rateBtn(OnboardingPalette p, Color tone, String label, Rating rating) {
    final fg = p.dark ? Color.lerp(tone, Colors.white, 0.45)! : tone;
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: Color.alphaBlend(tone.withValues(alpha: 0.14), p.card),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _c.rate(rating),
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: tone.withValues(alpha: 0.35)),
            ),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: p.chrome(size: 13, weight: FontWeight.w600, color: fg),
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

  Widget _flipHint(OnboardingPalette p) => Container(
    margin: const EdgeInsets.only(top: 14),
    padding: const EdgeInsets.only(top: 14),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: p.line)),
    ),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        ObEchoMark(color: p.ink3, size: 15, ringOpacities: const [0.34, 0.34, 0.34]),
        const SizedBox(width: 7),
        Text('Tap to reveal meaning', style: p.chrome(size: 12, color: p.ink3)),
      ],
    ),
  );

  /// Render a context sentence with the captured span highlighted (latte wash + coffee underline).
  /// Clamps to the captured offsets; an invalid/empty span falls back to plain text (CJK-safe — no
  /// lemma re-find). Mirrors the macOS Review card.
  Widget _sentence(
    OnboardingPalette p,
    String text,
    int? start,
    int? end, {
    double size = 19,
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

  // ---- rest states (loading / done / caught-up / nothing / error) ----------

  Widget _centerCol(
    OnboardingPalette p, {
    required bool faded,
    required String title,
    String? body,
    String? footnote,
    Widget? action,
    Widget? art,
  }) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            art ??
                ObEchoMark(
                  color: p.primary,
                  size: 52,
                  ringOpacities: faded ? const [0.34, 0.34, 0.34] : const [1, 1, 1],
                ),
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: p.display(size: 22, color: p.ink),
            ),
            if (body != null) ...[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  body,
                  textAlign: TextAlign.center,
                  style: p.body(size: 14.5, height: 1.55, color: p.ink2),
                ),
              ),
            ],
            if (footnote != null) ...[
              const SizedBox(height: 14),
              Text(footnote, style: p.mono(size: 13, color: p.primary)),
            ],
            if (action != null) ...[const SizedBox(height: 20), action],
          ],
        ),
      ),
    );
  }
}
