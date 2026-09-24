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
  /// progress, weighted by duration (the manifest has no file sizes).
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

/// Bytes still to download for a book (decision E62). The manifest has
/// durations but no file sizes, so the rest is extrapolated from the sizes
/// known so far -- the completed files ([doneBytes] over [doneMs]) plus the
/// running file once its size ([currentSize], 0 if the server sent none) is
/// known -- over the duration still missing ([totalMs]). The running
/// file's own rest is exact when its size is known. Null while nothing
/// gives a byte rate yet. Pure, so it is unit-tested on its own.
int? estimateRemainingBytes({
  required int doneBytes,
  required int doneMs,
  required int totalMs,
  int currentBytes = 0,
  int currentSize = 0,
  int currentMs = 0,
}) {
  final sizeKnown = currentSize > 0;
  final rateBytes = doneBytes + (sizeKnown ? currentSize : 0);
  final rateMs = doneMs + (sizeKnown ? currentMs : 0);
  if (rateBytes <= 0 || rateMs <= 0) return null;
  final bytesPerMs = rateBytes / rateMs;
  final currentRest = sizeKnown ? currentSize - currentBytes : currentMs * bytesPerMs - currentBytes;
  final laterMs = totalMs - doneMs - currentMs;
  final rest = (currentRest < 0 ? 0 : currentRest) + (laterMs < 0 ? 0 : laterMs) * bytesPerMs;
  return rest.round();
}

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
  bool _disposed = false;

  BookDownloads({required this.manager, this.progressInterval = const Duration(milliseconds: 250)});

  BookDownloadState stateFor(String bookId) => _states[bookId] ?? BookDownloadState.unknown;

  Map<String, BookDownloadState> get states => Map.unmodifiable(_states);

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
    var done = 0;
    var bytes = 0;
    for (final file in manifest.files) {
      if (await manager.isDownloaded(file.fileHash)) {
        done++;
        bytes += await manager.bytesOnDisk(file.fileHash);
      }
    }
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
      bytesOnDisk: bytes,
      error: error,
    );
  }

  /// Downloads every missing file of [manifest], one after another. Returns
  /// true once the whole book is on the device. A cancel returns false
  /// without a failure state; any other problem leaves
  /// [BookDownloadStatus.failed]. Calling it again retries (already
  /// verified files are skipped).
  Future<bool> download(String bookId, Manifest manifest) async {
    if (_running.containsKey(bookId)) return false;
    final token = CancelToken();
    _running[bookId] = token;
    final totalMs = manifest.totalDurationMs;
    var doneMs = 0;
    var filesDone = 0;
    var bytes = 0;
    var received = 0;
    String? currentHash;
    _set(
      bookId,
      BookDownloadState(
        status: BookDownloadStatus.downloading,
        filesTotal: manifest.files.length,
      ),
    );
    try {
      for (final file in manifest.files) {
        if (token.isCancelled) break;
        if (await manager.isDownloaded(file.fileHash)) {
          filesDone++;
          doneMs += file.durationMs;
          bytes += await manager.bytesOnDisk(file.fileHash);
          continue;
        }
        currentHash = file.fileHash;
        final lastNotify = Stopwatch()..start();
        final receivedBefore = received;
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
                filesTotal: manifest.files.length,
                receivedBytes: received,
                fraction: totalMs <= 0 ? 0 : (doneMs + file.durationMs * part) / totalMs,
                bytesOnDisk: bytes,
                remainingBytes: estimateRemainingBytes(
                  doneBytes: bytes,
                  doneMs: doneMs,
                  totalMs: totalMs,
                  currentBytes: got,
                  currentSize: total,
                  currentMs: file.durationMs,
                ),
              ),
            );
          },
        );
        currentHash = null;
        if (!result.ok) {
          _set(bookId, await _scan(manifest, error: result.error ?? 'download failed'));
          return false;
        }
        filesDone++;
        doneMs += file.durationMs;
        bytes += await manager.bytesOnDisk(file.fileHash);
        _set(
          bookId,
          BookDownloadState(
            status: BookDownloadStatus.downloading,
            filesDone: filesDone,
            filesTotal: manifest.files.length,
            receivedBytes: received,
            fraction: totalMs <= 0 ? 0 : doneMs / totalMs,
            bytesOnDisk: bytes,
            remainingBytes: estimateRemainingBytes(doneBytes: bytes, doneMs: doneMs, totalMs: totalMs),
          ),
        );
      }
      if (token.isCancelled) {
        _set(bookId, await _scan(manifest));
        return false;
      }
      final finalState = await _scan(manifest);
      _set(bookId, finalState);
      return finalState.isDownloaded;
    } on DioException catch (e) {
      if (currentHash != null) await manager.deletePartial(currentHash);
      _set(
        bookId,
        CancelToken.isCancel(e) ? await _scan(manifest) : await _scan(manifest, error: e.message ?? e.type.name),
      );
      return false;
    } catch (e) {
      if (currentHash != null) await manager.deletePartial(currentHash);
      _set(bookId, await _scan(manifest, error: e.toString()));
      return false;
    } finally {
      _running.remove(bookId);
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
    for (final token in _running.values) {
      token.cancel();
    }
    super.dispose();
  }
}
