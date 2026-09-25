import 'package:faden/domain/auto_rewind.dart';
import 'package:faden/domain/pause_reason.dart';
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

  group('after a lost connection (E80)', () {
    test('30 s from 10 s on, so the thread is there again after leaving the car', () {
      expect(autoRewindMs(9999, reason: PauseReason.routeLost), 0);
      expect(autoRewindMs(10 * 1000, reason: PauseReason.routeLost), 30000);
      expect(autoRewindMs(6 * 60 * 1000, reason: PauseReason.routeLost), 30000);
      expect(autoRewindMs(3 * 60 * 60 * 1000, reason: PauseReason.routeLost), 30000);
    });

    test('every other reason keeps the table', () {
      for (final r in [null, ...PauseReason.values.where((r) => r != PauseReason.routeLost)]) {
        expect(autoRewindMs(10 * 1000, reason: r), 3000, reason: '$r');
        expect(autoRewindMs(5 * 60 * 1000, reason: r), 10000, reason: '$r');
        expect(autoRewindMs(60 * 60 * 1000, reason: r), 30000, reason: '$r');
      }
    });

    test('stays below the 2 min jump threshold', () {
      for (final ms in [0, 10000, 300000, 3600000, 1 << 40]) {
        expect(autoRewindMs(ms, reason: PauseReason.routeLost), lessThan(2 * 60 * 1000));
      }
    });

    test('autoRewoundGlobalMs passes the reason on, never before the book start', () {
      expect(autoRewoundGlobalMs(globalMs: 100000, pausedForMs: 20000, reason: PauseReason.routeLost), 70000);
      expect(autoRewoundGlobalMs(globalMs: 100000, pausedForMs: 20000), 97000);
      expect(autoRewoundGlobalMs(globalMs: 12000, pausedForMs: 20000, reason: PauseReason.routeLost), 0);
    });
  });
}
