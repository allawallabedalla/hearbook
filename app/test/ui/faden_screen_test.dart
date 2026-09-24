// Tests ui/faden_screen.dart being left by a back gesture / route pop while
// the Faden-Suche is still running (no result, no long-press): the search
// must end silently (no further PROBE, no RESUME, no playback start, no
// exception), the probe must stop, and the audio handler must leave Faden
// mode so media buttons act normally again. Uses a real FadenAudioHandler
// over an in-memory journal (no openBook(), see test/audio/handler_test.dart)
// and a fake probe player instead of real platform audio.

import 'package:faden/audio/handler.dart';
import 'package:faden/audio/probe_player.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/ui/faden_screen.dart';
import 'package:faden/ui/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;

class _FakeProbePlayer implements ProbePlayer {
  int tones = 0;
  final List<({int fileIndex, int offsetMs, int fileDurationMs})> probes = [];
  int stops = 0;
  bool disposed = false;

  @override
  void open(List<ja.IndexedAudioSource> sources) {}

  @override
  Future<void> playTone() async => tones++;

  @override
  Future<void> playProbe({
    required int fileIndex,
    required int offsetMs,
    required int probeLenMs,
    required int fileDurationMs,
  }) async {
    probes.add((fileIndex: fileIndex, offsetMs: offsetMs, fileDurationMs: fileDurationMs));
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async => disposed = true;
}

const _manifest = Manifest(manifestId: 'm1', files: [
  ManifestFile(idx: 0, fileHash: 'h0', durationMs: 20 * 60000),
  ManifestFile(idx: 1, fileHash: 'h1', durationMs: 25 * 60000),
]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );

  testWidgets('popping the Faden screen mid-search stops the search and leaves Faden mode',
      (tester) async {
    // Created outside the fake-async zone: the real just_audio player and
    // drift database behind the handler need real async to dispose/query.
    late final AppDatabase db;
    late final Journal journal;
    late final FadenAudioHandler handler;
    await tester.runAsync(() async {
      db = AppDatabase.memory();
      journal = Journal(db);
      handler = FadenAudioHandler(journal: journal, deviceId: 'dev-a');
    });
    final probePlayer = _FakeProbePlayer();
    final navigatorKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [audioHandlerProvider.overrideWithValue(handler)],
        child: MaterialApp(navigatorKey: navigatorKey, home: const Scaffold(body: Text('player'))),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => FadenScreen(
          manifest: _manifest,
          lo: 5 * 60000,
          hi: 40 * 60000,
          pausen: const [],
          playlistSources: const [],
          probePlayer: probePlayer,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(handler.fadenModeActive, isTrue);

    await tester.pump(const Duration(seconds: 1)); // inside probe 1's answer window
    expect(probePlayer.probes, hasLength(1));
    // Probe 1 (hi - 25 s = 39:35 global) lies in h1; its bound is h1's
    // manifest duration (bug fix: not the full probe length when the
    // player's own duration is still unknown).
    expect(probePlayer.probes.single.fileIndex, 1);
    expect(probePlayer.probes.single.fileDurationMs, 25 * 60000);

    navigatorKey.currentState!.pop(); // back gesture, no result
    await tester.pumpAndSettle();
    await tester.pump(const Duration(minutes: 5)); // well past every answer window

    expect(tester.takeException(), isNull);
    expect(find.text('player'), findsOneWidget);
    expect(handler.fadenModeActive, isFalse);
    expect(probePlayer.probes, hasLength(1)); // no further probe
    expect(probePlayer.stops, greaterThanOrEqualTo(1));
    expect(probePlayer.disposed, isTrue);

    await tester.runAsync(() async {
      // No PROBE for the interrupted probe, no RESUME.
      expect(await journal.eventsForBook(''), isEmpty);
      // Media buttons act normally again: a pause is a PAUSE, not an answer.
      await handler.pause();
      final events = await journal.eventsForBook('');
      expect(events.single.type, EventType.pause);
      await handler.dispose();
      await db.close();
    });
  });
}
