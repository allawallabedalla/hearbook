import 'dart:io';

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
class DownloadManager {
  final ApiClient api;
  final Directory targetDir;

  DownloadManager({required this.api, required this.targetDir});

  /// Where a completed download for [fileHash] lives (or will live).
  File pathFor(String fileHash) => File(_join(targetDir.path, '$fileHash.mp3'));

  Future<DownloadResult> download(
    String fileHash, {
    void Function(int received, int total)? onProgress,
  }) async {
    await targetDir.create(recursive: true);
    final dest = pathFor(fileHash);
    final partial = File('${dest.path}.part');

    await api.downloadFile(fileHash, partial, onProgress: onProgress);

    final actualHash = await hashFile(partial);
    if (actualHash != fileHash) {
      if (await partial.exists()) await partial.delete();
      return DownloadResult.failure('hash mismatch: expected $fileHash, got $actualHash');
    }

    await partial.rename(dest.path);
    return const DownloadResult.success();
  }

  /// Whether [fileHash] is already downloaded with a matching hash. A
  /// mismatch (local corruption, a hand-edited file) counts as "not
  /// downloaded" so the caller re-downloads rather than trusting it.
  Future<bool> isDownloaded(String fileHash) async {
    final file = pathFor(fileHash);
    if (!await file.exists()) return false;
    return await hashFile(file) == fileHash;
  }
}

String _join(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';
