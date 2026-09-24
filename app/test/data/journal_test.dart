import 'package:faden/core/hlc.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/domain/event.dart';
import 'package:flutter_test/flutter_test.dart';

Event _event({
  String id = 'e1',
  EventType type = EventType.play,
  int pt = 1000,
  String bookId = 'book-1',
}) =>
    Event(
      eventId: id,
      deviceId: 'dev-a',
      sessionId: 's1',
      bookId: bookId,
      manifestId: 'm1',
      type: type,
      fileHash: 'f1',
      offsetMs: 0,
      hlc: Hlc(pt: pt, c: 0),
      wallMs: pt,
      tzMin: 0,
      source: EventSource.ui,
      data: const {'note': 'x'},
    );

void main() {
  late AppDatabase db;
  late Journal journal;

  setUp(() {
    db = AppDatabase.memory();
    journal = Journal(db);
  });
  tearDown(() => db.close());

  group('record (CLAUDE.md invariant 3: event before action)', () {
    test('the event row is committed before action runs', () async {
      var sawRowInAction = false;
      await journal.record(_event(), () async {
        final rows = await db.select(db.eventRows).get();
        sawRowInAction = rows.length == 1 && rows.single.eventId == 'e1';
      });
      expect(sawRowInAction, isTrue);
    });

    test('the event survives even if action throws afterwards '
        '(a crash between write and action never loses the event)', () async {
      await expectLater(
        journal.record(_event(), () async => throw StateError('boom')),
        throwsA(isA<StateError>()),
      );
      final rows = await db.select(db.eventRows).get();
      expect(rows, hasLength(1));
    });

    test("action's return value is passed through", () async {
      final result = await journal.record(_event(), () async => 42);
      expect(result, 42);
    });

    test('duplicate event_id is ignored (idempotent, matches server push)', () async {
      await journal.record(_event(id: 'e1', pt: 1000), () async {});
      await journal.record(_event(id: 'e1', pt: 1000), () async {});
      final rows = await db.select(db.eventRows).get();
      expect(rows, hasLength(1));
    });
  });

  group('eventsForBook', () {
    test('returns only the given book, sorted by HLC', () async {
      await journal.record(_event(id: 'e2', pt: 2000), () async {});
      await journal.record(_event(id: 'e1', pt: 1000), () async {});
      await journal.record(_event(id: 'other-book', pt: 500, bookId: 'book-2'), () async {});

      final events = await journal.eventsForBook('book-1');
      expect(events.map((e) => e.eventId), ['e1', 'e2']);
    });

    test('round-trips data (JSON payload survives the DB)', () async {
      await journal.record(_event(id: 'e1'), () async {});
      final events = await journal.eventsForBook('book-1');
      expect(events.single.data, {'note': 'x'});
    });
  });

  group('unsyncedEvents / markSynced', () {
    test('unsynced events are returned until marked synced', () async {
      await journal.record(_event(id: 'e1'), () async {});
      expect((await journal.unsyncedEvents()).map((e) => e.eventId), ['e1']);

      await journal.markSynced(['e1']);
      expect(await journal.unsyncedEvents(), isEmpty);
    });

    test('storeRemote marks the row synced without running any action', () async {
      await journal.storeRemote(_event(id: 'remote-1'));
      expect(await journal.unsyncedEvents(), isEmpty);
      final events = await journal.eventsForBook('book-1');
      expect(events.map((e) => e.eventId), ['remote-1']);
    });
  });

  group('maxHlc', () {
    test('is Hlc(0, 0) for an empty journal', () async {
      expect(await journal.maxHlc(), const Hlc(pt: 0, c: 0));
    });

    test('covers remote events of other devices and other books, not just own ones', () async {
      await journal.record(_event(id: 'own', pt: 1000), () async {});
      final remote = Event(
        eventId: 'remote',
        deviceId: 'dev-b',
        sessionId: 's2',
        bookId: 'book-2',
        manifestId: 'm2',
        type: EventType.seek,
        fileHash: 'f9',
        offsetMs: 0,
        hlc: const Hlc(pt: 9000, c: 4),
        wallMs: 9000,
        tzMin: 0,
        source: EventSource.ui,
      );
      await journal.storeRemote(remote);
      expect(await journal.maxHlc(), const Hlc(pt: 9000, c: 4));
    });
  });
}
