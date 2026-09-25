// Tests domain/sleep_onset.dart, docs/ARCHITEKTUR.md section 9's M6 rule:
// "hi = min(stop, pos(T + 5 Min)), prior = pos(T - 10 Min) falls > lo. lo
// wird nie aus Gesundheitsdaten gesetzt (Invariante 9)." Pure -- no health
// plugin, no I/O; test/ui/player_session_sleep_test.dart covers the wiring
// (opt-in, permission, and CLAUDE.md invariant 7) around this.

import 'package:faden/domain/sleep_onset.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('positionAtWallClock', () {
    test('empty heartbeats -> null', () {
      expect(positionAtWallClock(const [], 1000), isNull);
    });

    test('interpolates linearly between two bracketing heartbeats', () {
      final heartbeats = [
        const HeartbeatSample(wallMs: 0, globalMs: 0),
        const HeartbeatSample(wallMs: 10000, globalMs: 10000),
      ];
      expect(positionAtWallClock(heartbeats, 4000), 4000);
    });

    test('interpolates correctly across an intermediate seek (uneven rate)', () {
      // A seek between two heartbeats breaks the "wall time == audio time"
      // assumption; interpolation still runs proportionally on wall time
      // between the two measured global-ms endpoints.
      final heartbeats = [
        const HeartbeatSample(wallMs: 0, globalMs: 0),
        const HeartbeatSample(wallMs: 10000, globalMs: 100000), // a seek happened
      ];
      expect(positionAtWallClock(heartbeats, 5000), 50000);
    });

    test('clamps to the first heartbeat before the range', () {
      final heartbeats = [
        const HeartbeatSample(wallMs: 5000, globalMs: 5000),
        const HeartbeatSample(wallMs: 10000, globalMs: 10000),
      ];
      expect(positionAtWallClock(heartbeats, 0), 5000);
    });

    test('clamps to the last heartbeat past the range', () {
      final heartbeats = [
        const HeartbeatSample(wallMs: 0, globalMs: 0),
        const HeartbeatSample(wallMs: 5000, globalMs: 5000),
      ];
      expect(positionAtWallClock(heartbeats, 999999), 5000);
    });

    test('a single heartbeat is used for any wallMs', () {
      final heartbeats = [const HeartbeatSample(wallMs: 5000, globalMs: 12345)];
      expect(positionAtWallClock(heartbeats, 0), 12345);
      expect(positionAtWallClock(heartbeats, 5000), 12345);
      expect(positionAtWallClock(heartbeats, 999999), 12345);
    });

    test('unsorted input is sorted before bracketing', () {
      final heartbeats = [
        const HeartbeatSample(wallMs: 10000, globalMs: 10000),
        const HeartbeatSample(wallMs: 0, globalMs: 0),
      ];
      expect(positionAtWallClock(heartbeats, 4000), 4000);
    });
  });

  group('adjustForSleepOnset', () {
    // A steady session: wallMs == globalMs (1x, no seeks), so the T +/-
    // offsets translate 1:1 into global ms for readable expectations.
    final steadyHeartbeats = [
      for (var t = 0; t <= 60 * 60000; t += 5000) HeartbeatSample(wallMs: t, globalMs: t),
    ];

    test('shrinks hi to pos(T + 5 Min) when that is below stop', () {
      const t = 20 * 60000; // T = 20 min
      final result = adjustForSleepOnset(
        lo: 0,
        hi: 60 * 60000, // stop = 60 min
        sleepOnsetWallMs: t,
        sessionMinWallMs: 0,
        sessionMaxWallMs: 60 * 60000,
        heartbeats: steadyHeartbeats,
      );
      expect(result.hi, t + hiLookaheadMs); // pos(T + 5 Min)
    });

    test('hi never exceeds the original stop (min(stop, pos(T + 5 Min)))', () {
      const t = 55 * 60000; // T + 5 Min would be past stop
      final result = adjustForSleepOnset(
        lo: 0,
        hi: 56 * 60000, // stop
        sleepOnsetWallMs: t,
        sessionMinWallMs: 0,
        sessionMaxWallMs: 60 * 60000,
        heartbeats: steadyHeartbeats,
      );
      expect(result.hi, 56 * 60000); // unchanged: min(stop, ...) picked stop
    });

    test('sets prior = pos(T - 10 Min) when that is above lo', () {
      const t = 20 * 60000;
      final result = adjustForSleepOnset(
        lo: 5 * 60000,
        hi: 60 * 60000,
        sleepOnsetWallMs: t,
        sessionMinWallMs: 0,
        sessionMaxWallMs: 60 * 60000,
        heartbeats: steadyHeartbeats,
      );
      expect(result.prior, t - priorLookbehindMs); // pos(T - 10 Min) = 10 Min
    });

    test('drops prior when pos(T - 10 Min) is <= lo', () {
      const t = 12 * 60000; // T - 10 Min = 2 min
      final result = adjustForSleepOnset(
        lo: 5 * 60000, // above pos(T - 10 Min)
        hi: 60 * 60000,
        sleepOnsetWallMs: t,
        sessionMinWallMs: 0,
        sessionMaxWallMs: 60 * 60000,
        heartbeats: steadyHeartbeats,
      );
      expect(result.prior, isNull);
      expect(result.hi, isNot(equals(60 * 60000))); // hi itself still adjusts
    });

    test('drops prior when pos(T - 10 Min) equals lo exactly (not "> lo")', () {
      const lo = 10 * 60000;
      const t = lo + priorLookbehindMs; // pos(T - 10 Min) == lo exactly
      final result = adjustForSleepOnset(
        lo: lo,
        hi: 60 * 60000,
        sleepOnsetWallMs: t,
        sessionMinWallMs: 0,
        sessionMaxWallMs: 60 * 60000,
        heartbeats: steadyHeartbeats,
      );
      expect(result.prior, isNull);
    });

    test('T outside the session range -> no adjustment at all (hi unchanged, prior null)', () {
      final result = adjustForSleepOnset(
        lo: 0,
        hi: 60 * 60000,
        sleepOnsetWallMs: 70 * 60000, // after sessionMaxWallMs
        sessionMinWallMs: 0,
        sessionMaxWallMs: 60 * 60000,
        heartbeats: steadyHeartbeats,
      );
      expect(result.hi, 60 * 60000);
      expect(result.prior, isNull);

      final resultBefore = adjustForSleepOnset(
        lo: 0,
        hi: 60 * 60000,
        sleepOnsetWallMs: -1, // before sessionMinWallMs
        sessionMinWallMs: 0,
        sessionMaxWallMs: 60 * 60000,
        heartbeats: steadyHeartbeats,
      );
      expect(resultBefore.hi, 60 * 60000);
      expect(resultBefore.prior, isNull);
    });

    test('no HEARTBEAT events at all -> no adjustment (hi unchanged, prior null)', () {
      final result = adjustForSleepOnset(
        lo: 0,
        hi: 60 * 60000,
        sleepOnsetWallMs: 20 * 60000,
        sessionMinWallMs: 0,
        sessionMaxWallMs: 60 * 60000,
        heartbeats: const [],
      );
      expect(result.hi, 60 * 60000);
      expect(result.prior, isNull);
    });

    test('a reading placing T + 5 Min at or before lo is discarded entirely (lo stays authoritative)', () {
      const t = 3 * 60000; // T + 5 Min = 8 min, still below lo = 10 min
      final result = adjustForSleepOnset(
        lo: 10 * 60000,
        hi: 60 * 60000,
        sleepOnsetWallMs: t,
        sessionMinWallMs: 0,
        sessionMaxWallMs: 60 * 60000,
        heartbeats: steadyHeartbeats,
      );
      expect(result.hi, 60 * 60000); // original hi, not the (invalid) shrink
      expect(result.prior, isNull);
    });

    test('lo itself is never present anywhere in the result -- only used to validate', () {
      // Documents invariant 9 at the type level: SleepPriorAdjustment has
      // no `lo` field at all, so there is no way for a caller to read one
      // back out of this function.
      const t = 20 * 60000;
      final result = adjustForSleepOnset(
        lo: 0,
        hi: 60 * 60000,
        sleepOnsetWallMs: t,
        sessionMinWallMs: 0,
        sessionMaxWallMs: 60 * 60000,
        heartbeats: steadyHeartbeats,
      );
      expect(result.hi, isNotNull); // sanity: this case does compute something
    });
  });

  group('wallClockAtPosition (inverse, decision E79)', () {
    const base = 1700000000000;
    final steady = [
      for (var i = 0; i <= 12; i++) HeartbeatSample(wallMs: base + i * 5000, globalMs: 600000 + i * 5000),
    ];

    test('empty samples -> null', () {
      expect(wallClockAtPosition(const [], 1000), isNull);
    });

    test('interpolates between the two heartbeats around the position', () {
      expect(wallClockAtPosition(steady, 612500), base + 12500);
      expect(wallClockAtPosition(steady, 600000), base);
      expect(wallClockAtPosition(steady, 660000), base + 60000);
    });

    test('is the inverse of positionAtWallClock for steady playback', () {
      for (var g = 600000; g <= 660000; g += 1234) {
        final w = wallClockAtPosition(steady, g)!;
        expect(positionAtWallClock(steady, w), g);
      }
    });

    test('in any order, at 1.5x speed', () {
      final fast = [
        for (var i = 5; i >= 0; i--) HeartbeatSample(wallMs: base + i * 5000, globalMs: i * 7500),
      ];
      expect(wallClockAtPosition(fast, 15000), base + 10000);
    });

    test('a position heard twice (a seek back) maps to the later time', () {
      final samples = [
        const HeartbeatSample(wallMs: base, globalMs: 100000),
        const HeartbeatSample(wallMs: base + 5000, globalMs: 105000),
        const HeartbeatSample(wallMs: base + 10000, globalMs: 110000),
        // seek back to 100000
        const HeartbeatSample(wallMs: base + 15000, globalMs: 101000),
        const HeartbeatSample(wallMs: base + 20000, globalMs: 106000),
      ];
      expect(wallClockAtPosition(samples, 103000), base + 17000);
    });

    test('never interpolates across a jump (no playback runs that fast)', () {
      final samples = [
        const HeartbeatSample(wallMs: base, globalMs: 0),
        const HeartbeatSample(wallMs: base + 5000, globalMs: 5000),
        const HeartbeatSample(wallMs: base + 10000, globalMs: 900000), // a seek forward
        const HeartbeatSample(wallMs: base + 15000, globalMs: 905000),
      ];
      expect(wallClockAtPosition(samples, 400000), isNull);
      expect(wallClockAtPosition(samples, 902000), base + 12000);
    });

    test('just outside the heartbeats: extrapolated at 1x up to 10 s, else null', () {
      expect(wallClockAtPosition(steady, 596000), base - 4000);
      expect(wallClockAtPosition(steady, 665000), base + 65000);
      expect(wallClockAtPosition(steady, 580000), isNull);
      expect(wallClockAtPosition(steady, 700000), isNull);
    });
  });
}
