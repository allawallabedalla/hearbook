// Tests data/settings_store.dart's M6 addition, the health-data opt-in
// (docs/ARCHITEKTUR.md section 9 / KONZEPT.md "Schlafdaten erlauben"),
// plus the appearance (decision E28) and the night window.
// Safety-relevant: the whole M6 feature is gated behind this being true,
// so an unset key must read back as false, not as some other default.

import 'package:faden/data/db.dart';
import 'package:faden/data/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late SettingsStore settings;

  setUp(() {
    db = AppDatabase.memory();
    settings = SettingsStore(db);
  });

  tearDown(() => db.close());

  test('health data opt-in defaults to false (off) when never set', () async {
    expect(await settings.healthDataOptIn(), isFalse);
  });

  test('health data opt-in round-trips true and false', () async {
    await settings.setHealthDataOptIn(true);
    expect(await settings.healthDataOptIn(), isTrue);

    await settings.setHealthDataOptIn(false);
    expect(await settings.healthDataOptIn(), isFalse);
  });

  test('appearance defaults to "Wie iPhone" (system) when never set', () async {
    expect(await settings.appearance(), Appearance.system);
  });

  test('appearance round-trips every value', () async {
    for (final appearance in Appearance.values) {
      await settings.setAppearance(appearance);
      expect(await settings.appearance(), appearance);
    }
  });

  test('night window defaults to 20:00-06:00 and round-trips', () async {
    expect(await settings.nightStartMin(), 20 * 60);
    expect(await settings.nightEndMin(), 6 * 60);
    await settings.setNightStartMin(22 * 60 + 15);
    await settings.setNightEndMin(5 * 60 + 45);
    expect(await settings.nightStartMin(), 22 * 60 + 15);
    expect(await settings.nightEndMin(), 5 * 60 + 45);
  });

  test('speed per book (E38): 1.0 by default, stored per book', () async {
    expect(await settings.bookSpeed('book-1'), 1.0);
    await settings.setBookSpeed('book-1', 1.5);
    await settings.setBookSpeed('book-2', 0.75);
    expect(await settings.bookSpeed('book-1'), 1.5);
    expect(await settings.bookSpeed('book-2'), 0.75);
    expect(await settings.bookSpeed('book-3'), 1.0);
  });

  test('mobile-data chapters (E66): off by default, hint shown by default', () async {
    expect(await settings.cellularChapters(), isFalse);
    expect(await settings.cellularHintOff(), isFalse);
    await settings.setCellularChapters(true);
    await settings.setCellularHintOff(true);
    expect(await settings.cellularChapters(), isTrue);
    expect(await settings.cellularHintOff(), isTrue);
  });

  test('library view (E70): defaults, round-trips, and unknown values fall back', () async {
    expect(await settings.libraryView(), const LibraryView());
    const view = LibraryView(
      sort: LibrarySort.length,
      status: LibraryStatusFilter.finished,
      grouping: LibraryGrouping.author,
      genre: 'Humor',
    );
    await settings.setLibraryView(view);
    expect(await settings.libraryView(), view);
    await settings.setLibraryView(view.withGenre(null));
    expect((await settings.libraryView()).genre, isNull);

    await db.into(db.keyValueSettings).insertOnConflictUpdate(
          KeyValueSettingsCompanion.insert(key: SettingsKeys.libraryStatus, value: 'someday'),
        );
    expect((await settings.libraryView()).status, LibraryStatusFilter.all);
  });
}
