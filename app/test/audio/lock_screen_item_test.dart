import 'package:faden/audio/handler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('book is the title, author and chapter position underneath', () {
    final item = lockScreenItem(
      fileHash: 'abc',
      chapter: 3,
      chapterCount: 12,
      durationMs: 60000,
      bookTitle: 'Dark Matter',
      author: 'Blake Crouch',
      artUri: Uri.file('/tmp/cover'),
    );

    expect(item.id, 'abc');
    expect(item.title, 'Dark Matter');
    expect(item.artist, 'Blake Crouch · Kapitel 3 von 12');
    expect(item.duration, const Duration(minutes: 1));
    expect(item.artUri, Uri.file('/tmp/cover'));
  });

  test('without an author only the chapter position is shown', () {
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
  });
}
