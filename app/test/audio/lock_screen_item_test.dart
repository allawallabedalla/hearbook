import 'package:faden/audio/handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('book is the title, author and the chapter title underneath (E65)', () {
    final item = lockScreenItem(
      fileHash: 'abc',
      chapter: 3,
      chapterCount: 12,
      durationMs: 60000,
      bookTitle: 'Dark Matter',
      chapterTitle: ' Die Kiste ',
      author: 'Blake Crouch',
      artUri: Uri.file('/tmp/cover'),
    );

    expect(item.id, 'abc');
    expect(item.title, 'Dark Matter');
    expect(item.artist, 'Blake Crouch · Die Kiste');
    expect(item.duration, const Duration(minutes: 1));
    expect(item.artUri, Uri.file('/tmp/cover'));
  });

  test('a chapter without a title falls back to its position', () {
    for (final chapterTitle in [null, '', '  ']) {
      final item = lockScreenItem(
        fileHash: 'abc',
        chapter: 3,
        chapterCount: 12,
        durationMs: 1,
        bookTitle: 'Dark Matter',
        chapterTitle: chapterTitle,
        author: 'Blake Crouch',
      );
      expect(item.artist, 'Blake Crouch · Kapitel 3 von 12');
    }
  });

  test('without an author only the chapter is shown', () {
    for (final author in [null, '', '  ']) {
      final item = lockScreenItem(
        fileHash: 'abc',
        chapter: 1,
        chapterCount: 2,
        durationMs: 1,
        bookTitle: 'Dark Matter',
        author: author,
      );
      expect(item.artist, 'Kapitel 1 von 2');
      expect(item.artUri, isNull);
    }
    final titled = lockScreenItem(
      fileHash: 'abc',
      chapter: 1,
      chapterCount: 2,
      durationMs: 1,
      bookTitle: 'Dark Matter',
      chapterTitle: 'Die Kiste',
    );
    expect(titled.artist, 'Die Kiste');
  });
}
