import 'package:capecho_api/capecho_api.dart';
import 'package:capecho_app_core/capecho_app_core.dart';
import 'package:flutter_test/flutter_test.dart';

PosGroup _pos(String label, List<String> senses) => PosGroup(partOfSpeech: label, senses: senses);

Reading _reading(String primary, String secondary, List<PosGroup> pos, {String? kind}) =>
    Reading(pronunciationPrimary: primary, pronunciationSecondary: secondary, kind: kind, pos: pos);

void main() {
  test('single reading: shows every sense per POS', () {
    final layout = computeSenseLayout(
      WordExplanation(
        readings: [
          _reading('rʌn', 'rʌn', [
            _pos('verb', ['to move fast', 'to operate']),
            _pos('noun', ['an act of running']),
          ]),
        ],
      ),
    );
    expect(layout.readings, hasLength(1));
    final pos = layout.readings.single.pos;
    expect(pos[0].partOfSpeech, 'verb');
    expect(pos[0].senses, ['to move fast', 'to operate']);
    expect(pos[1].senses, ['an act of running']);
  });

  test('shows every stored sense (uncapped — no cap, no "more" hint)', () {
    final layout = computeSenseLayout(
      WordExplanation(
        readings: [
          _reading('rʌn', 'rʌn', [
            _pos('verb', ['s1', 's2', 's3', 's4', 's5', 's6', 's7', 's8']),
          ]),
        ],
      ),
    );
    expect(layout.readings.single.pos.single.senses, [
      's1',
      's2',
      's3',
      's4',
      's5',
      's6',
      's7',
      's8',
    ]); // every sense shown, nothing trimmed
  });

  test('heteronym: one block per reading, IPA preserved', () {
    final layout = computeSenseLayout(
      WordExplanation(
        readings: [
          _reading('ˈrɛkɚd', 'ˈrɛkɔːd', [
            _pos('noun', ['a stored account']),
          ]),
          _reading('rɪˈkɔːrd', 'rɪˈkɔːd', [
            _pos('verb', ['to store sound']),
          ]),
        ],
      ),
    );
    expect(layout.readings, hasLength(2));
    expect(layout.readings[0].isIdiom, isFalse);
    expect(layout.readings[0].pronunciationPrimary, 'ˈrɛkɚd');
    expect(layout.readings[1].pos.single.partOfSpeech, 'verb');
  });

  test('idiom: block flagged, no pronunciation', () {
    final layout = computeSenseLayout(
      WordExplanation(
        readings: [
          _reading('', '', [
            _pos('idiom', ['打破僵局']),
          ], kind: 'idiom'),
        ],
      ),
    );
    final block = layout.readings.single;
    expect(block.isIdiom, isTrue);
    expect(block.hasPronunciation, isFalse);
    expect(block.pos.single.senses, ['打破僵局']);
  });

  test('drops blank senses, empty POS groups, and readings with nothing to show', () {
    final layout = computeSenseLayout(
      WordExplanation(
        readings: [
          _reading('x', '', [
            _pos('noun', ['   ', '']),
          ]), // all-blank → reading drops
          _reading('y', '', [
            _pos('adj', ['']), // empty POS drops
            _pos('verb', ['a real meaning']), // kept
          ]),
        ],
      ),
    );
    expect(layout.readings, hasLength(1));
    expect(layout.readings.single.pos.single.partOfSpeech, 'verb');
  });

  group('shared form note', () {
    test('a note repeated on every sense is pulled out once, stripped from each', () {
      final layout = computeSenseLayout(
        WordExplanation(
          readings: [
            _reading('ˈmeɪkɪŋ', 'ˈmeɪkɪŋ', [
              _pos('verb', ['制造 (make 的现在分词)', '做 (make 的现在分词)', '使得 (make 的现在分词)']),
              _pos('noun', ['制造', '制作', '形成', '构成']),
            ]),
          ],
        ),
      );
      final pos = layout.readings.single.pos;
      expect(pos[0].note, 'make 的现在分词');
      expect(pos[0].senses, ['制造', '做', '使得']); // each note stripped
      expect(pos[1].note, isEmpty); // the noun senses share no note
      expect(pos[1].senses, ['制造', '制作', '形成', '构成']);
    });

    test('full-width parentheses are recognized too', () {
      final layout = computeSenseLayout(
        WordExplanation(
          readings: [
            _reading('x', '', [
              _pos('verb', ['制造（make 的现在分词）', '做（make 的现在分词）']),
            ]),
          ],
        ),
      );
      final pos = layout.readings.single.pos.single;
      expect(pos.note, 'make 的现在分词');
      expect(pos.senses, ['制造', '做']);
    });

    test('does not consolidate when the notes differ', () {
      final layout = computeSenseLayout(
        WordExplanation(
          readings: [
            _reading('x', '', [
              _pos('verb', ['制造 (make 的现在分词)', '做 (do 的现在分词)']),
            ]),
          ],
        ),
      );
      final pos = layout.readings.single.pos.single;
      expect(pos.note, isEmpty);
      expect(pos.senses, ['制造 (make 的现在分词)', '做 (do 的现在分词)']);
    });

    test('does not consolidate when only some senses carry the note', () {
      final layout = computeSenseLayout(
        WordExplanation(
          readings: [
            _reading('x', '', [
              _pos('verb', ['制造 (make 的现在分词)', '做']),
            ]),
          ],
        ),
      );
      final pos = layout.readings.single.pos.single;
      expect(pos.note, isEmpty);
      expect(pos.senses, ['制造 (make 的现在分词)', '做']);
    });

    test('a single sense keeps its note inline (no repetition to fix)', () {
      final layout = computeSenseLayout(
        WordExplanation(
          readings: [
            _reading('x', '', [
              _pos('verb', ['学习 (study 的过去式)']),
            ]),
          ],
        ),
      );
      final pos = layout.readings.single.pos.single;
      expect(pos.note, isEmpty);
      expect(pos.senses, ['学习 (study 的过去式)']);
    });

    test('does not consolidate when a sense is only the note (would empty it)', () {
      final layout = computeSenseLayout(
        WordExplanation(
          readings: [
            _reading('x', '', [
              _pos('verb', ['(make 的现在分词)', '制造 (make 的现在分词)']),
            ]),
          ],
        ),
      );
      final pos = layout.readings.single.pos.single;
      expect(pos.note, isEmpty);
      expect(pos.senses, ['(make 的现在分词)', '制造 (make 的现在分词)']);
    });

    test('ordinary senses carry no note', () {
      final layout = computeSenseLayout(
        WordExplanation(
          readings: [
            _reading('rʌn', 'rʌn', [
              _pos('verb', ['to move fast', 'to operate']),
            ]),
          ],
        ),
      );
      expect(layout.readings.single.pos.single.note, isEmpty);
    });
  });
}
