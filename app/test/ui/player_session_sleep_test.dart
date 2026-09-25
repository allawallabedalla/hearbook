// Tests ui/providers.dart's `PlayerSessionController.sleepOnsetAdjustment`,
// the M6 orchestration layer (docs/ARCHITEKTUR.md section 9) that sits
// between data/sleep_data_source.dart (an untrusted local reading) and
// domain/sleep_onset.dart (the pure hi/prior formula): opt-in gating,
// platform support, permission, filtering the journal down to the winning
// session's own events, and -- the single most safety-critical property of
// this milestone, CLAUDE.md invariant 7 -- that none of it ever adds
// anything to the journal.
//
// Uses a real FadenAudioHandler/Journal/AppDatabase, same setup as
// test/audio/handler_test.dart (no `openBook()`, no real platform channel
// touched), plus a fake SleepDataSource this file defines itself (no real
// `health` plugin instance is ever constructed in tests -- see
// data/sleep_data_source.dart's own doc comment on why).

import 'package:faden/audio/handler.dart';
import 'package:faden/core/hlc.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/data/sleep_data_source.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/domain/resolver.dart';
import 'package:faden/ui/providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSleepDataSource implements SleepDataSource {
  bool supported = true;
  bool permissionGranted = true;
  int? onsetWallMs;

  int permissionRequests = 0;
  int readCalls = 0;
  int? lastFromWallMs;
  int? lastToWallMs;

  @override
  bool get isSupported => supported;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permissionGranted;
  }

  @override
  Future<int?> sleepOnsetWallMs({required int fromWallMs, required int toWallMs}) async {
    readCalls++;
    lastFromWallMs = fromWallMs;
    lastToWallMs = toWallMs;
    return onsetWallMs;
  }
}

Event _event({
  required String id,
  required EventType type,
  required String sessionId,
  required int wallMs,
  int offsetMs = 0,
  String fileHash = 'f1',
  String bookId = 'book-1',
}) =>
    Event(
      eventId: id,
      deviceId: 'dev-a',
      sessionId: sessionId,
      bookId: bookId,
      manifestId: 'm1',
      type: type,
      fileHash: fileHash,
      offsetMs: offsetMs,
      hlc: Hlc(pt: wallMs, c: 0),
      wallMs: wallMs,
      tzMin: 0,
      source: EventSource.ui,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );

  const bookId = 'book-1';
  const winningSessionId = 's1';
  final manifest = const Manifest(
    manifestId: 'm1',
    files: [ManifestFile(idx: 0, fileHash: 'f1', durationMs: 100 * 60000)],
  );

  late AppDatabase db;
  late Journal journal;
  late FadenAudioHandler handler;
  late PlayerSessionController session;
  late _FakeSleepDataSource dataSource;

  BookState fakeState() => BookState(
        position: const Position(fileHash: 'f1', offsetMs: 0),
        globalMs: 0,
        lastAwake: const Position(fileHash: 'f1', offsetMs: 0),
        stop: const Position(fileHash: 'f1', offsetMs: 40 * 60000),
        sleepSuspected: true,
        history: const [],
        finished: false,
        needsConfirmation: false,
        sessionId: winningSessionId,
      );

  setUp(() async {
    db = AppDatabase.memory();
    journal = Journal(db);
    handler = FadenAudioHandler(journal: journal, deviceId: 'dev-a');
    session = PlayerSessionController(handler: handler, journal: journal);
    session.bookId = bookId;
    session.manifest = manifest;
    session.bookState = fakeState();
    dataSource = _FakeSleepDataSource();

    // The winning session: a PLAY at wallMs 0, then a steady HEARTBEAT
    // every simulated minute up to wallMs 40 min (offset_ms == wallMs,
    // single file, so global ms == wallMs throughout -- a readable 1x
    // mapping for the expectations below).
    await journal.record(
      _event(id: 'e-play', type: EventType.play, sessionId: winningSessionId, wallMs: 0),
      () async {},
    );
    for (var t = 60000; t <= 40 * 60000; t += 60000) {
      await journal.record(
        _event(
          id: 'e-hb-$t',
          type: EventType.heartbeat,
          sessionId: winningSessionId,
          wallMs: t,
          offsetMs: t,
        ),
        () async {},
      );
    }
    // A losing/older session with its own (wider) HEARTBEAT range -- must
    // never affect the winning session's own min/max wallMs or heartbeats.
    await journal.record(
      _event(
        id: 'e-hb-other',
        type: EventType.heartbeat,
        sessionId: 's0',
        wallMs: 999 * 60000,
        offsetMs: 0,
      ),
      () async {},
    );
  });

  tearDown(() async {
    await handler.dispose();
    await db.close();
  });

  test('opt-in off -> null, and the plugin is never touched at all', () async {
    final result = await session.sleepOnsetAdjustment(
      dataSource: dataSource,
      optedIn: false,
      lo: 0,
      hi: 40 * 60000,
    );
    expect(result, isNull);
    expect(dataSource.permissionRequests, 0);
    expect(dataSource.readCalls, 0);
  });

  test('no data source configured -> null, opted in or not', () async {
    final result = await session.sleepOnsetAdjustment(
      dataSource: null,
      optedIn: true,
      lo: 0,
      hi: 40 * 60000,
    );
    expect(result, isNull);
  });

  test('unsupported platform -> null, permission never requested', () async {
    dataSource.supported = false;
    final result = await session.sleepOnsetAdjustment(
      dataSource: dataSource,
      optedIn: true,
      lo: 0,
      hi: 40 * 60000,
    );
    expect(result, isNull);
    expect(dataSource.permissionRequests, 0);
  });

  test('permission denied -> null, no read attempted', () async {
    dataSource.permissionGranted = false;
    final result = await session.sleepOnsetAdjustment(
      dataSource: dataSource,
      optedIn: true,
      lo: 0,
      hi: 40 * 60000,
    );
    expect(result, isNull);
    expect(dataSource.permissionRequests, 1);
    expect(dataSource.readCalls, 0);
  });

  test('no reading in range -> null', () async {
    dataSource.onsetWallMs = null;
    final result = await session.sleepOnsetAdjustment(
      dataSource: dataSource,
      optedIn: true,
      lo: 0,
      hi: 40 * 60000,
    );
    expect(result, isNull);
    expect(dataSource.readCalls, 1);
  });

  test('reads only the winning session\'s own wallMs range, not the losing session\'s', () async {
    dataSource.onsetWallMs = null; // don't care about the result, just the query bounds
    await session.sleepOnsetAdjustment(
      dataSource: dataSource,
      optedIn: true,
      lo: 0,
      hi: 40 * 60000,
    );
    expect(dataSource.lastFromWallMs, 0);
    expect(dataSource.lastToWallMs, 40 * 60000); // not 999 min from session s0
  });

  test('happy path: computes hi/prior from the winning session\'s own heartbeats', () async {
    dataSource.onsetWallMs = 20 * 60000; // T = 20 min
    final result = await session.sleepOnsetAdjustment(
      dataSource: dataSource,
      optedIn: true,
      lo: 0,
      hi: 40 * 60000,
    );
    expect(result, isNotNull);
    expect(result!.hi, 25 * 60000); // min(stop=40, pos(T + 5 Min)=25)
    expect(result.prior, 10 * 60000); // pos(T - 10 Min)=10, > lo=0
  });

  test(
    'CLAUDE.md invariant 7: sleepOnsetAdjustment never adds, changes or removes '
    'anything in the journal, however the reading comes out',
    () async {
      dataSource.onsetWallMs = 20 * 60000;
      final before = await journal.eventsForBook(bookId);

      final result = await session.sleepOnsetAdjustment(
        dataSource: dataSource,
        optedIn: true,
        lo: 0,
        hi: 40 * 60000,
      );
      expect(result, isNotNull); // sanity: this run actually did something

      final after = await journal.eventsForBook(bookId);
      expect(after.length, before.length);
      expect(
        after.map((e) => e.eventId).toList(),
        before.map((e) => e.eventId).toList(),
      );
      expect(
        after.map((e) => e.toJson()).toList(),
        before.map((e) => e.toJson()).toList(),
      );
    },
  );

  group('the Resolver uses the night window from the settings (E84)', () {
    test('default 20-06: the session (00:00-00:40) lies in the night window', () async {
      await session.onRemoteEvents();
      expect(session.bookState!.inNightWindow, isTrue);
    });

    test('a window of 12:00-13:00 set by the listener: not in the night window', () async {
      final store = SettingsStore(db);
      await store.setNightStartMin(12 * 60);
      await store.setNightEndMin(13 * 60);
      final withSettings = PlayerSessionController(handler: handler, journal: journal, settings: store)
        ..bookId = bookId
        ..manifest = manifest;
      await withSettings.onRemoteEvents();
      expect(withSettings.bookState!.inNightWindow, isFalse);
      withSettings.dispose();
    });
  });
}
