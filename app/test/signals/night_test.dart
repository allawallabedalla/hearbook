import 'package:fake_async/fake_async.dart';
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

  test('isNightModeActive: window or running sleep timer', () {
    expect(isNightModeActive(inNightWindow: true, sleepTimerRunning: false), isTrue);
    expect(isNightModeActive(inNightWindow: false, sleepTimerRunning: true), isTrue);
    expect(isNightModeActive(inNightWindow: false, sleepTimerRunning: false), isFalse);
  });

  group('ScreenLockController', () {
    test('locks after the idle timeout with no interaction', () {
      fakeAsync((async) {
        final controller = ScreenLockController(
          idleTimeout: const Duration(seconds: 10),
          holdToUnlock: const Duration(seconds: 1),
        );
        expect(controller.locked, isFalse);
        async.elapse(const Duration(seconds: 10));
        expect(controller.locked, isTrue);
        controller.dispose();
      });
    });

    test('interaction before the timeout postpones the lock', () {
      fakeAsync((async) {
        final controller = ScreenLockController(
          idleTimeout: const Duration(seconds: 10),
          holdToUnlock: const Duration(seconds: 1),
        );
        async.elapse(const Duration(seconds: 8));
        controller.onInteraction();
        async.elapse(const Duration(seconds: 8));
        expect(controller.locked, isFalse); // 16s total, but reset at 8s
        async.elapse(const Duration(seconds: 2));
        expect(controller.locked, isTrue);
        controller.dispose();
      });
    });

    test('a full 1s hold unlocks', () {
      fakeAsync((async) {
        final controller = ScreenLockController();
        async.elapse(const Duration(seconds: 10));
        expect(controller.locked, isTrue);
        controller.startUnlockHold();
        async.elapse(const Duration(seconds: 1));
        expect(controller.locked, isFalse);
        controller.dispose();
      });
    });

    test('releasing before 1s does not unlock', () {
      fakeAsync((async) {
        final controller = ScreenLockController();
        async.elapse(const Duration(seconds: 10));
        expect(controller.locked, isTrue);
        controller.startUnlockHold();
        async.elapse(const Duration(milliseconds: 600));
        controller.cancelUnlockHold();
        async.elapse(const Duration(seconds: 1));
        expect(controller.locked, isTrue);
        controller.dispose();
      });
    });

    test('lockedStream emits on lock and unlock', () {
      fakeAsync((async) {
        final controller = ScreenLockController();
        final events = <bool>[];
        controller.lockedStream.listen(events.add);
        async.elapse(const Duration(seconds: 10));
        controller.startUnlockHold();
        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(events, [true, false]);
        controller.dispose();
      });
    });
  });
}
