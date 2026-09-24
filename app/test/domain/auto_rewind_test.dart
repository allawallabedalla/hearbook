import 'package:faden/domain/auto_rewind.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('autoRewindMs (E32)', () {
    test('no rewind for pauses under 10 s', () {
      expect(autoRewindMs(0), 0);
      expect(autoRewindMs(9999), 0);
    });

    test('3 s from 10 s', () {
      expect(autoRewindMs(10 * 1000), 3000);
      expect(autoRewindMs(5 * 60 * 1000 - 1), 3000);
    });

    test('10 s from 5 min', () {
      expect(autoRewindMs(5 * 60 * 1000), 10000);
      expect(autoRewindMs(60 * 60 * 1000 - 1), 10000);
    });

    test('30 s from 1 h, however long the pause', () {
      expect(autoRewindMs(60 * 60 * 1000), 30000);
      expect(autoRewindMs(3 * 24 * 60 * 60 * 1000), 30000);
    });

    test('every rewind stays below the 2 min jump threshold (never an undo hint)', () {
      for (final ms in [0, 10000, 300000, 3600000, 1 << 40]) {
        expect(autoRewindMs(ms), lessThan(2 * 60 * 1000));
      }
    });
  });

  group('autoRewoundGlobalMs', () {
    test('rewinds by the rule', () {
      expect(autoRewoundGlobalMs(globalMs: 100000, pausedForMs: 6 * 60 * 1000), 90000);
    });

    test('never before the start of the book', () {
      expect(autoRewoundGlobalMs(globalMs: 2000, pausedForMs: 2 * 60 * 60 * 1000), 0);
    });

    test('unknown or negative pause: no rewind', () {
      expect(autoRewoundGlobalMs(globalMs: 50000, pausedForMs: null), 50000);
      expect(autoRewoundGlobalMs(globalMs: 50000, pausedForMs: -5), 50000);
    });
  });
}
