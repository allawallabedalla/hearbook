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

    test('exact from the manifest sizes of the files still to come (E66)', () {
      expect(estimateRemainingBytes(doneBytes: 0, doneMs: 0, totalMs: 60000, laterBytes: 5000), 5000,
          reason: 'known before any byte arrived');
      expect(
        estimateRemainingBytes(
          doneBytes: 0,
          doneMs: 0,
          totalMs: 6000,
          currentBytes: 500,
          currentSize: 3000,
          currentMs: 1000,
          laterBytes: 4000,
        ),
        2500 + 4000,
      );
      expect(
        estimateRemainingBytes(doneBytes: 1000, doneMs: 1000, totalMs: 3000, currentBytes: 400, currentMs: 1000, laterBytes: 0),
        600,
        reason: 'the running file without a size falls back to the rate',
      );
    });

    test('knownSizeOf: the sum, or null when a size is missing', () {
      expect(knownSizeOf(const [ManifestFile(idx: 0, fileHash: 'a', durationMs: 1, sizeBytes: 10)]), 10);
      expect(knownSizeOf(const []), 0);
      expect(
        knownSizeOf(const [
          ManifestFile(idx: 0, fileHash: 'a', durationMs: 1, sizeBytes: 10),
          ManifestFile(idx: 1, fileHash: 'b', durationMs: 1),
        ]),
        isNull,
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

  group('with sizes and chapter runs (E66)', () {
    final c = _tone(7, 2000);
    final hashC = audioHashBytes(c);
    final sized = Manifest(manifestId: 'm', files: [
      ManifestFile(idx: 0, fileHash: hashA, durationMs: 1000, sizeBytes: 1000),
      ManifestFile(idx: 1, fileHash: hashB, durationMs: 3000, sizeBytes: 3000),
      ManifestFile(idx: 2, fileHash: hashC, durationMs: 2000, sizeBytes: 2000),
    ]);

    test('the whole book: the rest is exact from the manifest sizes from the start', () async {
      final downloads = BookDownloads(
        manager: DownloadManager(api: _api({hashA: a, hashB: b, hashC: c}), targetDir: dir),
        progressInterval: Duration.zero,
      );
      final rests = <int?>[];
      downloads.addListener(() {
        final state = downloads.stateFor('book');
        if (state.isDownloading) rests.add(state.remainingBytes);
      });
      expect(await downloads.download('book', sized), isTrue);
      expect(rests.whereType<int>().first, 6000, reason: 'known as soon as the local files are counted');
      expect(rests, contains(5000));
      expect(rests, contains(2000));
    });

    test('downloads only the chapters asked for, shown as downloading, and reports each file', () async {
      final manager = DownloadManager(api: _api({hashA: a, hashB: b, hashC: c}), targetDir: dir);
      final downloads = BookDownloads(manager: manager, progressInterval: Duration.zero);
      final files = <DownloadedFile>[];
      final sub = downloads.fileDownloaded.listen(files.add);
      final seen = <BookDownloadState>[];
      downloads.addListener(() => seen.add(downloads.stateFor('book')));

      final run = downloads.downloadChapters('book', sized, [hashB, hashC]);
      expect(downloads.isChapterRun('book'), isTrue);
      expect(await run, ChapterRunResult.done);

      expect(await manager.isDownloaded(hashA), isFalse);
      expect(await manager.isDownloaded(hashB), isTrue);
      expect(await manager.isDownloaded(hashC), isTrue);
      expect(downloads.stateFor('book').status, BookDownloadStatus.partial);
      expect(downloads.isChapterRun('book'), isFalse);
      expect(seen.where((s) => s.isDownloading).map((s) => s.remainingBytes), contains(5000),
          reason: 'the rest of the two chapters, not of the book');
      await Future<void>.delayed(Duration.zero);
      expect(files.map((f) => f.fileHash), [hashB, hashC]);
      expect(files.every((f) => f.bookId == 'book'), isTrue);
      await sub.cancel();
    });

    test('a file no longer wanted is skipped', () async {
      final manager = DownloadManager(api: _api({hashA: a, hashB: b, hashC: c}), targetDir: dir);
      final downloads = BookDownloads(manager: manager);
      final result = await downloads.downloadChapters('book', sized, [hashA, hashB], stillWanted: (h) => h != hashA);
      expect(result, ChapterRunResult.done);
      expect(await manager.isDownloaded(hashA), isFalse);
      expect(await manager.isDownloaded(hashB), isTrue);
    });

    test('a failed chapter run is not kept as a failure', () async {
      final downloads = BookDownloads(
        manager: DownloadManager(api: _api({hashA: a, hashB: b, hashC: c}, failing: {hashB}), targetDir: dir),
      );
      expect(await downloads.downloadChapters('book', sized, [hashA, hashB]), ChapterRunResult.failed);
      expect(downloads.stateFor('book').hasFailed, isFalse);
      expect(downloads.stateFor('book').status, BookDownloadStatus.partial);
    });

    test('the stop button cancels a chapter run', () async {
      final gate = Completer<void>();
      final downloads = BookDownloads(
        manager: DownloadManager(api: _api({hashA: a, hashB: b, hashC: c}, gate: gate), targetDir: dir),
      );
      final run = downloads.downloadChapters('book', sized, [hashA]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      downloads.cancel('book');
      gate.complete();
      expect(await run, ChapterRunResult.cancelled);
    });

    test('a whole-book download takes over a running chapter run; not the other way round', () async {
      final gate = Completer<void>();
      final manager = DownloadManager(api: _api({hashA: a, hashB: b, hashC: c}, gate: gate), targetDir: dir);
      final downloads = BookDownloads(manager: manager);
      final chapters = downloads.downloadChapters('book', sized, [hashA]);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final whole = downloads.download('book', sized);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(await downloads.downloadChapters('book', sized, [hashC]), ChapterRunResult.busy);
      gate.complete();
      expect(await chapters, ChapterRunResult.superseded);
      expect(await whole, isTrue);
      expect(downloads.stateFor('book').isDownloaded, isTrue);
    });
  });
}
