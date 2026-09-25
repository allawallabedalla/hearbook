import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../domain/manifest.dart';
import 'downloads.dart';

enum BookDownloadStatus {
  /// Not checked yet, or no file of the book is on the device.
  none,

  /// Some, not all, files are on the device (e.g. after a cancel).
  partial,

  /// A download is running.
  downloading,

  /// Every file of the active manifest is on the device and verified.
  done,

  /// The last download failed; [BookDownloadState.error] says why. Stays
  /// until the next [BookDownloads.download]/retry or delete.
  failed,
}

/// Download state of one book, for the library and the player.
class BookDownloadState {
  final BookDownloadStatus status;
  final int filesDone;
  final int filesTotal;

  /// Bytes received by the running download so far (0 otherwise).
  final int receivedBytes;

  /// 0..1 while downloading: completed files plus the running file's byte
  /// progress, weighted by duration.
  final double fraction;

  /// Bytes this book's completed files take on disk.
  final int bytesOnDisk;

  /// Why the last download failed (not meant for display as is).
  final String? error;

  /// While downloading: an estimate of the bytes still to fetch
  /// ([estimateRemainingBytes], decision E62); null before there is a
  /// basis for it (no file size known yet) and when not downloading.
  final int? remainingBytes;

  const BookDownloadState({
    required this.status,
    this.filesDone = 0,
    this.filesTotal = 0,
    this.receivedBytes = 0,
    this.fraction = 0,
    this.bytesOnDisk = 0,
    this.error,
    this.remainingBytes,
  });

  static const unknown = BookDownloadState(status: BookDownloadStatus.none);

  bool get isDownloaded => status == BookDownloadStatus.done;
  bool get isDownloading => status == BookDownloadStatus.downloading;
  bool get hasFailed => status == BookDownloadStatus.failed;
}

/// Bytes still to download for a book (decision E62). When the sizes of
/// all files still to come are known from the manifest (`size_bytes`,
/// decision E66), [laterBytes] is their sum and the result is exact: the
/// running file's rest ([currentSize] minus [currentBytes]; at the known
/// rate while its size is unknown) plus [laterBytes]. Otherwise the rest is extrapolated from the sizes known so
/// far -- the completed files ([doneBytes] over [doneMs]) plus the running
/// file once its size ([currentSize], 0 if unknown) is known -- over the
/// duration still missing ([totalMs]). Null while nothing gives a byte
/// rate yet. Pure, so it is unit-tested on its own.
int? estimateRemainingBytes({
  required int doneBytes,
  required int doneMs,
  required int totalMs,
  int currentBytes = 0,
  int currentSize = 0,
  int currentMs = 0,
  int? laterBytes,
}) {
  final sizeKnown = currentSize > 0;
  if (laterBytes != null) {
    final double? currentRest = sizeKnown
        ? (currentSize - currentBytes).toDouble()
        : currentMs == 0
            ? 0
            : (doneBytes > 0 && doneMs > 0)
                ? currentMs * doneBytes / doneMs - currentBytes
                : null;
    if (currentRest != null) return (currentRest < 0 ? 0 : currentRest).round() + laterBytes;
  }
  final rateBytes = doneBytes + (sizeKnown ? currentSize : 0);
  final rateMs = doneMs + (sizeKnown ? currentMs : 0);
  if (rateBytes <= 0 || rateMs <= 0) return null;
  final bytesPerMs = rateBytes / rateMs;
  final currentRest = sizeKnown ? currentSize - currentBytes : currentMs * bytesPerMs - currentBytes;
  final laterMs = totalMs - doneMs - currentMs;
  final rest = (currentRest < 0 ? 0 : currentRest) + (laterMs < 0 ? 0 : laterMs) * bytesPerMs;
  return rest.round();
}

/// Sum of the manifest sizes of [files], or null when any is unknown.
int? knownSizeOf(Iterable<ManifestFile> files) {
  var sum = 0;
  for (final f in files) {
    final size = f.sizeBytes;
    if (size == null || size < 0) return null;
    sum += size;
  }
  return sum;
}

/// How a [BookDownloads.downloadChapters] run ended.
enum ChapterRunResult {
  /// Every requested file still wanted is on the device.
  done,

  /// Stopped through [BookDownloads.cancel] (the library's stop button).
  cancelled,

  /// A whole-book download of the same book took over.
  superseded,

  /// A whole-book download of this book is running; nothing was started.
  busy,

  /// A file failed (network gone, hash mismatch). Not shown as a failure.
  failed,
}

/// A file of [bookId] that finished downloading and is verified.
typedef DownloadedFile = ({String bookId, String fileHash});

/// Whole-book downloads (decision E34/E35): byte-level progress, cancel,
/// retry, delete and storage per book, and a failure state that stays
/// visible. Files are verified once on completion (data/downloads.dart).
class BookDownloads extends ChangeNotifier {
  final DownloadManager manager;

  /// Minimum time between two progress notifications while a file
  /// downloads (dio reports progress per received chunk).
  final Duration progressInterval;

  final Map<String, BookDownloadState> _states = {};
  final Map<String, CancelToken> _running = {};
  final Map<String, Future<void>> _runs = {};

  /// Books whose running download is a chapter run (decision E66).
  final Set<String> _chapterRuns = {};
  final Set<String> _superseded = {};
  final StreamController<DownloadedFile> _fileDownloaded = StreamController<DownloadedFile>.broadcast();
  bool _disposed = false;

  BookDownloads({required this.manager, this.progressInterval = const Duration(milliseconds: 250)});

  BookDownloadState stateFor(String bookId) => _states[bookId] ?? BookDownloadState.unknown;

  Map<String, BookDownloadState> get states => Map.unmodifiable(_states);

  /// Emits every file that finished downloading (verified), so the player
  /// can switch that chapter from the stream to the file (decision E66).
  Stream<DownloadedFile> get fileDownloaded => _fileDownloaded.stream;

  /// Whether [bookId]'s running download fetches single chapters over
  /// mobile data (decision E66) rather than the whole book.
  bool isChapterRun(String bookId) => _chapterRuns.contains(bookId);

  /// Re-checks which of [manifest]'s files are on the device (cheap: marker
  /// + size, no hashing). Leaves a running download or a failure alone.
  Future<BookDownloadState> refresh(String bookId, Manifest manifest) async {
    final current = stateFor(bookId);
    if (current.isDownloading || current.hasFailed) return current;
    final next = await _scan(manifest);
    if (stateFor(bookId).isDownloading) return stateFor(bookId);
    _set(bookId, next);
    return next;
  }

  Future<BookDownloadState> _scan(Manifest manifest, {String? error}) async {
    final local = await _local(manifest);
    final done = local.hashes.length;
    final total = manifest.files.length;
    final status = error != null
        ? BookDownloadStatus.failed
        : (total > 0 && done == total)
            ? BookDownloadStatus.done
            : (done > 0 ? BookDownloadStatus.partial : BookDownloadStatus.none);
    return BookDownloadState(
      status: status,
      filesDone: done,
      filesTotal: total,
      bytesOnDisk: local.bytes,
      error: error,
    );
  }

  /// The files of [manifest] on the device, their bytes and duration.
  Future<({Set<String> hashes, int bytes, int ms})> _local(Manifest manifest) async {
    final hashes = <String>{};
    var bytes = 0;
    var ms = 0;
    for (final file in manifest.files) {
      if (await manager.isDownloaded(file.fileHash)) {
        hashes.add(file.fileHash);
        bytes += await manager.bytesOnDisk(file.fileHash);
        ms += file.durationMs;
      }
    }
    return (hashes: hashes, bytes: bytes, ms: ms);
  }

  /// Downloads every missing file of [manifest], one after another. Returns
  /// true once the whole book is on the device. A cancel returns false
  /// without a failure state; any other problem leaves
  /// [BookDownloadStatus.failed]. Calling it again retries (already
  /// verified files are skipped). A running chapter run of the same book
  /// (decision E66) is stopped first and this takes over.
  Future<bool> download(String bookId, Manifest manifest) async {
    if (_chapterRuns.contains(bookId)) {
      _superseded.add(bookId);
      _running[bookId]?.cancel();
      await _runs[bookId];
    }
    if (_running.containsKey(bookId)) return false;
    final result = await _start(bookId, manifest, manifest.files, chapters: false);
    return result == ChapterRunResult.done && stateFor(bookId).isDownloaded;
  }

  /// Decision E66: downloads just the files [fileHashes] of [manifest] (the
  /// current and the next chapter over mobile data), shown like any other
  /// download. Before each file, [stillWanted] may drop it (playback moved
  /// on). A failure is not kept as [BookDownloadStatus.failed] -- losing
  /// the mobile network is normal, and the next trigger simply tries again.
  Future<ChapterRunResult> downloadChapters(
    String bookId,
    Manifest manifest,
    List<String> fileHashes, {
    bool Function(String fileHash)? stillWanted,
  }) async {
    if (_running.containsKey(bookId)) return ChapterRunResult.busy;
    final wanted = fileHashes.toSet();
    final files = [for (final f in manifest.files) if (wanted.contains(f.fileHash)) f];
    return _start(bookId, manifest, files, chapters: true, stillWanted: stillWanted);
  }

  Future<ChapterRunResult> _start(
    String bookId,
    Manifest manifest,
    List<ManifestFile> files, {
    required bool chapters,
    bool Function(String fileHash)? stillWanted,
  }) {
    final token = CancelToken();
    _running[bookId] = token;
    if (chapters) _chapterRuns.add(bookId);
    final run = _run(bookId, manifest, files, token, chapters: chapters, stillWanted: stillWanted).whenComplete(() {
      _running.remove(bookId);
      _runs.remove(bookId);
      _chapterRuns.remove(bookId);
      _superseded.remove(bookId);
    });
    _runs[bookId] = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<ChapterRunResult> _run(
    String bookId,
    Manifest manifest,
    List<ManifestFile> files,
    CancelToken token, {
    required bool chapters,
    bool Function(String fileHash)? stillWanted,
  }) async {
    final filesTotal = manifest.files.length;
    String? currentHash;
    _set(
      bookId,
      BookDownloadState(
        status: BookDownloadStatus.downloading,
        filesDone: stateFor(bookId).filesDone,
        filesTotal: filesTotal,
        bytesOnDisk: stateFor(bookId).bytesOnDisk,
      ),
    );
    ChapterRunResult ended(ChapterRunResult cancelled) =>
        _superseded.contains(bookId) ? ChapterRunResult.superseded : cancelled;
    try {
      // What is on the device already: the rate basis for the estimate
      // (E62) and what is skipped.
      final local = await _local(manifest);
      final missing = [for (final f in files) if (!local.hashes.contains(f.fileHash)) f];
      final totalMs = local.ms + missing.fold<int>(0, (sum, f) => sum + f.durationMs);
      var doneMs = local.ms;
      var filesDone = local.hashes.length;
      var bytes = local.bytes;
      var received = 0;
      var laterBytes = knownSizeOf(missing);
      _set(
        bookId,
        BookDownloadState(
          status: BookDownloadStatus.downloading,
          filesDone: filesDone,
          filesTotal: filesTotal,
          bytesOnDisk: bytes,
          remainingBytes: estimateRemainingBytes(
            doneBytes: bytes,
            doneMs: doneMs,
            totalMs: totalMs,
            laterBytes: laterBytes,
          ),
        ),
      );
      for (var i = 0; i < missing.length; i++) {
        if (token.isCancelled) break;
        final file = missing[i];
        if (stillWanted != null && !stillWanted(file.fileHash)) continue;
        currentHash = file.fileHash;
        final lastNotify = Stopwatch()..start();
        final receivedBefore = received;
        final later = knownSizeOf(missing.skip(i + 1));
        final result = await manager.download(
          file.fileHash,
          cancelToken: token,
          onProgress: (got, total) {
            received = receivedBefore + got;
            if (lastNotify.elapsed < progressInterval) return;
            lastNotify.reset();
            final part = total > 0 ? (got / total).clamp(0.0, 1.0) : 0.0;
            _set(
              bookId,
              BookDownloadState(
                status: BookDownloadStatus.downloading,
                filesDone: filesDone,
                filesTotal: filesTotal,
                receivedBytes: received,
                fraction: totalMs <= 0 ? 0 : (doneMs + file.durationMs * part) / totalMs,
                bytesOnDisk: bytes,
                remainingBytes: estimateRemainingBytes(
                  doneBytes: bytes,
                  doneMs: doneMs,
                  totalMs: totalMs,
                  currentBytes: got,
                  currentSize: total > 0 ? total : (file.sizeBytes ?? 0),
                  currentMs: file.durationMs,
                  laterBytes: later,
                ),
              ),
            );
          },
        );
        currentHash = null;
        if (!result.ok) {
          _set(bookId, await _scan(manifest, error: chapters ? null : (result.error ?? 'download failed')));
          return ChapterRunResult.failed;
        }
        filesDone++;
        doneMs += file.durationMs;
        bytes += await manager.bytesOnDisk(file.fileHash);
        if (!_fileDownloaded.isClosed) _fileDownloaded.add((bookId: bookId, fileHash: file.fileHash));
        laterBytes = later;
        _set(
          bookId,
          BookDownloadState(
            status: BookDownloadStatus.downloading,
            filesDone: filesDone,
            filesTotal: filesTotal,
            receivedBytes: received,
            fraction: totalMs <= 0 ? 0 : doneMs / totalMs,
            bytesOnDisk: bytes,
            remainingBytes: estimateRemainingBytes(
              doneBytes: bytes,
              doneMs: doneMs,
              totalMs: totalMs,
              laterBytes: laterBytes,
            ),
          ),
        );
      }
      _set(bookId, await _scan(manifest));
      return token.isCancelled ? ended(ChapterRunResult.cancelled) : ChapterRunResult.done;
    } on DioException catch (e) {
      if (currentHash != null) await manager.deletePartial(currentHash);
      final cancelled = CancelToken.isCancel(e);
      _set(
        bookId,
        cancelled || chapters ? await _scan(manifest) : await _scan(manifest, error: e.message ?? e.type.name),
      );
      return cancelled ? ended(ChapterRunResult.cancelled) : ChapterRunResult.failed;
    } catch (e) {
      if (currentHash != null) await manager.deletePartial(currentHash);
      _set(bookId, await _scan(manifest, error: chapters ? null : e.toString()));
      return ChapterRunResult.failed;
    }
  }

  /// Same as [download]; named for the UI's "Erneut versuchen".
  Future<bool> retry(String bookId, Manifest manifest) => download(bookId, manifest);

  /// Stops a running download of [bookId]; already completed files stay.
  void cancel(String bookId) => _running[bookId]?.cancel();

  /// Cancels a running download and removes every downloaded file of
  /// [manifest]. The book then streams again (if the server is reachable).
  Future<void> deleteBook(String bookId, Manifest manifest) async {
    final token = _running[bookId];
    token?.cancel();
    for (final file in manifest.files) {
      await manager.delete(file.fileHash);
    }
    _set(bookId, BookDownloadState(status: BookDownloadStatus.none, filesTotal: manifest.files.length));
  }

  /// Bytes all downloaded audio takes on this device.
  Future<int> totalBytesOnDisk() => manager.totalBytesOnDisk();

  void _set(String bookId, BookDownloadState state) {
    if (_disposed) return;
    _states[bookId] = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_fileDownloaded.close());
    for (final token in _running.values) {
      token.cancel();
    }
    super.dispose();
  }
}
