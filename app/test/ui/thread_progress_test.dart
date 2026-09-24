import 'package:faden/domain/manifest.dart';
import 'package:faden/ui/theme.dart';
import 'package:faden/ui/thread_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Manifest _manifest() => const Manifest(manifestId: 'm', files: [
      ManifestFile(idx: 0, fileHash: 'h0', durationMs: 10 * 60000), // 0-10 min
      ManifestFile(idx: 1, fileHash: 'h1', durationMs: 10 * 60000), // 10-20 min
      ManifestFile(idx: 2, fileHash: 'h2', durationMs: 20 * 60000), // 20-40 min
    ]);

void main() {
  group('computeThreadLayout', () {
    test('heardFraction at the very start is 0', () {
      final layout = computeThreadLayout(manifest: _manifest(), globalMs: 0);
      expect(layout.heardFraction, 0);
    });

    test('heardFraction at the very end is 1', () {
      final manifest = _manifest();
      final layout = computeThreadLayout(manifest: manifest, globalMs: manifest.totalDurationMs);
      expect(layout.heardFraction, 1);
    });

    test('heardFraction mid-book', () {
      final layout = computeThreadLayout(manifest: _manifest(), globalMs: 10 * 60000);
      expect(layout.heardFraction, closeTo(0.25, 0.0001)); // 10 of 40 min
    });

    test('chapter boundaries are between chapters, not at 0 or 1', () {
      final layout = computeThreadLayout(manifest: _manifest(), globalMs: 0);
      expect(layout.chapterBoundaryFractions.length, 2); // 3 chapters -> 2 boundaries
      expect(layout.chapterBoundaryFractions[0], closeTo(0.25, 0.0001)); // 10/40
      expect(layout.chapterBoundaryFractions[1], closeTo(0.5, 0.0001)); // 20/40
      for (final f in layout.chapterBoundaryFractions) {
        expect(f, greaterThan(0));
        expect(f, lessThan(1));
      }
    });

    test('a globalMs beyond the total is clamped to 1', () {
      final manifest = _manifest();
      final layout =
          computeThreadLayout(manifest: manifest, globalMs: manifest.totalDurationMs + 60000);
      expect(layout.heardFraction, 1);
    });

    test('empty manifest yields the empty layout', () {
      final layout = computeThreadLayout(
        manifest: const Manifest(manifestId: 'm', files: []),
        globalMs: 0,
      );
      expect(layout.heardFraction, 0);
      expect(layout.chapterBoundaryFractions, isEmpty);
    });
  });

  testWidgets('ThreadProgress renders without a gesture detector (not draggable)', (tester) async {
    final layout = computeThreadLayout(manifest: _manifest(), globalMs: 5 * 60000);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ThreadProgress(layout: layout, tokens: FadenTokens.day),
        ),
      ),
    );
    expect(find.byType(ThreadProgress), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    // KONZEPT.md: the thread replaces the scrubber and is explicitly not
    // draggable -- it must not carry its own gesture/drag detector.
    expect(
      find.descendant(of: find.byType(ThreadProgress), matching: find.byType(GestureDetector)),
      findsNothing,
    );
  });
}
