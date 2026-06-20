import 'dart:convert';
import 'dart:typed_data';

import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter/material.dart';

import 'word_book_widgets.dart';

/// The Word Book **export dialog** — format choice + attribution toggle over the dimmed catalog. Both
/// formats download to a real file via the native save panel: CSV
/// (`/export?format=csv`) and a one-click Anki `.apkg` deck built on-device from `/export?format=json`
/// (see `anki_deck.dart`).
enum _ExportFormat { anki, csv }

enum _ExportPhase { form, done }

const List<BoxShadow> _kEdgeShadowSm = [BoxShadow(color: Color(0x1F2B2320), offset: Offset(2, 2))];

class ExportDialog extends StatefulWidget {
  const ExportDialog({
    super.key,
    required this.controller,
    required this.totalCount,
    this.saveFile,
  });
  final WordBookController controller;
  final int totalCount;

  /// The native save-to-file seam (null in tests / hosts without the plugin → export is a no-op).
  final ExportFileSaver? saveFile;

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  _ExportFormat _format = _ExportFormat.anki;
  bool _attribution = false;
  _ExportPhase _phase = _ExportPhase.form;
  bool _busy = false;
  String? _error;

  // What landed on disk (drives the "done" copy): the saved file's name + which format it was.
  String _savedName = '';
  _ExportFormat _savedFormat = _ExportFormat.csv;

  int get _count => widget.totalCount;
  String get _cards => '$_count ${_count == 1 ? 'card' : 'cards'}';

  /// The CSV path counts plain "words and phrases", not Anki "cards" (a CSV row is a saved
  /// word/phrase, not a flashcard).
  String get _csvItems => '$_count ${_count == 1 ? 'word and phrase' : 'words and phrases'}';

  Future<void> _onExport() => _format == _ExportFormat.anki ? _exportAnki() : _exportCsv();

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
    await _save('capecho-export.csv', Uint8List.fromList(utf8.encode(csv)), _ExportFormat.csv);
  }

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
    await _save('capecho.apkg', deck, _ExportFormat.anki);
  }

  /// Hand the bytes to the native save panel. A returned path → the "exported" screen; the user
  /// cancelling → quietly back to the form (no scary error); a missing save seam → a calm message
  /// (the shipping app always wires it, so this only guards a degraded host — no silent dead button).
  Future<void> _save(String suggestedName, Uint8List bytes, _ExportFormat format) async {
    final saver = widget.saveFile;
    if (saver == null) {
      setState(() {
        _busy = false;
        _error = 'Exporting to a file isn’t available here.';
      });
      return;
    }
    final String? savedPath;
    try {
      savedPath = await saver(suggestedName: suggestedName, bytes: bytes);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Couldn’t save the file — please try again.';
      });
      return;
    }
    if (!mounted) return;
    if (savedPath == null) {
      // The user cancelled the save panel → quietly back to the form.
      setState(() {
        _busy = false;
        _phase = _ExportPhase.form;
      });
      return;
    }
    setState(() {
      _busy = false;
      _phase = _ExportPhase.done;
      _savedFormat = format;
      _savedName = _basename(savedPath!);
    });
  }

  void _failFetch() => setState(() {
    _busy = false;
    _phase = _ExportPhase.form;
    _error = 'Couldn’t export right now — check your connection and try again.';
  });

  String _basename(String path) {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  @override
  Widget build(BuildContext context) {
    final p = OnboardingPalette.of(context);
    return Dialog(
      backgroundColor: p.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(11),
        side: BorderSide(color: p.line),
      ),
      child: SizedBox(
        width: 440,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
          child: switch (_phase) {
            _ExportPhase.form => _formBody(p),
            _ExportPhase.done => _doneBody(p),
          },
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
          const SizedBox(height: 8),
          _attributionToggle(p),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: p.chrome(size: 12, color: p.error, height: 1.4)),
          ],
          const SizedBox(height: 12),
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
    final isAnki = _savedFormat == _ExportFormat.anki;
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
          isAnki
              ? '$_cards saved as an Anki deck — double-click it to import, or use File → Import in Anki. '
                    'Revealed in Finder.'
              : '$_csvItems saved as CSV — open it in a spreadsheet, or import it into Anki. Revealed in Finder.',
          textAlign: TextAlign.center,
          style: p.chrome(size: 12.5, color: p.ink2, height: 1.5),
        ),
        const SizedBox(height: 14),
        _fileChip(
          p,
          _savedName,
          '${isAnki ? _cards : _csvItems} · ${isAnki ? 'Anki deck' : 'CSV'}',
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
      return GestureDetector(
        onTap: () => setState(() => _format = f),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: active ? p.card : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: active ? _kEdgeShadowSm : null,
          ),
          child: Text(
            label,
            style: p.chrome(size: 13, weight: FontWeight.w500, color: active ? p.ink : p.ink2),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.primarySoft, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [opt('Anki deck', _ExportFormat.anki), opt('CSV', _ExportFormat.csv)],
      ),
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
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: p.line)),
    ),
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

  Widget _fileChip(OnboardingPalette p, String name, String meta) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
    decoration: BoxDecoration(
      color: p.card,
      border: Border.all(color: p.line),
      borderRadius: BorderRadius.circular(8),
      boxShadow: _kEdgeShadowSm,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.description_outlined, size: 18, color: p.primary),
        const SizedBox(width: 9),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name, style: p.mono(size: 12, color: p.ink)),
            Text(meta, style: p.mono(size: 10.5, color: p.ink3)),
          ],
        ),
      ],
    ),
  );
}

/// A 40×24 pill toggle; off = line track, on = primary track with the knob slid right.
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
      width: 40,
      height: 24,
      decoration: BoxDecoration(
        color: on ? p.primary : p.line,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: p.line),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 120),
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Container(
            width: 18,
            height: 18,
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
