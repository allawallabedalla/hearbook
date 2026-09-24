import 'position.dart';

/// One file entry in a manifest, in playback order.
class ManifestFile {
  final int idx;
  final String fileHash;
  final int durationMs;

  const ManifestFile({
    required this.idx,
    required this.fileHash,
    required this.durationMs,
  });

  factory ManifestFile.fromJson(Map<String, dynamic> json) => ManifestFile(
        idx: json['idx'] as int,
        fileHash: json['file_hash'] as String,
        durationMs: json['duration_ms'] as int,
      );

  Map<String, dynamic> toJson() =>
      {'idx': idx, 'file_hash': fileHash, 'duration_ms': durationMs};
}

/// The active manifest of a book: an ordered list of files, per
/// docs/ARCHITEKTUR.md sections 2 and 3. Maps between a `Position`
/// (`file_hash` + `offset_ms`, invariant 1) and a single "global ms" axis
/// (the file's playback order concatenated), which the Resolver (section 7)
/// and Faden-Suche (section 8) use to compare and search positions.
class Manifest {
  final String manifestId;

  /// Files in playback order. `idx` is expected to be 0..n-1 in list order;
  /// this class trusts that order rather than re-sorting by `idx`.
  final List<ManifestFile> files;

  const Manifest({required this.manifestId, required this.files});

  factory Manifest.fromJson(Map<String, dynamic> json) => Manifest(
        manifestId: json['manifest_id'] as String,
        files: (json['files'] as List)
            .map((f) => ManifestFile.fromJson(f as Map<String, dynamic>))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'manifest_id': manifestId,
        'files': files.map((f) => f.toJson()).toList(),
      };

  int get totalDurationMs => files.fold(0, (sum, f) => sum + f.durationMs);

  bool containsFile(String fileHash) => files.any((f) => f.fileHash == fileHash);

  /// Global ms where `fileHash` starts, or null if it is not part of this
  /// manifest.
  int? fileStartMs(String fileHash) {
    var acc = 0;
    for (final f in files) {
      if (f.fileHash == fileHash) return acc;
      acc += f.durationMs;
    }
    return null;
  }

  /// Global ms for a position, or null if its `file_hash` is not part of
  /// this manifest (section 7 rule 8: that is a `needs_confirmation`
  /// signal for the Resolver, the position itself must stay untouched).
  int? globalMsFor(Position pos) {
    final start = fileStartMs(pos.fileHash);
    if (start == null) return null;
    return start + pos.offsetMs;
  }

  /// Maps a global ms value (clamped to `[0, totalDurationMs]`) back to a
  /// `Position`. Throws if the manifest has no files.
  Position positionForGlobalMs(int globalMs) {
    if (files.isEmpty) {
      throw StateError('cannot map a global ms offset in an empty manifest');
    }
    final clamped = globalMs < 0
        ? 0
        : (globalMs > totalDurationMs ? totalDurationMs : globalMs);
    var acc = 0;
    for (final f in files) {
      final end = acc + f.durationMs;
      if (clamped < end || identical(f, files.last)) {
        return Position(fileHash: f.fileHash, offsetMs: clamped - acc);
      }
      acc = end;
    }
    final last = files.last;
    return Position(fileHash: last.fileHash, offsetMs: last.durationMs);
  }
}
