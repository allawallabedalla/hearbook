import 'dart:io';
import 'dart:typed_data';

import 'package:faden/domain/audio_hash_bounds.dart';
import 'package:faden/data/hash_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List _tone(int seed, int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * seed + 11) % 256));

void main() {
  late Directory tmpDir;
  setUp(() async => tmpDir = await Directory.systemTemp.createTemp('faden-hash-file-test'));
  tearDown(() => tmpDir.delete(recursive: true));

  test('hashFile of a plain file matches domain audioHashBytes', () async {
    final audio = _tone(37, 5000);
    final file = File(p.join(tmpDir.path, 'plain.mp3'));
    await file.writeAsBytes(audio);

    expect(await hashFile(file), audioHashBytes(audio));
  });

  test('hashFile strips ID3v2/ID3v1 tags exactly like the in-memory algorithm, '
      'even when read in small blocks', () async {
    final audio = _tone(53, 20000); // larger than the small blockSize below
    final id3v2 = [
      ...'ID3'.codeUnits,
      4, 0, 0,
      0, 0, 0, 10, // syncsafe size = 10
      ...List.filled(10, 0),
    ];
    final id3v1 = [...'TAG'.codeUnits, ...List.filled(125, 0)];
    final bytes = [...id3v2, ...audio, ...id3v1];

    final file = File(p.join(tmpDir.path, 'tagged.mp3'));
    await file.writeAsBytes(bytes);

    final hash = await hashFile(file, blockSize: 777); // deliberately not a divisor
    expect(hash, audioHashBytes(audio));
  });

  test('two files with the same audio but different tags hash the same', () async {
    final audio = _tone(11, 3000);
    final untagged = File(p.join(tmpDir.path, 'a.mp3'))..writeAsBytesSync(audio);
    final tagged = File(p.join(tmpDir.path, 'b.mp3'))
      ..writeAsBytesSync([...audio, ...'TAG'.codeUnits, ...List.filled(125, 0)]);

    expect(await hashFile(tagged), await hashFile(untagged));
  });
}
