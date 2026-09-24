import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/pause_index.dart';
import 'package:flutter_test/flutter_test.dart';

Manifest _manifest() => const Manifest(manifestId: 'm', files: [
      ManifestFile(idx: 0, fileHash: 'h0', durationMs: 10 * 60000), // 0-10 min
      ManifestFile(idx: 1, fileHash: 'h1', durationMs: 10 * 60000), // 10-20 min
    ]);

void main() {
  group('globalPauseOffsets', () {
    test('shifts each file\'s offsets by its global start', () {
      final result = globalPauseOffsets(_manifest(), {
        'h0': [0, 5000],
        'h1': [0, 3000],
      });
      expect(result, [0, 5000, 10 * 60000, 10 * 60000 + 3000]);
    });

    test('is sorted even if the input map is not', () {
      final result = globalPauseOffsets(_manifest(), {
        'h1': [3000],
        'h0': [5000],
      });
      expect(result, [5000, 10 * 60000 + 3000]);
    });

    test('ignores a file_hash not in the manifest', () {
      final result = globalPauseOffsets(_manifest(), {
        'h0': [0],
        'unknown-file': [1234],
      });
      expect(result, [0]);
    });

    test('empty map yields an empty list (search runs without snapping)', () {
      expect(globalPauseOffsets(_manifest(), {}), isEmpty);
    });
  });
}
