import 'package:faden/audio/playback_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isBuffering (E39)', () {
    test('only while playback is wanted and data is missing', () {
      expect(isBuffering(playing: true, phase: PlayerPhase.buffering), isTrue);
      expect(isBuffering(playing: true, phase: PlayerPhase.loading), isTrue);
      expect(isBuffering(playing: true, phase: PlayerPhase.ready), isFalse);
      expect(isBuffering(playing: false, phase: PlayerPhase.buffering), isFalse);
      expect(isBuffering(playing: true, phase: PlayerPhase.idle), isFalse);
    });
  });

  group('isNaturalChapterAdvance', () {
    test('index + 1 without a seek is playback running into the next chapter', () {
      expect(isNaturalChapterAdvance(previous: 2, next: 3, expectedSeekIndex: null), isTrue);
    });

    test('the index a seek targeted is never a natural advance', () {
      expect(isNaturalChapterAdvance(previous: 2, next: 3, expectedSeekIndex: 3), isFalse);
    });

    test('jumps back or further, and the first index after opening, are not', () {
      expect(isNaturalChapterAdvance(previous: 3, next: 2, expectedSeekIndex: null), isFalse);
      expect(isNaturalChapterAdvance(previous: 1, next: 3, expectedSeekIndex: null), isFalse);
      expect(isNaturalChapterAdvance(previous: null, next: 0, expectedSeekIndex: null), isFalse);
    });
  });

  test('PlaybackStatus.copyWith keeps or clears the error', () {
    const failure = PlaybackFailure(code: 1, message: 'x');
    final withError = PlaybackStatus.idle.copyWith(error: failure);
    expect(withError.error, failure);
    expect(withError.copyWith(playing: true).error, failure);
    expect(withError.copyWith(clearError: true).error, isNull);
  });
}
