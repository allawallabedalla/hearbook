// Tests domain/sleep_learning.dart (decisions E78, E79, E81): stored
// sleep onsets, the learned prior (median listening time from the last
// awake proof to the onset), the night-window suggestion and the "Im Bett"
// interval for Health. Pure, no I/O.

import 'dart:math';

import 'package:faden/domain/faden_search.dart';
import 'package:faden/domain/sleep_learning.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2024-01-02 00:00 UTC.
const int _day = 1704153600000;

SleepOnsetRecord _onsetAt(int hour, int minute, {int dayOffset = 0, int tzMin = 0, int listenMs = 0, String? id}) {
  final wall = _day + dayOffset * 86400000 + (hour * 60 + minute - tzMin) * 60000;
  return SleepOnsetRecord(
    sessionId: id ?? 's$dayOffset-$hour-$minute',
    bookId: 'b',
    onsetWallMs: wall,
    tzMin: tzMin,
    listenMs: listenMs,
  );
}

void main() {
  group('SleepOnsetRecord', () {
    test('JSON round-trip, with the local date and clock time', () {
      final r = SleepOnsetRecord(
        sessionId: 's1',
        bookId: 'b1',
        onsetWallMs: _day + 22 * 3600000 + 30 * 60000, // 22:30 UTC
        tzMin: 120, // 00:30 local, the next day
        listenMs: 17 * 60000,
        wakeWallMs: _day + 30 * 3600000,
        healthWritten: true,
      );
      expect(r.localDate, '2024-01-03');
      expect(r.localMinuteOfDay, 30);
      final back = SleepOnsetRecord.fromJson(r.toJson());
      expect(back.toJson(), r.toJson());
      expect(r.toJson()['date'], '2024-01-03');
    });

    test('decodes a list, skipping broken entries', () {
      final ok = _onsetAt(23, 0).toJson();
      expect(decodeOnsets('[${_encode(ok)}, {"x": 1}, 7]'), hasLength(1));
      expect(decodeOnsets('nonsense'), isEmpty);
      expect(decodeOnsets(null), isEmpty);
    });

    test('upsert replaces the same session, keeps the newest, oldest first', () {
      var list = <SleepOnsetRecord>[];
      for (var d = 0; d < 70; d++) {
        list = upsertOnset(list, _onsetAt(23, 0, dayOffset: d));
      }
      expect(list, hasLength(maxStoredOnsets));
      expect(list.first.onsetWallMs, lessThan(list.last.onsetWallMs));
      final replaced = upsertOnset(list, _onsetAt(23, 0, dayOffset: 69).copyWith(listenMs: 5));
      expect(replaced, hasLength(maxStoredOnsets));
      expect(replaced.last.listenMs, 5);
      expect(removeOnset(replaced, replaced.last.sessionId), hasLength(maxStoredOnsets - 1));
    });
  });

  group('learnedListenMs (E78)', () {
    test('needs at least 5 onsets', () {
      final four = [for (var i = 0; i < 4; i++) _onsetAt(23, i, listenMs: 600000)];
      expect(learnedListenMs(four), isNull);
      expect(learnedListenMs([...four, _onsetAt(23, 9, listenMs: 600000)]), 600000);
    });

    test('is the median (odd and even counts)', () {
      final odd = [for (final m in [5, 40, 12, 9, 20]) _onsetAt(23, m, listenMs: m * 60000)];
      expect(learnedListenMs(odd), 12 * 60000);
      final even = [...odd, _onsetAt(23, 50, listenMs: 30 * 60000)];
      expect(learnedListenMs(even), 16 * 60000); // (12 + 20) / 2
    });

    test('uses only the most recent onsets', () {
      final old = [for (var d = 0; d < 40; d++) _onsetAt(23, 0, dayOffset: d, listenMs: 60 * 60000)];
      final recent = [for (var d = 40; d < 40 + learningWindow; d++) _onsetAt(23, 0, dayOffset: d, listenMs: 60000)];
      expect(learnedListenMs([...old, ...recent]), 60000);
    });
  });

  group('learnedPrior (E78)', () {
    final five = [for (var i = 0; i < 5; i++) _onsetAt(23, i, listenMs: 10 * 60000)];

    test('lo plus the learned minutes', () {
      expect(learnedPrior(lo: 60000, hi: 60 * 60000, onsets: five), 60000 + 10 * 60000);
    });

    test('only strictly inside (lo, hi), else none', () {
      expect(learnedPrior(lo: 0, hi: 10 * 60000, onsets: five), isNull);
      expect(learnedPrior(lo: 0, hi: 5 * 60000, onsets: five), isNull);
      final zero = [for (var i = 0; i < 5; i++) _onsetAt(23, i, listenMs: 0)];
      expect(learnedPrior(lo: 0, hi: 60 * 60000, onsets: zero), isNull, reason: 'never lo itself');
    });

    test('property: never outside (lo, hi) and never below lo, for random onsets', () {
      final rng = Random(78);
      for (var i = 0; i < 5000; i++) {
        final n = rng.nextInt(12);
        final onsets = [
          for (var k = 0; k < n; k++) _onsetAt(22, k, dayOffset: k, listenMs: rng.nextInt(4 * 60 * 60000)),
        ];
        final lo = rng.nextInt(10 * 60 * 60000);
        final hi = lo + rng.nextInt(5 * 60 * 60000);
        final prior = learnedPrior(lo: lo, hi: hi, onsets: onsets);
        if (prior == null) continue;
        expect(prior, greaterThan(lo));
        expect(prior, lessThan(hi));
      }
    });

    test('property: a search with the learned prior never skips what the listener heard', () async {
      final rng = Random(79);
      for (var i = 0; i < 3000; i++) {
        final onsets = [
          for (var k = 0; k < 5 + rng.nextInt(10); k++)
            _onsetAt(22, k, dayOffset: k, listenMs: rng.nextInt(3 * 60 * 60000)),
        ];
        final lo = rng.nextInt(60 * 60000);
        final hi = lo + 1 + rng.nextInt(4 * 60 * 60000);
        final s = lo + rng.nextInt(hi - lo + 1);
        final known = <int>[];
        final result = await fadenSuche(
          lo,
          hi,
          const [],
          (p, n) async {
            if (p <= s) known.add(p);
            return p <= s;
          },
          prior: learnedPrior(lo: lo, hi: hi, onsets: onsets),
          priorAfterFalseAlarm: true,
        );
        expect(result.start, lessThanOrEqualTo(s));
        expect(result.leiter, [lo, ...known], reason: 'lo moves only by "kenne ich"');
      }
    });
  });

  group('suggestNightWindow (E81)', () {
    test('needs at least 5 onsets', () {
      expect(suggestNightWindow([for (var d = 0; d < 4; d++) _onsetAt(23, 0, dayOffset: d)]), isNull);
    });

    test('10th to 90th percentile, padded 30 min, on 15 min, across midnight', () {
      final onsets = [
        _onsetAt(23, 0, dayOffset: 0),
        _onsetAt(23, 30, dayOffset: 1),
        _onsetAt(23, 45, dayOffset: 2),
        _onsetAt(0, 10, dayOffset: 4),
        _onsetAt(0, 30, dayOffset: 5),
      ];
      final w = suggestNightWindow(onsets)!;
      expect((w.startMin, w.endMin), (22 * 60 + 30, 60)); // 22:30-01:00
    });

    test('uses the local clock time of each onset', () {
      final onsets = [for (var d = 0; d < 5; d++) _onsetAt(22, 0, dayOffset: d, tzMin: 120)];
      final w = suggestNightWindow(onsets)!;
      expect((w.startMin, w.endMin), (21 * 60 + 30, 22 * 60 + 30));
    });

    test('a window entirely before midnight', () {
      final onsets = [for (final m in [0, 10, 20, 30, 40]) _onsetAt(21, m, dayOffset: m)];
      final w = suggestNightWindow(onsets)!;
      expect((w.startMin, w.endMin), (20 * 60 + 30, 22 * 60 + 15));
    });

    test('a window entirely after midnight', () {
      final onsets = [for (final m in [5, 15, 25, 35, 55]) _onsetAt(1, m, dayOffset: m)];
      final w = suggestNightWindow(onsets)!;
      expect(w.startMin, 0 * 60 + 30);
      expect(w.endMin, 2 * 60 + 30);
    });

    test('midnight exactly', () {
      final onsets = [for (var d = 0; d < 6; d++) _onsetAt(0, 0, dayOffset: d)];
      final w = suggestNightWindow(onsets)!;
      expect((w.startMin, w.endMin), (23 * 60 + 30, 30));
    });

    test('too scattered to suggest anything', () {
      final onsets = [for (var h = 0; h < 24; h += 3) _onsetAt(h, 0, dayOffset: h)];
      expect(suggestNightWindow(onsets), isNull);
    });
  });

  group('widenNightWindow (E90: the suggestion only widens)', () {
    const h = 60;
    (int, int)? widen(int s, int e, int ss, int se) {
      final w = widenNightWindow(
        currentStartMin: s,
        currentEndMin: e,
        suggestion: SuggestedNightWindow(startMin: ss, endMin: se),
      );
      return w == null ? null : (w.startMin, w.endMin);
    }

    test('a suggestion inside the current window changes nothing', () {
      expect(widen(20 * h, 6 * h, 22 * h + 30, 1 * h), isNull);
      expect(widen(20 * h, 6 * h, 20 * h, 6 * h), isNull);
    });

    test('a later end widens the end only', () {
      expect(widen(20 * h, 6 * h, 23 * h, 7 * h), (20 * h, 7 * h));
    });

    test('an earlier start widens the start only', () {
      expect(widen(20 * h, 6 * h, 19 * h, 2 * h), (19 * h, 6 * h));
    });

    test('a suggestion around the current window replaces it', () {
      expect(widen(22 * h, 2 * h, 21 * h, 3 * h), (21 * h, 3 * h));
    });

    test('disjoint: the shorter span covering both, never narrower', () {
      // 22-02 and 03-05: 22-05 (7 h) instead of 03-02 (23 h).
      expect(widen(22 * h, 2 * h, 3 * h, 5 * h), (22 * h, 5 * h));
      // 01-03 and 22-23: 22-03.
      expect(widen(1 * h, 3 * h, 22 * h, 23 * h), (22 * h, 3 * h));
    });

    test('a whole-day window cannot widen', () {
      expect(widen(0, 0, 22 * h, 2 * h), isNull);
    });

    test('the result always contains the current window', () {
      final rng = Random(7);
      for (var i = 0; i < 2000; i++) {
        final s = rng.nextInt(24 * 4) * 15, e = rng.nextInt(24 * 4) * 15;
        final ss = rng.nextInt(24 * 4) * 15, se = rng.nextInt(24 * 4) * 15;
        if (s == e || ss == se) continue;
        final w = widen(s, e, ss, se);
        if (w == null) continue;
        bool inside(int m, int a, int b) => a < b ? m >= a && m < b : m >= a || m < b;
        for (var m = 0; m < 24 * 60; m += 15) {
          if (inside(m, s, e)) expect(inside(m, w.$1, w.$2), isTrue, reason: '$s-$e + $ss-$se -> $w at $m');
          if (inside(m, ss, se)) expect(inside(m, w.$1, w.$2), isTrue, reason: '$s-$e + $ss-$se -> $w at $m');
        }
      }
    });
  });

  group('inBedInterval (E82)', () {
    final onset = _onsetAt(23, 0);

    test('from the onset to the first awake proof after the stop', () {
      final r = onset.copyWith(wakeWallMs: onset.onsetWallMs + 7 * 3600000);
      expect(inBedInterval(r), (start: r.onsetWallMs, end: r.onsetWallMs + 7 * 3600000));
    });

    test('none without a wake time, under 30 min or over 16 h', () {
      expect(inBedInterval(onset), isNull);
      expect(inBedInterval(onset.copyWith(wakeWallMs: onset.onsetWallMs + 29 * 60000)), isNull);
      expect(inBedInterval(onset.copyWith(wakeWallMs: onset.onsetWallMs + 17 * 3600000)), isNull);
    });
  });
}

String _encode(Map<String, dynamic> json) => encodeOnsets([SleepOnsetRecord.fromJson(json)]).replaceAll(RegExp(r'^\[|\]$'), '');
