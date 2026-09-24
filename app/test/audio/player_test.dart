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
}
