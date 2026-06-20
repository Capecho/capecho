import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:capecho_api/capecho_api.dart' show ExportRow;
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// Verifies the on-device Anki `.apkg` builder produces an import-correct package: a ZIP of a SQLite
/// `collection.anki2` (Anki schema v11) + a `media` map, with one note + one card per export row. The
/// final gate — importing into a real Anki — is manual (the schema mirrors genanki, the de-facto
/// standard, so structural correctness here is strong evidence).
void main() {
  const builder = AnkiDeckBuilder();
  const nowMs = 1700000000000; // fixed → deterministic ids/guids

  final rows = <ExportRow>[
    const ExportRow(
      word: 'serendipity',
      context: 'a fresh serendipity of events',
      contextLanguage: '',
      definition: '(n) a happy accident',
      targetLanguage: 'en',
    ),
    const ExportRow(
      word: 'palabra',
      context: 'the word palabra appears here',
      contextLanguage: 'en', // differs from target → rides as a ctx- tag
      definition: '(n) word',
      targetLanguage: 'es',
    ),
    const ExportRow(
      // A unit that starts with '#': harmless in an .apkg (unlike the TSV, where it would be a comment).
      word: '#define',
      context: '',
      contextLanguage: '',
      definition: '',
      targetLanguage: 'en',
    ),
  ];

  /// Unzip the .apkg, write collection.anki2 to a temp file, and open it.
  ({Database db, Archive archive, Directory tmp}) openDeck(List<int> apkg) {
    final archive = ZipDecoder().decodeBytes(apkg);
    final col = archive.findFile('collection.anki2');
    expect(col, isNotNull, reason: 'an .apkg must contain collection.anki2');
    final tmp = Directory.systemTemp.createTempSync('apkg_test_');
    final path = '${tmp.path}/collection.anki2';
    File(path).writeAsBytesSync(col!.content as List<int>);
    return (db: sqlite3.open(path), archive: archive, tmp: tmp);
  }

  test('package layout: a ZIP of collection.anki2 + an empty media map, nothing else', () {
    final apkg = builder.build(rows, nowMs: nowMs);
    final archive = ZipDecoder().decodeBytes(apkg);
    final names = archive.files.map((f) => f.name).toSet();
    expect(names, {'collection.anki2', 'media'});
    final media = archive.findFile('media')!;
    expect(utf8.decode(media.content as List<int>), '{}');
  });

  test('col row: schema v11, with the Capecho deck + note type registered', () {
    final deck = openDeck(builder.build(rows, nowMs: nowMs));
    try {
      final col = deck.db.select('SELECT ver, decks, models, conf FROM col').first;
      expect(col['ver'], 11);

      final decks = jsonDecode(col['decks'] as String) as Map<String, dynamic>;
      expect(decks.containsKey('1'), isTrue, reason: 'the Default deck is always present');
      // The Capecho deck is registered under a stable non-1 id, named "Capecho".
      final capecho =
          decks.values.firstWhere((d) => d['name'] == 'Capecho') as Map<String, dynamic>;
      expect(capecho['id'], isNot(1));

      final models = jsonDecode(col['models'] as String) as Map<String, dynamic>;
      expect(models, hasLength(1));
      final model = models.values.first as Map<String, dynamic>;
      expect(model['name'], 'Capecho');
      expect((model['flds'] as List).map((f) => f['name']), ['Word', 'Definition', 'Context']);
      expect(model['tmpls'] as List, hasLength(1));
    } finally {
      deck.db.close();
      deck.tmp.deleteSync(recursive: true);
    }
  });

  test('one note + one card per row; fields, tags, and card scheduling are import-correct', () {
    final deck = openDeck(builder.build(rows, nowMs: nowMs));
    try {
      final notes = deck.db.select('SELECT guid, flds, sfld, tags, mid FROM notes ORDER BY id');
      final cards = deck.db.select('SELECT nid, did, ord, type, queue, due FROM cards ORDER BY id');
      expect(notes, hasLength(3));
      expect(cards, hasLength(3));

      // Row 0: three 0x1f-joined fields (Word | Definition | Context), sort field = the word.
      final n0 = notes.first;
      expect((n0['flds'] as String).split('\x1f'), [
        'serendipity',
        '(n) a happy accident',
        'a fresh serendipity of events',
      ]);
      expect(n0['sfld'], 'serendipity');
      expect(n0['tags'], ' en '); // space-wrapped, target language as a tag

      // Row 1: context language differs → ctx- tag alongside the target tag.
      expect(notes[1]['tags'], ' es ctx-en ');

      // Every card is a fresh "new" card in the Capecho deck, ordered by Word Book position.
      final deckId =
          (jsonDecode(deck.db.select('SELECT decks FROM col').first['decks'] as String)
                  as Map<String, dynamic>)
              .values
              .firstWhere((d) => d['name'] == 'Capecho')['id'];
      for (final c in cards) {
        expect(c['did'], deckId);
        expect(c['ord'], 0);
        expect(c['type'], 0);
        expect(c['queue'], 0);
      }
      expect(cards.map((c) => c['due']), [1, 2, 3]);

      // guid is non-empty + unique per note (stable identity for re-import de-dup).
      final guids = notes.map((n) => n['guid'] as String).toSet();
      expect(guids, hasLength(3));
      expect(guids.every((g) => g.isNotEmpty), isTrue);
    } finally {
      deck.db.close();
      deck.tmp.deleteSync(recursive: true);
    }
  });

  test('opt-in attribution adds a captured-with-capecho tag to every note', () {
    final deck = openDeck(builder.build(rows, nowMs: nowMs, attribution: true));
    try {
      final tags = deck.db.select('SELECT tags FROM notes').map((r) => r['tags'] as String);
      expect(tags.every((t) => t.contains('captured-with-capecho')), isTrue);
    } finally {
      deck.db.close();
      deck.tmp.deleteSync(recursive: true);
    }
  });

  test(
    'fields are HTML-escaped + control-stripped (Anki renders flds as HTML); csum is the real SHA-1',
    () {
      final deck = openDeck(
        builder.build([
          const ExportRow(
            word: 'AT&T',
            context: 'use <b>bold</b> & a < b',
            contextLanguage: '',
            definition: 'a & b > c',
            targetLanguage: 'en',
          ),
          // A field carrying a stray 0x1f (the field separator) must NOT split the note into extra fields.
          ExportRow(
            word: 'na${String.fromCharCode(0x1f)}ive', // "na" + U+001F + "ive"
            context: '',
            contextLanguage: '',
            definition: '',
            targetLanguage: 'en',
          ),
        ], nowMs: nowMs),
      );
      try {
        final notes = deck.db.select('SELECT flds, csum FROM notes ORDER BY id');

        // Row 0: & < > are entity-escaped so they render literally; the note still has exactly 3 fields.
        final f0 = (notes.first['flds'] as String).split('\x1f');
        expect(f0, hasLength(3));
        expect(f0[0], 'AT&amp;T');
        expect(f0[1], 'a &amp; b &gt; c');
        expect(f0[2], 'use &lt;b&gt;bold&lt;/b&gt; &amp; a &lt; b');
        expect(f0[0], isNot(contains('<'))); // no raw angle brackets survive

        // Row 1: the stray 0x1f was stripped, so the note still splits into 3 fields (not 4).
        final f1 = (notes[1]['flds'] as String).split('\x1f');
        expect(f1, hasLength(3));
        expect(f1[0], 'naive');

        // csum = int of the first 8 hex of SHA-1 over the (stripped) first field = the raw word.
        final expected = int.parse(
          sha1.convert(utf8.encode('AT&T')).toString().substring(0, 8),
          radix: 16,
        );
        expect(notes.first['csum'], expected);
        expect(notes.first['csum'], isNot(0)); // not the genanki placeholder anymore
      } finally {
        deck.db.close();
        deck.tmp.deleteSync(recursive: true);
      }
    },
  );

  test(
    'note guid is stable across exports (same unit → same guid → re-import updates, not duplicates)',
    () {
      String guidOf(List<int> apkg) {
        final deck = openDeck(apkg);
        try {
          return deck.db.select('SELECT guid FROM notes ORDER BY id').first['guid'] as String;
        } finally {
          deck.db.close();
          deck.tmp.deleteSync(recursive: true);
        }
      }

      // Same (targetLanguage, word) but a CHANGED definition/context, and a different export time → the
      // guid must still match (it's keyed on unit identity, not content/time).
      final first = builder.build(rows, nowMs: nowMs);
      final later = builder.build([
        const ExportRow(
          word: 'serendipity',
          context: 'a different sentence',
          contextLanguage: '',
          definition: 'updated gloss',
          targetLanguage: 'en',
        ),
      ], nowMs: nowMs + 999999);
      expect(guidOf(first), guidOf(later));
    },
  );

  test('an empty word book still produces a valid (note-less) deck', () {
    final deck = openDeck(builder.build(const [], nowMs: nowMs));
    try {
      expect(deck.db.select('SELECT COUNT(*) c FROM notes').first['c'], 0);
      expect(deck.db.select('SELECT COUNT(*) c FROM cards').first['c'], 0);
      expect(deck.db.select('SELECT ver FROM col').first['ver'], 11); // col still well-formed
    } finally {
      deck.db.close();
      deck.tmp.deleteSync(recursive: true);
    }
  });
}
