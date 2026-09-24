// Tests the playback-core additions to audio/handler.dart: lock-screen
// seek (E43), auto-rewind (E32), interruption routing (E36), pausing the
// old book on a switch (E41), sync sharing and the remote take-over (E31),
// and eventsWritten carrying the event (E40). Same setup as
// handler_test.dart: a real handler over an in-memory journal, books opened
// with an empty source list so no platform channel is touched.

import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:dio/dio.dart';
import 'package:faden/audio/handler.dart';
import 'package:faden/audio/undo_hint.dart';
import 'package:faden/core/clock.dart';
import 'package:faden/core/hlc.dart';
import 'package:faden/data/api.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/sync.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/l10n/strings.dart';
import 'package:faden/ui/providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeClock implements Clock {
  int ms = 1000000000;

  @override
  int nowMs() => ms;

  @override
  int tzOffsetMin() => 60;
}

/// Lets a test decide what "playing" reports (a real player never plays
/// here, see handler_test.dart).
class _Handler extends FadenAudioHandler {
  _Handler({required super.journal, required super.clock, super.syncClient}) : super(deviceId: 'dev-a');

  bool fakePlaying = false;

  @override
  bool get playing => fakePlaying;
}

const _manifest = Manifest(manifestId: 'm1', files: [
  ManifestFile(idx: 0, fileHash: 'h0', durationMs: 20 * 60000),
  ManifestFile(idx: 1, fileHash: 'h1', durationMs: 20 * 60000),
]);

Event _remote({
  required String id,
  required EventType type,
  required Position at,
  required int pt,
  String session = 'session-b',
}) =>
    Event(
      eventId: id,
      deviceId: 'dev-b',
      sessionId: session,
      bookId: 'book',
      manifestId: 'm1',
      type: type,
      fileHash: at.fileHash,
      offsetMs: at.offsetMs,
      hlc: Hlc(pt: pt, c: 0),
      wallMs: pt,
      tzMin: 60,
      source: EventSource.ui,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );

  late AppDatabase db;
  late Journal journal;
  late _FakeClock clock;
  late _Handler handler;

  setUp(() {
    db = AppDatabase.memory();
    journal = Journal(db);
    clock = _FakeClock();
    handler = _Handler(journal: journal, clock: clock);
  });

  tearDown(() async {
    await handler.dispose();
    await db.close();
  });

  Future<List<Event>> events([String bookId = 'book']) => journal.eventsForBook(bookId);

  Future<void> openBook({
    String bookId = 'book',
    Position at = const Position(fileHash: 'h1', offsetMs: 10 * 60000),
  }) =>
      handler.openBook(
        bookId: bookId,
        manifest: _manifest,
        bookTitle: 'Buch',
        sources: const [],
        initialPosition: at,
      );

  /// See handler_test.dart `fireAndWaitForJournal`: just_audio's play()
  /// never completes on an empty playlist, the journal write happens first.
  Future<void> fire(Future<void> Function() action) async {
    unawaited(action());
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  group('lock-screen seek (E43)', () {
    test('writes a SEEK within the current chapter', () async {
      await openBook();
      await handler.seek(const Duration(minutes: 11));
      final seek = (await events()).single;
      expect(seek.type, EventType.seek);
      expect(seek.source, EventSource.system);
      expect(seek.position, const Position(fileHash: 'h1', offsetMs: 11 * 60000));
      expect(handler.currentPosition(), seek.position);
    });

    test('a drag over 2 min emits the same undo hint as other seeks', () async {
      await openBook();
      final hints = <UndoHint>[];
      final sub = handler.undoHints.listen(hints.add);
      await handler.seek(const Duration(minutes: 2));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(hints.single.target, const Position(fileHash: 'h1', offsetMs: 10 * 60000));
    });

    test('is clamped to the chapter', () async {
      await openBook();
      await handler.seek(const Duration(hours: 5));
      expect((await events()).single.position, const Position(fileHash: 'h1', offsetMs: 20 * 60000));
    });

    test('is ignored in Faden mode and before a book is open', () async {
      await handler.seek(const Duration(minutes: 1));
      await openBook();
      handler.enterFadenMode();
      await handler.seek(const Duration(minutes: 1));
      expect(await events(), isEmpty);
    });
  });

  group('auto-rewind on play (E32)', () {
    test('after a 6 min pause, PLAY carries the position 10 s earlier', () async {
      await openBook();
      await handler.pauseFrom(EventSource.ui);
      clock.ms += 6 * 60000;
      await fire(() => handler.playFrom(EventSource.ui));
      final play = (await events()).last;
      expect(play.type, EventType.play);
      expect(play.position, const Position(fileHash: 'h1', offsetMs: 10 * 60000 - 10000));
    });

    test('no rewind after a pause under 10 s', () async {
      await openBook();
      await handler.pauseFrom(EventSource.ui);
      clock.ms += 9000;
      await fire(() => handler.playFrom(EventSource.mediaButton));
      expect((await events()).last.position, const Position(fileHash: 'h1', offsetMs: 10 * 60000));
    });

    test('rewinds across the chapter boundary, never before the start of the book', () async {
      await openBook(at: const Position(fileHash: 'h1', offsetMs: 5000));
      await handler.pauseFrom(EventSource.ui);
      clock.ms += 2 * 60 * 60000;
      await fire(() => handler.playFrom(EventSource.ui));
      expect((await events()).last.position, const Position(fileHash: 'h0', offsetMs: 20 * 60000 - 25000));

      await handler.dispose();
      handler = _Handler(journal: journal, clock: clock);
      await openBook(bookId: 'other', at: const Position(fileHash: 'h0', offsetMs: 4000));
      await handler.pauseFrom(EventSource.ui);
      clock.ms += 2 * 60 * 60000;
      await fire(() => handler.playFrom(EventSource.ui));
      expect((await events('other')).last.position, const Position(fileHash: 'h0', offsetMs: 0));
    });

    test('a pause spanning an app restart counts from the book\'s newest event', () async {
      await journal.record(
        _remote(id: 'old', type: EventType.pause, at: const Position(fileHash: 'h1', offsetMs: 600000), pt: clock.ms),
        () async {},
      );
      clock.ms += 2 * 60 * 60000;
      await openBook();
      await fire(() => handler.playFrom(EventSource.ui));
      expect((await events()).last.position, const Position(fileHash: 'h1', offsetMs: 10 * 60000 - 30000));
    });

    test('no rewind after an explicit seek while paused', () async {
      await openBook();
      await handler.pauseFrom(EventSource.ui);
      clock.ms += 6 * 60000;
      await handler.seekBySeconds(-30);
      await fire(() => handler.playFrom(EventSource.ui));
      expect((await events()).last.position, const Position(fileHash: 'h1', offsetMs: 10 * 60000 - 30000));
    });

    test('never for "Ab Stopp weiterhören" / Faden-Suche results', () async {
      await openBook();
      await handler.pauseFrom(EventSource.ui);
      clock.ms += 3 * 60 * 60000;
      await handler.resumeFromStop(const Position(fileHash: 'h1', offsetMs: 9 * 60000), fileIndex: 1);
      final resume = (await events()).last;
      expect(resume.type, EventType.resume);
      expect(resume.position, const Position(fileHash: 'h1', offsetMs: 9 * 60000));
    });
  });

  group('audio-session interruptions (E36)', () {
    late StreamController<AudioInterruptionEvent> interruptions;
    late StreamController<void> noisy;

    setUp(() {
      interruptions = StreamController<AudioInterruptionEvent>();
      noisy = StreamController<void>();
      handler.attachAudioSessionEvents(interruptions: interruptions.stream, becomingNoisy: noisy.stream);
    });

    tearDown(() async {
      await interruptions.close();
      await noisy.close();
    });

    test('a call pauses (journaled) and its end resumes with a rewind', () async {
      await openBook();
      handler.fakePlaying = true;
      interruptions.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      handler.fakePlaying = false;
      expect((await events()).single.type, EventType.pause);
      expect((await events()).single.source, EventSource.system);

      clock.ms += 60000;
      interruptions.add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final play = (await events()).last;
      expect(play.type, EventType.play);
      expect(play.source, EventSource.system);
      expect(play.offsetMs, 10 * 60000 - 3000);
    });

    test('an "unknown" interruption pauses but never resumes by itself', () async {
      await openBook();
      handler.fakePlaying = true;
      interruptions.add(AudioInterruptionEvent(true, AudioInterruptionType.unknown));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      handler.fakePlaying = false;
      interruptions.add(AudioInterruptionEvent(false, AudioInterruptionType.unknown));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await events()).map((e) => e.type), [EventType.pause]);
    });

    test('nothing is written when nothing plays', () async {
      await openBook();
      interruptions.add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      noisy.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await events(), isEmpty);
    });

    test('unplugging the headphones pauses, journaled', () async {
      await openBook();
      handler.fakePlaying = true;
      noisy.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final pause = (await events()).single;
      expect(pause.type, EventType.pause);
      expect(pause.source, EventSource.system);
    });
  });

  test('switching books while playing pauses the old book first (E41)', () async {
    await openBook(bookId: 'old-book');
    handler.fakePlaying = true;
    await openBook(bookId: 'new-book');
    final pause = (await events('old-book')).single;
    expect(pause.type, EventType.pause);
    expect(pause.source, EventSource.ui);
    expect(await events('new-book'), isEmpty);
    expect(handler.bookId, 'new-book');
  });

  test('eventsWritten carries each event, so listeners can skip heartbeats (E40)', () async {
    final written = <Event>[];
    final sub = handler.eventsWritten.listen(written.add);
    await handler.awake();
    await handler.pauseFrom(EventSource.ui);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(written.map((e) => e.type), [EventType.awake, EventType.pause]);
  });

  test('remembers an unreachable server until a sync succeeds again', () async {
    var reachable = false;
    final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, h) {
      if (!reachable) {
        h.reject(DioException.connectionError(requestOptions: options, reason: 'NAS off'));
        return;
      }
      h.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: options.method == 'POST'
            ? {'accepted': 0, 'duplicates': 0, 'max_seq': null}
            : {'events': [], 'has_more': false},
      ));
    }));
    await handler.dispose();
    handler = _Handler(journal: journal, clock: clock, syncClient: SyncClient(db: db, journal: journal, api: ApiClient(dio)));

    expect(handler.lastSyncFailed, isFalse);
    await handler.syncNow();
    expect(handler.lastSyncFailed, isTrue);
    reachable = true;
    await handler.syncNow();
    expect(handler.lastSyncFailed, isFalse);
  });

  group('remote take-over (E31)', () {
    test('adoptRemotePosition moves the paused player and offers the way back', () async {
      await openBook();
      final hints = <UndoHint>[];
      final sub = handler.undoHints.listen(hints.add);
      final moved = await handler.adoptRemotePosition(const Position(fileHash: 'h0', offsetMs: 60000));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(moved, isTrue);
      expect(handler.currentPosition(), const Position(fileHash: 'h0', offsetMs: 60000));
      expect(hints.single.message, AppStrings.remotePositionAdopted);
      expect(hints.single.target, const Position(fileHash: 'h1', offsetMs: 10 * 60000));
      expect(await events(), isEmpty); // the remote events already decided it
    });

    test('never while playing', () async {
      await openBook();
      handler.fakePlaying = true;
      expect(await handler.adoptRemotePosition(const Position(fileHash: 'h0', offsetMs: 0)), isFalse);
    });

    test('a sync that pulls another device\'s SEEK moves the prepared player, with an undo hint',
        () async {
      final remotePt = clock.ms + 1000;
      var pulls = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, h) {
        if (options.method == 'POST') {
          h.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'accepted': 0, 'duplicates': 0, 'max_seq': null},
          ));
          return;
        }
        pulls++;
        h.resolve(Response(requestOptions: options, statusCode: 200, data: {
          'events': [
            {
              ..._remote(
                id: 'remote-seek',
                type: EventType.seek,
                at: const Position(fileHash: 'h0', offsetMs: 90000),
                pt: remotePt,
              ).toJson(),
              'seq': 1,
              'skew_flag': false,
            },
          ],
          'has_more': false,
        }));
      }));
      await handler.dispose();
      handler = _Handler(
        journal: journal,
        clock: clock,
        syncClient: SyncClient(db: db, journal: journal, api: ApiClient(dio)),
      );
      final session = PlayerSessionController(handler: handler, journal: journal);
      await handler.openBook(
        bookId: 'book',
        manifest: _manifest,
        bookTitle: 'Buch',
        sources: const [],
        initialPosition: const Position(fileHash: 'h1', offsetMs: 10 * 60000),
        syncAfterOpen: false,
      );
      session
        ..bookId = 'book'
        ..manifest = _manifest;

      final hints = <UndoHint>[];
      final sub = handler.undoHints.listen(hints.add);
      final summary = await handler.syncNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();

      expect(pulls, 1);
      expect(summary!.pulledBookIds, {'book'});
      expect(session.bookState!.position, const Position(fileHash: 'h0', offsetMs: 90000));
      expect(handler.currentPosition(), const Position(fileHash: 'h0', offsetMs: 90000));
      expect(hints.single.message, AppStrings.remotePositionAdopted);

      // One tap back: an UNDO that now wins as the newest intent.
      await handler.undo(hints.single.target);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(session.bookState!.position, const Position(fileHash: 'h1', offsetMs: 10 * 60000));
      session.dispose();
    });
  });

  group('syncNow', () {
    test('shares a running sync and gives up waiting after the timeout', () async {
      final gate = Completer<void>();
      var pushes = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, h) async {
        if (options.method == 'POST') pushes++;
        await gate.future;
        h.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {'events': <dynamic>[], 'has_more': false},
        ));
      }));
      await handler.dispose();
      handler = _Handler(
        journal: journal,
        clock: clock,
        syncClient: SyncClient(db: db, journal: journal, api: ApiClient(dio)),
      );

      final first = handler.syncNow();
      final second = handler.syncNow(timeout: const Duration(milliseconds: 10));
      expect(await second, isNull); // timed out, sync carries on
      gate.complete();
      expect(await first, isNotNull);
      expect(pushes, 0); // nothing to push; one shared pull
    });

    test('returns null without a server', () async {
      expect(await handler.syncNow(), isNull);
    });
  });
}
