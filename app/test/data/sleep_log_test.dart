// Tests data/sleep_log.dart (decisions E79, E82): a recognised passage
// from the Faden search becomes a locally stored sleep onset (wall clock
// via the session's heartbeats), and -- only with the setting on -- one
// "Im Bett" sample in Health, never over existing sleep data. Invariant 7:
// nothing is journaled.

import 'package:faden/core/hlc.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/data/sleep_health_writer.dart';
import 'package:faden/data/sleep_log.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/sleep_learning.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHealthWriter implements SleepHealthWriter {
  @override
  bool isSupported = true;
  bool allowed = true;
  bool overlapping = false;
  bool permissionRequested = false;
  final List<({int start, int end})> written = [];
  final List<({int start, int end})> overlapChecks = [];

  @override
  Future<bool> requestPermission() async {
    permissionRequested = true;
    return allowed;
  }

  @override
  Future<bool> canWrite() async => allowed;

  @override
  Future<bool> hasSleepOverlapping({required int startWallMs, required int endWallMs}) async {
    overlapChecks.add((start: startWallMs, end: endWallMs));
    return overlapping;
  }

  @override
  Future<bool> writeInBed({required int startWallMs, required int endWallMs}) async {
    written.add((start: startWallMs, end: endWallMs));
    return true;
  }
}

const _manifest = Manifest(manifestId: 'm1', files: [
  ManifestFile(idx: 0, fileHash: 'f1', durationMs: 3600000),
  ManifestFile(idx: 1, fileHash: 'f2', durationMs: 3600000),
]);

/// 2024-01-02 22:00 UTC.
const int _t0 = 1704232800000;
var _n = 0;

Event _e(EventType type, int offsetMs, int wallMs,
        {String session = 's1', EventSource source = EventSource.ui, String book = 'b1'}) =>
    Event(
      eventId: 'e${_n++}',
      deviceId: 'd',
      sessionId: session,
      bookId: book,
      manifestId: 'm1',
      type: type,
      fileHash: 'f1',
      offsetMs: offsetMs,
      hlc: Hlc(pt: wallMs, c: 0),
      wallMs: wallMs,
      tzMin: 60,
      source: source,
    );

void main() {
  late AppDatabase db;
  late Journal journal;
  late SettingsStore settings;
  late FakeHealthWriter writer;
  late SleepLog log;

  setUp(() async {
    db = AppDatabase.memory();
    journal = Journal(db);
    settings = SettingsStore(db);
    writer = FakeHealthWriter();
    log = SleepLog(settings: settings, journal: journal, healthWriter: writer);
    // PLAY at 22:00, heartbeats every 5 s for 40 min, then a media-button
    // pause with SLEEP_HINT; at 06:30 a touch (AWAKE in a detached session),
    // probes in the old session, then the RESUME.
    await journal.record(_e(EventType.play, 0, _t0), () async {});
    for (var s = 5; s <= 40 * 60; s += 5) {
      await journal.record(_e(EventType.heartbeat, s * 1000, _t0 + s * 1000), () async {});
    }
    await journal.record(_e(EventType.pause, 2400000, _t0 + 2400000, source: EventSource.system), () async {});
    await journal.record(_e(EventType.sleepHint, 2400000, _t0 + 2400001, source: EventSource.system), () async {});
    const morning = _t0 + 8 * 3600000 + 30 * 60000;
    await journal.record(_e(EventType.awake, 2400000, morning, session: 'detached'), () async {});
    await journal.record(_e(EventType.probe, 1000000, morning + 60000, source: EventSource.faden), () async {});
    await journal.record(_e(EventType.resume, 1200000, morning + 120000, session: 's2', source: EventSource.faden),
        () async {});
  });

  tearDown(() => db.close());

  Future<void> choose(int globalMs, {bool recognised = true}) => log.recordChoice(
        bookId: 'b1',
        sessionId: 's1',
        manifest: _manifest,
        loGlobalMs: 0,
        chosenGlobalMs: globalMs,
        recognised: recognised,
      );

  test('a recognised passage becomes an onset: wall clock via heartbeats, listening time, wake time', () async {
    final before = await journal.eventsForBook('b1');
    await choose(1200000); // 20 min into the session
    final onsets = await log.onsets();
    expect(onsets, hasLength(1));
    final o = onsets.single;
    expect(o.sessionId, 's1');
    expect(o.onsetWallMs, _t0 + 1200000);
    expect(o.listenMs, 1200000);
    expect(o.tzMin, 60);
    expect(o.localDate, '2024-01-02'); // 22:20 local
    expect(o.wakeWallMs, _t0 + 8 * 3600000 + 30 * 60000, reason: 'the morning touch, not the probes');
    expect(await journal.eventsForBook('b1'), hasLength(before.length), reason: 'invariant 7: no events');
  });

  test('"Früher" replaces the onset of the same session; the fallback to lo removes it', () async {
    await choose(1200000);
    await choose(900000);
    expect((await log.onsets()).single.onsetWallMs, _t0 + 900000);
    await choose(0, recognised: false);
    expect(await log.onsets(), isEmpty);
  });

  test('nothing without a way back to the wall clock', () async {
    await choose(3 * 3600000); // never played in this session
    expect(await log.onsets(), isEmpty);
  });

  test('five onsets give a learned prior', () async {
    expect(await log.learnedPriorFor(lo: 0, hi: 3600000), isNull);
    await choose(600000);
    final first = (await log.onsets()).single;
    await settings.setSleepOnsetsJson(encodeOnsets([
      first,
      for (var i = 1; i < 5; i++)
        SleepOnsetRecord.fromJson({...first.toJson(), 'session_id': 'other$i', 'onset_wall_ms': first.onsetWallMs + i}),
    ]));
    expect(await log.learnedPriorFor(lo: 60000, hi: 3600000), 60000 + 600000);
  });

  group('Health (E82)', () {
    test('off by default: nothing written, nothing read', () async {
      await choose(1200000);
      expect(writer.written, isEmpty);
      expect(writer.overlapChecks, isEmpty);
    });

    test('with the setting on: one "Im Bett" from the onset to the morning touch', () async {
      await settings.setHealthWriteOptIn(true);
      await choose(1200000);
      expect(writer.written, [(start: _t0 + 1200000, end: _t0 + 8 * 3600000 + 30 * 60000)]);
      expect((await log.onsets()).single.healthWritten, isTrue);
      await choose(900000); // "Früher": the night is not written twice
      expect(writer.written, hasLength(1));
      expect((await log.onsets()).single.healthWritten, isTrue);
    });

    test('skipped when Health already has sleep for that night', () async {
      await settings.setHealthWriteOptIn(true);
      writer.overlapping = true;
      await choose(1200000);
      expect(writer.overlapChecks, hasLength(1));
      expect(writer.written, isEmpty);
      expect((await log.onsets()).single.healthWritten, isFalse);
    });

    test('skipped without write permission or off iOS', () async {
      await settings.setHealthWriteOptIn(true);
      writer.allowed = false;
      await choose(1200000);
      expect(writer.written, isEmpty);
      writer
        ..allowed = true
        ..isSupported = false;
      await choose(1100000);
      expect(writer.written, isEmpty);
    });

    test('skipped when the night is shorter than 30 min', () async {
      await settings.setHealthWriteOptIn(true);
      // A second session: fell asleep at 14:00, picked up at 14:20.
      const t = _t0 + 16 * 3600000;
      await journal.record(_e(EventType.play, 0, t, session: 's3', book: 'b2'), () async {});
      for (var s = 5; s <= 600; s += 5) {
        await journal.record(_e(EventType.heartbeat, s * 1000, t + s * 1000, session: 's3', book: 'b2'), () async {});
      }
      await journal.record(_e(EventType.pause, 600000, t + 600000, session: 's3', book: 'b2', source: EventSource.system),
          () async {});
      await journal.record(_e(EventType.resume, 300000, t + 20 * 60000, session: 's4', book: 'b2'), () async {});
      await log.recordChoice(
        bookId: 'b2',
        sessionId: 's3',
        manifest: _manifest,
        loGlobalMs: 0,
        chosenGlobalMs: 300000,
        recognised: true,
      );
      expect((await log.onsets()).where((o) => o.sessionId == 's3'), hasLength(1));
      expect(writer.written, isEmpty);
    });
  });
}
