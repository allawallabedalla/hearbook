// Property tests for Faden-Suche, docs/ARCHITEKTUR.md section 8. Same 5
// properties already validated for the JS reference implementation in
// prototype/faden.html against 20,000 randomized listener simulations
// (docs/ROADMAP.md M0). At least 10,000 random cases per docs/ROADMAP.md M3.
//
// Simulated listener: knows a probe at position p exactly when p <= S, for
// an S drawn uniformly from [lo, hi] -- i.e. they fell asleep at S and
// remember everything before it, nothing after.

import 'dart:math';

import 'package:faden/domain/faden_search.dart';
import 'package:flutter_test/flutter_test.dart';

const int _caseCount = 12000;

class _Case {
  final int lo;
  final int hi;
  final int s;
  final List<int> pausen;

  const _Case({required this.lo, required this.hi, required this.s, required this.pausen});
}

Frage listenerFor(int s) => (p, n) async => p <= s;

/// Draws a randomized (lo, hi, S, pausen) case. `maxWindowMs` bounds
/// `hi - lo`; pausen are scattered across the window (including some
/// deliberately close to lo/hi, which [snap] must reject) so snapping is
/// exercised, not just plain bisection.
_Case _randomCase(Random rng, int maxWindowMs) {
  final lo = rng.nextInt(2 * 60 * 60000); // up to 2 h into the book
  final window = 1 + rng.nextInt(maxWindowMs);
  final hi = lo + window;
  final s = lo + rng.nextInt(window + 1);
  final pausenCount = rng.nextInt(6);
  final pausen = List.generate(pausenCount, (_) => lo + rng.nextInt(window + 1));
  return _Case(lo: lo, hi: hi, s: s, pausen: pausen);
}

void main() {
  final rng = Random(20260924); // fixed seed: deterministic, reproducible failures

  group('property 1: start <= S always (invariant 9, never skips unheard content)', () {
    test('holds across $_caseCount random cases, any window size', () async {
      for (var i = 0; i < _caseCount; i++) {
        final c = _randomCase(rng, 5 * 60 * 60000); // up to 5 h windows
        final result = await fadenSuche(c.lo, c.hi, c.pausen, listenerFor(c.s));
        expect(
          result.start,
          lessThanOrEqualTo(c.s),
          reason: 'case #$i: lo=${c.lo} hi=${c.hi} s=${c.s} pausen=${c.pausen} '
              'start=${result.start} leiter=${result.leiter}',
        );
      }
    });
  });

  group('property 2: window <= 30 min => S - start <= target + preroll', () {
    test('holds across $_caseCount random cases with window <= 30 min', () async {
      for (var i = 0; i < _caseCount; i++) {
        final c = _randomCase(rng, 30 * 60000); // window in (0, 30 min]
        final result = await fadenSuche(c.lo, c.hi, c.pausen, listenerFor(c.s));
        expect(
          c.s - result.start,
          lessThanOrEqualTo(target + preroll),
          reason: 'case #$i: lo=${c.lo} hi=${c.hi} s=${c.s} pausen=${c.pausen} '
              'start=${result.start} leiter=${result.leiter}',
        );
      }
    });
  });

  group('property 3: never more than maxProbes probes', () {
    test('holds across $_caseCount random cases, any window size', () async {
      for (var i = 0; i < _caseCount; i++) {
        final c = _randomCase(rng, 6 * 60 * 60000); // up to 6 h windows
        var probes = 0;
        await fadenSuche(c.lo, c.hi, c.pausen, (p, n) async {
          probes++;
          return p <= c.s;
        });
        expect(
          probes,
          lessThanOrEqualTo(maxProbes),
          reason: 'case #$i: lo=${c.lo} hi=${c.hi} s=${c.s} pausen=${c.pausen} probes=$probes',
        );
      }
    });
  });

  group('property 4: listener never answers => start = max(lo - preroll, 0)', () {
    test('holds across $_caseCount random cases, any window size', () async {
      for (var i = 0; i < _caseCount; i++) {
        final c = _randomCase(rng, 6 * 60 * 60000);
        final result = await fadenSuche(c.lo, c.hi, c.pausen, (p, n) async => false);
        expect(
          result.start,
          max(c.lo - preroll, 0),
          reason: 'case #$i: lo=${c.lo} hi=${c.hi} pausen=${c.pausen} start=${result.start}',
        );
        expect(result.leiter, [c.lo]);
      }
    });
  });

  group('property 5: "Früher" steps exactly one ladder entry back at a time', () {
    test('holds for the ladders produced by $_caseCount random cases', () async {
      for (var i = 0; i < _caseCount; i++) {
        final c = _randomCase(rng, 6 * 60 * 60000);
        final result = await fadenSuche(c.lo, c.hi, c.pausen, listenerFor(c.s));
        var index = result.leiter.length - 1;
        final visited = <int>[index];
        while (index > 0) {
          final next = stepEarlier(index);
          expect(
            next,
            index - 1,
            reason: 'case #$i: leiter=${result.leiter} should step back by exactly 1',
          );
          index = next;
          visited.add(index);
        }
        expect(visited.last, 0);
        // Stepping again from 0 stays at 0 (never goes negative).
        expect(stepEarlier(0), 0);
        // Every index maps to a well-defined position, index 0 preroll-adjusted.
        expect(
          positionAtLeiterIndex(result.leiter, 0),
          max(result.leiter[0] - preroll, 0),
        );
        for (var idx = 1; idx < result.leiter.length; idx++) {
          expect(positionAtLeiterIndex(result.leiter, idx), result.leiter[idx]);
        }
      }
    });
  });
}
