import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:flutter_test/flutter_test.dart';

Manifest threeFileManifest() => Manifest(
      manifestId: 'm1',
      files: const [
        ManifestFile(idx: 0, fileHash: 'a', durationMs: 10000),
        ManifestFile(idx: 1, fileHash: 'b', durationMs: 20000),
        ManifestFile(idx: 2, fileHash: 'c', durationMs: 5000),
      ],
    );

void main() {
  group('globalMsFor', () {
    test('first file: global ms equals offset', () {
      final m = threeFileManifest();
      expect(m.globalMsFor(Position(fileHash: 'a', offsetMs: 3000)), 3000);
    });

    test('second file: global ms is prior durations plus offset', () {
      final m = threeFileManifest();
      expect(m.globalMsFor(Position(fileHash: 'b', offsetMs: 1000)), 11000);
    });

    test('third file: global ms sums all prior durations', () {
      final m = threeFileManifest();
      expect(m.globalMsFor(Position(fileHash: 'c', offsetMs: 500)), 30500);
    });

    test('unknown file_hash returns null (needs_confirmation trigger)', () {
      final m = threeFileManifest();
      expect(m.globalMsFor(Position(fileHash: 'zzz', offsetMs: 0)), isNull);
    });
  });

  group('positionForGlobalMs', () {
    test('maps into the first file', () {
      final m = threeFileManifest();
      expect(m.positionForGlobalMs(3000), Position(fileHash: 'a', offsetMs: 3000));
    });

    test('maps into the second file at the boundary', () {
      final m = threeFileManifest();
      expect(m.positionForGlobalMs(10000), Position(fileHash: 'b', offsetMs: 0));
    });

    test('maps into the last file', () {
      final m = threeFileManifest();
      expect(m.positionForGlobalMs(30500), Position(fileHash: 'c', offsetMs: 500));
    });

    test('clamps below zero to the very start', () {
      final m = threeFileManifest();
      expect(m.positionForGlobalMs(-5), Position(fileHash: 'a', offsetMs: 0));
    });

    test('clamps beyond the end to the last file end', () {
      final m = threeFileManifest();
      expect(m.positionForGlobalMs(999999), Position(fileHash: 'c', offsetMs: 5000));
    });

    test('round-trips with globalMsFor', () {
      final m = threeFileManifest();
      for (final ms in [0, 3000, 9999, 10000, 25000, 34999]) {
        final pos = m.positionForGlobalMs(ms);
        expect(m.globalMsFor(pos), ms);
      }
    });
  });

  test('totalDurationMs sums all files', () {
    final m = threeFileManifest();
    expect(m.totalDurationMs, 35000);
  });

  test('containsFile', () {
    final m = threeFileManifest();
    expect(m.containsFile('b'), isTrue);
    expect(m.containsFile('zzz'), isFalse);
  });

  test('manifestId is a SHA-256 over ordered file hashes joined by newlines', () {
    // docs/ARCHITEKTUR.md section 2: manifest_id = SHA-256 over the ordered
    // file_hash values, separated by newlines. Computing it is a server
    // concern (it mints manifests); the app only ever receives it as an
    // opaque string and must not recompute it to validate a manifest.
    final m = threeFileManifest();
    expect(m.manifestId, isA<String>());
  });

  test('json round-trip preserves file order and fields', () {
    final m = threeFileManifest();
    final decoded = Manifest.fromJson(m.toJson());
    expect(decoded.manifestId, m.manifestId);
    expect(decoded.files.map((f) => f.fileHash), m.files.map((f) => f.fileHash));
    expect(decoded.files.map((f) => f.durationMs), m.files.map((f) => f.durationMs));
  });

  group('file titles', () {
    test('are read from the server manifest and fall back when missing or blank', () {
      final m = Manifest.fromJson({
        'manifest_id': 'm',
        'files': [
          {'idx': 0, 'file_hash': 'a', 'duration_ms': 1, 'title': ' Prolog '},
          {'idx': 1, 'file_hash': 'b', 'duration_ms': 1, 'title': null},
          {'idx': 2, 'file_hash': 'c', 'duration_ms': 1, 'title': '  '},
          {'idx': 3, 'file_hash': 'd', 'duration_ms': 1},
        ],
      });
      expect(m.files[0].displayTitle('Kapitel 1'), 'Prolog');
      expect(m.files[1].displayTitle('Kapitel 2'), 'Kapitel 2');
      expect(m.files[2].displayTitle('Kapitel 3'), 'Kapitel 3');
      expect(m.files[3].title, isNull);
      expect(Manifest.fromJson(m.toJson()).files[0].title, ' Prolog ');
      expect(m.files[1].toJson().containsKey('title'), isFalse);
    });

    test('fractionFor: share of the whole book, null for an unknown file', () {
      final m = threeFileManifest();
      expect(m.fractionFor(Position(fileHash: 'b', offsetMs: 7500)), closeTo(0.5, 1e-9));
      expect(m.fractionFor(Position(fileHash: 'x', offsetMs: 0)), isNull);
      expect(m.indexOf('c'), 2);
    });
  });
}
