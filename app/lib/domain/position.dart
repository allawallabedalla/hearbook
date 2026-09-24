/// A position in a book. Invariant 1 (CLAUDE.md): a position is always
/// `(file_hash, offset_ms)`, never a filename, path or track index.
class Position {
  final String fileHash;
  final int offsetMs;

  const Position({required this.fileHash, required this.offsetMs});

  factory Position.fromJson(Map<String, dynamic> json) => Position(
        fileHash: json['file_hash'] as String,
        offsetMs: json['offset_ms'] as int,
      );

  Map<String, dynamic> toJson() => {'file_hash': fileHash, 'offset_ms': offsetMs};

  @override
  bool operator ==(Object other) =>
      other is Position && fileHash == other.fileHash && offsetMs == other.offsetMs;

  @override
  int get hashCode => Object.hash(fileHash, offsetMs);

  @override
  String toString() => 'Position(fileHash: $fileHash, offsetMs: $offsetMs)';
}
