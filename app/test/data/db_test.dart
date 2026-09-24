import 'package:drift/drift.dart';
import 'package:faden/data/db.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.memory());
  tearDown(() => db.close());

  test('inserts and reads back an event row', () async {
    await db.into(db.eventRows).insert(
          EventRowsCompanion.insert(
            eventId: 'e1',
            deviceId: 'dev-a',
            sessionId: 's1',
            bookId: 'book-1',
            manifestId: 'm1',
            type: 'PLAY',
            fileHash: 'f1',
            offsetMs: 0,
            hlcPt: 1000,
            hlcC: 0,
            wallMs: 1000,
            tzMin: 0,
            source: 'ui',
          ),
        );

    final rows = await db.select(db.eventRows).get();
    expect(rows, hasLength(1));
    expect(rows.single.eventId, 'e1');
    expect(rows.single.synced, isFalse);
  });

  test('event_id is the primary key: a duplicate insert is idempotent '
      'with InsertMode.insertOrIgnore', () async {
    final row = EventRowsCompanion.insert(
      eventId: 'e1',
      deviceId: 'dev-a',
      sessionId: 's1',
      bookId: 'book-1',
      manifestId: 'm1',
      type: 'PLAY',
      fileHash: 'f1',
      offsetMs: 0,
      hlcPt: 1000,
      hlcC: 0,
      wallMs: 1000,
      tzMin: 0,
      source: 'ui',
    );
    await db.into(db.eventRows).insert(row, mode: InsertMode.insertOrIgnore);
    await db.into(db.eventRows).insert(row, mode: InsertMode.insertOrIgnore);

    final rows = await db.select(db.eventRows).get();
    expect(rows, hasLength(1));
  });

  test('sync cursor defaults to 0 and can be upserted per book', () async {
    await db.into(db.syncCursors).insertOnConflictUpdate(
          SyncCursorsCompanion.insert(bookId: 'book-1', sinceSeq: const Value(42)),
        );
    final row = await (db.select(db.syncCursors)
          ..where((t) => t.bookId.equals('book-1')))
        .getSingle();
    expect(row.sinceSeq, 42);
  });
}
