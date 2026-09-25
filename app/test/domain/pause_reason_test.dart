// Tests domain/pause_reason.dart (decision E80): why playback paused, what
// that means for SLEEP_HINT, and which pauses rule sleep out for the
// Resolver (section 7 rule 5).

import 'package:faden/core/hlc.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/pause_reason.dart';
import 'package:flutter_test/flutter_test.dart';

Event _pause(Map<String, dynamic> data, {EventType type = EventType.pause}) => Event(
      eventId: 'e',
      deviceId: 'd',
      sessionId: 's',
      bookId: 'b',
      manifestId: 'm',
      type: type,
      fileHash: 'f',
      offsetMs: 0,
      hlc: const Hlc(pt: 1, c: 0),
      wallMs: 1,
      tzMin: 0,
      source: EventSource.system,
      data: data,
    );

void main() {
  group('PauseReason wire names', () {
    test('round-trip', () {
      for (final r in PauseReason.values) {
        expect(PauseReason.fromWire(r.wireName), r);
      }
      expect(PauseReason.routeLost.wireName, 'route_lost');
      expect(PauseReason.fromWire('nonsense'), isNull);
      expect(PauseReason.fromWire(null), isNull);
    });
  });

  group('defaultPauseReason', () {
    test('the on-screen button is a conscious pause', () {
      expect(defaultPauseReason(EventSource.ui), PauseReason.conscious);
    });

    test('media button and system (AirPods sleep detection, lock screen) are unconscious', () {
      expect(defaultPauseReason(EventSource.mediaButton), PauseReason.unconscious);
      expect(defaultPauseReason(EventSource.system), PauseReason.unconscious);
    });

    test('the sleep timer is its own reason', () {
      expect(defaultPauseReason(EventSource.timer), PauseReason.timer);
    });
  });

  group('writesSleepHint', () {
    test('an unconscious pause writes SLEEP_HINT at any time of day', () {
      expect(writesSleepHint(PauseReason.unconscious, carRoute: false), isTrue);
    });

    test('the sleep timer always does', () {
      expect(writesSleepHint(PauseReason.timer, carRoute: false), isTrue);
    });

    test('never for a conscious pause, a lost connection, an interruption or an error', () {
      for (final r in [PauseReason.conscious, PauseReason.routeLost, PauseReason.interruption, PauseReason.error]) {
        expect(writesSleepHint(r, carRoute: false), isFalse, reason: r.name);
      }
    });

    test('never in the car (CarPlay): the driver pressing pause is not asleep', () {
      expect(writesSleepHint(PauseReason.unconscious, carRoute: true), isFalse);
    });
  });

  group('pauseData', () {
    test('records the reason, and the car route when CarPlay is the output', () {
      expect(pauseData(PauseReason.routeLost, carRoute: false), {'reason': 'route_lost'});
      expect(pauseData(PauseReason.unconscious, carRoute: true), {'reason': 'unconscious', 'route': 'car'});
    });
  });

  group('pauseReasonOf', () {
    test('reads the reason of a PAUSE event', () {
      expect(pauseReasonOf(_pause({'reason': 'interruption'})), PauseReason.interruption);
    });

    test('older PAUSE events without data have no reason', () {
      expect(pauseReasonOf(_pause(const {})), isNull);
    });

    test('other event types have none', () {
      expect(pauseReasonOf(_pause({'reason': 'route_lost'}, type: EventType.play)), isNull);
    });
  });

  group('rulesOutSleep (section 7 rule 5)', () {
    test('a lost connection, an interruption or the car rule sleep out', () {
      expect(rulesOutSleep(_pause({'reason': 'route_lost'})), isTrue);
      expect(rulesOutSleep(_pause({'reason': 'interruption'})), isTrue);
      expect(rulesOutSleep(_pause({'reason': 'unconscious', 'route': 'car'})), isTrue);
    });

    test('other pauses do not', () {
      expect(rulesOutSleep(_pause({'reason': 'unconscious'})), isFalse);
      expect(rulesOutSleep(_pause({'reason': 'timer'})), isFalse);
      expect(rulesOutSleep(_pause({'reason': 'error'})), isFalse);
      expect(rulesOutSleep(_pause(const {})), isFalse);
    });

    test('only PAUSE events count', () {
      expect(rulesOutSleep(_pause({'reason': 'route_lost'}, type: EventType.heartbeat)), isFalse);
    });
  });
}
