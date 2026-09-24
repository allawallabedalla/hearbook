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

  test('sync cursor is a single global row that can be upserted', () async {
    // id must be passed explicitly as 0: SQLite treats a bare `INTEGER
    // PRIMARY KEY` as a rowid alias and auto-assigns it (ignoring any
    // column-level default) whenever it is left out of the INSERT.
    await db.into(db.syncState).insertOnConflictUpdate(
          SyncStateCompanion.insert(id: const Value(0), sinceSeq: const Value(42)),
        );
    final row = await db.select(db.syncState).getSingle();
    expect(row.id, 0);
    expect(row.sinceSeq, 42);

    await db.into(db.syncState).insertOnConflictUpdate(
          SyncStateCompanion.insert(id: const Value(0), sinceSeq: const Value(99)),
        );
    final rows = await db.select(db.syncState).get();
    expect(rows, hasLength(1)); // still a single row, updated in place
    expect(rows.single.sinceSeq, 99);
  });
}
