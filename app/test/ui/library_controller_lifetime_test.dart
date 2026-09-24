import 'dart:io';

import 'package:faden/data/book_downloads.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/downloads.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/ui/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_audio_handler.dart';

class _PingableDownloads extends BookDownloads {
  _PingableDownloads(Directory dir) : super(manager: DownloadManager(api: null, targetDir: dir));

  void ping() => notifyListeners();
}

void main() {
  test('a download-state change does not recreate the library controller', () async {
    final dir = Directory.systemTemp.createTempSync('faden_lib_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final downloads = _PingableDownloads(dir);
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final journal = Journal(db);
    final container = ProviderContainer(overrides: [
      bookDownloadsProvider.overrideWith((ref) => downloads),
      journalProvider.overrideWithValue(journal),
      audioHandlerProvider.overrideWithValue(FakeAudioHandler(journal)),
    ]);
    addTearDown(container.dispose);
    final sub = container.listen(libraryControllerProvider, (_, _) {});
    addTearDown(sub.close);

    final before = container.read(libraryControllerProvider);
    downloads.ping();
    await Future<void>.delayed(Duration.zero);

    expect(identical(container.read(libraryControllerProvider), before), isTrue);
  });
}
