import 'dart:convert';

import 'package:drift/drift.dart';

import '../core/hlc.dart';
import '../domain/event.dart';
import '../domain/position.dart';
import 'db.dart';

/// The local event journal: the durable, append-only record CLAUDE.md
/// invariant 2 builds on ("state is a pure function of events").
///
/// [record] implements invariant 3 ("jedes Event liegt in einer lokalen
/// SQLite-Transaktion, bevor die Aktion ausgefuehrt oder als erledigt
/// angezeigt wird"): the event is written and committed to SQLite first,
/// and only once that succeeds does [action] run. If the app crashes
/// between the two, the event survives and the Resolver still sees it on
/// next launch, even though the action itself (a player seek, a UI update)
/// never completed.
class Journal {
  final AppDatabase db;

  Journal(this.db);

  /// Writes [event] in one transaction, then runs [action]. Duplicate
  /// `event_id`s are ignored (matches the server's idempotent push,
  /// section 6, and Resolver rule 1) rather than erroring.
  Future<T> record<T>(Event event, Future<T> Function() action) async {
    await db.transaction(() async {
      await db.into(db.eventRows).insert(
            _toCompanion(event),
            mode: InsertMode.insertOrIgnore,
          );
    });
    return action();
  }

  /// All journaled events for [bookId], oldest first (unfiltered by
  /// `synced`: the Resolver needs every locally known event, pushed or
  /// not).
  Future<List<Event>> eventsForBook(String bookId) async {
    final rows = await (db.select(db.eventRows)
          ..where((t) => t.bookId.equals(bookId))
          ..orderBy([(t) => OrderingTerm.asc(t.hlcPt), (t) => OrderingTerm.asc(t.hlcC)]))
        .get();
    return rows.map(_toEvent).toList();
  }

  /// The most advanced `Hlc` of any stored event, local or pulled from
  /// another device, across every book. The HLC receive rule
  /// (docs/ARCHITEKTUR.md section 5) folds this into the device clock so a
  /// new local event always sorts after everything already known.
  /// `Hlc(pt: 0, c: 0)` for an empty journal.
  Future<Hlc> maxHlc() async {
    final rows = await (db.select(db.eventRows)
          ..orderBy([
            (t) => OrderingTerm.desc(t.hlcPt),
            (t) => OrderingTerm.desc(t.hlcC),
          ])
          ..limit(1))
        .get();
    if (rows.isEmpty) return const Hlc(pt: 0, c: 0);
    return Hlc(pt: rows.first.hlcPt, c: rows.first.hlcC);
  }

  /// Rows not yet marked `synced`, oldest first -- what the sync client
  /// (data/sync.dart) still needs to push.
  Future<List<Event>> unsyncedEvents({int limit = 500}) async {
    final rows = await (db.select(db.eventRows)
          ..where((t) => t.synced.equals(false))
          ..orderBy([(t) => OrderingTerm.asc(t.hlcPt), (t) => OrderingTerm.asc(t.hlcC)])
          ..limit(limit))
        .get();
    return rows.map(_toEvent).toList();
  }

  /// Marks the given event ids as pushed to the server.
  Future<void> markSynced(Iterable<String> eventIds) async {
    if (eventIds.isEmpty) return;
    await db.transaction(() async {
      for (final id in eventIds) {
        await (db.update(db.eventRows)..where((t) => t.eventId.equals(id)))
            .write(const EventRowsCompanion(synced: Value(true)));
      }
    });
  }

  /// Stores an already-synced remote event (pulled from the server, section
  /// 6) locally, without running any local action. Also idempotent on
  /// `event_id`. Returns whether the event was new to this device (false
  /// for a duplicate, e.g. this device's own event coming back in a pull).
  Future<bool> storeRemote(Event event) {
    return db.transaction(() async {
      final existing = await (db.selectOnly(db.eventRows)
            ..addColumns([db.eventRows.eventId])
            ..where(db.eventRows.eventId.equals(event.eventId))
            ..limit(1))
          .getSingleOrNull();
      if (existing != null) return false;
      await db.into(db.eventRows).insert(
            _toCompanion(event).copyWith(synced: const Value(true)),
            mode: InsertMode.insertOrIgnore,
          );
      return true;
    });
  }

  /// Wall time of the newest event of [bookId] (any device, any type), or
  /// null for a book without events. Used for the auto-rewind after a
  /// pause that spans an app restart (domain/auto_rewind.dart).
  Future<int?> lastWallMsForBook(String bookId) async {
    final maxWall = db.eventRows.wallMs.max();
    final row = await (db.selectOnly(db.eventRows)
          ..addColumns([maxWall])
          ..where(db.eventRows.bookId.equals(bookId)))
        .getSingleOrNull();
    return row?.read(maxWall);
  }

  /// Per-book progress for the library (decision E33), for every book with
  /// at least one intent event, in one query instead of a Resolver replay
  /// per row. Mirrors Resolver rules 1-3 (domain/resolver.dart): the
  /// winning session is the one of the last intent event by `(hlc.pt,
  /// hlc.c, device_id, event_id)`, and the position is that session's last
  /// event. `lastWallMs` is the newest event of the book of any type.
  Future<Map<String, BookProgressRow>> progressRows() async {
    final rows = await db.customSelect(
      _progressQuery,
      readsFrom: {db.eventRows},
    ).get();
    return {
      for (final r in rows)
        r.read<String>('book_id'): BookProgressRow(
          bookId: r.read<String>('book_id'),
          manifestId: r.read<String>('manifest_id'),
          position: Position(fileHash: r.read<String>('file_hash'), offsetMs: r.read<int>('offset_ms')),
          lastWallMs: r.read<int>('last_wall_ms'),
        ),
    };
  }

  EventRowsCompanion _toCompanion(Event e) => EventRowsCompanion.insert(
        eventId: e.eventId,
        deviceId: e.deviceId,
        sessionId: e.sessionId,
        bookId: e.bookId,
        manifestId: e.manifestId,
        type: e.type.wireName,
        fileHash: e.fileHash,
        offsetMs: e.offsetMs,
        hlcPt: e.hlc.pt,
        hlcC: e.hlc.c,
        wallMs: e.wallMs,
        tzMin: e.tzMin,
        source: e.source.wireName,
        dataJson: Value(jsonEncode(e.data)),
      );

  Event _toEvent(EventRow row) => Event(
        eventId: row.eventId,
        deviceId: row.deviceId,
        sessionId: row.sessionId,
        bookId: row.bookId,
        manifestId: row.manifestId,
        type: EventType.fromWire(row.type),
        fileHash: row.fileHash,
        offsetMs: row.offsetMs,
        hlc: Hlc(pt: row.hlcPt, c: row.hlcC),
        wallMs: row.wallMs,
        tzMin: row.tzMin,
        source: EventSource.fromWire(row.source),
        data: Map<String, dynamic>.from(jsonDecode(row.dataJson) as Map),
      );
}

/// One book's resolved position and last activity, see
/// [Journal.progressRows].
class BookProgressRow {
  final String bookId;
  final String manifestId;
  final Position position;
  final int lastWallMs;

  const BookProgressRow({
    required this.bookId,
    required this.manifestId,
    required this.position,
    required this.lastWallMs,
  });
}

const _progressQuery = '''
WITH last_intent AS (
  SELECT book_id, session_id FROM (
    SELECT book_id, session_id,
           ROW_NUMBER() OVER (PARTITION BY book_id
             ORDER BY hlc_pt DESC, hlc_c DESC, device_id DESC, event_id DESC) AS rn
    FROM event_rows WHERE type IN ('PLAY', 'SEEK', 'RESUME', 'UNDO')
  ) WHERE rn = 1
),
last_event AS (
  SELECT e.book_id, e.manifest_id, e.file_hash, e.offset_ms,
         ROW_NUMBER() OVER (PARTITION BY e.book_id
           ORDER BY e.hlc_pt DESC, e.hlc_c DESC, e.device_id DESC, e.event_id DESC) AS rn
  FROM event_rows e
  JOIN last_intent li ON li.book_id = e.book_id AND li.session_id = e.session_id
),
last_wall AS (
  SELECT book_id, MAX(wall_ms) AS last_wall_ms FROM event_rows GROUP BY book_id
)
SELECT le.book_id, le.manifest_id, le.file_hash, le.offset_ms, lw.last_wall_ms
FROM last_event le JOIN last_wall lw ON lw.book_id = le.book_id
WHERE le.rn = 1
''';
