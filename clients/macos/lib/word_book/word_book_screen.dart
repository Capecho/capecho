import 'package:capecho_api/capecho_api.dart' show CapechoApi, WordFsrs;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../capture_shortcut_scope.dart';
import '../surface_transitions.dart';
import 'export_dialog.dart';
import 'recently_deleted_route.dart';
import 'sign_in_dialog.dart';
import 'word_book_screen_art.dart';
import 'word_book_widgets.dart';
import 'word_detail_route.dart';

/// The macOS Word Book — a **single-column catalog** of the account's saved words:
/// a `Capecho.` masthead with "N due today", a toolbar
/// (count · search · Export), and a scrolling list of row-cards (index · unit + POS · context
/// snippet · date). Tapping a row opens its **detail as a pushed route**:
/// meaning + all saved contexts. `Esc` closes / goes back.
///
/// All states render: loading skeleton, first-run empty + IL-02, populated, search no-results. The
/// per-row + detail **memory meter + "due"** reads the per-unit `Word.fsrs` projection `/words`
/// returns (`meterFor`). Delete + restore persist; the paid "explain in this sentence" layer + the
/// export dialog are wired. (Unit-text edit stays UI-local — the unit is immutable by design.)
class WordBookScreen extends StatefulWidget {
  const WordBookScreen({
    super.key,
    required this.api,
    this.local,
    this.auth,
    this.explanationLanguage = 'en',
    this.onClose,
    this.onBack,
    this.backLabel = 'Back',
    this.saveExportFile,
  });

  final CapechoApi api;

  /// Saves an export (CSV / Anki `.apkg`) to a file via the native save panel + reveals it in Finder.
  /// Null in tests / hosts without the native plugin (the export then degrades to a no-op). Wired from
  /// the app shell to `CaptureNative.saveExportFile`.
  final ExportFileSaver? saveExportFile;

  /// The signed-out data source (the device-local store). Null → no local catalog (falls back to the
  /// server banner; e.g. in tests). Passed straight through to [WordBookController.local].
  final LocalWordBook? local;

  /// The sign-in controller — drives the signed-out "Sign in" dialog and the signed-in "Sync N words"
  /// banner. Null in tests / hosts that don't wire auth (both affordances then degrade gracefully).
  final AuthController? auth;

  final String explanationLanguage;

  /// Dismiss the catalog. The agent app supplies `hideWindow` (close = hide the window, return to the
  /// menu bar). Null falls back to `Navigator.maybePop` (tests / a nested host). Detail + recently-
  /// deleted are pushed ON TOP and keep their own back-to-catalog pop — only the catalog closes here.
  final VoidCallback? onClose;

  /// When non-null the Word Book is a NESTED page (e.g. opened from Settings): the shared header shows
  /// a back button wired to this. Null → a root surface (header shows the brand, dismiss via Esc).
  final VoidCallback? onBack;

  /// The back button's label when nested (e.g. 'Settings'); ignored for a root surface.
  final String backLabel;

  @override
  State<WordBookScreen> createState() => _WordBookScreenState();
}

class _WordBookScreenState extends State<WordBookScreen> {
  late final WordBookController _c;
  final FocusNode _focus = FocusNode(debugLabel: 'wordbook');
  final TextEditingController _search = TextEditingController();

  /// A sync is in flight (disables the "Sync N" banner button).
  bool _syncing = false;

  /// Tracks the auth sign-in state so a flip (signed in via the dialog, or signed out) reloads the
  /// catalog from the now-correct source (server vs the local store).
  bool? _wasSignedIn;

  @override
  void initState() {
    super.initState();
    _c = WordBookController(
      api: widget.api,
      local: widget.local,
      explanationLanguage: widget.explanationLanguage,
    );
    _c.load();
    _wasSignedIn = widget.auth?.isSignedIn ?? false;
    widget.auth?.addListener(_onAuthChanged);
  }

  @override
  void dispose() {
    widget.auth?.removeListener(_onAuthChanged);
    _c.dispose();
    _focus.dispose();
    _search.dispose();
    super.dispose();
  }

  /// Reload the catalog when the sign-in state flips (auth fires on busy/error too — the guard keeps
  /// this to genuine sign-in/out transitions).
  void _onAuthChanged() {
    final signedIn = widget.auth?.isSignedIn ?? false;
    if (_wasSignedIn != signedIn) {
      _wasSignedIn = signedIn;
      _c.load();
    }
  }

  void _close() {
    final close = widget.onClose;
    if (close != null) {
      // Agent: collapse the Word Book back to the hidden host THEN hide the window, so re-opening a
      // DIFFERENT surface doesn't briefly flash this (now stale) one. No shell to return to.
      Navigator.of(context).popUntil((r) => r.isFirst);
      close();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Esc, or ⌘W (standard macOS close-window) → back to the menu-bar agent (bug #3).
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.escape ||
            (event.logicalKey == LogicalKeyboardKey.keyW &&
                HardwareKeyboard.instance.isMetaPressed))) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Open the export dialog: format choice + attribution toggle, over the dimmed catalog. Both formats
  /// download to a real file via the native save panel — CSV (`/export?format=csv`)
  /// and a one-click Anki `.apkg` deck assembled on-device from `/export?format=json`.
  Future<void> _export() async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.34),
      builder: (_) =>
          ExportDialog(controller: _c, totalCount: _c.totalCount, saveFile: widget.saveExportFile),
    );
  }

  void _openRecentlyDeleted() {
    // A nested page: it slides in from the right; the catalog beneath stays fixed.
    Navigator.of(context).push(nestedSurfaceRoute(RecentlyDeletedRoute(controller: _c)));
  }

  /// Pre-login "Sign in": open the shared sign-in panel right here in a dialog
  /// (no detour to Settings). On a successful sign-in the dialog closes and the auth listener reloads
  /// the catalog from the server. Falls back to a pointer snackbar when no auth is wired (e.g. tests).
  Future<void> _requestSignIn() async {
    final auth = widget.auth;
    if (auth == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Sign in from Settings or the menu bar to sync these words and start reviewing.',
          ),
        ),
      );
      return;
    }
    final p = OnboardingPalette.of(context);
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.34),
      builder: (_) => SignInDialog(p: p, auth: auth),
    );
  }

  /// Signed in with un-synced local captures, and the catalog has resolved → offer the explicit sync.
  bool get _showSyncBanner {
    final auth = widget.auth;
    return auth != null &&
        auth.isSignedIn &&
        auth.pendingAnonymousCount > 0 &&
        _c.phase != WordBookPhase.loading;
  }

  /// Push the device's anonymous local captures into the signed-in account (the explicit, user-chosen
  /// claim — the silent auto-claim was removed), then reload so the synced words appear in the
  /// server-backed catalog and the banner clears.
  Future<void> _syncLocal() async {
    final auth = widget.auth;
    if (auth == null || _syncing) return;
    setState(() => _syncing = true);
    final n = await auth.syncLocalCaptures();
    if (!mounted) return;
    setState(() => _syncing = false);
    await _c.load();
    if (!mounted) return;
    // Always surface the outcome: the success count, or the controller's error. Sync is best-effort,
    // so a failed claim leaves the banner in place — without this the tap reads as a silent no-op.
    final msg = n > 0
        ? 'Synced $n ${n == 1 ? 'word' : 'words'} to your account.'
        : (auth.error ?? 'Couldn’t sync your words — try again.');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _openDetail(WordBookEntry e) {
    _c.select(e.id); // kicks off the detail load (meaning + contexts) if not already loaded
    // A nested page: it slides in from the right; the catalog beneath stays fixed.
    Navigator.of(context).push(nestedSurfaceRoute(WordDetailRoute(controller: _c, entry: e)));
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
        // Listen to auth too, so the "Sync N" banner + sign-in state stay live (sync drops the count;
        // a sign-in via the dialog flips the catalog source).
        body: AnimatedBuilder(
          animation: Listenable.merge([_c, widget.auth]),
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SurfaceHeader(
                p: p,
                title: 'Word Book',
                onBack: widget.onBack,
                backLabel: widget.backLabel,
                trailing: _headerMeta(p),
              ),
              _toolbar(p),
              Divider(height: 1, color: p.line),
              if (_showSyncBanner) _syncBanner(p),
              Expanded(child: _bodyForPhase(p)),
            ],
          ),
        ),
      ),
    );
  }

  // ---- header meta + toolbar -----------------------------------------------

  /// The shared header's right-aligned meta: "Not signed in" pre-login, else "N due today". Null when
  /// signed in with nothing due (the header then shows just brand + title).
  Widget? _headerMeta(OnboardingPalette p) {
    if (_c.preLogin) {
      return Text('Not signed in', style: p.chrome(size: 12, color: p.ink3));
    }
    final due = _c.dueToday;
    if (due != null && due > 0) {
      return Text('$due due today', style: p.chrome(size: 12, color: p.ink3));
    }
    return null;
  }

  /// The toolbar: the catalog count, then search + Export on the right. (The "Word Book" title + brand
  /// live in the shared [SurfaceHeader] above this row.)
  Widget _toolbar(OnboardingPalette p) {
    final total = _c.totalCount;
    final searching = _c.query.trim().isNotEmpty;
    final shown = _c.visible.length;
    final plural = total == 1 ? 'word and phrase' : 'words and phrases';
    // The count reads "N words and phrases · on this device" pre-login (saved locally, not synced).
    final count = searching
        ? '$shown of $total'
        : '$total $plural${_c.preLogin ? ' · on this device' : ''}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Row(
        children: [
          // The count claims the slack so search + Export sit flush against the toolbar's right edge.
          // (A lone Spacer beside a flex-1 Flexible split the slack between them, stranding the two
          // controls mid-row with a dead gap to their right instead of right-aligning them.)
          Expanded(
            child: Text(
              count,
              overflow: TextOverflow.ellipsis,
              style: p.mono(size: 12, color: p.ink3),
            ),
          ),
          if (_c.recentlyDeleted.isNotEmpty) ...[
            _recentlyDeletedButton(p, _c.recentlyDeleted.length),
            const SizedBox(width: 6),
          ],
          SizedBox(width: 220, child: _searchField(p)),
          // Export is server-backed (`/export` is account-scoped) → hidden signed-out.
          if (!_c.preLogin) ...[const SizedBox(width: 12), _exportButton(p)],
        ],
      ),
    );
  }

  /// Entry point to the Recently-deleted view, shown only once something's been
  /// soft-deleted this session. Compact (icon + count) so the toolbar stays within the min window width.
  Widget _recentlyDeletedButton(OnboardingPalette p, int n) {
    return Tooltip(
      message: 'Recently deleted ($n)',
      child: TextButton.icon(
        onPressed: _openRecentlyDeleted,
        icon: Icon(Icons.restore_from_trash_outlined, size: 16, color: p.ink3),
        label: Text(
          '$n',
          style: p.chrome(size: 13, weight: FontWeight.w600, color: p.ink3),
        ),
        style: TextButton.styleFrom(
          foregroundColor: p.ink3,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Widget _searchField(OnboardingPalette p) {
    return TextField(
      controller: _search,
      onChanged: _c.search,
      autocorrect: false,
      enableSuggestions: false,
      style: p.chrome(size: 13, weight: FontWeight.w400, color: p.ink),
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: Icon(Icons.search, size: 16, color: p.ink3),
        prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        suffixIcon: _c.query.isEmpty
            ? null
            : IconButton(
                icon: Icon(Icons.close, size: 15, color: p.ink3),
                splashRadius: 14,
                tooltip: 'Clear search',
                onPressed: () {
                  _search.clear();
                  _c.search('');
                },
              ),
        suffixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 30),
        hintText: 'Search',
        hintStyle: p.chrome(size: 13, weight: FontWeight.w400, color: p.ink3),
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        filled: true,
        fillColor: p.card,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: p.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: p.primary, width: 1.4),
        ),
      ),
    );
  }

  /// A quiet ghost button with the upload glyph. Disabled (dimmed, non-tappable) when there are no
  /// saved words: an empty Word Book has nothing to export.
  Widget _exportButton(OnboardingPalette p) {
    final enabled = _c.totalCount > 0;
    final tint = enabled ? p.ink2 : p.ink3; // dimmed when there's nothing to export
    return TextButton.icon(
      onPressed: enabled ? _export : null,
      icon: Icon(Icons.file_download_outlined, size: 16, color: tint),
      label: Text(
        'Export',
        style: p.chrome(size: 14, weight: FontWeight.w500, color: tint),
      ),
      style: TextButton.styleFrom(foregroundColor: p.ink2, disabledForegroundColor: p.ink3),
    );
  }

  // ---- body per phase ------------------------------------------------------

  Widget _bodyForPhase(OnboardingPalette p) {
    switch (_c.phase) {
      case WordBookPhase.loading:
        return const WordBookSkeletonList();
      case WordBookPhase.error:
        return _centered(
          p,
          title: 'Word Book didn’t load',
          body: _c.error,
          action: ObPrimaryButton(p: p, label: 'Try again', onPressed: _c.retry),
        );
      case WordBookPhase.empty:
        return _emptyInvite(p);
      case WordBookPhase.loaded:
        final items = _c.visible;
        if (items.isEmpty) return _noResults(p);
        // Pre-login: the words are saved locally but have no server FSRS schedule yet, so a calm
        // "sign in to sync + review" banner sits above the catalog.
        if (_c.preLogin) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _preLoginBanner(p),
              Expanded(child: _catalogList(p, items)),
            ],
          );
        }
        return _catalogList(p, items);
    }
  }

  /// An info-toned card (clipped left accent bar so the radius is uniform — Flutter rejects a
  /// non-uniform border + borderRadius) inviting sign-in to sync + schedule reviews.
  Widget _preLoginBanner(OnboardingPalette p) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(
          color: p.card,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: p.info),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: p.line),
                        right: BorderSide(color: p.line),
                        bottom: BorderSide(color: p.line),
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              style: p.chrome(size: 12.5, color: p.ink2, height: 1.45),
                              children: [
                                const TextSpan(text: 'These words are saved on this Mac. '),
                                TextSpan(
                                  text: 'Sign in to sync them and start reviewing',
                                  style: p.chrome(
                                    size: 12.5,
                                    weight: FontWeight.w600,
                                    color: p.ink,
                                  ),
                                ),
                                const TextSpan(
                                  text:
                                      ' — review scheduling begins once they’re claimed to your account.',
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ObPrimaryButton(p: p, label: 'Sign in', onPressed: _requestSignIn),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Signed-in twin of the pre-login banner: N local captures aren't in the account yet → one-tap
  /// explicit Sync (the silent auto-claim was removed). A primary left accent distinguishes it.
  Widget _syncBanner(OnboardingPalette p) {
    final n = widget.auth!.pendingAnonymousCount;
    final plural = n == 1 ? 'word' : 'words';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: ColoredBox(
          color: p.card,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: p.primary),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(color: p.line),
                        right: BorderSide(color: p.line),
                        bottom: BorderSide(color: p.line),
                      ),
                    ),
                    padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$n $plural on this device ${n == 1 ? "isn’t" : "aren’t"} in your account '
                            'yet — sync to back them up and start reviewing.',
                            style: p.chrome(size: 12.5, color: p.ink2, height: 1.45),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ObPrimaryButton(p: p, label: 'Sync', busy: _syncing, onPressed: _syncLocal),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _catalogList(OnboardingPalette p, List<WordBookEntry> items) {
    // The ListView fills the full width so its scrollbar rides the window's right edge (like
    // Settings); each row is centered + width-capped INSIDE.
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: items.length,
      itemBuilder: (context, i) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: _row(p, items[i], i),
        ),
      ),
    );
  }

  /// A lifted card — index · (unit + phrase tag · context snippet) · aside (memory meter + date).
  /// Pre-login rows are dashed + shadowless with a "not yet scheduled" note.
  Widget _row(OnboardingPalette p, WordBookEntry e, int displayIndex) {
    // Lazily fetch this row's most-recent context for the snippet as it scrolls in (deduped).
    _c.ensureCatalogContext(e);
    final ctx = e.latestContext;
    final unscheduled = _c.preLogin; // no FSRS schedule yet
    // Outer Container draws the card fill + border + the stacked-paper shadow (which renders BEHIND,
    // not clipped); the transparent Material + InkWell put the tap ripple ON TOP, clipped to the rect.
    // Unscheduled rows drop the shadow + solid border and get a dashed outline (drawn on top) instead.
    final card = Container(
      decoration: BoxDecoration(
        color: p.card,
        border: unscheduled ? null : Border.all(color: p.line),
        borderRadius: BorderRadius.circular(11),
        boxShadow: unscheduled ? null : kSoftEdgeShadow,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _openDetail(e),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 30,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      (displayIndex + 1).toString().padLeft(2, '0'),
                      style: p.mono(size: 13, color: p.ink3),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 9,
                        runSpacing: 4,
                        children: [
                          Text(e.unit, style: p.display(size: 19, color: p.ink)),
                          if (e.word.isPhrase) phraseTag(p),
                        ],
                      ),
                      if (ctx != null) ...[
                        const SizedBox(height: 5),
                        // The whole row is the tap target (opens the detail) — the
                        // sentence must never swallow that tap, so it ignores
                        // pointers and the card's InkWell owns the click.
                        IgnorePointer(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 560),
                            child: _snippet(p, ctx.contextText, ctx.spanStart, ctx.spanEnd),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                _aside(p, e),
              ],
            ),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: unscheduled
          ? CustomPaint(
              foregroundPainter: DashedRRectPainter(color: p.line, radius: 11),
              child: card,
            )
          : card,
    );
  }

  /// The right-aligned memory meter (or pre-login "not yet scheduled" note) over the capture date.
  Widget _aside(OnboardingPalette p, WordBookEntry e) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 150),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_c.preLogin) _unscheduledNote(p) else _meterLine(p, e.word.fsrs),
          const SizedBox(height: 5),
          Text(shortDate(e.word.createdAt), style: p.mono(size: 11, color: p.ink3)),
        ],
      ),
    );
  }

  /// A calm dot + "not yet scheduled — sign in to review".
  Widget _unscheduledNote(OnboardingPalette p) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        margin: const EdgeInsets.only(top: 5),
        width: 5,
        height: 5,
        decoration: BoxDecoration(color: p.ink3, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          'Not yet scheduled — sign in to review',
          textAlign: TextAlign.right,
          style: p.chrome(size: 11.5, color: p.ink3, height: 1.35),
        ),
      ),
    ],
  );

  /// The echo-mark memory meter + an optional "due" line, both derived from the unit's server FSRS
  /// projection (US-1.2; full = due now → mid → low → settled). A never-reviewed unit (null projection)
  /// renders the calm level-less placeholder echo, no due.
  Widget _meterLine(OnboardingPalette p, WordFsrs? fsrs) {
    final (level, due) = meterFor(fsrs, DateTime.now().millisecondsSinceEpoch);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (due != null) ...[
          Text(
            due,
            style: p.chrome(
              size: 12,
              weight: level == MeterLevel.full ? FontWeight.w600 : FontWeight.w500,
              color: level == MeterLevel.full ? p.primary : p.ink2,
            ),
          ),
          const SizedBox(width: 7),
        ],
        meterEcho(p, level, size: 19),
      ],
    );
  }

  // ---- empty / no-results / loading-skeleton -------------------------------

  /// First-run empty: the IL-02 closed-book illustration + a warm capture invite.
  Widget _emptyInvite(OnboardingPalette p) {
    final captureDisplay = CaptureShortcutScope.displayOf(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 36, 28, 44),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const WordBookEmptyArt(),
            const SizedBox(height: 22),
            Text(
              'Your Word Book is ready for its first word.',
              textAlign: TextAlign.center,
              style: p.display(size: 22, color: p.ink),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Text(
                'When you meet a word while reading anywhere on your Mac, capture it — '
                'it lands here with the sentence you saw it in.',
                textAlign: TextAlign.center,
                style: p.body(size: 15, height: 1.6, color: p.ink2),
              ),
            ),
            const SizedBox(height: 18),
            ObKeyCombo(p: p, parts: _captureComboParts(captureDisplay)),
            const SizedBox(height: 12),
            Text(
              'Rest your cursor near a word, press $captureDisplay, then Save.',
              textAlign: TextAlign.center,
              style: p.chrome(size: 12.5, weight: FontWeight.w400, color: p.ink3),
            ),
          ],
        ),
      ),
    );
  }

  /// Split the live Capture shortcut [display] into [ObKeyCombo] parts joined by '+',
  /// mirroring onboarding (e.g. "⌥E" → ['⌥', '+', 'E']).
  List<String> _captureComboParts(String display) {
    final parts = <String>[];
    for (var i = 0; i < display.length; i++) {
      if (parts.isNotEmpty) parts.add('+');
      parts.add(display[i]);
    }
    return parts;
  }

  /// Search no-results: a settled echo + "no matches" + Clear search.
  Widget _noResults(OnboardingPalette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(28, 40, 28, 56),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ObEchoMark(color: p.ink3, size: 30, ringOpacities: const [0.5, 0.5, 0.5]),
            const SizedBox(height: 16),
            Text(
              'No words or phrases match “${_c.query.trim()}”',
              textAlign: TextAlign.center,
              style: p.display(size: 19, color: p.ink),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                'Nothing in your Word Book matches that search. Capture it next time you meet it while reading.',
                textAlign: TextAlign.center,
                style: p.body(size: 14.5, height: 1.55, color: p.ink2),
              ),
            ),
            const SizedBox(height: 16),
            ObQuietButton(
              p: p,
              label: 'Clear search',
              onPressed: () {
                _search.clear();
                _c.search('');
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _centered(OnboardingPalette p, {required String title, String? body, Widget? action}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ObEchoMark(color: p.primary, size: 48, ringOpacities: const [0.5, 0.5, 0.5]),
            const SizedBox(height: 20),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Text(
                title,
                textAlign: TextAlign.center,
                style: p.display(size: 22, color: p.ink),
              ),
            ),
            if (body != null) ...[
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  body,
                  textAlign: TextAlign.center,
                  style: p.body(size: 15, color: p.ink2),
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action],
          ],
        ),
      ),
    );
  }

  // ---- shared small parts --------------------------------------------------

  // The context snippet: italic, secondary ink, 2-line clamp, line-height 1.45.
  Widget _snippet(OnboardingPalette p, String text, int? start, int? end) => wbHighlight(
    p,
    text,
    start,
    end,
    size: 14,
    italic: true,
    baseColor: p.ink2,
    height: 1.45,
    lineClamp: 2,
  );
}
