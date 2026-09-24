import 'package:faden/audio/undo_hint.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:flutter_test/flutter_test.dart';

Manifest _manifest() => const Manifest(manifestId: 'm', files: [
      ManifestFile(idx: 0, fileHash: 'h0', durationMs: 20 * 60000),
      ManifestFile(idx: 1, fileHash: 'h1', durationMs: 20 * 60000),
      ManifestFile(idx: 2, fileHash: 'h2', durationMs: 20 * 60000),
    ]);

void main() {
  test('isUndoWorthyJump is exclusive at exactly 2 minutes', () {
    expect(isUndoWorthyJump(0, 2 * 60000), isFalse);
    expect(isUndoWorthyJump(0, 2 * 60000 + 1), isTrue);
    expect(isUndoWorthyJump(2 * 60000 + 1, 0), isTrue); // symmetric
  });

  test('no hint for a jump of 2 minutes or less', () {
    final manifest = _manifest();
    final hint = undoHintForJump(
      from: const Position(fileHash: 'h0', offsetMs: 0),
      fromGlobalMs: 0,
      toGlobalMs: 60000,
      manifest: manifest,
    );
    expect(hint, isNull);
  });

  test('formats the KONZEPT.md pattern for a forward jump over 2 min', () {
    final manifest = _manifest();
    // Jump away from chapter 7's... well this fixture only has 3 chapters,
    // so use chapter 2 (idx 1) at 23:41 to mirror the concept text pattern
    // with the fixture's own numbering.
    final from = const Position(fileHash: 'h1', offsetMs: (23 * 60 + 41) * 1000);
    final hint = undoHintForJump(
      from: from,
      fromGlobalMs: 20 * 60000 + (23 * 60 + 41) * 1000,
      toGlobalMs: 50 * 60000,
      manifest: manifest,
    );
    expect(hint, isNotNull);
    expect(hint!.target, from);
    expect(hint.message, 'Zurück zu Kapitel 2, 23:41');
  });

  test('seconds are zero-padded', () {
    final manifest = _manifest();
    final from = const Position(fileHash: 'h0', offsetMs: 5000); // 0:05
    final hint = undoHintForJump(
      from: from,
      fromGlobalMs: 5000,
      toGlobalMs: 10 * 60000,
      manifest: manifest,
    );
    expect(hint!.message, 'Zurück zu Kapitel 1, 0:05');
  });

  test('null when the position is not part of the manifest (needs_confirmation case)', () {
    final manifest = _manifest();
    final hint = undoHintForJump(
      from: const Position(fileHash: 'unknown', offsetMs: 0),
      fromGlobalMs: 0,
      toGlobalMs: 10 * 60000,
      manifest: manifest,
    );
    expect(hint, isNull);
  });
}
