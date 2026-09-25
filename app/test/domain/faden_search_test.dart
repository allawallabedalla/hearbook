import 'package:faden/domain/faden_search.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('snap', () {
    test('snaps to the nearest eligible pause within tolerance', () {
      // lo=0, hi=100000, probeLen=4000 -> eligible pauses in (4000, 96000).
      final pausen = [5000, 50900, 49900, 95000];
      expect(snap(50000, 0, 100000, 2000, pausen), 49900); // nearest of the two candidates
    });

    test('a tie keeps the earlier-listed pause (matches the JS reference reduce)', () {
      final pausen = [50100, 49900]; // both exactly 100 ms from x
      expect(snap(50000, 0, 100000, 2000, pausen), 50100);
    });

    test('ignores pauses too close to lo or hi for a full probe', () {
      final pausen = [1000, 99000]; // within probeLen of lo/hi
      expect(snap(50000, 0, 100000, 60000, pausen), 50000);
    });

    test('ignores pauses outside the tolerance window', () {
      final pausen = [10000];
      expect(snap(50000, 0, 100000, 2000, pausen), 50000);
    });

    test('returns x unchanged when pausen is empty', () {
      expect(snap(12345, 0, 100000, 5000, const []), 12345);
    });

    test('the probe length sets the bounds: a full probe must fit on both sides (4 / 6 / 8 s)', () {
      final pausen = [5000, 7000, 93000];
      // 4 s: 5000 is eligible (4000 < 5000), nearest to x = 6000.
      expect(snap(6000, 0, 100000, 2000, pausen, probeLen: 4000), 5000);
      // 6 s: 5000 is too close to lo, 7000 is the candidate.
      expect(snap(6000, 0, 100000, 2000, pausen, probeLen: 6000), 7000);
      // 8 s: both are too close to lo; x stays.
      expect(snap(6000, 0, 100000, 2000, pausen, probeLen: 8000), 6000);
      // hi side: 93000 < 100000 - 6000 but not < 100000 - 8000.
      expect(snap(93000, 0, 100000, 2000, pausen, probeLen: 6000), 93000);
      expect(snap(92500, 0, 100000, 2000, pausen, probeLen: 8000), 92500);
    });

    test('defaults to 6 s probes', () {
      expect(defaultProbeLen, 6000);
      expect(probeLengths, [4000, 6000, 8000]);
      expect(snap(6000, 0, 100000, 2000, const [5000, 7000]), 7000);
    });
  });

  group('fadenSuche', () {
    test('window already within target: returns immediately without asking', () async {
      var asked = 0;
      final result = await fadenSuche(0, target, const [], (p, n) async {
        asked++;
        return true;
      });
      expect(asked, 0);
      expect(result.start, 0); // max(0 - preroll, 0)
      expect(result.leiter, [0]);
    });

    test('preroll is subtracted but clamped at 0 near the file start', () async {
      final result = await fadenSuche(1000, 1000 + target, const [], (p, n) async => true);
      expect(result.start, 0); // max(1000 - 2000, 0)
    });

    test('probe 1 success returns immediately with a 2-entry leiter', () async {
      final lo = 0, hi = 40 * 60000; // 40 min window, forces the search to run
      final calls = <List<int>>[];
      final result = await fadenSuche(lo, hi, const [], (p, n) async {
        calls.add([p, n]);
        return true; // listener knows the very first probe
      });
      expect(calls.length, 1);
      expect(calls.single[1], 1);
      expect(result.leiter, [lo, calls.single[0]]);
      expect(result.start, calls.single[0]);
    });

    test('listener never answers: start is max(lo - preroll, 0), full probe budget used', () async {
      final lo = 0, hi = 60 * 60000; // 1 h window
      var probes = 0;
      final result = await fadenSuche(lo, hi, const [], (p, n) async {
        probes++;
        return false;
      });
      expect(probes, maxProbes);
      expect(result.start, 0);
      expect(result.leiter, [lo]);
    });

    test('a short window (<= 6 min, E87) asks only probe 1, then starts at lo', () async {
      const lo = 10 * 60000, hi = lo + 5 * 60000;
      final calls = <int>[];
      final result = await fadenSuche(lo, hi, const [], (p, n) async {
        calls.add(p);
        return false;
      });
      expect(calls, [hi - firstOffset]);
      expect(result.start, lo - preroll);
      expect(result.leiter, [lo]);
      expect(result.falseAlarm, isFalse);
    });

    test('a short window: probe 1 recognised is the false alarm as before', () async {
      const lo = 0, hi = shortWindow;
      final result = await fadenSuche(lo, hi, const [], (p, n) async => true);
      expect(result.falseAlarm, isTrue);
      expect(result.start, hi - firstOffset);
    });

    test('a short window ignores a health prior: probe 1 stays the only question', () async {
      const lo = 0, hi = 4 * 60000;
      final calls = <int>[];
      await fadenSuche(lo, hi, const [], (p, n) async {
        calls.add(p);
        return false;
      }, prior: 60000);
      expect(calls, [hi - firstOffset]);
    });

    test('just over 6 min the bisection runs as before', () async {
      const lo = 0, hi = shortWindow + 60000;
      var probes = 0;
      await fadenSuche(lo, hi, const [], (p, n) async {
        probes++;
        return false;
      });
      expect(probes, greaterThan(1));
    });

    test('never asks more than maxProbes probes', () async {
      final lo = 0, hi = 5 * 60 * 60000; // 5 h window
      var probes = 0;
      await fadenSuche(lo, hi, const [], (p, n) async {
        probes++;
        return probes.isEven; // flip-flop, keeps the search running long
      });
      expect(probes, lessThanOrEqualTo(maxProbes));
    });

    test('prior skips the Fehlalarm-Test and is used for the very first probe', () async {
      // Pseudocode: the "wenn prior == null" block (probe 1 against
      // hi - first_offset) only runs when there is no prior; with a prior,
      // the loop's first iteration (proben == 0) uses it directly instead.
      final lo = 0, hi = 40 * 60000;
      final calls = <int>[];
      final result = await fadenSuche(
        lo,
        hi,
        const [],
        (p, n) async {
          calls.add(p);
          return false; // keep going so we can inspect every probe asked
        },
        prior: 5 * 60000,
      );
      expect(calls[0], 5 * 60000); // prior used verbatim (no snap points), not hi - firstOffset
      expect(result.leiter, [lo]); // listener never agreed
    });

    test('a learned prior keeps the Fehlalarm-Test, then replaces the first midpoint', () async {
      final lo = 0, hi = 40 * 60000;
      final calls = <int>[];
      final result = await fadenSuche(
        lo,
        hi,
        const [],
        (p, n) async {
          calls.add(p);
          return false;
        },
        prior: 5 * 60000,
        priorAfterFalseAlarm: true,
      );
      expect(calls[0], hi - firstOffset, reason: 'probe 1 still guards against a false alarm');
      expect(calls[1], 5 * 60000, reason: 'then the learned guess instead of the midpoint');
      expect(calls[2], (5 * 60000) ~/ 2, reason: 'plain bisection afterwards');
      expect(result.leiter, [lo]);
      expect(result.falseAlarm, isFalse);
    });

    test('a learned prior is ignored when probe 1 moved hi to or below it', () async {
      final lo = 0, hi = 40 * 60000;
      final calls = <int>[];
      await fadenSuche(
        lo,
        hi,
        const [],
        (p, n) async {
          calls.add(p);
          return false;
        },
        prior: hi - 10000, // after "no" to probe 1, hi = stop - 25 s < prior
        priorAfterFalseAlarm: true,
      );
      expect(calls[1], (hi - firstOffset) ~/ 2, reason: 'midpoint instead of an out-of-window guess');
    });

    test('a learned prior never moves lo by itself', () async {
      final lo = 60000, hi = 40 * 60000;
      final result = await fadenSuche(
        lo,
        hi,
        const [],
        (p, n) async => false,
        prior: lo, // not strictly inside: ignored
        priorAfterFalseAlarm: true,
      );
      expect(result.leiter, [lo]);
      expect(result.start, lo - preroll);
    });

    test('falseAlarm marks a probe 1 that was recognised', () async {
      final result = await fadenSuche(0, 40 * 60000, const [], (p, n) async => true);
      expect(result.falseAlarm, isTrue);
      final other = await fadenSuche(0, 40 * 60000, const [], (p, n) async => n == 2);
      expect(other.falseAlarm, isFalse);
      expect(other.leiter, hasLength(2));
    });
  });

  group('fadenResultKind (E88: an honest result text)', () {
    test('probe 1 recognised: still awake, just before it stopped', () {
      expect(fadenResultKind(falseAlarm: true, leiterIndex: 1, resultIndex: 1), FadenResultKind.stillAwake);
    });

    test('nothing recognised: from the last touch', () {
      expect(fadenResultKind(falseAlarm: false, leiterIndex: 0, resultIndex: 0), FadenResultKind.nothingRecognised);
    });

    test('a passage found', () {
      expect(fadenResultKind(falseAlarm: false, leiterIndex: 3, resultIndex: 3), FadenResultKind.found);
      expect(fadenResultKind(falseAlarm: false, leiterIndex: 2, resultIndex: 3), FadenResultKind.found);
    });

    test('stepped back to lo: from the last touch', () {
      expect(fadenResultKind(falseAlarm: false, leiterIndex: 0, resultIndex: 2), FadenResultKind.lastTouch);
      expect(fadenResultKind(falseAlarm: true, leiterIndex: 0, resultIndex: 1), FadenResultKind.lastTouch);
    });
  });

  group('remainingQuestions (E89: "Noch höchstens 6 Fragen")', () {
    test('counts down from the probe budget', () {
      expect(remainingQuestions(probeNr: 2, windowMs: 60 * 60000), maxProbes - 2);
      expect(remainingQuestions(probeNr: 8, windowMs: 60 * 60000), 0);
    });

    test('a short window has probe 1 only', () {
      expect(remainingQuestions(probeNr: 1, windowMs: shortWindow), 0);
    });
  });

  group('stepEarlier / positionAtLeiterIndex ("Früher")', () {
    test('steps back exactly one index at a time, never below 0', () {
      var i = 3;
      expect(i = stepEarlier(i), 2);
      expect(i = stepEarlier(i), 1);
      expect(i = stepEarlier(i), 0);
      expect(i = stepEarlier(i), 0);
    });

    test('index 0 applies preroll, other indices use the raw ladder value', () {
      final leiter = [1000, 20000, 35000];
      expect(positionAtLeiterIndex(leiter, 0), 0); // max(1000 - 2000, 0)
      expect(positionAtLeiterIndex(leiter, 1), 20000);
      expect(positionAtLeiterIndex(leiter, 2), 35000);
    });
  });
}
