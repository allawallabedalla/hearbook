import 'package:faden/core/hlc.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/pause_reason.dart';
import 'package:flutter_test/flutter_test.dart';

Event _event({
  String id = 'e1',
  EventType type = EventType.play,
  int pt = 1000,
  String bookId = 'book-1',
  EventSource source = EventSource.ui,
  Map<String, dynamic> data = const {'note': 'x'},
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
      source: source,
      data: data,
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

  group('lastPauseReasonForBook (E80)', () {
    test('the reason of the newest PAUSE when no intent came after it', () async {
      await journal.record(_event(id: 'a', pt: 1000), () async {});
      await journal.record(
          _event(id: 'b', type: EventType.pause, pt: 2000, source: EventSource.system, data: {'reason': 'route_lost'}),
          () async {});
      await journal.record(_event(id: 'c', type: EventType.awake, pt: 3000), () async {});
      expect(await journal.lastPauseReasonForBook('book-1'), PauseReason.routeLost);
    });

    test('null once an intent followed, for other books, and for old pauses without data', () async {
      await journal.record(
          _event(id: 'b', type: EventType.pause, pt: 2000, data: {'reason': 'route_lost'}), () async {});
      await journal.record(_event(id: 'c', type: EventType.play, pt: 3000), () async {});
      expect(await journal.lastPauseReasonForBook('book-1'), isNull);
      expect(await journal.lastPauseReasonForBook('book-2'), isNull);
      await journal.record(_event(id: 'd', type: EventType.pause, pt: 4000, data: const {}), () async {});
      expect(await journal.lastPauseReasonForBook('book-1'), isNull);
    });
  });

  group('firstAwakeProofWallMsAfter (E79)', () {
    test('the first awake proof after the time, any book; heartbeats, hints and system pauses do not count',
        () async {
      await journal.record(_event(id: 'a', type: EventType.play, pt: 1000), () async {});
      await journal.record(_event(id: 'b', type: EventType.heartbeat, pt: 2000), () async {});
      await journal.record(_event(id: 'c', type: EventType.sleepHint, pt: 3000), () async {});
      await journal.record(
          _event(id: 'd', type: EventType.pause, pt: 4000, source: EventSource.system), () async {});
      await journal.record(_event(id: 'e', type: EventType.probe, pt: 5000), () async {});
      await journal.record(_event(id: 'f', type: EventType.awake, pt: 6000, bookId: 'book-2'), () async {});
      await journal.record(_event(id: 'g', type: EventType.resume, pt: 7000), () async {});
      expect(await journal.firstAwakeProofWallMsAfter(1000), 6000);
      expect(await journal.firstAwakeProofWallMsAfter(6000), 7000);
      expect(await journal.firstAwakeProofWallMsAfter(7000), isNull);
    });

    test('a UI pause counts', () async {
      await journal.record(_event(id: 'a', type: EventType.pause, pt: 5000), () async {});
      expect(await journal.firstAwakeProofWallMsAfter(1000), 5000);
    });
  });
}
