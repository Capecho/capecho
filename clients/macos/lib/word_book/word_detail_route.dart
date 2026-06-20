import 'package:capecho_api/capecho_api.dart' show ContextView;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A word's **detail**, pushed when a catalog row is tapped: a back-nav masthead, the unit header
/// (unit + POS + target language + memory meter), the free meaning, and ALL saved contexts with the
/// paid "Explain in this sentence" affordance + per-context edit/remove. The unit itself is immutable
/// — only the context sentence + its gloss are editable here.
///
/// The per-context paid "Explain in this sentence" UI phase. A persisted gloss (`ContextView.gloss`) is
/// the success state and is data-driven (not here); an absent entry = idle (the CTA shows).
enum _ExplainPhase { generating, quota, offline, failed }

class WordDetailRoute extends StatefulWidget {
  const WordDetailRoute({super.key, required this.controller, required this.entry});

  final WordBookController controller;
  final WordBookEntry entry;

  @override
  State<WordDetailRoute> createState() => _WordDetailRouteState();
}

class _WordDetailRouteState extends State<WordDetailRoute> {
  final FocusNode _focus = FocusNode(debugLabel: 'wordbook-detail');

  // The captured unit is IMMUTABLE — no word-text edit (see the capecho-units-immutable decision).
  // Only the context sentence + its gloss are editable, and those edit/remove/explain calls are REAL.
  final Map<String, TextEditingController> _ctxDrafts = {}; // ctx.id → draft (presence = editing)
  final Set<String> _editedCtx =
      {}; // ctx ids edited this session → render without the (now-stale) span hl
  final Map<String, String> _ctxError = {}; // ctx.id → inline edit error (empty/too-large/offline)
  final Map<String, _ExplainPhase> _explain = {}; // ctx.id → paid-explain phase (absent = idle)
  // Tap-to-hear audio is deferred — the speaker is removed and the buttons hidden. Re-add once the
  // backend audio-cache lands; see CHANGELOG. The reading rows show US/UK IPA only.

  @override
  void initState() {
    super.initState();
    // Make sure this word's detail is loading (no-op if the catalog tap already started it).
    widget.controller.select(widget.entry.id);
  }

  @override
  void dispose() {
    _focus.dispose();
    for (final c in _ctxDrafts.values) {
      c.dispose();
    }
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Esc, or ⌘W (standard macOS close) → cancel an edit, else close this detail (bug #3).
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.escape ||
            (event.logicalKey == LogicalKeyboardKey.keyW &&
                HardwareKeyboard.instance.isMetaPressed))) {
      // Esc cancels an in-progress context edit first; otherwise it closes the detail.
      if (_ctxDrafts.isNotEmpty) {
        setState(() {
          for (final c in _ctxDrafts.values) {
            c.dispose();
          }
          _ctxDrafts.clear();
        });
      } else {
        Navigator.of(context).maybePop();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ---- actions -------------------------------------------------------------

  void _deleteUnit() {
    final id = widget.entry.id;
    final unit = widget.entry.unit;
    // Grab the messenger before we pop — it lives above this route, so it survives back to the catalog.
    final messenger = ScaffoldMessenger.of(context);
    widget.controller.deleteEntry(
      id,
    ); // soft-delete (persists DELETE /words/{id}) → Recently deleted
    Navigator.of(context).maybePop();
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('Deleted “$unit” — it’s in Recently deleted.'),
          // Undo restores it (POST /words/{id}/restore — preserves its FSRS, unlike re-capturing).
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => widget.controller.restoreEntry(id),
          ),
        ),
      );
  }

  void _startEditCtx(ContextView c) => setState(() {
    _ctxError.remove(c.id);
    // Editing changes the sentence, so any prior explain result/error (quota/offline/failed) is now
    // moot — clear it so it doesn't linger under the edited sentence + the CTA returns.
    _explain.remove(c.id);
    _ctxDrafts[c.id] = TextEditingController(text: c.contextText);
  });
  void _cancelEditCtx(ContextView c) => setState(() {
    _ctxDrafts.remove(c.id)?.dispose();
    _ctxError.remove(c.id);
  });

  /// Save an edited context (real `PATCH /contexts/{id}`). On success the field closes and the sentence
  /// renders without its now-stale-span highlight; on failure the field stays with an inline error.
  Future<void> _saveCtx(ContextView c) async {
    final draft = _ctxDrafts[c.id];
    if (draft == null) return;
    final text = draft.text;
    setState(() => _ctxError.remove(c.id));
    final err = await widget.controller.editContext(widget.entry, c.id, text);
    if (!mounted) return;
    setState(() {
      if (err != null) {
        _ctxError[c.id] = err; // keep editing; show the inline error
      } else {
        _editedCtx.add(c.id);
        _ctxDrafts.remove(c.id)?.dispose();
      }
    });
  }

  /// Remove a context (real `DELETE /contexts/{id}`).
  Future<void> _removeCtx(ContextView c) async {
    final err = await widget.controller.removeContext(widget.entry, c.id);
    if (!mounted || err == null) return;
    _toast(err);
  }

  /// The paid "Explain in this sentence" call (real `POST /explain/context`). generating → ready (the
  /// stored gloss renders) / quota / offline / failed (retryable).
  Future<void> _explainCtx(ContextView c) async {
    if (_explain[c.id] == _ExplainPhase.generating) return; // already in flight
    setState(() => _explain[c.id] = _ExplainPhase.generating);
    final outcome = await widget.controller.explainContext(widget.entry, c.id);
    if (!mounted) return;
    setState(() {
      _explain.remove(c.id);
      final phase = switch (outcome) {
        ContextExplainOutcome.ready => null, // the gloss (now on the context) renders
        ContextExplainOutcome.quota => _ExplainPhase.quota,
        ContextExplainOutcome.offline => _ExplainPhase.offline,
        ContextExplainOutcome.failed => _ExplainPhase.failed,
      };
      if (phase != null) _explain[c.id] = phase;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    final e = widget.entry;
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: p.canvas,
        body: AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SurfaceHeader(
                p: p,
                onBack: () => Navigator.of(context).maybePop(),
                backLabel: 'Word Book',
              ),
              Expanded(
                // The ListView fills the full width so its scrollbar rides the window's right edge
                // (like Settings + the catalog); the content is centered + width-capped INSIDE.
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(28, 22, 28, 32),
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 760),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _header(p, e),
                            const SizedBox(height: 24),
                            _meaning(p, e),
                            const SizedBox(height: 26),
                            _ctxHead(p, e),
                            const SizedBox(height: 10),
                            _contexts(p, e),
                            if (e.contextsLoaded && !e.contextsFailed) _unitControls(p),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The header: unit + "lang · learning" on the left, the memory meter on the right.
  /// The unit is immutable (no word-text edit); only the context sentences below are editable.
  Widget _header(OnboardingPalette p, WordBookEntry e) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                e.unit,
                style: p.display(size: 40, color: p.ink, height: 1.05, letterSpacing: -0.6),
              ),
              const SizedBox(height: 10),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    '${langName(e.word.targetLanguage)} · learning',
                    style: p.chrome(size: 12, weight: FontWeight.w500, color: p.ink3),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        _memoryMeter(p),
      ],
    );
  }

  /// The static echo memory meter + due + "Memory" label, from the unit's server FSRS projection
  /// (full = due now → mid → low → settled). A never-reviewed unit renders the calm placeholder echo
  /// with no due line.
  Widget _memoryMeter(OnboardingPalette p) {
    final (level, due) = meterFor(widget.entry.word.fsrs, DateTime.now().millisecondsSinceEpoch);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        meterEcho(p, level, size: 24),
        if (due != null) ...[
          const SizedBox(height: 4),
          Text(
            due,
            style: p.chrome(
              size: 12,
              weight: level == MeterLevel.full ? FontWeight.w600 : FontWeight.w400,
              color: level == MeterLevel.full ? p.primary : p.ink2,
            ),
          ),
        ],
        const SizedBox(height: 4),
        Text('MEMORY', style: p.mono(size: 10, color: p.ink3).copyWith(letterSpacing: 0.6)),
      ],
    );
  }

  /// Delete word. (Word-text edit is intentionally absent — the unit is immutable; edit the context
  /// sentence instead. See capecho-units-immutable.)
  Widget _unitControls(OnboardingPalette p) {
    return Container(
      margin: const EdgeInsets.only(top: 28),
      padding: const EdgeInsets.only(top: 18),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: p.line)),
      ),
      // The word-management control hugs the right edge, consistent with every other action cluster here.
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OutlinedButton.icon(
            onPressed: _deleteUnit,
            icon: Icon(Icons.delete_outline, size: 14, color: p.error),
            label: Text(
              'Delete word',
              style: p.chrome(size: 14, weight: FontWeight.w500, color: p.error),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: p.error,
              side: BorderSide(color: p.line),
              padding: kPillButtonPadding,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _meaning(OnboardingPalette p, WordBookEntry e) {
    switch (e.meaningStatus) {
      case DetailMeaningStatus.ready:
        // The meaning IS the per-POS senses: one block per reading — its pronunciation line (or idiom
        // badge) + each part of speech's senses on one line. The Word Book detail is uncapped (shows
        // every stored sense), unlike the overlay's glance.
        return SenseModules(
          p: p,
          explanation: e.meaning!,
          targetLanguage: e.word.targetLanguage,
          pronunciationSize: 15,
          senseSize: 17,
        );
      case DetailMeaningStatus.unsupported:
        return Text(
          'Meaning not available for this language yet.',
          style: p.body(size: 15.5, color: p.ink3, fontStyle: FontStyle.italic),
        );
      case DetailMeaningStatus.unavailable:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Meaning unavailable right now.',
              style: p.body(size: 15.5, color: p.ink3, fontStyle: FontStyle.italic),
            ),
            const SizedBox(height: 6),
            ObQuietButton(
              p: p,
              label: 'Retry',
              onPressed: () => widget.controller.retryDetail(e.id),
            ),
          ],
        );
      case DetailMeaningStatus.idle:
      case DetailMeaningStatus.loading:
        return Text(
          'Loading the meaning…',
          style: p.body(size: 15.5, color: p.ink3, fontStyle: FontStyle.italic),
        );
    }
  }

  Widget _ctxHead(OnboardingPalette p, WordBookEntry e) {
    final n = e.contexts.length;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        _sectionLabel(p, 'Your contexts'),
        if (n > 0) ...[
          const SizedBox(width: 8),
          Text(
            '$n saved',
            style: p.chrome(size: 11, weight: FontWeight.w500, color: p.ink3),
          ),
        ],
      ],
    );
  }

  Widget _contexts(OnboardingPalette p, WordBookEntry e) {
    if (!e.contextsLoaded && e.contexts.isEmpty) {
      return Text(
        'Loading your sentences…',
        style: p.body(size: 14, color: p.ink3, fontStyle: FontStyle.italic),
      );
    }
    if (e.contextsFailed) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Couldn’t load your sentences right now.',
            style: p.body(size: 14.5, color: p.ink3, fontStyle: FontStyle.italic),
          ),
          const SizedBox(height: 6),
          ObQuietButton(p: p, label: 'Retry', onPressed: () => widget.controller.retryDetail(e.id)),
        ],
      );
    }
    if (e.contexts.isEmpty) {
      // WB-5: a calm one-line re-capture invite, no add-context CTA.
      return Text(
        'No sentence saved yet — capture it again inside a sentence to keep the context it came from.',
        style: p.body(size: 14.5, color: p.ink3, fontStyle: FontStyle.italic),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [for (final c in e.contexts) _contextCard(p, e, c)],
    );
  }

  /// One saved context: the sentence; the paid "Explain in this sentence" affordance + its result;
  /// the per-context edit/remove controls; the date. Editing swaps the sentence for a text area.
  Widget _contextCard(OnboardingPalette p, WordBookEntry e, ContextView c) {
    final editing = _ctxDrafts.containsKey(c.id);
    final edited = _editedCtx.contains(c.id); // span is stale after an edit → render without the hl
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: p.card,
        border: Border.all(color: editing ? p.primary : p.line, width: editing ? 1.5 : 1),
        borderRadius: BorderRadius.circular(11),
        boxShadow: editing ? null : kSoftEdgeShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (editing)
            ..._ctxEditBody(p, c)
          else ...[
            if (edited)
              Text(
                '“${c.contextText}”',
                style: p.body(size: 15.5, height: 1.55, color: p.ink, fontStyle: FontStyle.italic),
              )
            else
              wbHighlight(
                p,
                c.contextText,
                c.spanStart,
                c.spanEnd,
                size: 15.5,
                italic: true,
                height: 1.55,
              ),
            // Capture provenance ("where I met this word"), quiet under the sentence.
            if (captureSourceCaption(p, sourceApp: c.sourceApp, sourceTitle: c.sourceTitle)
                case final source?) ...[
              const SizedBox(height: 9),
              source,
            ],
            ..._explainBlock(p, e, c),
            const SizedBox(height: 11),
            _ctxFoot(p, e, c),
          ],
        ],
      ),
    );
  }

  /// The paid "Explain in this sentence" result region.
  List<Widget> _explainBlock(OnboardingPalette p, WordBookEntry e, ContextView c) {
    if (c.hasGloss) {
      return [const SizedBox(height: 11), _gloss(p, c)]; // persisted sentence + word meaning
    }
    switch (_explain[c.id]) {
      case _ExplainPhase.generating:
        return [const SizedBox(height: 9), _generating(p, e.unit)];
      case _ExplainPhase.quota:
        return [
          // quota hit (daily cap reached): warning tone; Pro lifts the daily cap (§16)
          const SizedBox(height: 11),
          _ctxMsg(
            p,
            tone: p.warning,
            icon: Icons.warning_amber_rounded,
            title: 'Context explanations are done for today',
            desc:
                'They reset tomorrow — saving, review, word meanings, and your own sentences still work. '
                'Pro removes the daily cap.',
          ),
        ];
      case _ExplainPhase.offline:
        return [
          // needs a connection (info tone, no retry button — retrying offline just fails)
          const SizedBox(height: 11),
          _ctxMsg(
            p,
            tone: p.info,
            icon: Icons.wifi_off_outlined,
            title: 'Explaining in context needs a connection',
            desc:
                'Reconnect to generate the sentence-specific meaning. '
                'Nothing was counted against your daily limit.',
          ),
        ];
      case _ExplainPhase.failed:
        return [
          // generation failed (error tone) + Retry (the slot is refunded, not counted)
          const SizedBox(height: 11),
          _ctxMsg(
            p,
            tone: p.error,
            icon: Icons.error_outline,
            title: 'Couldn’t generate that explanation',
            desc:
                'Something went wrong on our side. We didn’t count it against your daily limit — try again.',
            action: _ctxAction(p, 'Retry', () => _explainCtx(c)),
          ),
        ];
      case null:
        return const [];
    }
  }

  Widget _ctxAction(OnboardingPalette p, String label, VoidCallback onTap) =>
      ObPrimaryButton(p: p, label: label, onPressed: onTap);

  Widget _ctxFoot(OnboardingPalette p, WordBookEntry e, ContextView c) {
    // Signed out: the paid "Explain in this sentence" call + the per-sentence edit/remove are all
    // server-backed (and metered), so the foot collapses to just the date (no local context editing).
    final preLogin = widget.controller.preLogin;
    final showCta = !preLogin && !c.hasGloss && _explain[c.id] == null;
    return Row(
      children: [
        if (showCta) Flexible(child: _explainCta(p, () => _explainCtx(c))),
        const Spacer(),
        Text(shortDate(c.createdAt), style: p.mono(size: 11, color: p.ink3)),
        if (!preLogin) ...[
          const SizedBox(width: 6),
          _iconBtn(p, Icons.edit_outlined, 'Edit', onTap: () => _startEditCtx(c)),
          _iconBtn(p, Icons.delete_outline, 'Remove', danger: true, onTap: () => _removeCtx(c)),
        ],
      ],
    );
  }

  List<Widget> _ctxEditBody(OnboardingPalette p, ContextView c) {
    final draft = _ctxDrafts[c.id]!;
    final hadGloss = c.hasGloss;
    return [
      TextField(
        controller: draft,
        autofocus: true,
        maxLines: null,
        style: p.body(size: 15.5, height: 1.55, color: p.ink, fontStyle: FontStyle.italic),
        cursorColor: p.primary,
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: p.canvas,
          contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: p.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: p.primary, width: 1.4),
          ),
        ),
      ),
      if (hadGloss) ...[
        const SizedBox(height: 7),
        // Editing the sentence clears its saved sentence-specific gloss.
        Text(
          'Editing this sentence clears its saved “in this sentence” explanation — re-generating it '
          'later uses one of your daily context explanations.',
          style: p
              .chrome(size: 11, weight: FontWeight.w400, color: p.ink3)
              .copyWith(fontStyle: FontStyle.italic),
        ),
      ],
      if (_ctxError[c.id] != null) ...[
        const SizedBox(height: 7),
        Text(
          _ctxError[c.id]!,
          style: p.chrome(size: 11.5, weight: FontWeight.w500, color: p.error),
        ),
      ],
      const SizedBox(height: 10),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          ObQuietButton(p: p, label: 'Cancel', onPressed: () => _cancelEditCtx(c)),
          const SizedBox(width: 8),
          ObPrimaryButton(p: p, label: 'Save', onPressed: () => _saveCtx(c)),
        ],
      ),
    ];
  }

  /// An outlined-primary "Explain here" pill with a small lock glyph (the lock signals it's metered).
  Widget _explainCta(OnboardingPalette p, VoidCallback onTap) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(Icons.lock_outline, size: 14, color: p.primary),
      label: Text(
        'Explain here',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: p.chrome(size: 12.5, weight: FontWeight.w600, color: p.primary),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: p.primary,
        side: BorderSide(color: p.primary),
        padding: kPillButtonPadding,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  /// The working echo + a "working out…" line.
  Widget _generating(OnboardingPalette p, String unit) {
    return Row(
      children: [
        ObEchoMark(color: p.primary, size: 20),
        const SizedBox(width: 9),
        Flexible(
          child: Text(
            'Working out what “$unit” means in this sentence…',
            style: p.chrome(size: 12.5, weight: FontWeight.w400, color: p.ink2),
          ),
        ),
      ],
    );
  }

  /// The persisted sentence-specific meaning. Mirrors the capture overlay: one combined
  /// explanation — the unit's meaning here AND what the whole sentence is saying — as an unlabeled
  /// callout attached to the sentence above (a warm left rule, not an eyebrow — adjacency + the
  /// highlighted unit do the labeling).
  Widget _gloss(OnboardingPalette p, ContextView c) {
    return Padding(
      padding: const EdgeInsets.only(left: 14),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 2, color: p.primary.withValues(alpha: 0.4)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(c.meaning!, style: p.body(size: 15, height: 1.55, color: p.ink)),
            ),
          ],
        ),
      ),
    );
  }

  /// An in-context message (quota / offline / failed / coming-soon), left-bordered by tone.
  Widget _ctxMsg(
    OnboardingPalette p, {
    required Color tone,
    required IconData icon,
    required String title,
    required String desc,
    Widget? action,
  }) {
    // Uniform 1px border + radius (allowed) with the tone accent as a clipped left child bar.
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: p.line),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, color: tone),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 14, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 18, color: tone),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: p.chrome(size: 13, weight: FontWeight.w600, color: p.ink),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            desc,
                            style: p
                                .chrome(size: 12, weight: FontWeight.w400, color: p.ink2)
                                .copyWith(height: 1.45),
                          ),
                          if (action != null) ...[const SizedBox(height: 9), action],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconBtn(
    OnboardingPalette p,
    IconData icon,
    String label, {
    bool danger = false,
    required VoidCallback onTap,
  }) {
    final color = danger ? p.error : p.ink2;
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 13, color: color),
      label: Text(
        label,
        style: p.chrome(size: 12, weight: FontWeight.w500, color: color),
      ),
      style: TextButton.styleFrom(
        foregroundColor: color,
        padding: kPillIconButtonPadding,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _sectionLabel(OnboardingPalette p, String text) => Text(
    text.toUpperCase(),
    style: p.chrome(size: 11, weight: FontWeight.w600, color: p.ink3, letterSpacing: 0.66),
  );
}
