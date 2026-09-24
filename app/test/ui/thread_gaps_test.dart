import 'package:faden/ui/thread_progress.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('wide chapters keep their gaps', () {
    expect(visibleChapterGaps([100, 200], width: 300), [100, 200]);
  });

  test('gaps next to chapters narrower than 12 px are dropped', () {
    expect(visibleChapterGaps([100, 105, 200], width: 300), [105, 200]);
    expect(visibleChapterGaps([5, 150], width: 300), [150]);
    expect(visibleChapterGaps([150, 295], width: 300), [150]);
  });

  test('many short chapters leave one continuous line', () {
    final dense = [for (var i = 1; i < 100; i++) i * 3.0];
    expect(visibleChapterGaps(dense, width: 300).length, lessThan(30));
    final kept = visibleChapterGaps(dense, width: 300);
    for (var i = 1; i < kept.length; i++) {
      expect(kept[i] - kept[i - 1], greaterThanOrEqualTo(12));
    }
  });
}
