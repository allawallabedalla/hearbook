import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

part 'db.g.dart';

/// The local event journal (CLAUDE.md invariant 2/3): every event the app
/// ever recorded, appended in order and never rewritten. Mirrors the event
/// shape from docs/ARCHITEKTUR.md section 5 one column per field, plus
/// `data` as JSON text, so it can be queried and pushed to the server
/// without deserializing a JSON blob for every row.
class EventRows extends Table {
  TextColumn get eventId => text()();
  TextColumn get deviceId => text()();
  TextColumn get sessionId => text()();
  TextColumn get bookId => text()();
  TextColumn get manifestId => text()();
  TextColumn get type => text()();
  TextColumn get fileHash => text()();
  IntColumn get offsetMs => integer()();
  IntColumn get hlcPt => integer()();
  IntColumn get hlcC => integer()();
  IntColumn get wallMs => integer()();
  IntColumn get tzMin => integer()();
  TextColumn get source => text()();
  TextColumn get dataJson => text().withDefault(const Constant('{}'))();

  /// Set once the server has accepted this event (section 6 push). Lets the
  /// sync client find only the rows it still needs to push.
  BoolColumn get synced => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {eventId};
}

/// The local pull cursor (section 6: "Cursor lokal speichern"): the
/// highest server `seq` this device has already pulled. `seq` is a single
/// autoincrement counter across all books on the server (section 2), and
/// `GET /api/v1/events?since=` is not scoped to a book either, so this is
/// one global value per device, not one per book. Always exactly one row
/// (id 0). Callers must pass `id: Value(0)` explicitly on every write:
/// SQLite treats a bare `INTEGER PRIMARY KEY` as a rowid alias and
/// auto-assigns it (ignoring the column's declared default) whenever it is
/// left out of the INSERT.
class SyncState extends Table {
  IntColumn get id => integer().withDefault(const Constant(0))();
  IntColumn get sinceSeq => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Local app settings: server connection, device id, night window and
/// other small values that must survive a restart. Deliberately a plain
/// key/value table (mirrors the server's own `settings` table, section 2)
/// rather than one column per setting, so adding a setting never needs a
/// schema migration. See data/settings_store.dart for the typed wrapper.
class KeyValueSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(tables: [EventRows, SyncState, KeyValueSettings])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  /// Opens (creating if needed) the on-disk database at [file]. Runs on a
  /// background isolate per drift's Flutter guidance, so database I/O never
  /// blocks the UI thread.
  AppDatabase.open(File file) : super(NativeDatabase.createInBackground(file));

  /// An in-memory database for tests: nothing is persisted to disk.
  AppDatabase.memory() : super(NativeDatabase.memory());

  /// v3 (decision E33) only adds [bookHlcIndex]: purely additive, no
  /// stored event is touched.
  @override
  int get schemaVersion => 3;

  /// Every per-book read (`Journal.eventsForBook`, the library progress
  /// query, the last-activity lookup) filters by `book_id` and orders by
  /// HLC; without this index each of them scans the whole journal, which
  /// grows by one heartbeat every 5 s of listening.
  static const bookHlcIndex = 'event_rows_book_hlc';

  static const _createBookHlcIndex =
      'CREATE INDEX IF NOT EXISTS $bookHlcIndex ON event_rows (book_id, hlc_pt, hlc_c)';

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await customStatement(_createBookHlcIndex);
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.createTable(keyValueSettings);
          }
          if (from < 3) {
            await customStatement(_createBookHlcIndex);
          }
        },
      );
}
