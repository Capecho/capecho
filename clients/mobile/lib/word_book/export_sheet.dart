import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Export sheet — format choice + the off-by-default attribution toggle, at full macOS parity: BOTH
/// formats build a real file and hand it to the system **share sheet** (save to Files, AirDrop, mail, …)
/// — the phone's equivalent of the macOS save panel. CSV comes from
/// `/export?format=csv`; the one-click Anki `.apkg` is assembled on-device by the shared
/// [AnkiDeckBuilder] from `/export?format=json` (SQLite `collection.anki2` + zip), exactly the deck the
/// macOS client emits. Presented as a bottom sheet from the Word Book toolbar's Export button.
typedef ExportFileSharer = Future<bool> Function({required String name, required Uint8List bytes});

enum _ExportFormat { anki, csv }

enum _ExportPhase { form, done }

class ExportSheet extends StatefulWidget {
  const ExportSheet({
    super.key,
    required this.controller,
    required this.totalCount,
    this.shareFile,
  });

  final WordBookController controller;
  final int totalCount;

  /// The share-to-OS seam: writes the bytes somewhere the user can keep them and returns whether it was
  /// shared (false = the share sheet was dismissed). Injected so tests record the (name, bytes) without a
  /// real share sheet / disk write; defaults to [_shareViaSystem] (a temp file + `share_plus`).
  final ExportFileSharer? shareFile;

  @override
  State<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<ExportSheet> {
  _ExportFormat _format = _ExportFormat.anki;
  bool _attribution = false; // off by default (the r/Anki community punishes spam) — matches macOS
  _ExportPhase _phase = _ExportPhase.form;
  _ExportFormat? _savedFormat; // which format the "done" screen is reporting
  bool _busy = false;
  String? _error;

  int get _count => widget.totalCount;
  String get _cards => '$_count ${_count == 1 ? 'card' : 'cards'}';
  String get _wordsAndPhrases => '$_count ${_count == 1 ? 'word or phrase' : 'words and phrases'}';

  Future<void> _onExport() => _format == _ExportFormat.anki ? _exportAnki() : _exportCsv();

  /// Build the one-click Anki `.apkg` on-device (shared [AnkiDeckBuilder]) from the structured rows, then
  /// hand it to the share sheet — identical to the deck the macOS client saves.
  Future<void> _exportAnki() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final rows = await widget.controller.exportRows();
    if (!mounted) return;
    if (rows == null) {
      _failFetch();
      return;
    }
    final Uint8List deck;
    try {
      deck = const AnkiDeckBuilder().build(
        rows,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        attribution: _attribution,
      );
    } catch (_) {
      setState(() {
        _busy = false;
        _error = 'Couldn’t build the Anki deck — please try again.';
      });
      return;
    }
    await _share('capecho.apkg', deck, _ExportFormat.anki);
  }

  Future<void> _exportCsv() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final csv = await widget.controller.exportCsv(attribution: _attribution);
    if (!mounted) return;
    if (csv == null) {
      _failFetch();
      return;
    }
    await _share('capecho-wordbook.csv', Uint8List.fromList(utf8.encode(csv)), _ExportFormat.csv);
  }

  /// Hand the bytes to the share sheet (the injected seam, else a temp file + `share_plus`). A share →
  /// the "exported" screen; the user dismissing the share sheet → quietly back to the form (no scary
  /// error); a thrown error → a calm retry message.
  Future<void> _share(String name, Uint8List bytes, _ExportFormat format) async {
    final sharer = widget.shareFile ?? _shareViaSystem;
    final bool shared;
    try {
      shared = await sharer(name: name, bytes: bytes);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Couldn’t share the file — please try again.';
      });
      return;
    }
    if (!mounted) return;
    if (!shared) {
      // Dismissed the share sheet → quietly back to the form.
      setState(() => _busy = false);
      return;
    }
    setState(() {
      _busy = false;
      _phase = _ExportPhase.done;
      _savedFormat = format;
    });
  }

  void _failFetch() => setState(() {
    _busy = false;
    _error = 'Couldn’t export right now — check your connection and try again.';
  });

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: p.card,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: switch (_phase) {
              _ExportPhase.form => _formBody(p),
              _ExportPhase.done => _doneBody(p),
            },
          ),
        ),
      ),
    );
  }

  Widget _formBody(OnboardingPalette p) {
    final exportLabel = _format == _ExportFormat.anki ? 'Export deck' : 'Export CSV';
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Export Word Book', style: p.display(size: 20, color: p.ink)),
          const SizedBox(height: 4),
          Text(
            'Export your $_count saved ${_count == 1 ? 'word or phrase' : 'words and phrases'} to use '
            'elsewhere. Your saved data is never changed.',
            style: p.chrome(size: 12.5, color: p.ink2, height: 1.5),
          ),
          const SizedBox(height: 18),
          _segLabel(p, 'Format'),
          const SizedBox(height: 8),
          _formatSeg(p),
          const SizedBox(height: 16),
          _exportNote(p),
          const SizedBox(height: 6),
          _attributionToggle(p),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: p.chrome(size: 12, color: p.error, height: 1.4)),
          ],
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ObQuietButton(
                p: p,
                label: 'Cancel',
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              const SizedBox(width: 10),
              ObPrimaryButton(p: p, label: exportLabel, busy: _busy, onPressed: _onExport),
            ],
          ),
        ],
      ),
    );
  }

  Widget _doneBody(OnboardingPalette p) {
    final anki = _savedFormat == _ExportFormat.anki;
    final body = anki
        ? '$_cards exported as an Anki deck (.apkg) — open it in Anki to import. Re-exporting later '
              'updates the same cards instead of duplicating them.'
        : '$_wordsAndPhrases exported as CSV — save it to Files, or send it to import into Anki or a spreadsheet.';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The "saved" mark is the ink-dot, never a checkmark.
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: p.primarySoft, shape: BoxShape.circle),
          child: Center(
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(color: p.primary, shape: BoxShape.circle),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text('Word Book exported', style: p.display(size: 20, color: p.ink)),
        const SizedBox(height: 4),
        Text(
          body,
          textAlign: TextAlign.center,
          style: p.chrome(size: 12.5, color: p.ink2, height: 1.5),
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerRight,
          child: ObPrimaryButton(
            p: p,
            label: 'Done',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
      ],
    );
  }

  Widget _segLabel(OnboardingPalette p, String text) => Text(
    text.toUpperCase(),
    style: p.chrome(size: 11, weight: FontWeight.w600, color: p.ink3, letterSpacing: 0.66),
  );

  Widget _formatSeg(OnboardingPalette p) {
    Widget opt(String label, _ExportFormat f) {
      final active = _format == f;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _format = f),
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: active ? p.card : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              boxShadow: active ? [BoxShadow(color: p.edge, offset: const Offset(2, 2))] : null,
            ),
            child: Text(
              label,
              style: p.chrome(size: 13, weight: FontWeight.w500, color: active ? p.ink : p.ink2),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.primarySoft, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [opt('Anki deck', _ExportFormat.anki), opt('CSV', _ExportFormat.csv)]),
    );
  }

  Widget _exportNote(OnboardingPalette p) {
    TextSpan b(String t) => TextSpan(
      text: t,
      style: p.chrome(size: 12, weight: FontWeight.w600, color: p.ink),
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: p.primarySoft, borderRadius: BorderRadius.circular(8)),
      child: Text.rich(
        TextSpan(
          style: p.chrome(size: 12, color: p.ink2, height: 1.5),
          children: [
            const TextSpan(text: 'Emits '),
            b('one card per saved word or phrase'),
            const TextSpan(text: ' — the word or phrase, its '),
            b('most-recent context'),
            const TextSpan(text: ' sentence, the explanation, and a '),
            b('language'),
            const TextSpan(text: ' column so multi-language decks don’t collide.'),
          ],
        ),
      ),
    );
  }

  Widget _attributionToggle(OnboardingPalette p) => Container(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Add “captured with Capecho”',
                style: p.chrome(size: 13, weight: FontWeight.w500, color: p.ink),
              ),
              const SizedBox(height: 2),
              Text(
                'A subtle footer + re-entry link on each card. Off by default.',
                style: p.chrome(size: 11.5, color: p.ink3, height: 1.4),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _ExportSwitch(
          p: p,
          on: _attribution,
          onTap: () => setState(() => _attribution = !_attribution),
        ),
      ],
    ),
  );
}

/// Default share seam: write the bytes to a temp file under the cache dir, then open the system share
/// sheet. Returns true unless the user explicitly dismissed it (Android can't always report a result, so
/// only an explicit dismissal counts as "not shared").
Future<bool> _shareViaSystem({required String name, required Uint8List bytes}) async {
  final dir = await getTemporaryDirectory();
  final file = File('${dir.path}/$name');
  await file.writeAsBytes(bytes, flush: true);
  final result = await SharePlus.instance.share(
    ShareParams(files: [XFile(file.path)], subject: 'Capecho Word Book'),
  );
  return result.status != ShareResultStatus.dismissed;
}

/// A 44×26 pill toggle (touch-sized); off = line track, on = primary track.
class _ExportSwitch extends StatelessWidget {
  const _ExportSwitch({required this.p, required this.on, required this.onTap});
  final OnboardingPalette p;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    behavior: HitTestBehavior.opaque,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 44,
      height: 26,
      decoration: BoxDecoration(
        color: on ? p.primary : p.line,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: p.line),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 120),
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: on ? p.primaryFg : p.card,
              shape: BoxShape.circle,
              boxShadow: const [
                BoxShadow(color: Color(0x40000000), blurRadius: 2, offset: Offset(0, 1)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
