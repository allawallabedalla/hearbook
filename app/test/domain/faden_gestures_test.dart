// Tests domain/faden_gestures.dart (decision E85): headphone gestures
// during the Faden search and on its result.

import 'package:faden/domain/faden_gestures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('during the search', () {
    test('1x (play, pause, click) is "Kenne ich"', () {
      expect(fadenGestureFor(RemoteCommand.play, FadenRemotePhase.search), FadenGesture.known);
      expect(fadenGestureFor(RemoteCommand.pause, FadenRemotePhase.search), FadenGesture.known);
    });

    test('2x (next track, skip forward) is "Kenne ich nicht"', () {
      expect(fadenGestureFor(RemoteCommand.next, FadenRemotePhase.search), FadenGesture.unknown);
      expect(fadenGestureFor(RemoteCommand.fastForward, FadenRemotePhase.search), FadenGesture.unknown);
    });

    test('3x (previous track, skip back) is "Nochmal hören"', () {
      expect(fadenGestureFor(RemoteCommand.previous, FadenRemotePhase.search), FadenGesture.replay);
      expect(fadenGestureFor(RemoteCommand.rewind, FadenRemotePhase.search), FadenGesture.replay);
    });

    test('every command is consumed', () {
      for (final c in RemoteCommand.values) {
        expect(fadenGestureFor(c, FadenRemotePhase.search), isNotNull, reason: '$c');
      }
    });
  });

  group('on the result', () {
    test('3x is "Etwas früher anfangen" while there is an earlier passage', () {
      expect(fadenGestureFor(RemoteCommand.previous, FadenRemotePhase.result, canGoEarlier: true),
          FadenGesture.earlier);
      expect(fadenGestureFor(RemoteCommand.rewind, FadenRemotePhase.result, canGoEarlier: true),
          FadenGesture.earlier);
    });

    test('without an earlier passage, and for every other command, buttons act normally', () {
      expect(fadenGestureFor(RemoteCommand.rewind, FadenRemotePhase.result, canGoEarlier: false), isNull);
      for (final c in [RemoteCommand.play, RemoteCommand.pause, RemoteCommand.next, RemoteCommand.fastForward]) {
        expect(fadenGestureFor(c, FadenRemotePhase.result, canGoEarlier: true), isNull, reason: '$c');
      }
    });
  });
}
