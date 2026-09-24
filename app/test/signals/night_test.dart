import 'package:faden/signals/night.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isInNightWindow', () {
    const start = 20 * 60; // 20:00
    const end = 6 * 60; // 06:00, wraps past midnight

    int wallMsAtLocalMinute(int minute) => minute * 60000; // tz_min = 0

    test('inside the window after midnight-wrap start', () {
      expect(
        isInNightWindow(
            nowWallMs: wallMsAtLocalMinute(21 * 60), tzMin: 0, nightStartMin: start, nightEndMin: end),
        isTrue,
      );
    });

    test('inside the window just before it ends (past midnight)', () {
      expect(
        isInNightWindow(
            nowWallMs: wallMsAtLocalMinute(5 * 60 + 59), tzMin: 0, nightStartMin: start, nightEndMin: end),
        isTrue,
      );
    });

    test('outside the window at noon', () {
      expect(
        isInNightWindow(
            nowWallMs: wallMsAtLocalMinute(12 * 60), tzMin: 0, nightStartMin: start, nightEndMin: end),
        isFalse,
      );
    });

    test('end boundary is exclusive', () {
      expect(
        isInNightWindow(
            nowWallMs: wallMsAtLocalMinute(6 * 60), tzMin: 0, nightStartMin: start, nightEndMin: end),
        isFalse,
      );
    });

    test('tz_min shifts local time', () {
      // UTC 22:30 in UTC+2 is local 00:30 -- inside the window.
      final utcWallMs = (22 * 60 + 30) * 60000;
      expect(
        isInNightWindow(nowWallMs: utcWallMs, tzMin: 120, nightStartMin: start, nightEndMin: end),
        isTrue,
      );
    });
  });

  group('nextNightView (display brightness, hysteresis)', () {
    test('turns on below 30 %', () {
      expect(nextNightView(current: false, brightness: 0.29), isTrue);
      expect(nextNightView(current: false, brightness: 0.0), isTrue);
    });

    test('does not turn on at exactly 30 % or in the band up to 35 %', () {
      expect(nextNightView(current: false, brightness: 0.30), isFalse);
      expect(nextNightView(current: false, brightness: 0.33), isFalse);
      expect(nextNightView(current: false, brightness: 0.35), isFalse);
    });

    test('once on, stays on up to 35 % and turns off only above', () {
      expect(nextNightView(current: true, brightness: 0.30), isTrue);
      expect(nextNightView(current: true, brightness: 0.35), isTrue);
      expect(nextNightView(current: true, brightness: 0.351), isFalse);
      expect(nextNightView(current: true, brightness: 1.0), isFalse);
    });

    test('a brightness wobbling around 30 % does not flicker', () {
      var on = false;
      final seen = <bool>[];
      for (final b in [0.40, 0.29, 0.31, 0.29, 0.32, 0.34, 0.31, 0.36, 0.31, 0.33]) {
        on = nextNightView(current: on, brightness: b);
        seen.add(on);
      }
      expect(seen, [false, true, true, true, true, true, true, false, false, false]);
    });

    test('no brightness means off', () {
      expect(nextNightView(current: true, brightness: null), isFalse);
      expect(nextNightView(current: false, brightness: null), isFalse);
      expect(nextNightView(current: true, brightness: double.nan), isFalse);
    });
  });
}
