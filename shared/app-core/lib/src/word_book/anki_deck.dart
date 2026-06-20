import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:capecho_api/capecho_api.dart' show ExportRow;
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

/// Builds a one-click Anki `.apkg` deck — as raw bytes — from the Word Book's export rows, entirely
/// on-device. An `.apkg` is a ZIP of a SQLite `collection.anki2` (Anki schema **v11**) plus a `media`
/// map; modern Anki still imports this legacy single-`collection.anki2` package, so we don't emit the
/// newer `collection.anki21`/protobuf `meta`. The schema + the default `col` JSON (conf/decks/dconf)
/// mirror **genanki**, the de-facto standard Python generator, so the deck imports cleanly across Anki
/// versions.
///
/// Card shape: one note type ("Capecho") with three fields — **Word** (front), **Definition**,
/// **Context** (back) — and one Front→Back template. The BCP-47 `target_language` rides as a note TAG
/// (matching the CSV/TSV export's "language as a tag" decision), as does the context language when it
/// differs, and the opt-in "captured-with-capecho" attribution. (The CSV export stays the full-fidelity
/// format; the deck is the study artifact.)
///
/// Stable identity for clean re-exports: the note type id and deck id are FIXED Capecho constants, so a
/// re-import MERGES into the same "Capecho" deck + note type (no `Capecho-2` proliferation), and each
/// note's `guid` is derived deterministically from `(targetLanguage, word)`, so re-importing an updated
/// deck UPDATES the matching note instead of duplicating it.
///
/// Lives in shared `app-core` so BOTH clients build the SAME deck: the backend hands over structured
/// rows (`GET /export?format=json`) and the packaging happens on-device — macOS saves it via the native
/// panel, mobile hands it to the system share sheet. Needs `sqlite3` + `archive`: `sqlite3` v3 bundles
/// the engine via Dart native-assets (SwiftPM-pure on macOS); mobile bundles the device library via
/// `sqlite3_flutter_libs`.
class AnkiDeckBuilder {
  const AnkiDeckBuilder();

  // Fixed, arbitrary large ids (genanki's "pick one stable random id per project" guidance). Distinct
  // namespaces (models vs decks), but kept distinct anyway for clarity.
  static const int _modelId = 1718384000001;
  static const int _deckId = 1718384000002;
  // Collection creation time (seconds). Fixed like genanki — only affects day-counter math, which Anki
  // recomputes on import.
  static const int _crt = 1411124400;
  static const String _deckName = 'Capecho';
  static const String _modelName = 'Capecho';

  /// Assemble the `.apkg` bytes. [nowMs] is injectable so tests are deterministic (it seeds the
  /// note/card ids + `mod` timestamps); production passes the wall clock.
  Uint8List build(List<ExportRow> rows, {required int nowMs, bool attribution = false}) {
    final modSeconds = nowMs ~/ 1000;

    // genanki writes the db to a temp file then zips it; this `sqlite3` package can't serialize an
    // in-memory db to bytes, so do the same — build on disk, read the bytes, delete. The temp dir is
    // removed in an OUTER finally so a mid-build throw (schema/insert/read) never orphans it (CR).
    final tmpDir = Directory.systemTemp.createTempSync('capecho_apkg_');
    try {
      final dbPath = '${tmpDir.path}/collection.anki2';
      final Uint8List dbBytes;
      final db = sqlite3.open(dbPath);
      try {
        db.execute(_schemaSql);
        _insertCol(db, modSeconds);
        _insertNotesAndCards(
          db,
          rows,
          nowMs: nowMs,
          modSeconds: modSeconds,
          attribution: attribution,
        );
        dbBytes = File(dbPath).readAsBytesSync();
      } finally {
        db.close();
      }

      final archive = Archive()
        ..addFile(ArchiveFile('collection.anki2', dbBytes.length, dbBytes))
        // No media → an empty JSON map (the `media` sidecar is always present in an .apkg).
        ..addFile(ArchiveFile('media', 2, utf8.encode('{}')));
      // archive 4.x: ZipEncoder().encode() returns the zip bytes directly (non-null).
      final zipped = ZipEncoder().encode(archive);
      return Uint8List.fromList(zipped);
    } finally {
      tmpDir.deleteSync(recursive: true);
    }
  }

  void _insertCol(Database db, int modSeconds) {
    final conf = <String, dynamic>{
      'activeDecks': [1],
      'addToCur': true,
      'collapseTime': 1200,
      'curDeck': 1,
      'curModel': '$_modelId',
      'dueCounts': true,
      'estTimes': true,
      'newBury': true,
      'newSpread': 0,
      'nextPos': 1,
      'sortBackwards': false,
      'sortType': 'noteFld',
      'timeLim': 0,
    };
    final models = <String, dynamic>{'$_modelId': _modelJson(modSeconds)};
    final decks = <String, dynamic>{
      '1': _defaultDeckJson(),
      '$_deckId': _capechoDeckJson(modSeconds),
    };

    db.execute('INSERT INTO col VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?);', <Object?>[
      1, // id
      _crt, // crt (s)
      modSeconds * 1000, // mod (ms)
      modSeconds * 1000, // scm (ms) — schema mod time, ≤ mod
      11, // ver
      0, // dty
      0, // usn
      0, // ls
      jsonEncode(conf), // conf
      jsonEncode(models), // models
      jsonEncode(decks), // decks
      jsonEncode(_defaultDconfJson()), // dconf
      '{}', // tags
    ]);
  }

  void _insertNotesAndCards(
    Database db,
    List<ExportRow> rows, {
    required int nowMs,
    required int modSeconds,
    required bool attribution,
  }) {
    final noteStmt = db.prepare('INSERT INTO notes VALUES(?,?,?,?,?,?,?,?,?,?,?);');
    final cardStmt = db.prepare('INSERT INTO cards VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);');
    // One monotonically increasing id-space for notes AND cards (must be unique per table; ascending is
    // also Anki's convention). Start at nowMs, like genanki.
    var nextId = nowMs;
    db.execute('BEGIN;');
    try {
      for (var i = 0; i < rows.length; i++) {
        final r = rows[i];
        final noteId = nextId++;
        final cardId = nextId++;
        // Fields are HTML-escaped (Anki renders flds as HTML) + control-stripped, then 0x1f-joined.
        final flds = [r.word, r.definition, r.context].map(_fieldHtml).join('\x1f');
        noteStmt.execute(<Object?>[
          noteId, // id
          _guidFor(r.targetLanguage, r.word), // guid (stable per unit)
          _modelId, // mid
          modSeconds, // mod (s)
          -1, // usn
          _formatTags(r, attribution: attribution), // tags (space-wrapped)
          flds, // flds
          r.word, // sfld (sort field = stripped first field — the raw word, as Anki would compute)
          _csumFor(r.word), // csum (real SHA-1 checksum → Anki's duplicate-finder works)
          0, // flags
          '', // data
        ]);
        cardStmt.execute(<Object?>[
          cardId, // id
          noteId, // nid
          _deckId, // did
          0, // ord (single template)
          modSeconds, // mod (s)
          -1, // usn
          0, // type = new
          0, // queue = new
          i + 1, // due (new-card order = Word Book order)
          0, // ivl
          0, // factor
          0, // reps
          0, // lapses
          0, // left
          0, // odue
          0, // odid
          0, // flags
          '', // data
        ]);
      }
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    } finally {
      noteStmt.close();
      cardStmt.close();
    }
  }

  // --- note tags -------------------------------------------------------------
  // Anki tags are space-delimited and the field is stored wrapped in a leading + trailing space.
  // Carries: the target language, the context language when it differs, and opt-in attribution.
  String _formatTags(ExportRow r, {required bool attribution}) {
    final tags = <String>[];
    if (r.targetLanguage.isNotEmpty) tags.add(_sanitizeTag(r.targetLanguage));
    if (r.contextLanguage.isNotEmpty) tags.add('ctx-${_sanitizeTag(r.contextLanguage)}');
    if (attribution) tags.add('captured-with-capecho');
    if (tags.isEmpty) return '';
    return ' ${tags.join(' ')} ';
  }

  // A tag can't contain whitespace; collapse any to '-' (BCP-47 tags have none, but be defensive).
  String _sanitizeTag(String s) => s.trim().replaceAll(RegExp(r'\s+'), '-');

  // --- note fields -----------------------------------------------------------
  // Anki note fields are HTML: a card renders `{{Word}}` etc. as markup. Escape the captured text so
  // `&`, `<`, `>` (e.g. "AT&T", "x<y", "<email>", a code snippet) render LITERALLY instead of as
  // broken tags/entities. `&` is escaped first so the `<`/`>` replacements don't double-encode it. Also
  // strip C0 control chars — crucially the 0x1f field separator — so a stray control char in a capture
  // can never split the note into extra fields. (\t \n \r are kept; HTML renders them as whitespace.)
  static final RegExp _c0Controls = RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]');
  String _fieldHtml(String s) => s
      .replaceAll(_c0Controls, '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  // Anki's note checksum: the integer of the first 8 hex digits of SHA-1 over the *stripped* first
  // field. Because we HTML-escape the stored field, Anki's stripHTMLMedia(stored) equals the raw word,
  // so hashing the raw word reproduces exactly what Anki computes — keeping the built-in duplicate
  // finder working without forcing a "Check Database" pass. (genanki ships 0 here; we compute the real
  // value since `crypto` is already on hand — strictly closer to a native-Anki note.)
  int _csumFor(String firstField) {
    final hex = sha1.convert(utf8.encode(firstField)).toString(); // 40 lowercase hex chars
    return int.parse(hex.substring(0, 8), radix: 16);
  }

  // --- stable note guid ------------------------------------------------------
  // genanki seeds the guid from the note fields (sha256 → base91). We seed from (targetLanguage, word)
  // instead — that's the unit's identity (dedup is by user × target_language × normalized_unit), so the
  // guid is stable across re-exports even if the definition/context changes (Anki then UPDATES the note
  // on re-import rather than duplicating). FNV-1a-64 avoids a crypto dependency; base91 matches Anki.
  static const List<String> _base91 = [
    'a',
    'b',
    'c',
    'd',
    'e',
    'f',
    'g',
    'h',
    'i',
    'j',
    'k',
    'l',
    'm',
    'n',
    'o',
    'p',
    'q',
    'r',
    's', //
    't',
    'u',
    'v',
    'w',
    'x',
    'y',
    'z',
    'A',
    'B',
    'C',
    'D',
    'E',
    'F',
    'G',
    'H',
    'I',
    'J',
    'K',
    'L', //
    'M',
    'N',
    'O',
    'P',
    'Q',
    'R',
    'S',
    'T',
    'U',
    'V',
    'W',
    'X',
    'Y',
    'Z',
    '0',
    '1',
    '2',
    '3',
    '4', //
    '5',
    '6',
    '7',
    '8',
    '9',
    '!',
    '#',
    r'$',
    '%',
    '&',
    '(',
    ')',
    '*',
    '+',
    ',',
    '-',
    '.',
    '/',
    ':', //
    ';', '<', '=', '>', '?', '@', '[', ']', '^', '_', '`', '{', '|', '}', '~',
  ];

  String _guidFor(String targetLanguage, String word) {
    final mask = (BigInt.one << 64) - BigInt.one;
    final prime = BigInt.parse('100000001b3', radix: 16);
    var hash = BigInt.parse('cbf29ce484222325', radix: 16); // FNV offset basis
    for (final b in utf8.encode('$targetLanguage\x1f$word')) {
      hash = (hash ^ BigInt.from(b)) & mask;
      hash = (hash * prime) & mask;
    }
    if (hash == BigInt.zero) return _base91[0];
    final out = <String>[];
    final base = BigInt.from(_base91.length);
    var n = hash;
    while (n > BigInt.zero) {
      out.add(_base91[(n % base).toInt()]);
      n = n ~/ base;
    }
    return out.reversed.join();
  }

  // --- note type (model) -----------------------------------------------------
  Map<String, dynamic> _modelJson(int modSeconds) {
    Map<String, dynamic> field(String name, int ord) => {
      'name': name,
      'ord': ord,
      'font': 'Arial',
      'media': <String>[],
      'rtl': false,
      'size': 20,
      'sticky': false,
    };
    return {
      'css': _css,
      'did': _deckId,
      'flds': [field('Word', 0), field('Definition', 1), field('Context', 2)],
      'id': '$_modelId',
      'latexPost': r'\end{document}',
      'latexPre':
          '\\documentclass[12pt]{article}\n\\special{papersize=3in,5in}\n\\usepackage[utf8]{inputenc}\n'
          '\\usepackage{amssymb,amsmath}\n\\pagestyle{empty}\n\\setlength{\\parindent}{0in}\n'
          '\\begin{document}\n',
      'latexsvg': false,
      'mod': modSeconds,
      'name': _modelName,
      // Front needs Word → it's the one required field.
      'req': [
        [
          0,
          'all',
          [0],
        ],
      ],
      'sortf': 0,
      'tags': <String>[],
      'tmpls': [
        {
          'name': 'Card 1',
          'ord': 0,
          'qfmt': '{{Word}}',
          'afmt':
              '{{FrontSide}}\n\n<hr id="answer">\n\n{{Definition}}\n'
              '{{#Context}}<div class="capecho-context">{{Context}}</div>{{/Context}}',
          'bqfmt': '',
          'bafmt': '',
          'bfont': '',
          'bsize': 0,
          'did': null,
        },
      ],
      'type': 0,
      'usn': -1,
      'vers': <dynamic>[],
    };
  }

  static const String _css =
      '.card {\n'
      '  font-family: -apple-system, "Helvetica Neue", Arial, sans-serif;\n'
      '  font-size: 20px;\n'
      '  text-align: center;\n'
      '  color: #2b2320;\n'
      '  background-color: #faf6f0;\n'
      '}\n'
      '.capecho-context {\n'
      '  margin-top: 14px;\n'
      '  font-size: 16px;\n'
      '  font-style: italic;\n'
      '  color: #6f655c;\n'
      '}\n';

  // --- decks + deck config (genanki defaults) --------------------------------
  Map<String, dynamic> _capechoDeckJson(int modSeconds) => {
    'collapsed': false,
    'conf': 1,
    'desc': 'Captured with Capecho',
    'dyn': 0,
    'extendNew': 0,
    'extendRev': 50,
    'id': _deckId,
    'lrnToday': [0, 0],
    'mod': modSeconds,
    'name': _deckName,
    'newToday': [0, 0],
    'revToday': [0, 0],
    'timeToday': [0, 0],
    'usn': -1,
  };

  Map<String, dynamic> _defaultDeckJson() => {
    'collapsed': false,
    'conf': 1,
    'desc': '',
    'dyn': 0,
    'extendNew': 10,
    'extendRev': 50,
    'id': 1,
    'lrnToday': [0, 0],
    'mod': 1425279151,
    'name': 'Default',
    'newToday': [0, 0],
    'revToday': [0, 0],
    'timeToday': [0, 0],
    'usn': 0,
  };

  Map<String, dynamic> _defaultDconfJson() => {
    '1': {
      'autoplay': true,
      'id': 1,
      'lapse': {
        'delays': [10],
        'leechAction': 0,
        'leechFails': 8,
        'minInt': 1,
        'mult': 0,
      },
      'maxTaken': 60,
      'mod': 0,
      'name': 'Default',
      'new': {
        'bury': true,
        'delays': [1, 10],
        'initialFactor': 2500,
        'ints': [1, 4, 7],
        'order': 1,
        'perDay': 20,
        'separate': true,
      },
      'replayq': true,
      'rev': {
        'bury': true,
        'ease4': 1.3,
        'fuzz': 0.05,
        'ivlFct': 1,
        'maxIvl': 36500,
        'minSpace': 1,
        'perDay': 100,
      },
      'timer': 0,
      'usn': 0,
    },
  };

  // --- collection.anki2 schema (Anki v11 — verbatim genanki APKG_SCHEMA) ------
  static const String _schemaSql = '''
CREATE TABLE col (
    id              integer primary key,
    crt             integer not null,
    mod             integer not null,
    scm             integer not null,
    ver             integer not null,
    dty             integer not null,
    usn             integer not null,
    ls              integer not null,
    conf            text not null,
    models          text not null,
    decks           text not null,
    dconf           text not null,
    tags            text not null
);
CREATE TABLE notes (
    id              integer primary key,
    guid            text not null,
    mid             integer not null,
    mod             integer not null,
    usn             integer not null,
    tags            text not null,
    flds            text not null,
    sfld            integer not null,
    csum            integer not null,
    flags           integer not null,
    data            text not null
);
CREATE TABLE cards (
    id              integer primary key,
    nid             integer not null,
    did             integer not null,
    ord             integer not null,
    mod             integer not null,
    usn             integer not null,
    type            integer not null,
    queue           integer not null,
    due             integer not null,
    ivl             integer not null,
    factor          integer not null,
    reps            integer not null,
    lapses          integer not null,
    left            integer not null,
    odue            integer not null,
    odid            integer not null,
    flags           integer not null,
    data            text not null
);
CREATE TABLE revlog (
    id              integer primary key,
    cid             integer not null,
    usn             integer not null,
    ease            integer not null,
    ivl             integer not null,
    lastIvl         integer not null,
    factor          integer not null,
    time            integer not null,
    type            integer not null
);
CREATE TABLE graves (
    usn             integer not null,
    oid             integer not null,
    type            integer not null
);
CREATE INDEX ix_notes_usn on notes (usn);
CREATE INDEX ix_cards_usn on cards (usn);
CREATE INDEX ix_revlog_usn on revlog (usn);
CREATE INDEX ix_cards_nid on cards (nid);
CREATE INDEX ix_cards_sched on cards (did, queue, due);
CREATE INDEX ix_revlog_cid on revlog (cid);
CREATE INDEX ix_notes_csum on notes (csum);
''';
}
