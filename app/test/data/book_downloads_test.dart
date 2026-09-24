import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:faden/data/api.dart';
import 'package:faden/data/book_downloads.dart';
import 'package:faden/data/downloads.dart';
import 'package:faden/domain/audio_hash_bounds.dart';
import 'package:faden/domain/manifest.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _tone(int seed, int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * seed + 11) % 256));

/// Serves `/api/v1/files/<hash>` from [files]; a hash in [failing] answers
/// 500; with [gate], every response waits for it.
ApiClient _api(Map<String, Uint8List> files, {Set<String> failing = const {}, Completer<void>? gate}) {
  final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
  dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) async {
    if (gate != null) await gate.future;
    if (options.cancelToken?.isCancelled ?? false) {
      handler.reject(DioException.requestCancelled(requestOptions: options, reason: 'cancel'));
      return;
    }
    final hash = options.path.split('/').last;
    if (failing.contains(hash)) {
      handler.reject(DioException.badResponse(
        statusCode: 500,
        requestOptions: options,
        response: Response(requestOptions: options, statusCode: 500),
      ));
      return;
    }
    handler.resolve(Response(
      requestOptions: options..responseType = ResponseType.stream,
      statusCode: 200,
      data: ResponseBody.fromBytes(files[hash]!, 200),
    ));
  }));
  return ApiClient(dio);
}

void main() {
  group('estimateRemainingBytes (E62)', () {
    test('nothing known yet: no estimate', () {
      expect(estimateRemainingBytes(doneBytes: 0, doneMs: 0, totalMs: 60000), isNull);
      expect(estimateRemainingBytes(doneBytes: 0, doneMs: 0, totalMs: 60000, currentBytes: 500, currentMs: 1000),
          isNull, reason: 'running file without a size');
    });

    test('from the completed files, over the duration still missing', () {
      // 2 MB for 1 min done, 3 min to go.
      expect(estimateRemainingBytes(doneBytes: 2000000, doneMs: 60000, totalMs: 240000), 6000000);
    });

    test('the running file: its exact rest once its size is known, the rest at the combined rate', () {
      expect(
        estimateRemainingBytes(
          doneBytes: 1000,
          doneMs: 1000,
          totalMs: 6000,
          currentBytes: 500,
          currentSize: 3000,
          currentMs: 1000,
        ),
        // 2500 of the running file, then 4000 ms at 4000 bytes / 2000 ms.
        2500 + 8000,
      );
    });

    test('the running file without a size is estimated at the known rate', () {
      expect(
        estimateRemainingBytes(doneBytes: 1000, doneMs: 1000, totalMs: 3000, currentBytes: 400, currentMs: 1000),
        600 + 1000,
      );
    });

    test('never negative', () {
      expect(
        estimateRemainingBytes(doneBytes: 1000, doneMs: 1000, totalMs: 2000, currentBytes: 5000, currentMs: 1000),
        0,
      );
    });
  });

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('faden-book-downloads'));
  tearDown(() => dir.delete(recursive: true));

  final a = _tone(3, 1000);
  final b = _tone(5, 3000);
  final hashA = audioHashBytes(a);
  final hashB = audioHashBytes(b);
  final manifest = Manifest(manifestId: 'm', files: [
    ManifestFile(idx: 0, fileHash: hashA, durationMs: 1000),
    ManifestFile(idx: 1, fileHash: hashB, durationMs: 3000),
  ]);

  test('downloads the whole book with progress and ends done, with its size', () async {
    final downloads = BookDownloads(
      manager: DownloadManager(api: _api({hashA: a, hashB: b}), targetDir: dir),
      progressInterval: Duration.zero,
    );
    final seen = <BookDownloadState>[];
    downloads.addListener(() => seen.add(downloads.stateFor('book')));

    expect(await downloads.download('book', manifest), isTrue);

    final state = downloads.stateFor('book');
    expect(state.status, BookDownloadStatus.done);
    expect(state.filesDone, 2);
    expect(state.bytesOnDisk, 4000);
    expect(seen.where((s) => s.isDownloading).map((s) => s.fraction), contains(closeTo(0.25, 0.001)));
    expect(seen.where((s) => s.isDownloading).any((s) => s.receivedBytes > 0), isTrue);
    // After the first file (1000 bytes for 1000 ms): 3000 ms to go at that rate (E62).
    expect(seen.where((s) => s.isDownloading).map((s) => s.remainingBytes), contains(3000));
    expect(state.remainingBytes, isNull, reason: 'only while downloading');
    expect(await downloads.totalBytesOnDisk(), 4000);
  });

  test('a failure stays visible until the retry succeeds', () async {
    final failing = {hashB};
    final downloads = BookDownloads(
      manager: DownloadManager(api: _api({hashA: a, hashB: b}, failing: failing), targetDir: dir),
    );
    expect(await downloads.download('book', manifest), isFalse);
    final failed = downloads.stateFor('book');
    expect(failed.status, BookDownloadStatus.failed);
    expect(failed.error, isNotNull);
    expect(failed.filesDone, 1);

    // A refresh (e.g. the library) leaves the failure alone.
    await downloads.refresh('book', manifest);
    expect(downloads.stateFor('book').hasFailed, isTrue);

    failing.clear();
    expect(await downloads.retry('book', manifest), isTrue);
    expect(downloads.stateFor('book').isDownloaded, isTrue);
  });

  test('cancel stops without a failure and keeps finished files', () async {
    final gate = Completer<void>();
    final downloads = BookDownloads(manager: DownloadManager(api: _api({hashA: a, hashB: b}, gate: gate), targetDir: dir));
    final running = downloads.download('book', manifest);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(downloads.stateFor('book').isDownloading, isTrue);
    downloads.cancel('book');
    gate.complete();
    expect(await running, isFalse);
    expect(downloads.stateFor('book').status, isNot(BookDownloadStatus.failed));
    expect(downloads.stateFor('book').isDownloading, isFalse);
  });

  test('deleteBook removes every file; refresh reports partial and none', () async {
    final manager = DownloadManager(api: _api({hashA: a, hashB: b}), targetDir: dir);
    final downloads = BookDownloads(manager: manager);
    await manager.download(hashA);
    expect((await downloads.refresh('book', manifest)).status, BookDownloadStatus.partial);

    await downloads.download('book', manifest);
    await downloads.deleteBook('book', manifest);
    expect(downloads.stateFor('book').status, BookDownloadStatus.none);
    expect(await manager.isDownloaded(hashA), isFalse);
    expect(await manager.isDownloaded(hashB), isFalse);
    expect((await downloads.refresh('book', manifest)).status, BookDownloadStatus.none);
  });
}
