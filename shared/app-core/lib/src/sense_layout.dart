import 'package:capecho_api/capecho_api.dart' show WordExplanation, Reading;

/// Shared presentation of a [WordExplanation]'s per-POS senses — one tested home so the macOS overlay
/// (a native Swift mirror), the Word Book, and Review agree. Each reading is a block (heteronyms get one
/// per pronunciation; an idiom suppresses IPA); each part of speech is ONE line of all its senses; a
/// parenthetical repeated on every sense (a form note like "make 的现在分词") is pulled to a single
/// [SensePosRow.note] at the front. Every sense is shown — there is no cap and no "more" hint (every
/// surface renders the full set, scrolling if tall).
class SenseLayout {
  const SenseLayout({required this.readings});

  /// The reading blocks, in order. Empty when the blob carries no usable sense.
  final List<SenseReadingRow> readings;
}

/// One reading block: its pronunciation slots (empty for an idiom) + its POS rows.
class SenseReadingRow {
  const SenseReadingRow({
    required this.pronunciationPrimary,
    required this.pronunciationSecondary,
    required this.isIdiom,
    required this.pos,
  });

  final String pronunciationPrimary;
  final String pronunciationSecondary;
  final bool isIdiom;
  final List<SensePosRow> pos;

  bool get hasPronunciation => pronunciationPrimary.isNotEmpty || pronunciationSecondary.isNotEmpty;
}

/// One POS row: the label + all its senses, with any shared trailing [note] pulled to the front once.
class SensePosRow {
  const SensePosRow({required this.partOfSpeech, required this.senses, this.note = ''});

  final String partOfSpeech;
  final List<String> senses;

  /// A note shared by every sense — e.g. "make 的现在分词" on an inflected form — shown once at the
  /// front instead of on each sense. Empty when the senses share no common trailing note.
  final String note;
}

/// Build the [SenseLayout]: drop blank senses, empty POS groups, and readings with no POS, so the result
/// renders without per-call guards. Shows every stored sense (uncapped — the surface scrolls if tall).
SenseLayout computeSenseLayout(WordExplanation explanation) {
  final readings = <SenseReadingRow>[];
  for (final Reading r in explanation.readings) {
    final rows = <SensePosRow>[];
    for (final g in r.pos) {
      final clean = [
        for (final s in g.senses)
          if (s.trim().isNotEmpty) s.trim(),
      ];
      if (clean.isEmpty) continue;
      final (senses, note) = _extractSharedTrailingNote(clean);
      rows.add(SensePosRow(partOfSpeech: g.partOfSpeech, senses: senses, note: note));
    }
    if (rows.isEmpty) continue;
    readings.add(
      SenseReadingRow(
        pronunciationPrimary: r.pronunciationPrimary,
        pronunciationSecondary: r.pronunciationSecondary,
        isIdiom: r.isIdiom,
        pos: rows,
      ),
    );
  }
  return SenseLayout(readings: readings);
}

/// A trailing parenthetical (half- or full-width) at the end of a sense, capturing the inner text.
final RegExp _trailingNote = RegExp(r'[(（]\s*([^()（）]+?)\s*[)）]\s*$');

/// When every sense ends with the SAME parenthetical (the model annotates each sense of an inflected
/// form — "制造 (make 的现在分词); 做 (make 的现在分词)"), pull it out to show once. Returns the senses
/// unchanged + '' when they don't all share one note, there's only one sense, or stripping empties one.
(List<String>, String) _extractSharedTrailingNote(List<String> senses) {
  if (senses.length < 2) return (senses, '');
  String? note;
  final stripped = <String>[];
  for (final s in senses) {
    final m = _trailingNote.firstMatch(s);
    if (m == null) return (senses, '');
    final inner = m.group(1)!.trim();
    note ??= inner;
    if (inner != note) return (senses, '');
    final head = s.substring(0, m.start).trim();
    if (head.isEmpty) return (senses, '');
    stripped.add(head);
  }
  return (stripped, note ?? '');
}
