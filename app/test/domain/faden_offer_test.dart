// Tests domain/faden_offer.dart (decision E86): when the player offers the
// Faden search as its main button or only underneath "Weiterhören", when a
// play from the lock screen or headphones starts it, and which sessions the
// search learns from.

import 'package:faden/domain/asleep_prompt.dart';
import 'package:faden/domain/faden_offer.dart';
import 'package:faden/domain/pause_reason.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/domain/resolver.dart';
import 'package:flutter_test/flutter_test.dart';

BookState _state({required bool suspected, bool night = false, PauseReason? reason}) {
  const p = Position(fileHash: 'f', offsetMs: 0);
  return BookState(
    position: p,
    globalMs: 0,
    lastAwake: p,
    stop: p,
    sleepSuspected: suspected,
    history: const [],
    finished: false,
    needsConfirmation: false,
    sessionId: 's',
    inNightWindow: night,
    stopReason: reason,
  );
}

void main() {
  group('fadenOfferFor', () {
    test('no suspicion: no offer', () {
      expect(fadenOfferFor(_state(suspected: false, night: true, reason: PauseReason.timer)), FadenOffer.none);
    });

    test('at night or after the sleep timer: "Faden aufnehmen" is the main button', () {
      expect(fadenOfferFor(_state(suspected: true, night: true, reason: PauseReason.unconscious)),
          FadenOffer.primary);
      expect(fadenOfferFor(_state(suspected: true, reason: PauseReason.timer)), FadenOffer.primary);
    });

    test('by day without a timer: "Weiterhören" stays, the search sits underneath', () {
      expect(fadenOfferFor(_state(suspected: true, reason: PauseReason.unconscious)), FadenOffer.secondary);
    });
  });

  group('searchesOnRemotePlay', () {
    test('a play from outside starts the search where it is the main button', () {
      expect(searchesOnRemotePlay(offer: FadenOffer.primary, asleepAsk: AsleepAsk.no, carRoute: false), isTrue);
      expect(searchesOnRemotePlay(offer: FadenOffer.secondary, asleepAsk: AsleepAsk.no, carRoute: false), isFalse);
      expect(searchesOnRemotePlay(offer: FadenOffer.none, asleepAsk: AsleepAsk.no, carRoute: false), isFalse);
    });

    test('or when "Eingeschlafen?" would ask', () {
      expect(searchesOnRemotePlay(offer: FadenOffer.none, asleepAsk: AsleepAsk.overAnHour, carRoute: false),
          isTrue);
    });

    test('never in the car', () {
      expect(searchesOnRemotePlay(offer: FadenOffer.primary, asleepAsk: AsleepAsk.overAnHour, carRoute: true),
          isFalse);
    });
  });

  group('learnsFromSession', () {
    test('only sessions in the night window or ended by the sleep timer', () {
      expect(learnsFromSession(inNightWindow: true, stopReason: PauseReason.unconscious), isTrue);
      expect(learnsFromSession(inNightWindow: false, stopReason: PauseReason.timer), isTrue);
      expect(learnsFromSession(inNightWindow: false, stopReason: PauseReason.unconscious), isFalse);
      expect(learnsFromSession(inNightWindow: false, stopReason: null), isFalse);
    });
  });
}
