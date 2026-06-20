import 'package:capecho_api/capecho_api.dart' show CapechoApi, WordFsrs;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import 'export_sheet.dart';
import 'recently_deleted_route.dart';
import 'word_detail_route.dart';

/// The mobile Word Book — a touch adaptation of the macOS catalog + detail, driven by the shared
/// [WordBookController]. It ports the macOS feature set 1:1 (same
/// warm aesthetic, same states, same content semantics) and adapts the interactions for portrait +
/// touch: a masthead + search, a single-column list of row-cards, and a pushed detail page.
///
/// **Signed-in only.** The mobile shell mounts the tabs only when signed in, and capture is macOS-only,
/// so there is no device-local catalog ([WordBookController.local] is null) — the catalog is always
/// server-authoritative. That drops the macOS pre-login banner, the "Sync N words" banner, and the
/// in-Word-Book sign-in dialog (none reachable here).
///
/// Returns a plain widget (no Scaffold): it's presented as a near-full-screen bottom popover
/// (`showCapechoSheet`) from the home's top-right corner button, on the warm canvas — like
/// `settings_screen.dart`. The detail, recently-deleted, and export surfaces are pushed as full routes on
/// the root navigator, layering above the popover. (In tests it's hosted in a bare Scaffold.)
class WordBookScreen extends StatefulWidget {
  const WordBookScreen({super.key, required this.api, this.explanationLanguage = 'en'});

  final CapechoApi api;
  final String explanationLanguage;

  @override
  State<WordBookScreen> createState() => _WordBookScreenState();
}

class _WordBookScreenState extends State<WordBookScreen> {
  late final WordBookController _c;
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    // No local store on mobile (capture is macOS): the catalog is always the server-authoritative
    // `/words`. A held session (the shell only mounts this when signed in) routes there.
    _c = WordBookController(
      api: widget.api,
      local: null,
      explanationLanguage: widget.explanationLanguage,
    );
    _c.load();
  }

  @override
  void dispose() {
    _c.dispose();
    _search.dispose();
    super.dispose();
  }

  void _openDetail(WordBookEntry e) {
    _c.select(e.id); // kicks off the detail load (meaning + contexts) if not already loaded
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WordDetailPage(controller: _c, entry: e),
      ),
    );
  }

  void _openRecentlyDeleted() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => RecentlyDeletedPage(controller: _c)));
  }

  /// Export the Word Book: a bottom sheet picks the format — a one-click Anki `.apkg` (built on-device,
  /// like macOS) or CSV — then hands the file to the system share sheet (save to Files, AirDrop, mail,
  /// …). Attribution stays OFF by default, matching macOS.
  Future<void> _export() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: double.infinity), // fill the full width
      backgroundColor: Colors.transparent,
      builder: (_) => ExportSheet(controller: _c, totalCount: _c.totalCount),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _masthead(p),
          _toolbar(p),
          Divider(height: 1, color: p.line),
          Expanded(child: _bodyForPhase(p)),
        ],
      ),
    );
  }

  // ---- masthead + toolbar --------------------------------------------------

  /// The editorial-serif "Word Book" title + the "N due today" line (from `controller.dueToday`, server
  /// FSRS) when something's due. Centered, with no back chevron.
  Widget _masthead(OnboardingPalette p) {
    final due = _c.dueToday;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Word Book', style: p.display(size: 20, color: p.ink)),
          if (due != null && due > 0) ...[
            const SizedBox(height: 2),
            Text(
              '$due due today',
              style: p.chrome(size: 12, weight: FontWeight.w500, color: p.ink3),
            ),
          ],
        ],
      ),
    );
  }

  /// The toolbar, decrowded for the phone: the catalog count + a Recently-deleted entry on one line, the
  /// search field beneath, Export as a trailing icon. (Export is server-backed; the shell is always signed
  /// in here, so it's always shown.)
  Widget _toolbar(OnboardingPalette p) {
    final total = _c.totalCount;
    final searching = _c.query.trim().isNotEmpty;
    final shown = _c.visible.length;
    final plural = total == 1 ? 'word and phrase' : 'words and phrases';
    final count = searching ? '$shown of $total' : '$total $plural';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  count,
                  overflow: TextOverflow.ellipsis,
                  style: p.mono(size: 12, color: p.ink3),
                ),
              ),
              if (_c.recentlyDeleted.isNotEmpty)
                _recentlyDeletedButton(p, _c.recentlyDeleted.length),
              _exportButton(p),
            ],
          ),
          const SizedBox(height: 8),
          Padding(padding: const EdgeInsets.only(right: 8), child: _searchField(p)),
        ],
      ),
    );
  }

  /// Entry point to the Recently-deleted page, shown only once something's been soft-deleted this session.
  /// Compact (icon + count) so the toolbar row stays tidy on a phone.
  Widget _recentlyDeletedButton(OnboardingPalette p, int n) {
    return TextButton.icon(
      onPressed: _openRecentlyDeleted,
      icon: Icon(Icons.restore_from_trash_outlined, size: 18, color: p.ink3),
      label: Text(
        '$n',
        style: p.chrome(size: 13, weight: FontWeight.w600, color: p.ink3),
      ),
      style: TextButton.styleFrom(
        foregroundColor: p.ink3,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        minimumSize: const Size(44, 44),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  /// A quiet ghost icon button (the upload glyph) sized for touch.
  Widget _exportButton(OnboardingPalette p) {
    return IconButton(
      onPressed: _export,
      tooltip: 'Export',
      icon: Icon(Icons.file_download_outlined, size: 20, color: p.ink2),
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    );
  }

  Widget _searchField(OnboardingPalette p) {
    return TextField(
      controller: _search,
      onChanged: _c.search,
      autocorrect: false,
      enableSuggestions: false,
      style: p.chrome(size: 14, weight: FontWeight.w400, color: p.ink),
      decoration: InputDecoration(
        isDense: true,
        prefixIcon: Icon(Icons.search, size: 18, color: p.ink3),
        prefixIconConstraints: const BoxConstraints(minWidth: 38, minHeight: 38),
        suffixIcon: _c.query.isEmpty
            ? null
            : IconButton(
                icon: Icon(Icons.close, size: 18, color: p.ink3),
                tooltip: 'Clear search',
                onPressed: () {
                  _search.clear();
                  _c.search('');
                },
              ),
        hintText: 'Search',
        hintStyle: p.chrome(size: 14, weight: FontWeight.w400, color: p.ink3),
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        filled: true,
        fillColor: p.card,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: p.primary, width: 1.4),
        ),
      ),
    );
  }

  // ---- body per phase ------------------------------------------------------

  Widget _bodyForPhase(OnboardingPalette p) {
    switch (_c.phase) {
      case WordBookPhase.loading:
        return const _SkeletonList();
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
        return _catalogList(p, items);
    }
  }

  Widget _catalogList(OnboardingPalette p, List<WordBookEntry> items) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: items.length,
      itemBuilder: (context, i) => _row(p, items[i], i),
    );
  }

  /// A lifted row-card — unit (+ phrase tag) + lazily-loaded context snippet, with the memory meter +
  /// capture date beneath. The macOS index column is dropped (it reads as desktop chrome); on a phone the
  /// meter + date move below the text so the row never gets too cramped to tap.
  Widget _row(OnboardingPalette p, WordBookEntry e, int displayIndex) {
    // Lazily fetch this row's most-recent context for the snippet as it scrolls in (deduped).
    _c.ensureCatalogContext(e);
    final ctx = e.latestContext;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: Container(
        decoration: BoxDecoration(
          color: p.card,
          border: Border.all(color: p.line),
          borderRadius: BorderRadius.circular(12),
          boxShadow: kSoftEdgeShadow,
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _openDetail(e),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 13),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 9,
                    runSpacing: 4,
                    children: [
                      Text(e.unit, style: p.display(size: 20, color: p.ink)),
                      if (e.word.isPhrase) phraseTag(p),
                    ],
                  ),
                  if (ctx != null) ...[
                    const SizedBox(height: 5),
                    _snippet(p, ctx.contextText, ctx.spanStart, ctx.spanEnd),
                  ],
                  const SizedBox(height: 9),
                  Row(
                    children: [
                      _meterLine(p, e.word.fsrs),
                      const Spacer(),
                      Text(shortDate(e.word.createdAt), style: p.mono(size: 11, color: p.ink3)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The echo-mark memory meter + an optional "due" line, both from the unit's server FSRS projection
  /// (full = due now → mid → low → settled). A never-reviewed unit (null projection) renders the calm
  /// level-less placeholder echo with no due. Static-fill, never animated.
  Widget _meterLine(OnboardingPalette p, WordFsrs? fsrs) {
    final (level, due) = meterFor(fsrs, DateTime.now().millisecondsSinceEpoch);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        meterEcho(p, level, size: 18),
        if (due != null) ...[
          const SizedBox(width: 7),
          Text(
            due,
            style: p.chrome(
              size: 12,
              weight: level == MeterLevel.full ? FontWeight.w600 : FontWeight.w500,
              color: level == MeterLevel.full ? p.primary : p.ink2,
            ),
          ),
        ],
      ],
    );
  }

  // ---- empty / no-results --------------------------------------------------

  /// First-run empty: the closed-book illustration + a warm capture invite. The capture hotkey is on the
  /// Mac, so the copy points there (capture is macOS-only).
  Widget _emptyInvite(OnboardingPalette p) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 36, 28, 44),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const WordBookEmptyArt(width: 184),
            const SizedBox(height: 20),
            Text(
              'Your Word Book is ready for its first word.',
              textAlign: TextAlign.center,
              style: p.display(size: 22, color: p.ink),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                'Capture words with ⌥E while you read on your Mac — they’ll arrive here with the '
                'sentence you saw them in, ready to review.',
                textAlign: TextAlign.center,
                style: p.body(size: 15, height: 1.55, color: p.ink2),
              ),
            ),
          ],
        ),
      ),
    );
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
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                'Nothing in your Word Book matches that search. Capture it next time you meet it while '
                'reading on your Mac.',
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
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ObEchoMark(color: p.primary, size: 48, ringOpacities: const [0.5, 0.5, 0.5]),
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
            if (action != null) ...[const SizedBox(height: 20), action],
          ],
        ),
      ),
    );
  }

  // The row's context snippet: italic, secondary ink, 2-line clamp, line-height 1.45.
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

// ════════════════════════════════════════════════════════════════════════════
// Loading skeleton — three pulsing row-cards while the catalog loads.
// ════════════════════════════════════════════════════════════════════════════

class _SkeletonList extends StatefulWidget {
  const _SkeletonList();
  @override
  State<_SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<_SkeletonList> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    final widths = [0.62, 0.44, 0.7];
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [for (var i = 0; i < 3; i++) _skelRow(p, widths[i])],
    );
  }

  Widget _skelRow(OnboardingPalette p, double unitWidth) {
    Widget bar(double w, double h) => FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: w,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (_, _) => Container(
          height: h,
          decoration: BoxDecoration(
            color: p.line.withValues(alpha: 0.45 + 0.55 * _pulse.value),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
      child: Container(
        decoration: BoxDecoration(
          color: p.card,
          border: Border.all(color: p.line),
          borderRadius: BorderRadius.circular(12),
          boxShadow: kSoftEdgeShadow,
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            bar(unitWidth.clamp(0.0, 0.6), 18),
            const SizedBox(height: 10),
            bar(0.9, 11),
            const SizedBox(height: 7),
            bar(0.6, 11),
            const SizedBox(height: 12),
            bar(0.3, 11),
          ],
        ),
      ),
    );
  }
}
