// Tests audio/handler.dart's M5 additions: AWAKE/SLEEP_HINT (docs/ARCHITEKTUR.md
// section 9), PROBE/RESUME (section 8), and the Faden-mode media-button gate
// ("Im Faden-Modus zählt jede Taste als 'kenne ich'"). Uses a real
// FadenAudioHandler over an in-memory Journal/AppDatabase -- no `openBook()`
// call, so the underlying just_audio player never touches a platform channel
// (its playlist stays empty, which keeps it on just_audio's own idle/no-op
// implementation; see the module doc comment on why this is safe).

import 'dart:async';

import 'package:faden/audio/handler.dart';
import 'package:faden/core/clock.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/position.dart';
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

  group('pauseFrom / SLEEP_HINT on media/system pause in the night window', () {
    test('a media-button pause in the night window also writes SLEEP_HINT', () async {
      handler.isInNightWindow = () => true;
      await handler.pauseFrom(EventSource.mediaButton);
      final events = await eventsFor('');
      expect(events.map((e) => e.type), [EventType.pause, EventType.sleepHint]);
      expect(events[1].source, EventSource.mediaButton);
    });

    test('a system pause in the night window also writes SLEEP_HINT', () async {
      handler.isInNightWindow = () => true;
      await handler.pauseFrom(EventSource.system);
      final events = await eventsFor('');
      expect(events.map((e) => e.type), [EventType.pause, EventType.sleepHint]);
    });

    test('no SLEEP_HINT outside the night window', () async {
      handler.isInNightWindow = () => false;
      await handler.pauseFrom(EventSource.system);
      final events = await eventsFor('');
      expect(events.map((e) => e.type), [EventType.pause]);
    });

    test('no SLEEP_HINT for a UI pause even in the night window', () async {
      handler.isInNightWindow = () => true;
      await handler.pauseFrom(EventSource.ui);
      final events = await eventsFor('');
      expect(events.map((e) => e.type), [EventType.pause]);
    });

    test('no SLEEP_HINT when isInNightWindow is unset (safe default)', () async {
      await handler.pauseFrom(EventSource.system);
      final events = await eventsFor('');
      expect(events.map((e) => e.type), [EventType.pause]);
    });

    test('bare pause() (framework/hardware entry point) uses source=system', () async {
      await handler.pause();
      final events = await eventsFor('');
      expect(events.single.source, EventSource.system);
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
      expect(events.single.type, EventType.pause);
      expect(events.single.source, EventSource.system);
    });

    test('fadenModeActive reflects enter/exit', () {
      expect(handler.fadenModeActive, isFalse);
      handler.enterFadenMode();
      expect(handler.fadenModeActive, isTrue);
      handler.exitFadenMode();
      expect(handler.fadenModeActive, isFalse);
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
      expect(events.single.type, EventType.pause);
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
