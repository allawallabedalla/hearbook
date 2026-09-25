// Tests audio/handler.dart's M5 additions: AWAKE/SLEEP_HINT (docs/ARCHITEKTUR.md
// section 9), PROBE/RESUME (section 8), and the Faden-mode media-button gate
// ("Im Faden-Modus zählt jede Taste als 'kenne ich'"). Uses a real
// FadenAudioHandler over an in-memory Journal/AppDatabase -- no `openBook()`
// call, so the underlying just_audio player never touches a platform channel
// (its playlist stays empty, which keeps it on just_audio's own idle/no-op
// implementation; see the module doc comment on why this is safe).

import 'dart:async';

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
import 'package:faden/domain/pause_reason.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/domain/resolver.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeClock implements Clock {
  int ms = 1000000;
  final int tz = 60;

  @override
  int nowMs() => ms;

  @override
  int tzOffsetMin() => tz;
}

const _manifest = Manifest(manifestId: 'm1', files: [
  ManifestFile(idx: 0, fileHash: 'h0', durationMs: 20 * 60000),
  ManifestFile(idx: 1, fileHash: 'h1', durationMs: 20 * 60000),
]);

/// A SEEK from another device whose clock runs an hour ahead of this one.
Event _remoteSeek({required int pt}) => Event(
      eventId: 'remote-seek',
      deviceId: 'dev-b',
      sessionId: 'session-b',
      bookId: 'book',
      manifestId: 'm1',
      type: EventType.seek,
      fileHash: 'h0',
      offsetMs: 5000,
      hlc: Hlc(pt: pt, c: 3),
      wallMs: pt,
      tzMin: 60,
      source: EventSource.ui,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Keeps package:audio_session's platform channel calls (made once, lazily,
  // the first time any AudioPlayer.play() runs) fast and inert in this
  // headless environment instead of relying on Flutter's default unhandled
  // -channel behaviour. This handler's own play()/pause()/seek() calls stay
  // on just_audio's pure-Dart idle player throughout these tests (no
  // `openBook()` is ever called, so the playlist stays empty and just_audio
  // never attempts a real platform connection of its own) -- see
  // `fireAndWaitForJournal`'s doc comment for the one real quirk this setup
  // does not avoid (a `play()` call on an empty-playlist player never
  // completes, regardless of this mock).
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );

  late AppDatabase db;
  late Journal journal;
  late _FakeClock clock;
  late FadenAudioHandler handler;

  setUp(() {
    db = AppDatabase.memory();
    journal = Journal(db);
    clock = _FakeClock();
    handler = FadenAudioHandler(journal: journal, deviceId: 'dev-a', clock: clock);
  });

  tearDown(() async {
    await handler.dispose();
    await db.close();
  });

  Future<List<Event>> eventsFor(String bookId) => journal.eventsForBook(bookId);

  /// just_audio's real `AudioPlayer.play()` never completes on a player
  /// whose playlist was never populated (`openBook()` is deliberately never
  /// called in this file -- see the module doc comment): its platform-
  /// activation step is skipped for an empty playlist, yet it unconditionally
  /// awaits a completer only that step would fulfil. That is an audio-only
  /// implementation detail this handler is never exposed to in the real app
  /// (a book is always open, with a non-empty playlist, before any of these
  /// M5 methods can run), so it is not itself a product bug -- but it means
  /// a call chain ending in `_player.play()` (docs/ARCHITEKTUR.md section 13)
  /// must never be awaited directly in these tests. [action] is started and
  /// then given a short moment to reach the journal, which -- per invariant
  /// 3 -- always happens strictly before the (here: permanently pending)
  /// player action; the journal write is exactly what these tests assert.
  Future<void> fireAndWaitForJournal(Future<void> Function() action) async {
    unawaited(action());
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  /// `openBook()` with an empty source list: just_audio's `load()` is a
  /// no-op for an empty playlist, so no platform channel is touched, while
  /// the handler still gets its manifest and starting position.
  Future<void> openBook({Position at = const Position(fileHash: 'h1', offsetMs: 10 * 60000)}) =>
      handler.openBook(
        bookId: 'book',
        manifest: _manifest,
        bookTitle: 'Buch',
        sources: const [],
        initialPosition: at,
      );

  group('awake', () {
    test('writes an AWAKE event and rate-limits to 1 per 10s', () async {
      final wrote1 = await handler.awake();
      clock.ms += 4000;
      final wrote2 = await handler.awake();
      clock.ms += 6001; // total 10001ms since the first
      final wrote3 = await handler.awake();

      expect(wrote1, isTrue);
      expect(wrote2, isFalse);
      expect(wrote3, isTrue);

      final events = await eventsFor('');
      expect(events.where((e) => e.type == EventType.awake), hasLength(2));
    });

    test('AWAKE is never an intent event and does not start a session', () async {
      await handler.awake();
      final events = await eventsFor('');
      expect(events.single.type.isIntent, isFalse);
    });
  });

  group('sleepHint', () {
    test('writes a SLEEP_HINT event, never rate-limited', () async {
      await handler.sleepHint(source: EventSource.timer);
      await handler.sleepHint(source: EventSource.timer);
      final events = await eventsFor('');
      expect(events.where((e) => e.type == EventType.sleepHint), hasLength(2));
    });

    test('is not an awake-proof', () {
      const e = EventType.sleepHint;
      expect(e.wireName, 'SLEEP_HINT');
    });
  });

  group('pauseForSleepTimerExpiry', () {
    test('writes PAUSE(source=timer) then SLEEP_HINT(source=timer)', () async {
      await handler.pauseForSleepTimerExpiry();
      final events = await eventsFor('');
      expect(events.map((e) => e.type), [EventType.pause, EventType.sleepHint]);
      expect(events[0].source, EventSource.timer);
      expect(events[1].source, EventSource.timer);
      expect(events[0].isAwakeProof, isFalse); // source != ui
    });
  });

  group('pauseFrom / SLEEP_HINT by pause reason (E80)', () {
    test('a media-button pause writes SLEEP_HINT at any time of day', () async {
      await handler.pauseFrom(EventSource.mediaButton);
      final events = await eventsFor('');
      expect(events.map((e) => e.type), [EventType.pause, EventType.sleepHint]);
      expect(events[0].data, {'reason': 'unconscious'});
      expect(events[1].source, EventSource.mediaButton);
    });

    test('a system pause (AirPods sleep detection, lock screen) too', () async {
      await handler.pauseFrom(EventSource.system);
      final events = await eventsFor('');
      expect(events.map((e) => e.type), [EventType.pause, EventType.sleepHint]);
    });

    test('no SLEEP_HINT for a UI pause', () async {
      await handler.pauseFrom(EventSource.ui);
      final events = await eventsFor('');
      expect(events.map((e) => e.type), [EventType.pause]);
      expect(events.single.data, {'reason': 'conscious'});
    });

    test('no SLEEP_HINT for a lost connection or an interruption', () async {
      await handler.pauseFrom(EventSource.system, reason: PauseReason.routeLost);
      await handler.pauseFrom(EventSource.system, reason: PauseReason.interruption);
      final events = await eventsFor('');
      expect(events.map((e) => e.type), [EventType.pause, EventType.pause]);
      expect(events.map((e) => e.data['reason']), ['route_lost', 'interruption']);
    });

    test('bare pause() (framework/hardware entry point) uses source=system', () async {
      await handler.pause();
      final events = await eventsFor('');
      expect(events.first.source, EventSource.system);
      expect(events.map((e) => e.type), [EventType.pause, EventType.sleepHint]);
    });

    test('playPause() takes the play branch with source=ui when not playing', () async {
      // A freshly constructed handler is never playing, so playPause() goes
      // through playFrom(ui) -> _player.play() (see fireAndWaitForJournal).
      await fireAndWaitForJournal(handler.playPause);
      final events = await eventsFor('');
      expect(events.single.type, EventType.play);
      expect(events.single.source, EventSource.ui);
    });
  });

  group('probe', () {
    test('writes a PROBE event with data.known and source=faden', () async {
      await handler.probe(position: const Position(fileHash: 'h1', offsetMs: 5000), known: true);
      await handler.probe(position: const Position(fileHash: 'h1', offsetMs: 2000), known: false);
      final events = await eventsFor('');
      expect(events, hasLength(2));
      expect(events[0].type, EventType.probe);
      expect(events[0].source, EventSource.faden);
      expect(events[0].data['known'], isTrue);
      expect(events[1].data['known'], isFalse);
    });

    test('PROBE is never an intent event and never awake-proof', () async {
      await handler.probe(position: const Position(fileHash: 'h1', offsetMs: 0), known: true);
      final event = (await eventsFor('')).single;
      expect(event.type.isIntent, isFalse);
      expect(event.isAwakeProof, isFalse);
    });
  });

  group('resumeFromFaden / resumeFromStop', () {
    test('resumeFromFaden writes a RESUME event with source=faden', () async {
      await fireAndWaitForJournal(
        () => handler.resumeFromFaden(const Position(fileHash: 'h1', offsetMs: 12000), fileIndex: null),
      );
      final event = (await eventsFor('')).single;
      expect(event.type, EventType.resume);
      expect(event.source, EventSource.faden);
      expect(event.fileHash, 'h1');
      expect(event.offsetMs, 12000);
      expect(event.isAwakeProof, isTrue); // RESUME is always an intent event
    });

    test('resumeFromStop writes a RESUME event with source=ui', () async {
      await fireAndWaitForJournal(
        () => handler.resumeFromStop(const Position(fileHash: 'h2', offsetMs: 500), fileIndex: null),
      );
      final event = (await eventsFor('')).single;
      expect(event.type, EventType.resume);
      expect(event.source, EventSource.ui);
    });

    test('a Faden RESUME over 2 min away emits an undo hint back to the pre-jump position '
        '(invariant 6)', () async {
      await openBook(); // paused at h1 10:00, where the listener fell asleep
      final hints = <UndoHint>[];
      final sub = handler.undoHints.listen(hints.add);

      await handler.resumeFromFaden(const Position(fileHash: 'h1', offsetMs: 2 * 60000), fileIndex: 1);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(hints, hasLength(1));
      expect(hints.single.target, const Position(fileHash: 'h1', offsetMs: 10 * 60000));
      expect(hints.single.message, contains('10:00'));
      final resume = (await eventsFor('book')).single;
      expect(resume.type, EventType.resume);
    });

    test('resumeFromStop over 2 min away also emits an undo hint', () async {
      await openBook(at: const Position(fileHash: 'h0', offsetMs: 60000));
      final hints = <UndoHint>[];
      final sub = handler.undoHints.listen(hints.add);
      await handler.resumeFromStop(const Position(fileHash: 'h1', offsetMs: 0), fileIndex: 1);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(hints.single.target, const Position(fileHash: 'h0', offsetMs: 60000));
    });

    test('a RESUME within 2 min emits no undo hint', () async {
      await openBook();
      final hints = <UndoHint>[];
      final sub = handler.undoHints.listen(hints.add);
      await handler.resumeFromFaden(const Position(fileHash: 'h1', offsetMs: 9 * 60000), fileIndex: 1);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(hints, isEmpty);
    });

    test('RESUME is an intent event (Resolver rule 2/5 dependence)', () {
      expect(EventType.resume.isIntent, isTrue);
    });
  });

  group('Faden-mode media-button gate', () {
    for (final trigger in <String, Future<void> Function(FadenAudioHandler)>{
      'play': (h) => h.play(),
      'pause': (h) => h.pause(),
      'skipToNext': (h) => h.skipToNext(),
      'skipToPrevious': (h) => h.skipToPrevious(),
      'fastForward': (h) => h.fastForward(),
      'rewind': (h) => h.rewind(),
    }.entries) {
      test('${trigger.key}() in Faden mode counts as an answer, not its normal action', () async {
        handler.enterFadenMode();
        final answers = <void>[];
        final sub = handler.fadenModeAnswers.listen(answers.add);

        await trigger.value(handler);

        await sub.cancel();
        expect(answers, hasLength(1));
        // No PLAY/PAUSE/SEEK event was written -- the call was fully
        // intercepted before it could touch the journal or the player.
        expect(await eventsFor(''), isEmpty);
      });
    }

    test('the same six calls behave normally once Faden mode ends', () async {
      handler.enterFadenMode();
      handler.exitFadenMode();
      // pause() (not play(), which -- see fireAndWaitForJournal's doc
      // comment -- never completes on a player with no playlist loaded)
      // still proves the gate lifted correctly: it is one of the same six
      // gated methods and reaches its normal source=system PAUSE action.
      await handler.pause();
      final events = await eventsFor('');
      expect(events.first.type, EventType.pause);
      expect(events.first.source, EventSource.system);
    });

    test('fadenModeActive reflects enter/exit', () {
      expect(handler.fadenModeActive, isFalse);
      handler.enterFadenMode();
      expect(handler.fadenModeActive, isTrue);
      handler.exitFadenMode();
      expect(handler.fadenModeActive, isFalse);
    });
  });

  group('HLC receive rule (docs/ARCHITEKTUR.md section 5)', () {
    test('a stored remote SEEK from a clock running ahead: the next local PLAY still wins', () async {
      final remotePt = clock.ms + 60 * 60000; // other device is an hour ahead
      await journal.storeRemote(_remoteSeek(pt: remotePt));

      await openBook();
      await fireAndWaitForJournal(() => handler.playFrom(EventSource.ui));

      final events = await eventsFor('book');
      final play = events.singleWhere((e) => e.type == EventType.play);
      expect(play.hlc.compareTo(Hlc(pt: remotePt, c: 3)), greaterThan(0));
      final state = resolve(events, _manifest);
      expect(state.position, const Position(fileHash: 'h1', offsetMs: 10 * 60000));
    });

    test('a remote SEEK pulled by sync after the book was opened advances the clock too', () async {
      final remotePt = clock.ms + 60 * 60000;
      final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, h) => h.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'events': [
                  {..._remoteSeek(pt: remotePt).toJson(), 'seq': 1, 'skew_flag': false},
                ],
                'has_more': false,
              },
            ),
          ),
        ),
      );
      await handler.dispose();
      handler = FadenAudioHandler(
        journal: journal,
        deviceId: 'dev-a',
        clock: clock,
        syncClient: SyncClient(db: db, journal: journal, api: ApiClient(dio)),
      );

      await openBook(); // also kicks off a sync, which pulls the remote SEEK
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await eventsFor('book')).map((e) => e.eventId), ['remote-seek']);

      await fireAndWaitForJournal(() => handler.playFrom(EventSource.ui));

      final events = await eventsFor('book');
      final state = resolve(events, _manifest);
      expect(state.position, const Position(fileHash: 'h1', offsetMs: 10 * 60000));
    });

    test('a remote event behind the local clock never moves it backwards', () async {
      await handler.awake(); // local event at clock.ms
      final before = (await eventsFor('')).single.hlc;
      handler.observeHlc(const Hlc(pt: 10, c: 0));
      clock.ms += 1;
      await handler.sleepHint(source: EventSource.ui);
      final after = (await eventsFor('')).last.hlc;
      expect(after.compareTo(before), greaterThan(0));
    });
  });

  group('last-minute sleep-timer extend hook', () {
    test('a media-button call is consumed as an extend and also writes AWAKE', () async {
      handler.onLastMinuteExtend = () => true;
      await handler.pause();
      final events = await eventsFor('');
      expect(events, hasLength(1));
      expect(events.single.type, EventType.awake);
      expect(events.single.source, EventSource.mediaButton);
    });

    test('falls through to the normal action when the hook returns false', () async {
      handler.onLastMinuteExtend = () => false;
      await handler.pause();
      final events = await eventsFor('');
      expect(events.map((e) => e.type), [EventType.pause, EventType.sleepHint]);
    });

    test('Faden-mode gate takes priority over the extend hook', () async {
      handler.enterFadenMode();
      var extendCalled = false;
      handler.onLastMinuteExtend = () {
        extendCalled = true;
        return true;
      };
      final answers = <void>[];
      final sub = handler.fadenModeAnswers.listen(answers.add);
      await handler.pause();
      await sub.cancel();
      expect(answers, hasLength(1));
      expect(extendCalled, isFalse);
    });
  });
}
