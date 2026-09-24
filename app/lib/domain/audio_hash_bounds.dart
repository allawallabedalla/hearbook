import 'dart:typed_data';

import 'package:convert/convert.dart' show AccumulatorSink;
import 'package:crypto/crypto.dart';

/// Reads `length` bytes starting at `start` from some byte source. May
/// return fewer bytes near the end of the source (never more, never a
/// negative-length result). This indirection keeps boundary detection and
/// hashing here free of `dart:io`: tests back it with an in-memory buffer
/// ([bytesRangeReader]), `data/hash_file.dart` backs it with a file read in
/// bounded blocks.
typedef ByteRangeReader = Uint8List Function(int start, int length);

/// A [ByteRangeReader] over an in-memory buffer.
ByteRangeReader bytesRangeReader(Uint8List data) {
  return (start, length) {
    if (start < 0 || start >= data.length || length <= 0) {
      return Uint8List(0);
    }
    final end = (start + length) > data.length ? data.length : start + length;
    return data.sublist(start, end);
  };
}

/// The audio payload's byte range within a file, `[start, end)`, with any
/// leading ID3v2 tag and trailing ID3v1/APEv2 tag stripped. Tags are
/// ignored on purpose (docs/ARCHITEKTUR.md section 3.4, decision E5):
/// renaming or re-tagging a file must never change its hash.
class AudioBounds {
  final int start;
  final int end;

  const AudioBounds({required this.start, required this.end});
}

final _id3Magic = 'ID3'.codeUnits;
final _id3v1Magic = 'TAG'.codeUnits;
final _apeMagic = 'APETAGEX'.codeUnits;
const _maxEndPasses = 4;

bool _bytesEqual(Uint8List a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _syncsafeU32(Uint8List b) => (b[0] << 21) | (b[1] << 14) | (b[2] << 7) | b[3];

int _u32Le(Uint8List b, int offset) =>
    b[offset] | (b[offset + 1] << 8) | (b[offset + 2] << 16) | (b[offset + 3] << 24);

/// Skips leading ID3v2 tag(s), each possibly carrying a 10-byte footer.
int _findStart(ByteRangeReader read) {
  var start = 0;
  while (true) {
    final header = read(start, 10);
    if (header.length < 10 || !_bytesEqual(header.sublist(0, 3), _id3Magic)) {
      break;
    }
    final size = _syncsafeU32(header.sublist(6, 10));
    final hasFooter = (header[5] & 0x10) != 0;
    start += 10 + size + (hasFooter ? 10 : 0);
  }
  return start;
}

/// Strips trailing ID3v1 and/or APEv2 (with or without header) tags.
int _findEnd(ByteRangeReader read, int fileSize, int start) {
  var ende = fileSize;
  for (var pass = 0; pass < _maxEndPasses; pass++) {
    var changed = false;

    if (ende - start >= 128) {
      final tag = read(ende - 128, 3);
      if (_bytesEqual(tag, _id3v1Magic)) {
        ende -= 128;
        changed = true;
      }
    }

    if (!changed && ende - start >= 32) {
      final footer = read(ende - 32, 32);
      if (footer.length == 32 && _bytesEqual(footer.sublist(0, 8), _apeMagic)) {
        final size = _u32Le(footer, 12);
        final flags = _u32Le(footer, 20);
        final hasHeader = (flags & 0x80000000) != 0;
        ende -= size + (hasHeader ? 32 : 0);
        changed = true;
      }
    }

    if (!changed) break;
  }
  return ende < start ? start : ende;
}

/// Finds the audio payload's byte range within a file of `fileSize` bytes,
/// reading only bounded, small ranges via [read] (never the whole file).
AudioBounds findAudioBounds(int fileSize, ByteRangeReader read) {
  final start = _findStart(read);
  final end = _findEnd(read, fileSize, start);
  return AudioBounds(start: start, end: end);
}

/// Hashes the audio payload of an in-memory byte buffer. For large files
/// read from disk, prefer [audioHashStreaming] so the whole file is never
/// held in memory at once.
String audioHashBytes(Uint8List data) {
  final bounds = findAudioBounds(data.length, bytesRangeReader(data));
  return sha256.convert(data.sublist(bounds.start, bounds.end)).toString();
}

/// Hashes the audio payload by reading `[start, end)` through [read] in
/// `blockSize` chunks, so the whole file is never held in memory at once
/// (mirrors `server/src/faden_server/audio_hash.py`, which streams in 1 MiB
/// blocks). `read` must be able to serve any sub-range of `[0, fileSize)`.
String audioHashStreaming(
  int fileSize,
  ByteRangeReader read, {
  int blockSize = 1024 * 1024,
}) {
  final bounds = findAudioBounds(fileSize, read);
  final output = AccumulatorSink<Digest>();
  final input = sha256.startChunkedConversion(output);
  var offset = bounds.start;
  while (offset < bounds.end) {
    final len = (bounds.end - offset) < blockSize ? (bounds.end - offset) : blockSize;
    final chunk = read(offset, len);
    if (chunk.isEmpty) break;
    input.add(chunk);
    offset += chunk.length;
  }
  input.close();
  return output.events.single.toString();
}
