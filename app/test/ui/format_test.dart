// Tests ui/format.dart: the calm, minute-level remaining time of the
// player (decision E44), German speed labels, storage sizes and the
// no-cover monogram.

import 'package:faden/ui/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const min = 60 * 1000;
  const hour = 60 * min;

  group('formatClockOfDay (E89)', () {
    test('local HH:MM from wall time and UTC offset', () {
      // 2024-01-02 22:12 UTC.
      final wall = DateTime.utc(2024, 1, 2, 22, 12, 40).millisecondsSinceEpoch;
      expect(formatClockOfDay(wall, 0), '22:12');
      expect(formatClockOfDay(wall, 60), '23:12');
      expect(formatClockOfDay(wall, 120), '00:12');
    });
  });

  group('formatRemaining', () {
    test('hours and minutes, no seconds', () {
      expect(formatRemaining(3 * hour + 45 * min), '3 Std. 45 Min.');
      expect(formatRemaining(3 * hour + 44 * min + 1), '3 Std. 45 Min.', reason: 'rounds up to the minute');
    });

    test('whole hours drop the minutes', () {
      expect(formatRemaining(2 * hour), '2 Std.');
      expect(formatRemaining(60 * min), '1 Std.');
    });

    test('under an hour: minutes only, never 0 while something is left', () {
      expect(formatRemaining(59 * min), '59 Min.');
      expect(formatRemaining(12 * min), '12 Min.');
      expect(formatRemaining(30 * 1000), '1 Min.');
      expect(formatRemaining(1), '1 Min.');
      expect(formatRemaining(0), '0 Min.');
      expect(formatRemaining(-5), '0 Min.');
    });

    test('changes at most once a minute', () {
      final texts = {for (var ms = 10 * min; ms > 9 * min; ms -= 200) formatRemaining(ms)};
      expect(texts, {'10 Min.'});
    });

    test('coarse (library): whole hours from one hour on', () {
      expect(formatRemaining(5 * hour + 12 * min, coarse: true), '5 Std.');
      expect(formatRemaining(5 * hour + 40 * min, coarse: true), '6 Std.');
      expect(formatRemaining(45 * min, coarse: true), '45 Min.');
    });
  });

  test('formatClock', () {
    expect(formatClock(0), '0:00');
    expect(formatClock(754 * 1000), '12:34');
    expect(formatClock(3 * hour + 4 * min + 5000), '3:04:05');
  });

  test('formatSpeed uses a decimal comma and the × sign', () {
    expect(formatSpeed(1.0), '1×');
    expect(formatSpeed(1.25), '1,25×');
    expect(formatSpeed(0.75), '0,75×');
    expect(formatSpeed(1.5), '1,5×');
    expect(formatSpeed(2.0), '2×');
  });

  test('formatBytes in decimal units', () {
    expect(formatBytes(0), '0 MB');
    expect(formatBytes(340 * 1000 * 1000), '340 MB');
    expect(formatBytes(1200 * 1000 * 1000), '1,2 GB');
    expect(formatBytes(150 * 1000 * 1000 * 1000), '150 GB');
  });

  test("formatRemainingBytes: a download's rest, coarse and rounded up (E62)", () {
    const mb = 1000 * 1000;
    expect(formatRemainingBytes(0), '0 MB');
    expect(formatRemainingBytes(1), '1 MB', reason: 'never "0 MB" while something is left');
    expect(formatRemainingBytes(3 * mb + 1), '4 MB');
    expect(formatRemainingBytes(37 * mb), '37 MB');
    expect(formatRemainingBytes(237 * mb), '240 MB', reason: 'steps of 10 MB from 100 MB');
    expect(formatRemainingBytes(240 * mb), '240 MB');
    expect(formatRemainingBytes(995 * mb), '1,0 GB', reason: 'no "1000 MB"');
    expect(formatRemainingBytes(1230 * mb), '1,3 GB', reason: 'German decimal comma');
    expect(formatRemainingBytes(9990 * mb), '10 GB');
    expect(formatRemainingBytes(12300 * mb), '13 GB');
  });

  test('formatBeforeStop: seconds under a minute, then minutes (E64)', () {
    expect(formatBeforeStop(25000), '25 Sek.');
    expect(formatBeforeStop(0), '0 Sek.');
    expect(formatBeforeStop(59001), '59 Sek.');
    expect(formatBeforeStop(4 * 60000), '4 Min.');
    expect(formatBeforeStop(65 * 60000), '1 Std. 5 Min.');
  });

  test('initialsFor', () {
    expect(initialsFor('Der Zauberberg'), 'DZ');
    expect(initialsFor('momo'), 'M');
    expect(initialsFor('  „Über“ allem  '), 'ÜA');
    expect(initialsFor('!!!'), '');
  });

  test('formatCellularEstimate: per hour and the chapter, "ca." when estimated (E66)', () {
    const mb = 1000 * 1000;
    expect(
      formatCellularEstimate(bytesPerHour: 57600000, chapterNumber: 3, chapterBytes: 23 * mb + 400000),
      '1 Std. ≈ 58 MB · Kapitel 3 ≈ 24 MB',
    );
    expect(
      formatCellularEstimate(bytesPerHour: 28800000, chapterNumber: 1, chapterBytes: 12 * mb, approximate: true),
      '1 Std. ca. 29 MB · Kapitel 1 ca. 12 MB',
    );
  });
}
