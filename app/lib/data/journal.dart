import 'dart:convert';

import 'package:drift/drift.dart';

import '../core/hlc.dart';
import '../domain/event.dart';
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

  /// The most advanced `Hlc` this device has locally logged, across every
  /// book (the clock is per-device, not per-book, docs/ARCHITEKTUR.md
  /// section 5). `Hlc(pt: 0, c: 0)` if this device has never logged an
  /// event, in which case `tick(nowMs)` naturally produces `nowMs`.
  Future<Hlc> latestHlc(String deviceId) async {
    final rows = await (db.select(db.eventRows)
          ..where((t) => t.deviceId.equals(deviceId))
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
  /// `event_id`.
  Future<void> storeRemote(Event event) async {
    await db.into(db.eventRows).insert(
          _toCompanion(event).copyWith(synced: const Value(true)),
          mode: InsertMode.insertOrIgnore,
        );
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
