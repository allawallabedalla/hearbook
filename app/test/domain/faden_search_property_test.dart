// Property tests for Faden-Suche, docs/ARCHITEKTUR.md section 8. Same 5
// properties already validated for the JS reference implementation in
// prototype/faden.html against 20,000 randomized listener simulations
// (docs/ROADMAP.md M0). At least 10,000 random cases, $len per docs/ROADMAP.md M3.
//
// Simulated listener: knows a probe at position p exactly when p <= S, for
// an S drawn uniformly from [lo, hi] -- i.e. they fell asleep at S and
// remember everything before it, nothing after.

import 'dart:math';

import 'package:faden/domain/faden_search.dart';
import 'package:flutter_test/flutter_test.dart';

const int _caseCount = 12000;

/// Cases per probe length (4 / 6 / 8 s): together the same 12,000.
const int _perLength = _caseCount ~/ 3;

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

  for (final probeLen in probeLengths) {
    _properties(rng, probeLen);
  }
  _learnedPriorProperties(Random(20260925));
}

void _properties(Random rng, int probeLen) {
  final len = '${probeLen ~/ 1000} s probes';

  group('property 1: start <= S always (invariant 9, never skips unheard content)', () {
    test('holds across $_perLength random cases, $len, any window size', () async {
      for (var i = 0; i < _perLength; i++) {
        final c = _randomCase(rng, 5 * 60 * 60000); // up to 5 h windows
        final result = await fadenSuche(c.lo, c.hi, c.pausen, listenerFor(c.s), probeLen: probeLen);
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
    test('holds across $_perLength random cases, $len with window <= 30 min', () async {
      for (var i = 0; i < _perLength; i++) {
        final c = _randomCase(rng, 30 * 60000); // window in (0, 30 min]
        final result = await fadenSuche(c.lo, c.hi, c.pausen, listenerFor(c.s), probeLen: probeLen);
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
    test('holds across $_perLength random cases, $len, any window size', () async {
      for (var i = 0; i < _perLength; i++) {
        final c = _randomCase(rng, 6 * 60 * 60000); // up to 6 h windows
        var probes = 0;
        await fadenSuche(c.lo, c.hi, c.pausen, (p, n) async {
          probes++;
          return p <= c.s;
        }, probeLen: probeLen);
        expect(
          probes,
          lessThanOrEqualTo(maxProbes),
          reason: 'case #$i: lo=${c.lo} hi=${c.hi} s=${c.s} pausen=${c.pausen} probes=$probes',
        );
      }
    });
  });

  group('property 4: listener never answers => start = max(lo - preroll, 0)', () {
    test('holds across $_perLength random cases, $len, any window size', () async {
      for (var i = 0; i < _perLength; i++) {
        final c = _randomCase(rng, 6 * 60 * 60000);
        final result = await fadenSuche(c.lo, c.hi, c.pausen, (p, n) async => false, probeLen: probeLen);
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
    test('holds for the ladders produced by $_perLength random cases, $len', () async {
      for (var i = 0; i < _perLength; i++) {
        final c = _randomCase(rng, 6 * 60 * 60000);
        final result = await fadenSuche(c.lo, c.hi, c.pausen, listenerFor(c.s), probeLen: probeLen);
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

/// Decision E78: a prior learned from earlier searches (the median minutes
/// from the last awake proof to the recognised passage). Probe 1 still runs;
/// the prior replaces only the first bisection midpoint. Random priors,
/// also far outside the window, and a simulated listener.
void _learnedPriorProperties(Random rng) {
  group('learned prior (priorAfterFalseAlarm)', () {
    test('start <= S, lo moves only by "kenne ich", at most maxProbes probes, '
        '$_caseCount random cases', () async {
      for (var i = 0; i < _caseCount; i++) {
        final probeLen = probeLengths[rng.nextInt(probeLengths.length)];
        final c = _randomCase(rng, 5 * 60 * 60000);
        final window = c.hi - c.lo;
        // Anywhere from well before lo to well after hi.
        final prior = c.lo - window + rng.nextInt(3 * window + 1);
        final asked = <int>[];
        final known = <int>[];
        final result = await fadenSuche(
          c.lo,
          c.hi,
          c.pausen,
          (p, n) async {
            asked.add(p);
            final k = p <= c.s;
            if (k) known.add(p);
            return k;
          },
          prior: prior,
          priorAfterFalseAlarm: true,
          probeLen: probeLen,
        );
        final why = 'case #$i: lo=${c.lo} hi=${c.hi} s=${c.s} prior=$prior pausen=${c.pausen} '
            'asked=$asked start=${result.start} leiter=${result.leiter}';
        expect(result.start, lessThanOrEqualTo(c.s), reason: why);
        expect(asked.length, lessThanOrEqualTo(maxProbes), reason: why);
        // The ladder is exactly lo plus every recognised probe (invariant 9).
        expect(result.leiter, [c.lo, ...known], reason: why);
        for (final p in asked) {
          expect(p, greaterThan(c.lo), reason: why);
          expect(p, lessThan(c.hi), reason: why);
        }
        if (window > target) {
          expect(asked.first, snap(c.hi - firstOffset, c.lo, c.hi, 2000, c.pausen, probeLen: probeLen),
              reason: 'probe 1 stays the Fehlalarm-Test: $why');
        }
      }
    });

    test('a prior strictly inside the window after probe 1 is the second probe', () async {
      for (var i = 0; i < 2000; i++) {
        final lo = rng.nextInt(60 * 60000);
        final hi = lo + target + 30000 + rng.nextInt(4 * 60 * 60000);
        final hiAfterProbe1 = hi - firstOffset;
        final prior = lo + 1 + rng.nextInt(hiAfterProbe1 - lo - 1);
        final asked = <int>[];
        await fadenSuche(lo, hi, const [], (p, n) async {
          asked.add(p);
          return false;
        }, prior: prior, priorAfterFalseAlarm: true);
        if (hiAfterProbe1 - lo > target) {
          expect(asked[1], prior, reason: 'lo=$lo hi=$hi prior=$prior asked=$asked');
        }
      }
    });

    test('listener never answers => start = max(lo - preroll, 0), whatever the prior', () async {
      for (var i = 0; i < 3000; i++) {
        final c = _randomCase(rng, 6 * 60 * 60000);
        final prior = c.lo + rng.nextInt(c.hi - c.lo + 1);
        final result = await fadenSuche(c.lo, c.hi, c.pausen, (p, n) async => false,
            prior: prior, priorAfterFalseAlarm: true);
        expect(result.start, max(c.lo - preroll, 0));
        expect(result.leiter, [c.lo]);
      }
    });
  });
}
