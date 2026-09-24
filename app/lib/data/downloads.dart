import 'dart:io';

import 'package:dio/dio.dart' show CancelToken;

import 'api.dart';
import 'hash_file.dart';

class DownloadResult {
  final bool ok;
  final String? error;

  const DownloadResult._(this.ok, this.error);

  const DownloadResult.success() : this._(true, null);

  const DownloadResult.failure(String error) : this._(false, error);
}

/// Downloads audio files and verifies them against `file_hash`.
///
/// docs/ARCHITEKTUR.md section 11: "Ein Download gilt erst als fertig,
/// wenn der Audio-Hash der Datei stimmt." -- the file is downloaded to a
/// `.part` path first; only once its hash (data/hash_file.dart, agreeing
/// bit-for-bit with the server's algorithm) matches the expected
/// `file_hash` is it moved into place. A mismatch deletes the partial file
/// so a retry starts clean rather than ever serving corrupt audio.
///
/// Decision E34: the hash is verified exactly once, when the download
/// completes; a `<file_hash>.ok` marker next to the file then records its
/// verified size, and [isDownloaded] trusts marker + size instead of
/// re-hashing the whole file on every book open and library refresh.
/// Files without a marker (downloaded before E34) are verified once, lazily,
/// and get their marker then.
class DownloadManager {
  /// Null while no server is configured: already downloaded files still
  /// play, only [download] is unavailable.
  final ApiClient? api;
  final Directory targetDir;

  DownloadManager({required this.api, required this.targetDir});

  /// Where a completed download for [fileHash] lives (or will live).
  File pathFor(String fileHash) => File(_join(targetDir.path, '$fileHash.mp3'));

  File _markerFor(String fileHash) => File(_join(targetDir.path, '$fileHash.ok'));

  File _partialFor(String fileHash) => File('${pathFor(fileHash).path}.part');

  Future<DownloadResult> download(
    String fileHash, {
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final client = api;
    if (client == null) return const DownloadResult.failure('no server configured');
    await targetDir.create(recursive: true);
    final dest = pathFor(fileHash);
    final partial = _partialFor(fileHash);

    await client.downloadFile(fileHash, partial, onProgress: onProgress, cancelToken: cancelToken);

    final actualHash = await hashFile(partial);
    if (actualHash != fileHash) {
      if (await partial.exists()) await partial.delete();
      return DownloadResult.failure('hash mismatch: expected $fileHash, got $actualHash');
    }

    await partial.rename(dest.path);
    await _writeMarker(fileHash, await dest.length());
    return const DownloadResult.success();
  }

  /// Whether [fileHash] is downloaded and verified: the file exists and its
  /// size matches the marker written when its hash was verified. A file
  /// without a marker is hashed once (and marked if it matches); a size
  /// mismatch (local corruption, a hand-edited file) counts as "not
  /// downloaded" so the caller re-downloads rather than trusting it.
  Future<bool> isDownloaded(String fileHash) async {
    final file = pathFor(fileHash);
    if (!await file.exists()) return false;
    final size = await file.length();
    final marker = _markerFor(fileHash);
    if (await marker.exists()) {
      final recorded = int.tryParse((await marker.readAsString()).trim());
      if (recorded == size) return true;
      await _tryDelete(marker);
      return false;
    }
    if (await hashFile(file) != fileHash) return false;
    await _writeMarker(fileHash, size);
    return true;
  }

  /// Bytes [fileHash] takes on disk (0 when not downloaded).
  Future<int> bytesOnDisk(String fileHash) async {
    final file = pathFor(fileHash);
    return await file.exists() ? await file.length() : 0;
  }

  /// Removes [fileHash]'s download, its marker and any partial file.
  Future<void> delete(String fileHash) async {
    await _tryDelete(pathFor(fileHash));
    await _tryDelete(_markerFor(fileHash));
    await _tryDelete(_partialFor(fileHash));
  }

  /// Removes a leftover partial file (after a cancel or failure).
  Future<void> deletePartial(String fileHash) => _tryDelete(_partialFor(fileHash));

  /// Bytes all downloaded audio takes on disk (completed files only).
  Future<int> totalBytesOnDisk() async {
    if (!await targetDir.exists()) return 0;
    var total = 0;
    await for (final entity in targetDir.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.mp3')) total += await entity.length();
    }
    return total;
  }

  Future<void> _writeMarker(String fileHash, int size) async {
    final marker = _markerFor(fileHash);
    final tmp = File('${marker.path}.tmp');
    await tmp.writeAsString('$size', flush: true);
    await tmp.rename(marker.path);
  }
}

Future<void> _tryDelete(File f) async {
  try {
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

String _join(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';
