import 'package:capecho_capture_core/capecho_capture_core.dart';
import 'package:test/test.dart';

void main() {
  group('surfaceUnit (edge-strip of stray punctuation)', () {
    test('strips wrapping punctuation, keeps internal hyphens', () {
      expect(surfaceUnit('(non-governmental),'), 'non-governmental');
      expect(surfaceUnit('"hello"'), 'hello');
      expect(surfaceUnit('word.'), 'word');
      expect(surfaceUnit('—word—'), 'word');
    });

    test('keeps a clean word and a contraction untouched', () {
      expect(surfaceUnit('serendipity'), 'serendipity');
      expect(surfaceUnit("don't"), "don't");
      expect(surfaceUnit('state-of-the-art'), 'state-of-the-art');
    });

    test('keeps letters of any script + diacritics (multi-target)', () {
      expect(surfaceUnit('¿café?'), 'café');
      expect(surfaceUnit('«мир»'), 'мир');
      expect(surfaceUnit('学习。'), '学习');
    });

    test('numbers (marks/digits) survive at the edges', () {
      expect(surfaceUnit('(3.14)'), '3.14');
    });

    test('an all-punctuation / symbol unit trims to empty', () {
      expect(surfaceUnit('—'), '');
      expect(surfaceUnit('•••'), '');
      expect(surfaceUnit('()'), '');
    });
  });
}
