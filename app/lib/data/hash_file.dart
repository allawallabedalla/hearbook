import 'dart:io';
import 'dart:typed_data';

import '../domain/audio_hash_bounds.dart';

/// Computes the audio-hash (docs/ARCHITEKTUR.md section 3.4) of a file on
/// disk, reading it in bounded [blockSize] chunks -- the file is never
/// held in memory at once, matching the server's algorithm
/// (server/src/faden_server/audio_hash.py) and using the same pure
/// boundary/hash logic (domain/audio_hash_bounds.dart) so the two agree
/// bit-for-bit. This is the `dart:io` half of that split: the domain
/// function stays platform-agnostic, this is the thin adapter that feeds
/// it real file bytes.
Future<String> hashFile(File file, {int blockSize = 1024 * 1024}) async {
  final raf = await file.open();
  try {
    final fileSize = await raf.length();
    Uint8List read(int start, int length) {
      raf.setPositionSync(start);
      return raf.readSync(length);
    }

    return audioHashStreaming(fileSize, read, blockSize: blockSize);
  } finally {
    await raf.close();
  }
}
