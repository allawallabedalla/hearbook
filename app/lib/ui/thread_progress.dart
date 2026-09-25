import 'package:flutter/material.dart';

import '../domain/manifest.dart';
import 'theme.dart';

/// The pure geometry behind the "Faden" (thread) progress indicator,
/// docs/KONZEPT.md "Design": "3 dp Linie über die volle Breite. Gehörter
/// Teil in faden, Rest in tinte-leise mit 40 % Deckkraft, Position als
/// 10 dp Knoten. Kapitelgrenzen sind 2 dp Lücken im Faden." Kept separate
/// from the painting code below so the fractions can be unit-tested
/// without spinning up a widget.
class ThreadLayout {
  /// Fraction (0..1) of the book heard so far -- also where the node sits.
  final double heardFraction;

  /// Fractions (0..1), strictly between chapters, where a 2dp gap is cut
  /// into the thread. Never includes 0.0 or 1.0 (the book's own start and
  /// end are not "boundaries").
  final List<double> chapterBoundaryFractions;

  const ThreadLayout({required this.heardFraction, required this.chapterBoundaryFractions});

  static const empty = ThreadLayout(heardFraction: 0, chapterBoundaryFractions: []);
}

/// Computes [ThreadLayout] for [manifest] at [globalMs]. Pure: no Flutter
/// dependency, so it is tested directly (test/ui/thread_progress_test.dart)
/// without pumping a widget.
ThreadLayout computeThreadLayout({required Manifest manifest, required int globalMs}) {
  final total = manifest.totalDurationMs;
  if (total <= 0 || manifest.files.isEmpty) return ThreadLayout.empty;
  final heard = (globalMs / total).clamp(0.0, 1.0);
  final boundaries = <double>[];
  var acc = 0;
  for (final file in manifest.files.take(manifest.files.length - 1)) {
    acc += file.durationMs;
    boundaries.add((acc / total).clamp(0.0, 1.0));
  }
  return ThreadLayout(heardFraction: heard, chapterBoundaryFractions: boundaries);
}

/// The "Faden" widget itself: a full-width, fixed-height progress
/// indicator that is deliberately *not* draggable (docs/KONZEPT.md
/// "Start ist der Player": "der Faden als Buchfortschritt (nicht
/// ziehbar)") -- unlike a scrubber it carries no `GestureDetector`.
/// Chapter boundaries (px) that get a visible gap: only where the chapters
/// on both sides are at least [minSegment] wide, so a book with many short
/// chapters stays one line instead of a dotted one.
List<double> visibleChapterGaps(List<double> boundariesPx, {required double width, double minSegment = 12}) {
  final sorted = [...boundariesPx]..sort();
  final kept = <double>[];
  var last = 0.0;
  for (var i = 0; i < sorted.length; i++) {
    final b = sorted[i];
    final next = i + 1 < sorted.length ? sorted[i + 1] : width;
    if (b - last >= minSegment && next - b >= minSegment && width - b >= minSegment) {
      kept.add(b);
      last = b;
    }
  }
  return kept;
}

/// The position is a small knot in the thread's own colour, not a round
/// thumb in `knoten` (decision E65): on the player the chapter scrubber
/// right below has the draggable thumb, and two alike handles read as two
/// sliders. The knot only marks where the heard part ends.
class ThreadProgress extends StatelessWidget {
  final ThreadLayout layout;
  final FadenTokens tokens;

  static const double lineThickness = 3;
  static const double nodeDiameter = 6;
  static const double gapWidth = 2;

  /// Height of the widget (the former 10 dp node), so the layout around it
  /// stays put.
  static const double height = 10;

  const ThreadProgress({super.key, required this.layout, required this.tokens});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _ThreadPainter(layout: layout, tokens: tokens),
      ),
    );
  }
}

class _ThreadPainter extends CustomPainter {
  final ThreadLayout layout;
  final FadenTokens tokens;

  const _ThreadPainter({required this.layout, required this.tokens});

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final heardPaint = Paint()..color = tokens.faden;
    final unheardPaint = Paint()..color = tokens.tinteLeiseFaden;
    final nodePaint = Paint()..color = tokens.faden;

    final boundariesPx = visibleChapterGaps(
      layout.chapterBoundaryFractions.map((f) => f * size.width).toList(),
      width: size.width,
    );
    final cutPoints = <double>[0, ...boundariesPx, size.width];

    for (var i = 0; i < cutPoints.length - 1; i++) {
      var start = cutPoints[i];
      var end = cutPoints[i + 1];
      // Carve a gapWidth-wide gap centered on each internal boundary
      // (not at the thread's own start/end).
      if (i > 0) start += ThreadProgress.gapWidth / 2;
      if (i < cutPoints.length - 2) end -= ThreadProgress.gapWidth / 2;
      if (end <= start) continue;
      final heardBoundaryPx = layout.heardFraction * size.width;
      _drawSegment(canvas, start, end, heardBoundaryPx, centerY, heardPaint, unheardPaint);
    }

    canvas.drawCircle(
      Offset(layout.heardFraction * size.width, centerY),
      ThreadProgress.nodeDiameter / 2,
      nodePaint,
    );
  }

  void _drawSegment(
    Canvas canvas,
    double start,
    double end,
    double heardBoundaryPx,
    double centerY,
    Paint heardPaint,
    Paint unheardPaint,
  ) {
    void rect(double a, double b, Paint paint) => canvas.drawRect(
          Rect.fromLTRB(a, centerY - ThreadProgress.lineThickness / 2, b,
              centerY + ThreadProgress.lineThickness / 2),
          paint,
        );
    if (heardBoundaryPx <= start) {
      rect(start, end, unheardPaint);
    } else if (heardBoundaryPx >= end) {
      rect(start, end, heardPaint);
    } else {
      rect(start, heardBoundaryPx, heardPaint);
      rect(heardBoundaryPx, end, unheardPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ThreadPainter oldDelegate) =>
      oldDelegate.layout.heardFraction != layout.heardFraction ||
      oldDelegate.layout.chapterBoundaryFractions != layout.chapterBoundaryFractions ||
      oldDelegate.tokens != tokens;
}
