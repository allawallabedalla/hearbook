import 'manifest.dart';

/// Converts the server's per-file pause index (docs/ARCHITEKTUR.md section
/// 4: `GET /api/v1/books/{id}/pauses`, `{file_hash: [offsets_ms, ...]}`)
/// into one manifest-global list of ms offsets -- the `pausen` parameter
/// domain/faden_search.dart's `fadenSuche`/`snap` expect, since `lo`, `hi`
/// and every probe position they work with already live on that same
/// global-ms axis (docs/ARCHITEKTUR.md section 8).
///
/// A `file_hash` from [perFileOffsetsMs] that is not part of [manifest] is
/// skipped rather than erroring (mirrors how a missing `file_hash` is
/// otherwise handled, e.g. domain/resolver.dart rule 8): its offsets simply
/// never become snap candidates. The result is sorted and may contain
/// duplicates if the server ever repeats an offset; `snap()` only cares
/// about the closest candidate, so that is harmless.
List<int> globalPauseOffsets(Manifest manifest, Map<String, List<int>> perFileOffsetsMs) {
  final result = <int>[];
  for (final file in manifest.files) {
    final offsets = perFileOffsetsMs[file.fileHash];
    if (offsets == null) continue;
    final start = manifest.fileStartMs(file.fileHash);
    if (start == null) continue;
    for (final offset in offsets) {
      result.add(start + offset);
    }
  }
  result.sort();
  return result;
}
