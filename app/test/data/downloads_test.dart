import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:faden/data/api.dart';
import 'package:faden/data/downloads.dart';
import 'package:faden/domain/audio_hash_bounds.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

Uint8List _tone(int seed, int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * seed + 11) % 256));

ApiClient _apiServing(Uint8List bytes) {
  final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response(
            requestOptions: options..responseType = ResponseType.stream,
            statusCode: 200,
            data: ResponseBody.fromBytes(bytes, 200),
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}

void main() {
  late Directory tmpDir;
  setUp(() async => tmpDir = await Directory.systemTemp.createTemp('faden-downloads-test'));
  tearDown(() => tmpDir.delete(recursive: true));

  test('a download whose bytes match file_hash succeeds and lands at pathFor()', () async {
    final audio = _tone(7, 4000);
    final hash = audioHashBytes(audio);
    final manager = DownloadManager(api: _apiServing(audio), targetDir: tmpDir);

    final result = await manager.download(hash);

    expect(result.ok, isTrue);
    expect(result.error, isNull);
    final dest = manager.pathFor(hash);
    expect(await dest.exists(), isTrue);
    expect(await dest.readAsBytes(), audio);
    expect(await File('${dest.path}.part').exists(), isFalse);
  });

  test('a download whose bytes do NOT match the expected hash fails and '
      'leaves no partial file behind', () async {
    final audio = _tone(7, 4000);
    final wrongHash = audioHashBytes(_tone(9, 4000)); // a different file's hash
    final manager = DownloadManager(api: _apiServing(audio), targetDir: tmpDir);

    final result = await manager.download(wrongHash);

    expect(result.ok, isFalse);
    expect(result.error, contains('hash mismatch'));
    expect(await manager.pathFor(wrongHash).exists(), isFalse);
    expect(await File('${manager.pathFor(wrongHash).path}.part').exists(), isFalse);
  });

  group('isDownloaded', () {
    test('false when the file does not exist yet', () async {
      final manager = DownloadManager(api: _apiServing(Uint8List(0)), targetDir: tmpDir);
      expect(await manager.isDownloaded('deadbeef'), isFalse);
    });

    test('true after a successful download', () async {
      final audio = _tone(3, 1000);
      final hash = audioHashBytes(audio);
      final manager = DownloadManager(api: _apiServing(audio), targetDir: tmpDir);
      await manager.download(hash);
      expect(await manager.isDownloaded(hash), isTrue);
    });

    test('false if the file on disk has been corrupted since', () async {
      final audio = _tone(3, 1000);
      final hash = audioHashBytes(audio);
      final manager = DownloadManager(api: _apiServing(audio), targetDir: tmpDir);
      await manager.download(hash);

      await manager.pathFor(hash).writeAsBytes([0, 1, 2, 3]); // simulate corruption
      expect(await manager.isDownloaded(hash), isFalse);
    });
  });

  test('pathFor() is stable and hash-based, independent of any file name from the server', () {
    final manager = DownloadManager(api: _apiServing(Uint8List(0)), targetDir: tmpDir);
    expect(manager.pathFor('abc123').path, p.join(tmpDir.path, 'abc123.mp3'));
  });

  group('verified once, then marker + size (E34)', () {
    test('after a download the file is trusted without re-hashing', () async {
      final audio = _tone(5, 3000);
      final hash = audioHashBytes(audio);
      final manager = DownloadManager(api: _apiServing(audio), targetDir: tmpDir);
      await manager.download(hash);

      // Same size, different bytes: only a re-hash could notice. The marker
      // is trusted instead, which is what makes a library refresh cheap.
      final file = manager.pathFor(hash);
      final tampered = Uint8List.fromList(audio.reversed.toList());
      await file.writeAsBytes(tampered);
      expect(await manager.isDownloaded(hash), isTrue);
      expect(await File(p.join(tmpDir.path, '$hash.ok')).readAsString(), '${audio.length}');
    });

    test('a file from before markers is verified once and then marked', () async {
      final audio = _tone(4, 2500);
      final hash = audioHashBytes(audio);
      final manager = DownloadManager(api: null, targetDir: tmpDir);
      await manager.pathFor(hash).writeAsBytes(audio);
      final marker = File(p.join(tmpDir.path, '$hash.ok'));
      expect(await marker.exists(), isFalse);

      expect(await manager.isDownloaded(hash), isTrue);
      expect(await marker.exists(), isTrue);
    });

    test('an unmarked file with the wrong hash is not downloaded and gets no marker', () async {
      final manager = DownloadManager(api: null, targetDir: tmpDir);
      final hash = audioHashBytes(_tone(4, 2500));
      await manager.pathFor(hash).writeAsBytes(_tone(6, 2500));
      expect(await manager.isDownloaded(hash), isFalse);
      expect(await File(p.join(tmpDir.path, '$hash.ok')).exists(), isFalse);
    });

    test('delete removes file and marker; sizes are reported', () async {
      final audio = _tone(8, 1200);
      final hash = audioHashBytes(audio);
      final manager = DownloadManager(api: _apiServing(audio), targetDir: tmpDir);
      await manager.download(hash);
      expect(await manager.bytesOnDisk(hash), 1200);
      expect(await manager.totalBytesOnDisk(), 1200);

      await manager.delete(hash);
      expect(await manager.isDownloaded(hash), isFalse);
      expect(await manager.bytesOnDisk(hash), 0);
      expect(await File(p.join(tmpDir.path, '$hash.ok')).exists(), isFalse);
    });

    test('without a server a download fails instead of throwing', () async {
      final manager = DownloadManager(api: null, targetDir: tmpDir);
      final result = await manager.download('abc');
      expect(result.ok, isFalse);
    });
  });
}
