import 'dart:io';

import 'package:capecho/capture_repository.dart';
import 'package:capture_native/capture_native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Routes Application Support to a temp dir so the real local store opens.
class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
}

CaptureResult _result(String word, String context) => CaptureResult(
  word: word,
  line: context,
  sentence: context,
  context: context,
  recognizedLineCount: 1,
  screenName: 'test',
  contextSource: CaptureContextSource.ocr,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('capture_native');
  late Directory tempDir;
  late List<Map<String, Object?>> fakeJournal; // the native journal, faked
  late int seq;
  late bool failDrain; // when true, journalEntries throws (a projection failure)

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('capecho_repo_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    fakeJournal = [];
    seq = 0;
    failDrain = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      methodChannel,
      (call) async {
        switch (call.method) {
          case 'saveCapture':
            seq += 1;
            final args = (call.arguments as Map).cast<String, Object?>();
            final clientRowId = 'crid-$seq';
            fakeJournal.add({
              'seq': seq,
              'clientRowId': clientRowId,
              'installId': 'test-install',
              'surfaceUnit': args['surfaceUnit'],
              'targetLanguage': args['targetLanguage'],
              'contextText': args['contextText'],
              'contextLanguage': args['contextLanguage'],
              'spanStart': args['spanStart'],
              'spanEnd': args['spanEnd'],
              'source': args['source'],
              'capturedAt': args['capturedAt'],
            });
            return {'clientRowId': clientRowId, 'seq': seq};
          case 'journalEntries':
            if (failDrain) {
              throw PlatformException(code: 'drain_unavailable');
            }
            final after = (call.arguments as Map)['afterSeq'] as int;
            return fakeJournal.where((e) => (e['seq'] as int) > after).toList();
          case 'hasScreenRecordingPermission':
            return false;
          case 'installId':
            return 'test-install';
          default:
            return null;
        }
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      methodChannel,
      null,
    );
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('save → durable journal → drain → store, with dedup', () async {
    final repo = await CaptureRepository.open();
    addTearDown(repo.close);

    await repo.save(_result('hello', 'hello world.'), targetLanguage: 'en');
    expect(repo.savedWords(), hasLength(1));
    expect(repo.savedWords().single.surfaceUnit, 'hello');
    expect(repo.savedWords().single.contextCount, 1);
    // The context's language is stamped ONLY when its script makes it certain — a Latin
    // sentence never pins one (which Latin language?), so it stays NULL; it is never
    // defaulted to the unit's target language.
    expect(fakeJournal.single['contextLanguage'], isNull);

    // Same unit again → dedups to one word with two contexts.
    await repo.save(_result('hello', 'a second hello sentence.'), targetLanguage: 'en');
    expect(repo.savedWords(), hasLength(1));
    expect(repo.savedWords().single.contextCount, 2);

    // A different unit → a second word.
    await repo.save(_result('world', 'the world is round.'), targetLanguage: 'en');
    expect(repo.savedWords(), hasLength(2));
  });

  test('save stamps the context language only when the sentence script makes it certain', () async {
    final repo = await CaptureRepository.open();
    addTearDown(repo.close);
    // A mono-script zh sentence pins its language (same accepted Han→zh-Hans default as the
    // unit auto-switch); the mixed zh-in-en sentence stays unknown.
    await repo.save(_result('学习', '我们今天学习新词。'), targetLanguage: 'zh-Hans');
    expect(fakeJournal.last['contextLanguage'], 'zh-Hans');
    await repo.save(_result('学习', 'The word 学习 means to study.'), targetLanguage: 'zh-Hans');
    expect(fakeJournal.last['contextLanguage'], isNull);
  });

  test('isAlreadySaved reflects the local store (bug #6)', () async {
    final repo = await CaptureRepository.open();
    addTearDown(repo.close);

    expect(repo.isAlreadySaved('hello', 'en'), isFalse);
    await repo.save(_result('hello', 'hello world.'), targetLanguage: 'en');
    expect(repo.isAlreadySaved('hello', 'en'), isTrue);
    // The provisional normalizer lowercases + trims, so a different surface form still matches.
    expect(repo.isAlreadySaved('  HELLO ', 'en'), isTrue);
    // A different language or unit is not "already saved".
    expect(repo.isAlreadySaved('hello', 'de'), isFalse);
    expect(repo.isAlreadySaved('world', 'en'), isFalse);
  });

  test(
    'isAlreadySaved scopes a claimed word to its owning account (cross-account cue fix)',
    () async {
      final repo = await CaptureRepository.open();
      addTearDown(repo.close);

      await repo.save(_result('hello', 'hello world.'), targetLanguage: 'en');
      // Sync it into account A (what the auth controller does after a successful claim).
      repo.markClaimed([repo.savedWords().single.clientRowId], 'acct-A');

      // The owning account still sees it; a different account on the same device does not.
      expect(repo.isAlreadySaved('hello', 'en', accountId: 'acct-A'), isTrue);
      expect(repo.isAlreadySaved('hello', 'en', accountId: 'acct-B'), isFalse);
      // Signed out (no account id) → it's claimed, so the anonymous catalog hides it.
      expect(repo.isAlreadySaved('hello', 'en'), isFalse);
    },
  );

  test('drain returns the applied word ids (post-login auto-claim, bug #5)', () async {
    final repo = await CaptureRepository.open();
    addTearDown(repo.close);

    // A pending journal entry the launch drain didn't see (it's added after open()).
    fakeJournal.add({
      'seq': 1,
      'clientRowId': 'crid-1',
      'installId': 'test-install',
      'surfaceUnit': 'hello',
      'targetLanguage': 'en',
      'contextText': 'hello world',
      'contextLanguage': 'en',
      'spanStart': null,
      'spanEnd': null,
      'source': 'ocr',
      'capturedAt': 1,
    });
    final applied = await repo.drain();
    expect(applied, hasLength(1)); // one new word id, the host claims just this one
    // A re-drain applies nothing new → empty (so it never re-claims).
    expect(await repo.drain(), isEmpty);
  });

  test(
    'drain excludes a re-capture that dedups into an existing word (review #5 follow-up)',
    () async {
      final repo = await CaptureRepository.open();
      addTearDown(repo.close);
      // First capture of "hello" → a brand-new word, returned for auto-claim.
      fakeJournal.add({
        'seq': 1,
        'clientRowId': 'crid-1',
        'installId': 'test-install',
        'surfaceUnit': 'hello',
        'targetLanguage': 'en',
        'contextText': 'hello world',
        'contextLanguage': 'en',
        'spanStart': null,
        'spanEnd': null,
        'source': 'ocr',
        'capturedAt': 1,
      });
      expect(await repo.drain(), hasLength(1));
      // Re-capture "hello" → dedups into the existing word → NOT newly created, so NOT auto-claimed
      // (a pre-login backlog word must not be swept into the account without explicit Sync).
      fakeJournal.add({
        'seq': 2,
        'clientRowId': 'crid-2',
        'installId': 'test-install',
        'surfaceUnit': 'hello',
        'targetLanguage': 'en',
        'contextText': 'hello again',
        'contextLanguage': 'en',
        'spanStart': null,
        'spanEnd': null,
        'source': 'ocr',
        'capturedAt': 2,
      });
      expect(await repo.drain(), isEmpty);
    },
  );

  test('drain is idempotent across a reopen (crash recovery)', () async {
    final repo = await CaptureRepository.open();
    await repo.save(_result('alpha', 'alpha beta.'), targetLanguage: 'en');
    expect(repo.savedWords(), hasLength(1));
    repo.close();

    // Reopen the same store dir: open() drains again, but the already-applied
    // journal entry must not duplicate.
    final repo2 = await CaptureRepository.open();
    addTearDown(repo2.close);
    expect(repo2.savedWords(), hasLength(1));
    expect(repo2.savedWords().single.surfaceUnit, 'alpha');
  });

  test('a poison journal record does not wedge the drain (H1)', () async {
    // A structurally-invalid record (unknown source) ahead of a valid one. The
    // bad record must be skipped, not abort the whole drain.
    fakeJournal.add({
      'seq': 1,
      'clientRowId': 'poison',
      'installId': 'test-install',
      'surfaceUnit': 'oops',
      'targetLanguage': 'en',
      'contextText': null,
      'contextLanguage': null,
      'spanStart': null,
      'spanEnd': null,
      'source': 'keyboard', // not in kJournalSources -> fromMap throws
      'capturedAt': 1,
    });
    fakeJournal.add({
      'seq': 2,
      'clientRowId': 'good',
      'installId': 'test-install',
      'surfaceUnit': 'hello',
      'targetLanguage': 'en',
      'contextText': 'hello world',
      'contextLanguage': null,
      'spanStart': null,
      'spanEnd': null,
      'source': 'ocr',
      'capturedAt': 2,
    });

    final repo = await CaptureRepository.open(); // open() drains
    addTearDown(repo.close);

    final units = repo.savedWords().map((w) => w.surfaceUnit).toList();
    expect(units, contains('hello')); // valid entry landed
    expect(units, isNot(contains('oops'))); // poison skipped, not fatal
  });

  test('a drain (projection) failure does not fail the durable save (P2)', () async {
    final repo = await CaptureRepository.open();
    addTearDown(repo.close);

    // The journal append (phase 1) succeeds and fsyncs, but the drain (phase 2)
    // is unavailable. Per the two-phase contract, save() must still report the
    // durable receipt — never surface the projection failure as a lost capture.
    failDrain = true;
    final ref = await repo.save(_result('hello', 'hello world.'), targetLanguage: 'en');
    expect(ref.seq, greaterThan(0)); // durable write receipt returned, no throw
    // The projection lagged, so the word isn't queryable yet...
    expect(repo.savedWords(), isEmpty);

    // ...but it is durable: once the drain recovers, the next save's drain (or a
    // relaunch drain) applies the still-journaled entry — nothing was lost.
    failDrain = false;
    await repo.save(_result('world', 'the world is round.'), targetLanguage: 'en');
    final units = repo.savedWords().map((w) => w.surfaceUnit).toList();
    expect(units, containsAll(<String>['hello', 'world']));
  });

  test('the explanation cache round-trips per-POS senses through the store (Lane E)', () async {
    final repo = await CaptureRepository.open();
    addTearDown(repo.close);

    // A miss before anything is cached.
    expect(
      repo.cachedExplanation(
        surfaceUnit: 'object',
        targetLanguage: 'en',
        explanationLanguage: 'en',
      ),
      isNull,
    );

    // Cache an enriched (heteronym) blob via the overlay controller's store-free record port.
    repo.cacheExplanation(
      surfaceUnit: 'object',
      targetLanguage: 'en',
      explanationLanguage: 'en',
      readings: [
        (
          pronunciationPrimary: 'ˈɑbdʒɛkt',
          pronunciationSecondary: 'ˈɒbdʒɪkt',
          kind: null,
          pos: [
            (partOfSpeech: 'noun', senses: ['a thing you can see or touch']),
          ],
        ),
        (
          pronunciationPrimary: 'əbˈdʒɛkt',
          pronunciationSecondary: 'əbˈdʒɛkt',
          kind: null,
          pos: [
            (partOfSpeech: 'verb', senses: ['to disagree']),
          ],
        ),
      ],
    );

    // A re-capture reads it back — every reading, its IPA, and the per-POS senses survive. Keyed by
    // the normalization (lowercase + trim), so a different surface form still hits.
    final hit = repo.cachedExplanation(
      surfaceUnit: '  Object ',
      targetLanguage: 'en',
      explanationLanguage: 'en',
    );
    expect(hit, isNotNull);
    expect(hit!.readings.map((r) => r.pos.single.partOfSpeech).toList(), ['noun', 'verb']);
    expect(hit.readings.first.pronunciationPrimary, 'ˈɑbdʒɛkt');
    expect(hit.readings.first.pos.single.senses, ['a thing you can see or touch']);
    expect(hit.readings.last.pos.single.senses, ['to disagree']);

    // A senseless blob is never cached (Phase 1 must-pass — the senses ARE the explanation), so the
    // unit stays a miss next time.
    repo.cacheExplanation(
      surfaceUnit: 'silent',
      targetLanguage: 'en',
      explanationLanguage: 'en',
      readings: [
        (
          pronunciationPrimary: 'ˈsaɪlənt',
          pronunciationSecondary: '',
          kind: null,
          pos: [
            (partOfSpeech: 'adjective', senses: ['   ']),
          ],
        ),
      ],
    );
    expect(
      repo.cachedExplanation(
        surfaceUnit: 'silent',
        targetLanguage: 'en',
        explanationLanguage: 'en',
      ),
      isNull,
    );
  });
}
