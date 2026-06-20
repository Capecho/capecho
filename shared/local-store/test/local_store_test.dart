import 'dart:io';

import 'package:capecho_local_store/capecho_local_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Stub normalizer: trim + lowercase. Deterministic, mirroring what `localDedupKey` does at a coarse
/// level (enough to exercise dedup).
String stubNormalizer(String surfaceUnit) => surfaceUnit.trim().toLowerCase();

const String kVersion = 'v-test';

/// Builds a [JournalEntry] with sensible defaults so each test only specifies what it cares about.
JournalEntry entry({
  required int seq,
  required String clientRowId,
  String installId = 'install-1',
  String surfaceUnit = 'serendipity',
  String targetLanguage = 'en',
  String? contextText = 'a moment of pure serendipity',
  String? contextLanguage = 'en',
  int? spanStart = 12,
  int? spanEnd = 23,
  String source = 'ocr',
  String? sourceApp = 'Google Chrome',
  String? sourceTitle = 'Serendipity — Wikipedia',
  String? detectedLanguage = 'en',
  double? detectedLanguageConfidence = 0.92,
  int capturedAt = 1000,
}) {
  return JournalEntry(
    seq: seq,
    clientRowId: clientRowId,
    installId: installId,
    surfaceUnit: surfaceUnit,
    targetLanguage: targetLanguage,
    contextText: contextText,
    contextLanguage: contextLanguage,
    spanStart: spanStart,
    spanEnd: spanEnd,
    source: source,
    sourceApp: sourceApp,
    sourceTitle: sourceTitle,
    detectedLanguage: detectedLanguage,
    detectedLanguageConfidence: detectedLanguageConfidence,
    capturedAt: capturedAt,
  );
}

LocalStore freshStore() => LocalStore.openInMemory(
      normalizer: stubNormalizer,
      normalizationVersion: kVersion,
    );

void main() {
  group('hasActiveWord (overlay already-saved cue, bug #6)', () {
    test('true after drain; false for other unit/language; false when tombstoned', () {
      final store = freshStore();
      addTearDown(store.close);
      expect(store.hasActiveWord('serendipity', 'en'), isFalse);
      store.drain([entry(seq: 1, clientRowId: 'ctx-1')]); // surfaceUnit 'serendipity', en
      expect(store.hasActiveWord('serendipity', 'en'), isTrue);
      // The stub normalizer trims + lowercases, so a different surface form still matches.
      expect(store.hasActiveWord('  Serendipity ', 'en'), isTrue);
      // A different language / unit is not saved.
      expect(store.hasActiveWord('serendipity', 'de'), isFalse);
      expect(store.hasActiveWord('elsewhere', 'en'), isFalse);
      // A soft-deleted (tombstoned) word no longer counts as active.
      store.softDelete(store.activeWords().single.clientRowId);
      expect(store.hasActiveWord('serendipity', 'en'), isFalse);
    });

    test(
        'claimed word matches its OWN account signed in, never the signed-out catalog (leak guard R2)',
        () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'ctx-1')]); // anonymous 'serendipity'
      store
          .markClaimed([store.activeWords().single.clientRowId], 'acct-A'); // synced into account A
      // Signed in as the OWNING account → still reads as saved.
      expect(store.hasActiveWord('serendipity', 'en', accountId: 'acct-A'), isTrue);
      // Signed out (no account id) → must NOT reveal the account-only word.
      expect(store.hasActiveWord('serendipity', 'en'), isFalse);
    });

    test('a word only ANOTHER account synced does not read as saved (cross-account cue fix)', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'ctx-1')]); // anonymous 'serendipity'
      store
          .markClaimed([store.activeWords().single.clientRowId], 'acct-A'); // synced into account A
      // Signed in as a DIFFERENT account B on the same shared device: A's word is not in B's book, so
      // the cue must read NOT saved (the bug was a global claimed flag matching every account).
      expect(store.hasActiveWord('serendipity', 'en', accountId: 'acct-B'), isFalse);
      // A still sees it (its owner is recorded), and B's re-capture below would land a fresh anon row.
      expect(store.hasActiveWord('serendipity', 'en', accountId: 'acct-A'), isTrue);
    });

    test(
        'an anonymous (un-synced) row reads as saved signed OUT but NOT signed in (it is not in any '
        'account book until synced)', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'ctx-1')]); // anonymous 'serendipity', never claimed
      // Signed out: the anonymous catalog IS the Word Book, so the cue reads saved.
      expect(store.hasActiveWord('serendipity', 'en'), isTrue);
      // Signed in: the book reads the server account, where an un-synced anonymous row is absent — so
      // the cue must NOT claim "already in your Word Book" (the account-switch false-positive fix). It
      // flips to saved the moment the row is claimed into the account.
      expect(store.hasActiveWord('serendipity', 'en', accountId: 'acct-A'), isFalse);
      store.markClaimed([store.activeWords().single.clientRowId], 'acct-A');
      expect(store.hasActiveWord('serendipity', 'en', accountId: 'acct-A'), isTrue);
    });
  });

  group('explanation cache (word_explanations)', () {
    test('put then get round-trips a heteronym — both readings, IPA, per-POS senses', () {
      final store = freshStore();
      addTearDown(store.close);
      store.putExplanation(
        surfaceUnit: 'object',
        targetLanguage: 'en',
        explanationLanguage: 'en',
        readings: const [
          LocalReading(
            pronunciationPrimary: 'ˈɑbdʒɛkt',
            pronunciationSecondary: 'ˈɒbdʒɪkt',
            pos: [
              LocalPosGroup(
                  partOfSpeech: 'noun', senses: ['a thing you can see or touch', 'a goal']),
            ],
          ),
          LocalReading(
            pronunciationPrimary: 'əbˈdʒɛkt',
            pronunciationSecondary: 'əbˈdʒɛkt',
            pos: [
              LocalPosGroup(partOfSpeech: 'verb', senses: ['to disagree']),
            ],
          ),
        ],
        now: 1000,
      );
      final hit = store.getExplanation(
          surfaceUnit: 'object', targetLanguage: 'en', explanationLanguage: 'en');
      expect(hit, isNotNull);
      expect(
          hit!.readings.map((r) => (r.pronunciationPrimary, r.pronunciationSecondary)).toList(), [
        ('ˈɑbdʒɛkt', 'ˈɒbdʒɪkt'),
        ('əbˈdʒɛkt', 'əbˈdʒɛkt'),
      ]);
      expect(hit.readings.map((r) => r.pos.single.partOfSpeech).toList(), ['noun', 'verb']);
      expect(hit.readings.first.pos.single.senses, ['a thing you can see or touch', 'a goal']);
      expect(hit.readings.last.pos.single.senses, ['to disagree']);
    });

    test('an idiom reading round-trips (kind = idiom, no transcription, senses carry the meaning)',
        () {
      final store = freshStore();
      addTearDown(store.close);
      store.putExplanation(
        surfaceUnit: 'out of the blue',
        targetLanguage: 'en',
        explanationLanguage: 'en',
        readings: const [
          LocalReading(
            pronunciationPrimary: '',
            pronunciationSecondary: '',
            kind: 'idiom',
            pos: [
              LocalPosGroup(
                  partOfSpeech: 'idiom',
                  senses: ['said when something arrives without any warning at all']),
            ],
          ),
        ],
        now: 1000,
      );
      final hit = store.getExplanation(
          surfaceUnit: 'out of the blue', targetLanguage: 'en', explanationLanguage: 'en');
      expect(hit, isNotNull);
      final reading = hit!.readings.single;
      expect(reading.kind, 'idiom');
      expect(reading.pronunciationPrimary, isEmpty);
      expect(reading.pos.single.senses, ['said when something arrives without any warning at all']);
    });

    test('a miss returns null', () {
      final store = freshStore();
      addTearDown(store.close);
      expect(
        store.getExplanation(
            surfaceUnit: 'unknown', targetLanguage: 'en', explanationLanguage: 'en'),
        isNull,
      );
    });

    test('keyed by the normalized unit — a different surface form of the same unit hits', () {
      final store = freshStore();
      addTearDown(store.close);
      store.putExplanation(
        surfaceUnit: '  Serendipity ', // normalizes (trim + lower) to 'serendipity'
        targetLanguage: 'en',
        explanationLanguage: 'en',
        readings: const [
          LocalReading(pronunciationPrimary: '', pronunciationSecondary: '', pos: [
            LocalPosGroup(
                partOfSpeech: 'noun', senses: ['finding something good purely by lucky chance']),
          ]),
        ],
        now: 1,
      );
      final hit = store.getExplanation(
          surfaceUnit: 'serendipity', targetLanguage: 'en', explanationLanguage: 'en');
      expect(hit?.readings.single.pos.single.senses.single,
          'finding something good purely by lucky chance');
    });

    test('newest put wins (INSERT OR REPLACE on the same key)', () {
      final store = freshStore();
      addTearDown(store.close);
      LocalReading sensed(String s) =>
          LocalReading(pronunciationPrimary: '', pronunciationSecondary: '', pos: [
            LocalPosGroup(partOfSpeech: 'noun', senses: [s]),
          ]);
      store.putExplanation(
          surfaceUnit: 'bank',
          targetLanguage: 'en',
          explanationLanguage: 'en',
          readings: [sensed('the raised ground along a river')],
          now: 1);
      store.putExplanation(
          surfaceUnit: 'bank',
          targetLanguage: 'en',
          explanationLanguage: 'en',
          readings: [sensed('a place that keeps and lends money')],
          now: 2);
      expect(
        store
            .getExplanation(surfaceUnit: 'bank', targetLanguage: 'en', explanationLanguage: 'en')
            ?.readings
            .single
            .pos
            .single
            .senses
            .single,
        'a place that keeps and lends money',
      );
    });

    test('scoped by explanation language AND target language', () {
      final store = freshStore();
      addTearDown(store.close);
      store.putExplanation(
          surfaceUnit: 'gato',
          targetLanguage: 'es',
          explanationLanguage: 'en',
          readings: const [
            LocalReading(pronunciationPrimary: '', pronunciationSecondary: '', pos: [
              LocalPosGroup(partOfSpeech: 'noun', senses: ['a cat'])
            ]),
          ],
          now: 1);
      // Same unit + target, different EXPLANATION language → miss.
      expect(
        store.getExplanation(
            surfaceUnit: 'gato', targetLanguage: 'es', explanationLanguage: 'zh-Hans'),
        isNull,
      );
      // Same unit + explanation language, different TARGET language → miss.
      expect(
        store.getExplanation(surfaceUnit: 'gato', targetLanguage: 'pt', explanationLanguage: 'en'),
        isNull,
      );
    });

    test('senses are MUST-PASS: a senseless blob, or an empty-normalizing unit, is never cached',
        () {
      final store = freshStore();
      addTearDown(store.close);
      // A blob whose only POS has nothing but blank senses → not cached (pronunciation alone is not an
      // explanation; there is no fallback field).
      store.putExplanation(
          surfaceUnit: 'word',
          targetLanguage: 'en',
          explanationLanguage: 'en',
          readings: const [
            LocalReading(pronunciationPrimary: 'wɝd', pronunciationSecondary: '', pos: [
              LocalPosGroup(partOfSpeech: 'noun', senses: ['  '])
            ]),
          ],
          now: 1);
      expect(
        store.getExplanation(surfaceUnit: 'word', targetLanguage: 'en', explanationLanguage: 'en'),
        isNull,
      );
      // No readings at all → nothing to show → not cached.
      store.putExplanation(
          surfaceUnit: 'empty',
          targetLanguage: 'en',
          explanationLanguage: 'en',
          readings: const [],
          now: 1);
      expect(
        store.getExplanation(surfaceUnit: 'empty', targetLanguage: 'en', explanationLanguage: 'en'),
        isNull,
      );
      // A unit that normalizes to empty → not cached even with a real sense.
      store.putExplanation(
          surfaceUnit: '   ',
          targetLanguage: 'en',
          explanationLanguage: 'en',
          readings: const [
            LocalReading(pronunciationPrimary: '', pronunciationSecondary: '', pos: [
              LocalPosGroup(partOfSpeech: 'noun', senses: ['whitespace'])
            ]),
          ],
          now: 1);
      expect(
        store.getExplanation(surfaceUnit: '   ', targetLanguage: 'en', explanationLanguage: 'en'),
        isNull,
      );
    });

    test('the usable filter drops senseless POS + readings, keeps the real one + its blank senses',
        () {
      final store = freshStore();
      addTearDown(store.close);
      store.putExplanation(
        surfaceUnit: 'mixed',
        targetLanguage: 'en',
        explanationLanguage: 'en',
        readings: const [
          // A reading whose POS has only a blank sense → the POS drops → the reading drops.
          LocalReading(pronunciationPrimary: 'noise', pronunciationSecondary: '', pos: [
            LocalPosGroup(partOfSpeech: 'noun', senses: [''])
          ]),
          // A real reading: a blank sense is stripped, the real one survives.
          LocalReading(pronunciationPrimary: 'mɪkst', pronunciationSecondary: '', pos: [
            LocalPosGroup(partOfSpeech: 'adjective', senses: ['', 'made of different things']),
          ]),
        ],
        now: 1,
      );
      final hit = store.getExplanation(
          surfaceUnit: 'mixed', targetLanguage: 'en', explanationLanguage: 'en');
      expect(hit!.readings.single.pronunciationPrimary, 'mɪkst'); // the senseless reading dropped
      expect(hit.readings.single.pos.single.partOfSpeech, 'adjective');
      expect(hit.readings.single.pos.single.senses, ['made of different things']); // blank stripped
    });

    test('survives reopen (persisted to disk)', () {
      final dir = Directory.systemTemp.createTempSync('capecho-expl-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/store.db';
      final s1 =
          LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion);
      s1.putExplanation(
          surfaceUnit: 'persist',
          targetLanguage: 'en',
          explanationLanguage: 'en',
          readings: const [
            LocalReading(pronunciationPrimary: 'pərˈsɪst', pronunciationSecondary: 'pəˈsɪst', pos: [
              LocalPosGroup(
                  partOfSpeech: 'verb',
                  senses: ['to keep going even when stopping would be easier']),
            ]),
          ],
          now: 1);
      s1.close();
      final s2 =
          LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion);
      addTearDown(s2.close);
      final hit = s2.getExplanation(
          surfaceUnit: 'persist', targetLanguage: 'en', explanationLanguage: 'en');
      expect(hit, isNotNull);
      expect(hit!.readings.single.pronunciationPrimary, 'pərˈsɪst');
      expect(hit.readings.single.pronunciationSecondary, 'pəˈsɪst');
      expect(hit.readings.single.pos.single.partOfSpeech, 'verb');
      expect(hit.readings.single.pos.single.senses.single,
          'to keep going even when stopping would be easier');
    });

    test('a corrupt / senseless cached row degrades to a MISS (never throws on the capture path)',
        () {
      final dir = Directory.systemTemp.createTempSync('capecho-expl-corrupt-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/store.db';
      // Let LocalStore create the schema, then hand-write malformed rows via a raw connection
      // (the writer never produces these — this guards a truncated write / manual edit / disk corruption).
      LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion)
          .close();
      final raw = sqlite3.open(path);
      raw.execute(
        'INSERT INTO word_explanations(target_language, normalized_unit, explanation_language, readings, cached_at) '
        "VALUES('en', 'badjson', 'en', 'not valid json', 1)",
      );
      // A well-formed blob whose only POS carries NO sense → a miss (senses are the only text).
      raw.execute(
        'INSERT INTO word_explanations(target_language, normalized_unit, explanation_language, readings, cached_at) '
        '''VALUES('en', 'nosense', 'en', '[{"pronunciationPrimary":"x","pronunciationSecondary":"","pos":[{"partOfSpeech":"noun","senses":[],"hasMore":false}]}]', 1)''',
      );
      // A non-string sense element must be a miss AT READ TIME — a lazy `.cast<String>()` view would
      // return a "hit" that throws on first iteration, outside the guard, on the overlay path.
      raw.execute(
        'INSERT INTO word_explanations(target_language, normalized_unit, explanation_language, readings, cached_at) '
        '''VALUES('en', 'badsense', 'en', '[{"pronunciationPrimary":"x","pronunciationSecondary":"","pos":[{"partOfSpeech":"noun","senses":["a thing", 7],"hasMore":false}]}]', 1)''',
      );
      raw.close();
      final store =
          LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion);
      addTearDown(store.close);
      expect(
        store.getExplanation(
            surfaceUnit: 'badjson', targetLanguage: 'en', explanationLanguage: 'en'),
        isNull, // malformed JSON → caught → a miss, not a crash
      );
      expect(
        store.getExplanation(
            surfaceUnit: 'nosense', targetLanguage: 'en', explanationLanguage: 'en'),
        isNull, // no sense = nothing to show — a miss, never a fallback
      );
      expect(
        store.getExplanation(
            surfaceUnit: 'badsense', targetLanguage: 'en', explanationLanguage: 'en'),
        isNull, // non-string element → caught eagerly → a miss
      );
    });

    test('v3 → v4 migration reshapes word_explanations (old-shape rows wiped; words untouched)',
        () {
      final dir = Directory.systemTemp.createTempSync('capecho-expl-migrate-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/store.db';
      // Build a current store with a word that must SURVIVE the explanation reshape.
      final s1 =
          LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion);
      s1.drain([entry(seq: 1, clientRowId: 'ctx-1')]);
      s1.close();
      // Rewind to a v3-shaped DB: recreate the OLD word_explanations (a `summary` column + the old
      // `readings` shape), seed an old-shape row, and roll the stored version back to 3.
      final raw = sqlite3.open(path);
      raw.execute('DROP TABLE word_explanations');
      raw.execute('''
        CREATE TABLE word_explanations (
          target_language      TEXT NOT NULL,
          normalized_unit      TEXT NOT NULL,
          explanation_language TEXT NOT NULL,
          summary              TEXT NOT NULL DEFAULT '',
          readings             TEXT NOT NULL,
          cached_at            INTEGER NOT NULL,
          PRIMARY KEY (target_language, normalized_unit, explanation_language)
        );
      ''');
      raw.execute(
        'INSERT INTO word_explanations(target_language, normalized_unit, explanation_language, summary, readings, cached_at) '
        '''VALUES('en', 'object', 'en', 'old summary', '[{"pronunciationPrimary":"x","pronunciationSecondary":"","partsOfSpeech":["noun"]}]', 1)''',
      );
      raw.execute("UPDATE meta SET value = '3' WHERE key = 'schema_version'");
      raw.close();
      // Reopen → the v3→v4 step DROPs + recreates word_explanations (new shape), so the old-shape row
      // is gone; the word survives.
      final s2 =
          LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion);
      addTearDown(s2.close);
      expect(
        s2.getExplanation(surfaceUnit: 'object', targetLanguage: 'en', explanationLanguage: 'en'),
        isNull, // the old-shape row is gone (next /explain refills the new shape)
      );
      expect(s2.hasActiveWord('serendipity', 'en'), isTrue); // words untouched
      // The reshaped table has the new shape: a summary-less INSERT (the v4 writer's columns) succeeds,
      // proving the `summary` column was dropped.
      s2.putExplanation(
          surfaceUnit: 'object',
          targetLanguage: 'en',
          explanationLanguage: 'en',
          readings: const [
            LocalReading(pronunciationPrimary: 'ˈɑbdʒɛkt', pronunciationSecondary: '', pos: [
              LocalPosGroup(partOfSpeech: 'noun', senses: ['a thing'])
            ]),
          ],
          now: 2);
      expect(
        s2
            .getExplanation(surfaceUnit: 'object', targetLanguage: 'en', explanationLanguage: 'en')
            ?.readings
            .single
            .pos
            .single
            .senses
            .single,
        'a thing',
      );
      final version = sqlite3.open(path);
      addTearDown(version.close);
      expect(
        version.select("SELECT value FROM meta WHERE key = 'schema_version'").first['value'],
        '$kSchemaVersion',
      );
    });

    test('v2 → v3 migration adds capture-source columns, backfilling NULL (rows untouched)', () {
      final dir = Directory.systemTemp.createTempSync('capecho-v3-migrate-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/store.db';
      // Build a current store with a word + context, then rewind to a v2-shaped DB that LACKS the v3
      // source columns (drop them, since the current base DDL creates them on a fresh open).
      final s1 =
          LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion);
      s1.drain([entry(seq: 1, clientRowId: 'ctx-1', contextText: 'a sentence')]);
      s1.close();
      final raw = sqlite3.open(path);
      for (final col in const [
        'source_app',
        'source_title',
        'detected_language',
        'detected_language_confidence',
      ]) {
        raw.execute('ALTER TABLE word_contexts DROP COLUMN $col');
      }
      raw.execute("UPDATE meta SET value = '2' WHERE key = 'schema_version'");
      raw.close();
      // Reopen → the v2→v3 step re-adds the columns; the pre-existing context row reads NULL for them.
      final s2 =
          LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion);
      addTearDown(s2.close);
      final words = s2.activeWords();
      expect(words, hasLength(1));
      final ctx = s2.contextsFor(words.single.clientRowId).single;
      expect(ctx.contextText, 'a sentence'); // row content untouched
      expect(ctx.sourceApp, isNull);
      expect(ctx.sourceTitle, isNull);
      expect(ctx.detectedLanguage, isNull);
      expect(ctx.detectedLanguageConfidence, isNull);
    });

    test('v4 → v5 migration adds the gloss_meaning column, backfilling NULL (rows untouched)', () {
      final dir = Directory.systemTemp.createTempSync('capecho-v5-migrate-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/store.db';
      final s1 =
          LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion);
      s1.drain([entry(seq: 1, clientRowId: 'ctx-1', contextText: 'a sentence')]);
      s1.close();
      // Rewind to a v4-shaped DB that LACKS the v5 gloss column.
      final raw = sqlite3.open(path);
      raw.execute('ALTER TABLE word_contexts DROP COLUMN gloss_meaning');
      raw.execute("UPDATE meta SET value = '4' WHERE key = 'schema_version'");
      raw.close();
      // Reopen → the v4→v5 step re-adds the column; the pre-existing row reads NULL, and a gloss can be set.
      final s2 =
          LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion);
      addTearDown(s2.close);
      final wordId = s2.activeWords().single.clientRowId;
      final ctx = s2.contextsFor(wordId).single;
      expect(ctx.contextText, 'a sentence'); // row content untouched
      expect(ctx.glossMeaning, isNull);
      s2.setContextGloss('ctx-1', 'in this sentence it means …');
      expect(s2.contextsFor(wordId).single.glossMeaning, 'in this sentence it means …');
    });
  });

  group('context gloss cache (in-sentence "Explain here")', () {
    test('setContextGloss is surfaced by contextsFor; null until set; no-op for unknown id', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'ctx-1')]);
      final wordId = store.activeWords().single.clientRowId;
      expect(store.contextsFor(wordId).single.glossMeaning, isNull);
      store.setContextGloss(
          'ctx-1', 'Here “serendipity” means a happy accident; the sentence says …');
      expect(store.contextsFor(wordId).single.glossMeaning,
          'Here “serendipity” means a happy accident; the sentence says …');
      store.setContextGloss('nope', 'x'); // unknown id → no throw, no change
      expect(store.contextsFor(wordId).single.glossMeaning,
          'Here “serendipity” means a happy accident; the sentence says …');
    });

    test('contextGlossKey returns (unit, contextText); null for unknown / context-less rows', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'ctx-1')]);
      final key = store.contextGlossKey('ctx-1');
      expect(key?.unit, 'serendipity');
      expect(key?.contextText, 'a moment of pure serendipity');
      expect(store.contextGlossKey('nope'), isNull);
      // A context-less save (null text) has nothing to gloss → no key.
      store.drain([entry(seq: 2, clientRowId: 'ctx-2', surfaceUnit: 'quux', contextText: null)]);
      expect(store.contextGlossKey('ctx-2'), isNull);
    });
  });

  group('fresh drain', () {
    test('inserts a word and its context', () {
      final store = freshStore();
      addTearDown(store.close);

      final applied = store.drain([entry(seq: 1, clientRowId: 'ctx-1')]);

      expect(applied, 1);
      expect(store.lastDrainedSeq, 1);

      final words = store.activeWords();
      expect(words, hasLength(1));
      final w = words.single;
      expect(w.surfaceUnit, 'serendipity');
      expect(w.normalizedUnit, 'serendipity');
      expect(w.targetLanguage, 'en');
      expect(w.targetNormalizationVersion, kVersion);
      expect(w.installId, 'install-1');
      expect(w.source, 'ocr');
      expect(w.createdAt, 1000);
      expect(w.updatedAt, 1000);
      expect(w.deletedAt, isNull);
      expect(w.syncDirty, isTrue);
      expect(w.serverWordId, isNull);
      expect(w.contextCount, 1);

      final contexts = store.contextsFor(w.clientRowId);
      expect(contexts, hasLength(1));
      final c = contexts.single;
      expect(c.clientRowId, 'ctx-1'); // PK == the journal entry's clientRowId
      expect(c.wordClientRowId, w.clientRowId);
      expect(c.contextText, 'a moment of pure serendipity');
      expect(c.contextLanguage, 'en');
      expect(c.spanStart, 12);
      expect(c.spanEnd, 23);
      // Capture-source metadata round-trips journal → store.
      expect(c.sourceApp, 'Google Chrome');
      expect(c.sourceTitle, 'Serendipity — Wikipedia');
      expect(c.detectedLanguage, 'en');
      expect(c.detectedLanguageConfidence, 0.92);
      expect(c.syncDirty, isTrue);
    });

    test('persists a context with NO source metadata (all-null) without error', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([
        entry(
          seq: 1,
          clientRowId: 'ctx-1',
          sourceApp: null,
          sourceTitle: null,
          detectedLanguage: null,
          detectedLanguageConfidence: null,
        ),
      ]);
      final c = store.contextsFor(store.activeWords().single.clientRowId).single;
      expect(c.sourceApp, isNull);
      expect(c.sourceTitle, isNull);
      expect(c.detectedLanguage, isNull);
      expect(c.detectedLanguageConfidence, isNull);
    });

    test('empty drain is a no-op and returns 0', () {
      final store = freshStore();
      addTearDown(store.close);
      expect(store.drain([]), 0);
      expect(store.lastDrainedSeq, 0);
    });

    test('word client_row_id is a v4 UUID', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'ctx-1')]);
      final id = store.activeWords().single.clientRowId;
      expect(
        id,
        matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
    });

    test('onApplied reports (entry.clientRowId -> word id) for each applied entry (T17)', () {
      final store = freshStore();
      addTearDown(store.close);

      final seen = <({String clientRowId, String wordId, bool created})>[];
      store.drain(
        [entry(seq: 1, clientRowId: 'ctx-1')],
        onApplied: (c, w, created) => seen.add((clientRowId: c, wordId: w, created: created)),
      );
      expect(seen, hasLength(1));
      expect(seen.single.clientRowId, 'ctx-1'); // the save-event (journal/context) id
      expect(seen.single.wordId,
          store.activeWords().single.clientRowId); // the WORD id (≠ the entry id)
      expect(seen.single.created, isTrue); // a brand-new word row was inserted

      // A second capture of the SAME unit dedups to the same word: onApplied reports the NEW save-event
      // id but the SAME (reused) word id, and created=false — exactly what lets the backend read a
      // repeat lookup (T15) and lets the host skip auto-claiming a re-capture.
      seen.clear();
      store.drain(
        [entry(seq: 2, clientRowId: 'ctx-2')],
        onApplied: (c, w, created) => seen.add((clientRowId: c, wordId: w, created: created)),
      );
      expect(seen.single.clientRowId, 'ctx-2');
      expect(seen.single.wordId, store.activeWords().single.clientRowId); // same word reused
      expect(seen.single.created, isFalse); // deduped into the existing word — not newly created
    });

    test('onApplied does NOT fire for a normalized-empty entry (no word created — T17)', () {
      final store = freshStore();
      addTearDown(store.close);
      final seen = <String>[];
      // The stub normalizer trims+lowercases, so a whitespace-only unit normalizes to empty.
      final applied = store.drain(
        [entry(seq: 1, clientRowId: 'blank', surfaceUnit: '   ', spanStart: null, spanEnd: null)],
        onApplied: (c, w, created) => seen.add(c),
      );
      expect(applied, 1); // the entry was consumed (cursor advanced)...
      expect(store.activeWords(), isEmpty); // ...but no word was created...
      expect(seen, isEmpty); // ...so onApplied did not fire.
    });
  });

  group('drain idempotency', () {
    test('re-applying the same batch creates no duplicates and holds the cursor', () {
      final store = freshStore();
      addTearDown(store.close);

      final batch = [
        entry(seq: 1, clientRowId: 'ctx-1', surfaceUnit: 'alpha'),
        entry(seq: 2, clientRowId: 'ctx-2', surfaceUnit: 'beta'),
      ];

      expect(store.drain(batch), 2);
      expect(store.lastDrainedSeq, 2);

      // Re-drain the exact same batch.
      expect(store.drain(batch), 0, reason: 'no NEW entries on replay');
      expect(store.lastDrainedSeq, 2, reason: 'cursor must not move backwards or repeat');

      expect(store.activeWords(), hasLength(2));
      for (final w in store.activeWords()) {
        expect(w.contextCount, 1, reason: 'each word still has exactly one context');
      }
    });

    test('an entry re-sent BELOW the cursor is ignored (no regress, no dup)', () {
      final store = freshStore();
      addTearDown(store.close);

      store.drain([
        entry(seq: 1, clientRowId: 'ctx-1', surfaceUnit: 'alpha'),
        entry(seq: 5, clientRowId: 'ctx-5', surfaceUnit: 'beta'),
      ]);
      expect(store.lastDrainedSeq, 5);

      // Re-send seq 1 (below cursor) alongside a genuinely new seq 6.
      final applied = store.drain([
        entry(seq: 1, clientRowId: 'ctx-1', surfaceUnit: 'alpha'),
        entry(seq: 6, clientRowId: 'ctx-6', surfaceUnit: 'gamma'),
      ]);

      expect(applied, 1, reason: 'only seq 6 is new');
      expect(store.lastDrainedSeq, 6);
      expect(store.activeWords(), hasLength(3));
    });

    test('the same clientRowId re-applied above the cursor still inserts no second context', () {
      // Defensive: even if a buggy native side re-emitted the same save event with a higher seq,
      // the context PK (clientRowId) guards against a duplicate context row.
      final store = freshStore();
      addTearDown(store.close);

      store.drain([entry(seq: 1, clientRowId: 'dup', surfaceUnit: 'alpha')]);
      // Same clientRowId, higher seq, same unit.
      final applied = store.drain([entry(seq: 2, clientRowId: 'dup', surfaceUnit: 'alpha')]);

      expect(applied, 1, reason: 'seq 2 counts as a drained entry');
      expect(store.lastDrainedSeq, 2);
      final words = store.activeWords();
      expect(words, hasLength(1));
      expect(words.single.contextCount, 1, reason: 'INSERT OR IGNORE on the context PK');
    });

    test('entries supplied out of seq order still apply correctly', () {
      final store = freshStore();
      addTearDown(store.close);
      final applied = store.drain([
        entry(seq: 3, clientRowId: 'c3', surfaceUnit: 'gamma'),
        entry(seq: 1, clientRowId: 'c1', surfaceUnit: 'alpha'),
        entry(seq: 2, clientRowId: 'c2', surfaceUnit: 'beta'),
      ]);
      expect(applied, 3);
      expect(store.lastDrainedSeq, 3);
      expect(store.activeWords(), hasLength(3));
    });
  });

  group('dedup', () {
    test('two captures of the same unit/language -> ONE word, TWO contexts', () {
      final store = freshStore();
      addTearDown(store.close);

      store.drain([
        entry(seq: 1, clientRowId: 'ctx-1', surfaceUnit: 'Serendipity', contextText: 'first'),
        entry(seq: 2, clientRowId: 'ctx-2', surfaceUnit: 'serendipity ', contextText: 'second'),
      ]);

      final words = store.activeWords();
      expect(words, hasLength(1), reason: 'normalized to the same dedup key');
      final w = words.single;
      expect(w.normalizedUnit, 'serendipity');
      expect(w.contextCount, 2);

      final contexts = store.contextsFor(w.clientRowId);
      expect(contexts, hasLength(2));
      expect(
        contexts.map((c) => c.contextText).toSet(),
        {'first', 'second'},
      );
    });

    test('same surface unit but DIFFERENT target language -> two words', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([
        entry(seq: 1, clientRowId: 'c1', surfaceUnit: 'gift', targetLanguage: 'en'),
        entry(seq: 2, clientRowId: 'c2', surfaceUnit: 'gift', targetLanguage: 'de'),
      ]);
      expect(store.activeWords(), hasLength(2),
          reason: 'dedup key is (target_language, normalized_unit)');
    });
  });

  group('resurrect-on-resave', () {
    test('soft-deleting then re-capturing clears deleted_at and adds a context', () {
      final store = freshStore();
      addTearDown(store.close);

      store.drain(
          [entry(seq: 1, clientRowId: 'ctx-1', surfaceUnit: 'phoenix', contextText: 'first')]);
      final wordId = store.activeWords().single.clientRowId;

      store.softDelete(wordId);
      expect(store.activeWords(), isEmpty, reason: 'tombstoned -> hidden');

      // Re-capture the same unit (new save event).
      final applied = store.drain([
        entry(
            seq: 2,
            clientRowId: 'ctx-2',
            surfaceUnit: 'phoenix',
            contextText: 'second',
            capturedAt: 9999)
      ]);
      expect(applied, 1);

      final active = store.activeWords();
      expect(active, hasLength(1), reason: 'resurrected, not duplicated');
      final w = active.single;
      expect(w.clientRowId, wordId, reason: 'same row reused');
      expect(w.deletedAt, isNull);
      expect(w.updatedAt, 9999, reason: 'resurrect bumps updated_at to the resave time');
      expect(w.syncDirty, isTrue);
      expect(w.contextCount, 2, reason: 'pre-delete context survives the cascade-less tombstone');

      // Both contexts (across the delete) are still linked to the resurrected word.
      expect(
        store.contextsFor(wordId).map((c) => c.contextText).toSet(),
        {'first', 'second'},
      );
    });
  });

  group('soft delete', () {
    test('hides from activeWords but leaves the row + contexts', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'ctx-1', surfaceUnit: 'ephemeral')]);
      final id = store.activeWords().single.clientRowId;

      store.softDelete(id);
      expect(store.activeWords(), isEmpty);
      // Contexts still queryable directly (drives sync reconciliation later).
      expect(store.contextsFor(id), hasLength(1));
    });

    test('is idempotent and a no-op for an unknown id', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'ctx-1')]);
      final id = store.activeWords().single.clientRowId;
      store.softDelete(id);
      // Second delete and a bogus id must not throw.
      expect(() => store.softDelete(id), returnsNormally);
      expect(() => store.softDelete('does-not-exist'), returnsNormally);
      expect(store.activeWords(), isEmpty);
    });
  });

  group('drain cursor persistence', () {
    test('cursor survives close/reopen on a real file (no re-apply on relaunch)', () {
      final dir = Directory.systemTemp.createTempSync('capecho_local_store_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/store.db';

      // First "launch": drain a batch, then close.
      final s1 =
          LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion);
      expect(
        s1.drain([
          entry(seq: 1, clientRowId: 'ctx-1', surfaceUnit: 'alpha'),
          entry(seq: 2, clientRowId: 'ctx-2', surfaceUnit: 'beta'),
        ]),
        2,
      );
      expect(s1.lastDrainedSeq, 2);
      s1.close();

      // Second "launch": reopen the same file.
      final s2 =
          LocalStore.open(path: path, normalizer: stubNormalizer, normalizationVersion: kVersion);
      addTearDown(s2.close);

      expect(s2.lastDrainedSeq, 2, reason: 'cursor persisted in meta');
      expect(s2.activeWords(), hasLength(2));

      // Re-draining the original batch after relaunch must be a no-op.
      expect(
          s2.drain([
            entry(seq: 1, clientRowId: 'ctx-1', surfaceUnit: 'alpha'),
            entry(seq: 2, clientRowId: 'ctx-2', surfaceUnit: 'beta'),
          ]),
          0);
      expect(s2.lastDrainedSeq, 2);
      expect(s2.activeWords(), hasLength(2));
    });
  });

  group('is_phrase derivation', () {
    test('single token -> not a phrase', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1', surfaceUnit: 'word')]);
      expect(store.activeWords().single.isPhrase, isFalse);
    });

    test('leading/trailing whitespace alone does NOT make a phrase', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1', surfaceUnit: '  word  ')]);
      expect(store.activeWords().single.isPhrase, isFalse);
    });

    test('internal whitespace -> phrase', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1', surfaceUnit: 'a moment')]);
      expect(store.activeWords().single.isPhrase, isTrue);
    });

    test('multiple internal spaces -> phrase', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1', surfaceUnit: 'pure   serendipity')]);
      expect(store.activeWords().single.isPhrase, isTrue);
    });
  });

  group('span pairing', () {
    test('both null is accepted (context-less or unspanned)', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1', spanStart: null, spanEnd: null)]);
      final c = store.contextsFor(store.activeWords().single.clientRowId).single;
      expect(c.spanStart, isNull);
      expect(c.spanEnd, isNull);
    });

    test('both present is accepted', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1', spanStart: 3, spanEnd: 7)]);
      final c = store.contextsFor(store.activeWords().single.clientRowId).single;
      expect(c.spanStart, 3);
      expect(c.spanEnd, 7);
    });

    test('only one side present fails validation / fromMap', () {
      expect(
        () => entry(seq: 1, clientRowId: 'c1', spanStart: 3, spanEnd: null).validate(),
        throwsArgumentError,
      );
      expect(
        () => entry(seq: 1, clientRowId: 'c1', spanStart: null, spanEnd: 7).validate(),
        throwsArgumentError,
      );
      // The store also re-validates on drain, so an unpaired span never reaches SQL.
      final store = freshStore();
      addTearDown(store.close);
      expect(
        () => store.drain([entry(seq: 1, clientRowId: 'c1', spanStart: 3, spanEnd: null)]),
        throwsArgumentError,
      );
    });

    test('negative start or end < start fails validation', () {
      expect(
        () => entry(seq: 1, clientRowId: 'c1', spanStart: -1, spanEnd: 2).validate(),
        throwsArgumentError,
      );
      expect(
        () => entry(seq: 1, clientRowId: 'c1', spanStart: 5, spanEnd: 2).validate(),
        throwsArgumentError,
      );
    });

    test('start == end (empty span) is accepted', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1', spanStart: 4, spanEnd: 4)]);
      final c = store.contextsFor(store.activeWords().single.clientRowId).single;
      expect(c.spanStart, 4);
      expect(c.spanEnd, 4);
    });
  });

  group('context-less save', () {
    test('null contextText is stored and the word still appears', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([
        entry(
          seq: 1,
          clientRowId: 'c1',
          contextText: null,
          contextLanguage: null,
          spanStart: null,
          spanEnd: null,
        )
      ]);
      final w = store.activeWords().single;
      expect(w.contextCount, 1);
      final c = store.contextsFor(w.clientRowId).single;
      expect(c.contextText, isNull);
      expect(c.contextLanguage, isNull);
    });
  });

  group('source validation', () {
    test('valid sources construct', () {
      for (final s in kJournalSources) {
        expect(() => entry(seq: 1, clientRowId: 'c1', source: s), returnsNormally);
      }
    });
    test('an unknown source fails validation and is rejected on drain', () {
      expect(
        () => entry(seq: 1, clientRowId: 'c1', source: 'keyboard').validate(),
        throwsArgumentError,
      );
      final store = freshStore();
      addTearDown(store.close);
      expect(
        () => store.drain([entry(seq: 1, clientRowId: 'c1', source: 'keyboard')]),
        throwsArgumentError,
      );
      expect(store.lastDrainedSeq, 0, reason: 'a bad entry leaves the cursor untouched');
    });
  });

  group('empty normalization', () {
    test('a unit that normalizes to empty is skipped but advances the cursor', () {
      // Normalizer that strips everything for a specific marker unit.
      String norm(String u) => u == '   ' ? '' : u.trim().toLowerCase();
      final store = LocalStore.openInMemory(normalizer: norm, normalizationVersion: kVersion);
      addTearDown(store.close);

      final applied = store.drain([
        entry(seq: 1, clientRowId: 'c1', surfaceUnit: '   '), // normalizes to empty
        entry(seq: 2, clientRowId: 'c2', surfaceUnit: 'real'),
      ]);

      // Both seqs are "applied" in the cursor sense; only the real one creates rows.
      expect(applied, 2);
      expect(store.lastDrainedSeq, 2);
      expect(store.activeWords(), hasLength(1));
      expect(store.activeWords().single.surfaceUnit, 'real');
    });
  });

  group('filtering & paging', () {
    test('activeWords filters by target language and pages newest-first', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([
        entry(
            seq: 1, clientRowId: 'c1', surfaceUnit: 'alpha', targetLanguage: 'en', capturedAt: 100),
        entry(
            seq: 2, clientRowId: 'c2', surfaceUnit: 'beta', targetLanguage: 'en', capturedAt: 200),
        entry(
            seq: 3, clientRowId: 'c3', surfaceUnit: 'gamma', targetLanguage: 'de', capturedAt: 300),
      ]);

      final en = store.activeWords(targetLanguage: 'en');
      expect(en.map((w) => w.surfaceUnit), ['beta', 'alpha'], reason: 'newest created_at first');

      final firstPage = store.activeWords(limit: 1);
      expect(firstPage, hasLength(1));
      expect(firstPage.single.surfaceUnit, 'gamma'); // newest overall
      final secondPage = store.activeWords(limit: 1, offset: 1);
      expect(secondPage.single.surfaceUnit, 'beta');
    });
  });

  group('JournalEntry map round-trip', () {
    test('toMap/fromMap preserves all fields (camelCase)', () {
      final e = entry(seq: 7, clientRowId: 'rt');
      final back = JournalEntry.fromMap(e.toMap());
      expect(back.toMap(), e.toMap());
    });
  });

  group('claimed isolation', () {
    test('drained captures are anonymous (claimed = 0), listed by anonymousWords', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1', surfaceUnit: 'alpha')]);
      final w = store.activeWords().single;
      expect(w.claimed, isFalse);
      expect(store.anonymousWords(), hasLength(1));
    });

    test('markClaimed hides a row from anonymousWords but keeps it active', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1', surfaceUnit: 'alpha')]);
      final id = store.activeWords().single.clientRowId;

      store.markClaimed([id], 'acct-A');

      expect(store.anonymousWords(), isEmpty,
          reason: 'claimed rows are hidden from the signed-out view');
      final active = store.activeWords();
      expect(active, hasLength(1));
      expect(active.single.claimed, isTrue);
    });

    test('markClaimed is idempotent and a no-op for unknown / empty ids', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1', surfaceUnit: 'alpha')]);
      final id = store.activeWords().single.clientRowId;
      store.markClaimed([id], 'acct-A');
      expect(() => store.markClaimed([id], 'acct-A'), returnsNormally);
      expect(() => store.markClaimed(['nope'], 'acct-A'), returnsNormally);
      expect(() => store.markClaimed(const [], 'acct-A'), returnsNormally);
      expect(store.anonymousWords(), isEmpty);
    });

    test('re-capture after claiming lands a FRESH anonymous row (no resurrect of the hidden one)',
        () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain(
          [entry(seq: 1, clientRowId: 'c1', surfaceUnit: 'serendipity', contextText: 'first')]);
      final claimedId = store.activeWords().single.clientRowId;
      store.markClaimed([claimedId], 'acct-A');
      expect(store.anonymousWords(), isEmpty);

      // Re-capture the same unit while signed out (a new save event).
      store.drain(
          [entry(seq: 2, clientRowId: 'c2', surfaceUnit: 'serendipity', contextText: 'second')]);

      final anon = store.anonymousWords();
      expect(anon, hasLength(1), reason: 'a fresh anon row, not a resurrect of the claimed one');
      expect(anon.single.clientRowId, isNot(claimedId));
      expect(anon.single.claimed, isFalse);
      expect(store.activeWords(), hasLength(2),
          reason: 'one claimed + one anonymous of the same unit');
    });

    test('markClaimed deletes a redundant anon row when a SAME-ACCOUNT claimed sibling exists', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1', surfaceUnit: 'phoenix')]);
      final firstId = store.activeWords().single.clientRowId;
      store.markClaimed([firstId], 'acct-A');
      store.drain([entry(seq: 2, clientRowId: 'c2', surfaceUnit: 'phoenix')]);
      final secondId = store.anonymousWords().single.clientRowId;
      expect(secondId, isNot(firstId));

      // Claiming the second (anon) row INTO THE SAME ACCOUNT would collide with the first claimed
      // sibling on the dedup key → it's hard-deleted instead of flipped.
      store.markClaimed([secondId], 'acct-A');

      expect(store.anonymousWords(), isEmpty);
      final active = store.activeWords();
      expect(active, hasLength(1), reason: 'the redundant anon row was hard-deleted, not flipped');
      expect(active.single.clientRowId, firstId);
      expect(store.contextsFor(secondId), isEmpty, reason: 'its contexts cascaded with the delete');
    });

    test('two accounts can each claim the SAME unit on one device — no collision, no false delete',
        () {
      final store = freshStore();
      addTearDown(store.close);
      // Account A captures + claims 'phoenix'.
      store.drain([entry(seq: 1, clientRowId: 'c1', surfaceUnit: 'phoenix', contextText: 'A')]);
      final aId = store.activeWords().single.clientRowId;
      store.markClaimed([aId], 'acct-A');
      // Later, on the same device, account B captures + claims 'phoenix' too.
      store.drain([entry(seq: 2, clientRowId: 'c2', surfaceUnit: 'phoenix', contextText: 'B')]);
      final bId = store.anonymousWords().single.clientRowId;
      expect(bId, isNot(aId));
      store.markClaimed([bId], 'acct-B');

      // Both claimed rows coexist (distinct owners → distinct dedup keys); neither was deleted.
      expect(store.anonymousWords(), isEmpty);
      expect(store.activeWords(), hasLength(2),
          reason: 'A and B each keep their own claimed row of the same unit');
      // Each account sees only its own; neither sees the other's.
      expect(store.hasActiveWord('phoenix', 'en', accountId: 'acct-A'), isTrue);
      expect(store.hasActiveWord('phoenix', 'en', accountId: 'acct-B'), isTrue);
      expect(store.contextsFor(aId), hasLength(1), reason: "A's row + context survived B's claim");
    });
  });

  group('restore', () {
    test('clears deleted_at and brings a word back into activeWords', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1', surfaceUnit: 'ephemeral')]);
      final id = store.activeWords().single.clientRowId;
      store.softDelete(id);
      expect(store.activeWords(), isEmpty);

      store.restore(id);
      final active = store.activeWords();
      expect(active, hasLength(1));
      expect(active.single.deletedAt, isNull);
    });

    test('is idempotent and a no-op for an unknown or already-active id', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1')]);
      final id = store.activeWords().single.clientRowId;
      expect(() => store.restore(id), returnsNormally); // already active
      expect(() => store.restore('nope'), returnsNormally);
      expect(store.activeWords(), hasLength(1));
    });
  });

  group('fresh schema', () {
    test('a fresh store is born at the current version and needs no migration', () {
      final store = freshStore();
      addTearDown(store.close);
      store.drain([entry(seq: 1, clientRowId: 'c1', surfaceUnit: 'alpha')]);
      final w = store.activeWords().single;
      expect(w.claimed, isFalse);
      expect(() => store.markClaimed([w.clientRowId], 'acct-A'), returnsNormally);
      expect(store.anonymousWords(), isEmpty);
    });
  });
}
