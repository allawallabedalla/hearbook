// Journal.progressRows (decision E33) must agree with the Resolver's
// position (rules 1-3) without replaying each book; and the v3 schema's
// index must arrive by an additive migration that keeps every stored event.

import 'dart:io';
import 'dart:math';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:faden/core/hlc.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/domain/resolver.dart';
import 'package:flutter_test/flutter_test.dart';

Event _e(
  String id, {
  required String book,
  required String session,
  required EventType type,
  required int pt,
  String device = 'dev-a',
  String file = 'f1',
  int offset = 0,
  int? wall,
}) =>
    Event(
      eventId: id,
      deviceId: device,
      sessionId: session,
      bookId: book,
      manifestId: 'm1',
      type: type,
      fileHash: file,
      offsetMs: offset,
      hlc: Hlc(pt: pt, c: 0),
      wallMs: wall ?? pt,
      tzMin: 0,
      source: EventSource.ui,
    );

const _manifest = Manifest(manifestId: 'm1', files: [
  ManifestFile(idx: 0, fileHash: 'f1', durationMs: 600000),
  ManifestFile(idx: 1, fileHash: 'f2', durationMs: 600000),
]);

void main() {
  late AppDatabase db;
  late Journal journal;

  setUp(() {
    db = AppDatabase.memory();
    journal = Journal(db);
  });
  tearDown(() => db.close());

  test('position of the winning session\'s last event, per book, like the Resolver', () async {
    final events = [
      // book-1: session s1 plays, then another device seeks later (s2 wins),
      // then s1's late heartbeat arrives -- it must not move the position.
      _e('a1', book: 'book-1', session: 's1', type: EventType.play, pt: 1000, offset: 0),
      _e('a2', book: 'book-1', session: 's1', type: EventType.heartbeat, pt: 2000, offset: 5000),
      _e('b1', book: 'book-1', session: 's2', type: EventType.seek, pt: 3000, device: 'dev-b', file: 'f2', offset: 1000),
      _e('b2', book: 'book-1', session: 's2', type: EventType.pause, pt: 4000, device: 'dev-b', file: 'f2', offset: 9000),
      _e('a3', book: 'book-1', session: 's1', type: EventType.heartbeat, pt: 5000, offset: 90000, wall: 5000),
      // book-2: only one session.
      _e('c1', book: 'book-2', session: 's3', type: EventType.play, pt: 1500, offset: 100),
      _e('c2', book: 'book-2', session: 's3', type: EventType.pause, pt: 1600, offset: 7000),
      // book-3: no intent event at all -> no row (the Resolver has none either).
      _e('d1', book: 'book-3', session: 's4', type: EventType.awake, pt: 1700),
    ];
    for (final e in events) {
      await journal.record(e, () async {});
    }

    final rows = await journal.progressRows();
    expect(rows.keys.toSet(), {'book-1', 'book-2'});
    for (final book in ['book-1', 'book-2']) {
      final resolved = resolve(await journal.eventsForBook(book), _manifest);
      expect(rows[book]!.position, resolved.position, reason: book);
    }
    expect(rows['book-1']!.position, const Position(fileHash: 'f2', offsetMs: 9000));
    expect(rows['book-1']!.lastWallMs, 5000);
    expect(rows['book-2']!.lastWallMs, 1600);
  });

  test('agrees with the Resolver on random event sets (incl. HLC ties)', () async {
    final random = Random(7);
    for (var round = 0; round < 20; round++) {
      final book = 'book-$round';
      final types = EventType.values;
      for (var i = 0; i < 25; i++) {
        final pt = 1000 + random.nextInt(8) * 10; // many ties on pt
        await journal.record(
          _e(
            '$round-$i',
            book: book,
            session: 's${random.nextInt(3)}',
            type: types[random.nextInt(types.length)],
            pt: pt,
            device: random.nextBool() ? 'dev-a' : 'dev-b',
            file: random.nextBool() ? 'f1' : 'f2',
            offset: random.nextInt(600000),
          ),
          () async {},
        );
      }
    }
    final rows = await journal.progressRows();
    for (var round = 0; round < 20; round++) {
      final book = 'book-$round';
      final events = await journal.eventsForBook(book);
      if (!events.any((e) => e.type.isIntent)) {
        expect(rows.containsKey(book), isFalse);
        continue;
      }
      expect(rows[book]!.position, resolve(events, _manifest).position, reason: book);
    }
  });

  test('lastWallMsForBook: newest event of the book, null without events', () async {
    expect(await journal.lastWallMsForBook('book-1'), isNull);
    await journal.record(_e('x1', book: 'book-1', session: 's', type: EventType.play, pt: 10, wall: 500), () async {});
    await journal.record(_e('x2', book: 'book-1', session: 's', type: EventType.pause, pt: 20, wall: 900), () async {});
    expect(await journal.lastWallMsForBook('book-1'), 900);
  });

  test('storeRemote reports whether the event was new', () async {
    final e = _e('r1', book: 'book-1', session: 's', type: EventType.seek, pt: 10);
    expect(await journal.storeRemote(e), isTrue);
    expect(await journal.storeRemote(e), isFalse);
  });

  group('schema v3 migration (additive)', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('faden-db-migration'));
    tearDown(() => dir.delete(recursive: true));

    test('a v2 database keeps every event, setting and the cursor, and gains the index', () async {
      final file = File('${dir.path}/faden.db');
      // Build the real schema, then turn it into a v2 file: no index,
      // user_version 2, with stored data.
      final v2 = AppDatabase(NativeDatabase(file));
      final j = Journal(v2);
      await j.record(_e('keep-1', book: 'book-1', session: 's', type: EventType.play, pt: 10), () async {});
      await j.storeRemote(_e('keep-2', book: 'book-1', session: 's', type: EventType.pause, pt: 20, device: 'dev-b'));
      await SettingsStore(v2).setServerUrl('http://nas.local:8787');
      await v2.customStatement('DROP INDEX ${AppDatabase.bookHlcIndex}');
      await v2.customStatement('PRAGMA user_version = 2');
      await v2.close();

      final v3 = AppDatabase(NativeDatabase(file));
      final kept = await Journal(v3).eventsForBook('book-1');
      expect(kept.map((e) => e.eventId), ['keep-1', 'keep-2']);
      expect(await SettingsStore(v3).serverUrl(), 'http://nas.local:8787');
      final index = await v3
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?",
              variables: [const Variable<String>(AppDatabase.bookHlcIndex)])
          .get();
      expect(index, hasLength(1));
      final version = await v3.customSelect('PRAGMA user_version').getSingle();
      expect(version.data.values.single, 3);
      await v3.close();
    });
  });
}
