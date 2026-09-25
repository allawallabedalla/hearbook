import 'dart:math' as math;

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

/// The thread wrapped around the cover (decision E71): the same book
/// progress as [ThreadProgress], drawn as a thin line along a rounded
/// square around [child], starting top-centre and running clockwise. The
/// heard part in `faden`, the rest in the thread-rest grey, the position as
/// a small dot, chapter boundaries as small gaps (only where both chapters
/// keep [minSegment] of the line, like [visibleChapterGaps]); a gap at the
/// top marks where the book starts and ends. Not draggable, like the
/// straight thread (E65 #12).
///
/// The widget is a square of the incoming width; [child] (the cover)
/// sits inside the ring at [coverSizeFor] with corners of [coverRadiusFor].
class ThreadRing extends StatelessWidget {
  final ThreadLayout layout;
  final FadenTokens tokens;
  final Widget child;

  /// The night view (E71): the ring is dimmed along with the cover.
  final bool dim;

  static const double lineThickness = 3;
  static const double dotDiameter = 8;
  static const double gapWidth = 3;

  /// From the ring's line to the cover's edge.
  static const double spacing = 7;

  /// From the widget's edge to the cover: room for the dot and the gap.
  static const double inset = dotDiameter / 2 + spacing;

  /// Smallest share of the line a chapter needs for its gap to show.
  static const double minSegment = 12;

  const ThreadRing({super.key, required this.layout, required this.tokens, required this.child, this.dim = false});

  /// The cover's edge inside a ring [size] wide.
  static double coverSizeFor(double size) => size - 2 * inset;

  /// The cover's corner radius at [coverSize]: rounder on a large cover,
  /// never below 10.
  static double coverRadiusFor(double coverSize) => (coverSize * 0.06).clamp(10.0, 20.0).toDouble();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.maxWidth;
        return SizedBox.square(
          dimension: size,
          child: CustomPaint(
            foregroundPainter: _RingPainter(layout: layout, tokens: tokens, dim: dim),
            child: Padding(padding: const EdgeInsets.all(inset), child: child),
          ),
        );
      },
    );
  }
}

/// The ring's path: a rounded square from top-centre, clockwise.
Path threadRingPath(Rect rect, double radius) {
  final r = math.min(radius, rect.shortestSide / 2);
  final cx = rect.center.dx;
  return Path()
    ..moveTo(cx, rect.top)
    ..lineTo(rect.right - r, rect.top)
    ..arcToPoint(Offset(rect.right, rect.top + r), radius: Radius.circular(r))
    ..lineTo(rect.right, rect.bottom - r)
    ..arcToPoint(Offset(rect.right - r, rect.bottom), radius: Radius.circular(r))
    ..lineTo(rect.left + r, rect.bottom)
    ..arcToPoint(Offset(rect.left, rect.bottom - r), radius: Radius.circular(r))
    ..lineTo(rect.left, rect.top + r)
    ..arcToPoint(Offset(rect.left + r, rect.top), radius: Radius.circular(r))
    ..lineTo(cx, rect.top);
}

class _RingPainter extends CustomPainter {
  final ThreadLayout layout;
  final FadenTokens tokens;
  final bool dim;

  const _RingPainter({required this.layout, required this.tokens, required this.dim});

  @override
  void paint(Canvas canvas, Size size) {
    const half = ThreadRing.dotDiameter / 2;
    final rect = Rect.fromLTWH(half, half, size.width - 2 * half, size.height - 2 * half);
    final coverSize = ThreadRing.coverSizeFor(size.width);
    final radius = ThreadRing.coverRadiusFor(coverSize) + ThreadRing.spacing;
    final metric = threadRingPath(rect, radius).computeMetrics().first;
    final length = metric.length;

    Color soften(Color c) => dim ? Color.alphaBlend(c.withValues(alpha: 0.7), tokens.grund) : c;
    final heardPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ThreadRing.lineThickness
      ..strokeCap = StrokeCap.butt
      ..color = soften(tokens.faden);
    final restPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ThreadRing.lineThickness
      ..strokeCap = StrokeCap.butt
      ..color = tokens.tinteLeiseFaden;

    final gaps = visibleChapterGaps(
      [for (final f in layout.chapterBoundaryFractions) f * length],
      width: length,
      minSegment: ThreadRing.minSegment,
    );
    // The book's own start and end meet at the top: a gap there too.
    final cuts = <double>[0, ...gaps, length];
    final heard = layout.heardFraction * length;
    for (var i = 0; i < cuts.length - 1; i++) {
      final start = cuts[i] + ThreadRing.gapWidth / 2;
      final end = cuts[i + 1] - ThreadRing.gapWidth / 2;
      if (end <= start) continue;
      if (heard > start) {
        canvas.drawPath(metric.extractPath(start, math.min(heard, end)), heardPaint);
      }
      if (heard < end) {
        canvas.drawPath(metric.extractPath(math.max(heard, start), end), restPaint);
      }
    }
    final at = metric.getTangentForOffset(heard.clamp(0.0, length));
    if (at != null) {
      canvas.drawCircle(at.position, half, Paint()..color = soften(tokens.faden));
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.layout.heardFraction != layout.heardFraction ||
      old.layout.chapterBoundaryFractions != layout.chapterBoundaryFractions ||
      old.tokens != tokens ||
      old.dim != dim;
}
