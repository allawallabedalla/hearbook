import 'dart:typed_data';

import 'package:faden/domain/audio_hash_bounds.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors server/tests/test_audio_hash.py: both implementations follow the
/// same pseudocode (docs/ARCHITEKTUR.md section 3.4) and must agree, so the
/// app can verify a downloaded file's hash against the one the server
/// reports. Test "audio" here is just a deterministic byte pattern -- the
/// algorithm treats the payload opaquely, it never looks at MP3 frames.

Uint8List _syncsafe(int n) => Uint8List.fromList([
      (n >> 21) & 0x7F,
      (n >> 14) & 0x7F,
      (n >> 7) & 0x7F,
      n & 0x7F,
    ]);

Uint8List _u32le(int n) => Uint8List.fromList([
      n & 0xFF,
      (n >> 8) & 0xFF,
      (n >> 16) & 0xFF,
      (n >> 24) & 0xFF,
    ]);

Uint8List _tone(int seed, int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * seed + 11) % 256));

Uint8List buildId3v2(Uint8List payload, {required bool footer}) {
  final flags = footer ? 0x10 : 0x00;
  final out = BytesBuilder()
    ..add('ID3'.codeUnits)
    ..add([4, 0, flags])
    ..add(_syncsafe(payload.length))
    ..add(payload);
  if (footer) {
    out
      ..add('3DI'.codeUnits)
      ..add([4, 0, flags])
      ..add(_syncsafe(payload.length));
  }
  return out.toBytes();
}

Uint8List buildId3v1() {
  final tag = Uint8List(128);
  tag.setRange(0, 3, 'TAG'.codeUnits);
  return tag;
}

Uint8List buildApe(Uint8List itemPayload, {required bool withHeader}) {
  final tagSize = itemPayload.length + 32;
  final flags = withHeader ? 0x80000000 : 0x00000000;
  final footer = (BytesBuilder()
        ..add('APETAGEX'.codeUnits)
        ..add(_u32le(2000))
        ..add(_u32le(tagSize))
        ..add(_u32le(1))
        ..add(_u32le(flags))
        ..add(Uint8List(8)))
      .toBytes();
  assert(footer.length == 32);
  final out = BytesBuilder();
  if (withHeader) out.add(footer);
  out
    ..add(itemPayload)
    ..add(footer);
  return out.toBytes();
}

void main() {
  final baseAudio = _tone(37, 2000);
  final otherAudio = _tone(53, 2000);

  test('same audio with different tags or name -> same hash', () {
    final tagged = (BytesBuilder()
          ..add(buildId3v2(Uint8List(40), footer: false))
          ..add(baseAudio)
          ..add(buildId3v1()))
        .toBytes();

    expect(audioHashBytes(tagged), audioHashBytes(baseAudio));
  });

  test('different audio -> different hash', () {
    expect(audioHashBytes(baseAudio), isNot(audioHashBytes(otherAudio)));
  });

  test('ID3v2 with footer is stripped', () {
    final wrapped = (BytesBuilder()
          ..add(buildId3v2(Uint8List(64), footer: true))
          ..add(baseAudio))
        .toBytes();
    expect(audioHashBytes(wrapped), audioHashBytes(baseAudio));
  });

  test('APEv2 without header is stripped', () {
    final wrapped = (BytesBuilder()
          ..add(baseAudio)
          ..add(buildApe(Uint8List(20), withHeader: false)))
        .toBytes();
    expect(audioHashBytes(wrapped), audioHashBytes(baseAudio));
  });

  test('APEv2 with header is stripped', () {
    final wrapped = (BytesBuilder()
          ..add(baseAudio)
          ..add(buildApe(Uint8List(20), withHeader: true)))
        .toBytes();
    expect(audioHashBytes(wrapped), audioHashBytes(baseAudio));
  });

  test('ID3v1 and APEv2 (without header) combined are stripped', () {
    final wrapped = (BytesBuilder()
          ..add(baseAudio)
          ..add(buildApe(Uint8List(20), withHeader: false))
          ..add(buildId3v1()))
        .toBytes();
    expect(audioHashBytes(wrapped), audioHashBytes(baseAudio));
  });

  test('ID3v1 and APEv2 (with header) combined are stripped', () {
    final wrapped = (BytesBuilder()
          ..add(baseAudio)
          ..add(buildApe(Uint8List(20), withHeader: true))
          ..add(buildId3v1()))
        .toBytes();
    expect(audioHashBytes(wrapped), audioHashBytes(baseAudio));
  });

  test('findAudioBounds strips only the tags, keeps the audio range', () {
    final wrapped = (BytesBuilder()
          ..add(buildId3v2(Uint8List(10), footer: false))
          ..add(baseAudio)
          ..add(buildId3v1()))
        .toBytes();
    final bounds = findAudioBounds(wrapped.length, bytesRangeReader(wrapped));
    expect(bounds.end - bounds.start, baseAudio.length);
    expect(wrapped.sublist(bounds.start, bounds.end), baseAudio);
  });

  test('audioHashStreaming agrees with audioHashBytes, in small blocks', () {
    final wrapped = (BytesBuilder()
          ..add(buildId3v2(Uint8List(10), footer: false))
          ..add(baseAudio)
          ..add(buildApe(Uint8List(20), withHeader: true))
          ..add(buildId3v1()))
        .toBytes();
    final streamed = audioHashStreaming(
      wrapped.length,
      bytesRangeReader(wrapped),
      blockSize: 97, // deliberately not a divisor of the payload length
    );
    expect(streamed, audioHashBytes(wrapped));
    expect(streamed, audioHashBytes(baseAudio));
  });

  test('hex digest shape: 64 lowercase hex characters', () {
    final h = audioHashBytes(baseAudio);
    expect(h.length, 64);
    expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(h), isTrue);
  });

  test('an untagged file with no ID3/APE/ID3v1 markers hashes as-is', () {
    expect(audioHashBytes(baseAudio), audioHashBytes(baseAudio));
    final bounds = findAudioBounds(baseAudio.length, bytesRangeReader(baseAudio));
    expect(bounds.start, 0);
    expect(bounds.end, baseAudio.length);
  });
}
