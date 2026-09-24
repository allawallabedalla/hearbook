import 'package:fake_async/fake_async.dart';
import 'package:faden/signals/sleep_timer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SleepTimerController', () {
    test('counts down and calls onExpire at zero', () {
      fakeAsync((async) {
        var expired = false;
        final controller = SleepTimerController(
          onExpire: () => expired = true,
          onVolumeChange: (_) {},
        );
        controller.start(const Duration(minutes: 15), mode: SleepTimerMode.fixed);
        expect(controller.state.running, isTrue);
        async.elapse(const Duration(minutes: 14, seconds: 59));
        expect(expired, isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(expired, isTrue);
        expect(controller.state.running, isFalse);
        controller.dispose();
      });
    });

    test('fades volume over the last 30s, reaching (near) 0 at expiry', () {
      fakeAsync((async) {
        final volumes = <double>[];
        final controller = SleepTimerController(
          onExpire: () {},
          onVolumeChange: volumes.add,
          fadeWindow: const Duration(seconds: 30),
        );
        controller.start(const Duration(minutes: 1), mode: SleepTimerMode.fixed);
        async.elapse(const Duration(seconds: 29)); // 31s remaining: still full volume
        expect(volumes, isEmpty); // no change from the initial 1.0 yet
        async.elapse(const Duration(seconds: 16)); // 15s remaining: mid-fade
        expect(volumes.last, closeTo(0.5, 0.05));
        async.elapse(const Duration(seconds: 15)); // expiry: restored to 1.0
        expect(volumes.last, 1.0);
        controller.dispose();
      });
    });

    test('cancel stops the countdown and restores volume', () {
      fakeAsync((async) {
        var expired = false;
        double? lastVolume;
        final controller = SleepTimerController(
          onExpire: () => expired = true,
          onVolumeChange: (v) => lastVolume = v,
        );
        controller.start(const Duration(minutes: 5), mode: SleepTimerMode.fixed);
        async.elapse(const Duration(minutes: 4, seconds: 45)); // 15s remaining: mid-fade
        expect(lastVolume, isNotNull);
        expect(lastVolume, lessThan(1.0));
        controller.cancel();
        expect(controller.state.running, isFalse);
        expect(lastVolume, 1.0);
        async.elapse(const Duration(minutes: 10));
        expect(expired, isFalse); // no longer ticking
        controller.dispose();
      });
    });

    test('inLastMinute is only true in the final minute', () {
      fakeAsync((async) {
        final controller = SleepTimerController(onExpire: () {}, onVolumeChange: (_) {});
        controller.start(const Duration(minutes: 15), mode: SleepTimerMode.fixed);
        expect(controller.inLastMinute, isFalse);
        async.elapse(const Duration(minutes: 14));
        expect(controller.inLastMinute, isTrue); // 1 minute remaining
        controller.dispose();
      });
    });

    test('extendIfInLastMinute resets to the original duration and restores volume', () {
      fakeAsync((async) {
        var expired = false;
        final controller = SleepTimerController(
          onExpire: () => expired = true,
          onVolumeChange: (_) {},
        );
        controller.start(const Duration(minutes: 15), mode: SleepTimerMode.fixed);
        async.elapse(const Duration(minutes: 14, seconds: 45)); // 15s remaining, mid-fade
        final consumed = controller.extendIfInLastMinute();
        expect(consumed, isTrue);
        expect(controller.state.remaining, const Duration(minutes: 15));
        expect(controller.state.volumeFactor, 1.0);
        async.elapse(const Duration(minutes: 14, seconds: 59));
        expect(expired, isFalse);
        controller.dispose();
      });
    });

    test('extendIfInLastMinute is a no-op outside the last minute', () {
      fakeAsync((async) {
        final controller = SleepTimerController(onExpire: () {}, onVolumeChange: (_) {});
        controller.start(const Duration(minutes: 15), mode: SleepTimerMode.fixed);
        async.elapse(const Duration(minutes: 5));
        expect(controller.extendIfInLastMinute(), isFalse);
        expect(controller.state.remaining, const Duration(minutes: 10));
        controller.dispose();
      });
    });
  });
}
