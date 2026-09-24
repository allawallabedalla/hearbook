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
