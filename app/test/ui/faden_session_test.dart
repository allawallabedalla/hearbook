// Tests ui/faden_session.dart's provider-level wiring:
// - FadenStarter (E86, E90): the search learns only from nights -- a
//   session in the night window or one the sleep timer ended; by day no
//   onset is recorded (and so nothing goes to Health).
// - the play from outside (E86, the audit's finding 1): where the search is
//   the main button, a play from the lock screen or headphones starts it
//   instead of playing; by day without a timer, and in the car, it plays.
// A fake probe player keeps real audio out.

import 'package:faden/audio/probe_player.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/pause_reason.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/domain/resolver.dart';
import 'package:faden/ui/faden_session.dart';
import 'package:faden/ui/providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'fake_audio_handler.dart';

const _manifest = Manifest(manifestId: 'm1', files: [
  ManifestFile(idx: 0, fileHash: 'h0', durationMs: 60 * 60000),
  ManifestFile(idx: 1, fileHash: 'h1', durationMs: 60 * 60000),
]);

BookState _state({required bool night, required PauseReason reason}) => BookState(
      position: const Position(fileHash: 'h1', offsetMs: 0),
      globalMs: 60 * 60000,
      lastAwake: const Position(fileHash: 'h0', offsetMs: 10 * 60000),
      stop: const Position(fileHash: 'h1', offsetMs: 0),
      sleepSuspected: true,
      history: const [],
      finished: false,
      needsConfirmation: false,
      sessionId: 's1',
      inNightWindow: night,
      stopReason: reason,
    );

class _SilentProbePlayer implements ProbePlayer {
  @override
  void open(List<ja.IndexedAudioSource> sources) {}
  @override
  Future<void> playTone() async {}
  @override
  Future<void> playCue(FadenCue cue) async {}
  @override
  Future<void> setKeepAlive(bool on) async {}
  @override
  Future<void> playProbe({
    required int fileIndex,
    required int offsetMs,
    required int probeLenMs,
    required int fileDurationMs,
    void Function()? onPlaying,
  }) async =>
      onPlaying?.call();
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

/// Builds sessions with a silent probe player.
class _TestStarter extends FadenStarter {
  _TestStarter(super.ref);

  @override
  ProbePlayer? get probePlayerForTests => _SilentProbePlayer();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );

  late AppDatabase db;
  late FakeAudioHandler handler;
  late PlayerSessionController session;
  late ProviderContainer container;

  Future<void> setUpContainer(WidgetTester tester, BookState state, {bool car = false}) async {
    await tester.runAsync(() async {
      db = AppDatabase.memory();
      final journal = Journal(db);
      handler = _CarHandler(journal, car: car)..fakeLoadedBookId = 'book-1';
      session = PlayerSessionController(handler: handler, journal: journal, settings: SettingsStore(db))
        ..bookId = 'book-1'
        ..manifest = _manifest
        ..playlistSources = const []
        ..bookState = state;
      container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(db),
        audioHandlerProvider.overrideWithValue(handler),
        playerSessionProvider.overrideWith((ref) => session),
        fadenStarterProvider.overrideWith(_TestStarter.new),
      ]);
    });
  }

  Future<void> tearDownContainer(WidgetTester tester) async {
    await tester.runAsync(() async {
      await container.read(fadenSessionProvider)?.cancel();
      container.dispose();
      await handler.dispose();
      await db.close();
    });
  }

  group('FadenStarter learns only from nights (E90)', () {
    for (final (name, state, learns) in [
      ('in the night window', _state(night: true, reason: PauseReason.unconscious), true),
      ('ended by the sleep timer by day', _state(night: false, reason: PauseReason.timer), true),
      ('an unconscious pause by day', _state(night: false, reason: PauseReason.unconscious), false),
    ]) {
      testWidgets('$name: ${learns ? 'learns' : 'does not learn'}', (tester) async {
        await setUpContainer(tester, state);
        final faden = await tester.runAsync(() => container.read(fadenStarterProvider).fromBookState());
        expect(faden, isNotNull);
        expect(faden!.lo, 10 * 60000);
        expect(faden.hi, 60 * 60000);
        expect(faden.controller.onChosen != null, learns);
        await tearDownContainer(tester);
      });
    }
  });

  group('a play from outside (E86)', () {
    testWidgets('at night / after the timer it starts the search instead of playing', (tester) async {
      await setUpContainer(tester, _state(night: false, reason: PauseReason.timer));
      container.read(fadenRemotePlayWiringProvider);
      final took = await tester.runAsync(() => handler.onRemotePlay!());
      expect(took, isTrue);
      expect(container.read(fadenSessionProvider), isNotNull);
      expect(handler.fadenModeActive, isTrue, reason: 'the next press answers probe 1');
      await tearDownContainer(tester);
    });

    testWidgets('by day without a timer it just plays', (tester) async {
      await setUpContainer(tester, _state(night: false, reason: PauseReason.unconscious));
      container.read(fadenRemotePlayWiringProvider);
      final took = await tester.runAsync(() => handler.onRemotePlay!());
      expect(took, isFalse);
      expect(container.read(fadenSessionProvider), isNull);
      await tearDownContainer(tester);
    });

    testWidgets('never in the car', (tester) async {
      await setUpContainer(tester, _state(night: true, reason: PauseReason.timer), car: true);
      container.read(fadenRemotePlayWiringProvider);
      final took = await tester.runAsync(() => handler.onRemotePlay!());
      expect(took, isFalse);
      await tearDownContainer(tester);
    });
  });
}

class _CarHandler extends FakeAudioHandler {
  final bool car;

  _CarHandler(super.journal, {required this.car});

  @override
  bool get carRoute => car;
}
