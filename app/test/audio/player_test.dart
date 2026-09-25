// audio/player.dart's `streamsFromServer` (decision E58): whether a
// playlist chapter would stream from the server rather than play a
// downloaded file -- what makes a playback error "not downloaded".

import 'package:faden/audio/player.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  final sources = <IndexedAudioSource>[
    AudioSource.uri(Uri.file('/data/audio/h1.mp3')),
    AudioSource.uri(Uri.parse('http://nas.local:8787/api/v1/files/h2'), headers: {'Authorization': 'Bearer t'}),
  ];

  test('a downloaded chapter plays from a file', () {
    expect(streamsFromServer(sources, 0), isFalse);
  });

  test('a chapter that is not downloaded streams', () {
    expect(streamsFromServer(sources, 1), isTrue);
  });

  test('an unknown index is not a stream', () {
    expect(streamsFromServer(sources, null), isFalse);
    expect(streamsFromServer(sources, 2), isFalse);
    expect(streamsFromServer(const [], 0), isFalse);
  });

  group('localSwapFor (E66): a chapter that finished downloading', () {
    LocalSwap swap(int index, {bool streaming = true, int? current = 2, bool idle = false}) =>
        localSwapFor(index: index, length: 6, streaming: streaming, currentIndex: current, playerIdle: idle);

    test('a chapter ahead switches to the file in the player', () {
      expect(swap(3), LocalSwap.inPlayer);
      expect(swap(5), LocalSwap.inPlayer);
    });

    test('the chapter playing now and those behind it stay as they are', () {
      expect(swap(2), LocalSwap.none, reason: 'switching would interrupt it');
      expect(swap(1), LocalSwap.none, reason: 'would move the index like a chapter change');
      expect(swap(3, current: null), LocalSwap.none);
    });

    test('after an error (player idle) only the kept list changes; the next play reloads it', () {
      expect(swap(2, idle: true), LocalSwap.listOnly);
      expect(swap(0, idle: true), LocalSwap.listOnly);
    });

    test('nothing for an entry that already plays from disk or lies outside the list', () {
      expect(swap(3, streaming: false), LocalSwap.none);
      expect(swap(6), LocalSwap.none);
      expect(swap(-1), LocalSwap.none);
    });
  });
}
