// Tests ui/faden_screen.dart:
// - left by a back gesture / route pop while the Faden-Suche is still
//   running (no result, no long-press): the search must end silently (no
//   further PROBE, no RESUME, no playback start, no exception), the probe
//   must stop, and the audio handler must leave Faden mode so media
//   buttons act normally again. Uses a real FadenAudioHandler over an
//   in-memory journal (no openBook(), see test/audio/handler_test.dart);
// - the visible proposals (decision E64): the probe as a passage card with
//   "Kenne ich" / "Kenne ich nicht", the list of passages heard, "Nochmal
//   hören", no answer from a tap on empty space, abort, and the result
//   with the recognised passages (never later than the result), each a
//   RESUME of its own;
// - no overflow on an iPhone SE and a Pro Max at text scale 1.0 and 1.35.
// All use a fake probe player instead of real platform audio.

import 'package:faden/audio/handler.dart';
import 'package:faden/audio/probe_player.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/faden_search.dart' as fs;
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/l10n/strings.dart';
import 'package:faden/signals/screen_awake.dart';
import 'package:faden/ui/faden_screen.dart';
import 'package:faden/ui/format.dart';
import 'package:faden/ui/providers.dart';
import 'package:faden/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;

class _FakeProbePlayer implements ProbePlayer {
  int tones = 0;
  final List<FadenCue> cues = [];
  final List<bool> keepAlive = [];
  final List<({int fileIndex, int offsetMs, int fileDurationMs})> probes = [];
  final List<int> probeLengths = [];
  int stops = 0;
  bool disposed = false;

  @override
  void open(List<ja.IndexedAudioSource> sources) {}

  @override
  Future<void> playTone() async => tones++;

  @override
  Future<void> playCue(FadenCue cue) async => cues.add(cue);

  @override
  Future<void> setKeepAlive(bool on) async => keepAlive.add(on);

  @override
  Future<void> playProbe({
    required int fileIndex,
    required int offsetMs,
    required int probeLenMs,
    required int fileDurationMs,
    void Function()? onPlaying,
  }) async {
    probes.add((fileIndex: fileIndex, offsetMs: offsetMs, fileDurationMs: fileDurationMs));
    probeLengths.add(probeLenMs);
    onPlaying?.call(); // plays at once
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> dispose() async => disposed = true;
}

/// Records PROBE and RESUME instead of journaling them and moving the main
/// player (the journal's own ordering is tested with the controller and in
/// test/audio/handler_test.dart).
class _RecordingHandler extends FadenAudioHandler {
  _RecordingHandler(Journal journal) : super(journal: journal, deviceId: 'dev-test');

  final List<({Position position, bool known})> probes = [];
  final List<Position> resumes = [];

  @override
  Future<void> probe({required Position position, required bool known}) async =>
      probes.add((position: position, known: known));

  @override
  Future<void> resumeFromFaden(Position target, {required int? fileIndex}) async => resumes.add(target);

  final List<EventSource> plays = [];

  @override
  Future<void> playFrom(EventSource source) async => plays.add(source);
}

class _FakeScreenAwake implements ScreenAwake {
  final List<bool> calls = [];

  @override
  Future<void> keepOn(bool on) async => calls.add(on);
}

/// Eight hours in eight chapters: a night the search cannot narrow to
/// 30 s with 8 probes.
final _longManifest = Manifest(manifestId: 'm-long', files: [
  for (var i = 0; i < 8; i++) ManifestFile(idx: i, fileHash: 'l$i', durationMs: 60 * 60000),
]);

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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // the route's transition
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
      expect(events.first.type, EventType.pause);
      expect(events.where((e) => e.type == EventType.probe), isEmpty);
      await handler.dispose();
      await db.close();
    });
  });

  group('visible proposals (E64)', () {
    const lo = 5 * 60000, hi = 40 * 60000;
    const se = Size(375, 667);
    const proMax = Size(430, 932);

    late AppDatabase db;
    late _RecordingHandler handler;
    late _FakeProbePlayer probePlayer;

    /// The manifest of the running screen ([_longManifest] for a long night).
    var m = _manifest;

    Future<void> pumpFaden(
      WidgetTester tester, {
      Size size = proMax,
      double textScale = 1.0,
      int probeLen = fs.defaultProbeLen,
      ScreenAwake? screenAwake,
      bool longNight = false,
    }) async {
      m = longNight ? _longManifest : _manifest;
      await tester.runAsync(() async {
        db = AppDatabase.memory();
        handler = _RecordingHandler(Journal(db));
      });
      probePlayer = _FakeProbePlayer();
      const dpr = 3.0;
      tester.view.physicalSize = size * dpr;
      tester.view.devicePixelRatio = dpr;
      tester.view.padding = size == se
          ? const FakeViewPadding(top: 20 * dpr)
          : const FakeViewPadding(top: 59 * dpr, bottom: 34 * dpr);
      addTearDown(tester.view.reset);
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioHandlerProvider.overrideWithValue(handler),
            screenAwakeProvider.overrideWithValue(screenAwake),
          ],
          child: MaterialApp(
            navigatorKey: navigatorKey,
            theme: fadenThemeFor(FadenTokens.day),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const Scaffold(body: Text('player')),
          ),
        ),
      );
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => FadenScreen(
            manifest: m,
            lo: lo,
            hi: longNight ? 6 * 60 * 60000 : hi,
            pausen: const [],
            playlistSources: const [],
            probePlayer: probePlayer,
            probeLen: probeLen,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> tearDownFaden(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
      await tester.runAsync(() async {
        await handler.dispose();
        await db.close();
      });
    }

    testWidgets('plays probes of the chosen length and times the window by it (E77)', (tester) async {
      await pumpFaden(tester, probeLen: 4000);
      await tester.pump(const Duration(seconds: 1));
      expect(probePlayer.probeLengths, [4000]);
      await tester.pump(const Duration(milliseconds: 4000 + fs.answerWindow));
      expect(handler.probes.single.known, isFalse, reason: 'window = 4 s + 3 s');
      await tearDownFaden(tester);
    });

    /// Global ms of the [i]-th probe played.
    int probeAt(int i) {
      final probe = probePlayer.probes[i];
      final before = m.files.take(probe.fileIndex).fold(0, (sum, f) => sum + f.durationMs);
      return before + probe.offsetMs;
    }

    String passage(int globalMs) {
      final pos = _manifest.positionForGlobalMs(globalMs);
      return AppStrings.fadenPassage(
        AppStrings.chapterLabel(_manifest.indexOf(pos.fileHash) + 1),
        formatClock(pos.offsetMs),
      );
    }

    Finder heardRows() => find.byWidgetPredicate(
        (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('faden-heard-'));

    Finder alternativeRows() => find.byWidgetPredicate(
        (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('faden-alternative-'));

    Future<void> answer(WidgetTester tester, {required bool known}) async {
      await tester.tap(find.text(known ? AppStrings.fadenKnown : AppStrings.fadenUnknown));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('shows the probe as a passage card with two big answer buttons', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpFaden(tester);
      await tester.pump(const Duration(seconds: 1));
      // "Noch höchstens 7 Fragen" (E89) instead of "Probe 1 von höchstens 8".
      expect(find.text(AppStrings.fadenQuestionsLeft(fs.maxProbes - 1)), findsOneWidget);
      expect(find.text(AppStrings.fadenModePrompt), findsOneWidget);
      // Probe 1 lies 25 s before the stop (40:00 global = chapter 2, 20:00).
      expect(probeAt(0), hi - fs.firstOffset);
      expect(find.text('${AppStrings.chapterLabel(2)} · 19:35'), findsOneWidget);
      expect(find.text(AppStrings.fadenBeforeStop(AppStrings.durationSeconds(25))), findsOneWidget);
      expect(find.bySemanticsLabel(AppStrings.fadenAnswerWindow), findsOneWidget);
      for (final label in [AppStrings.fadenKnown, AppStrings.fadenUnknown]) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
        expect(tester.getSize(find.widgetWithText(OutlinedButton, label)).height,
            greaterThanOrEqualTo(fadenMinTapTarget));
      }
      expect(find.text(AppStrings.fadenReplay), findsOneWidget);
      expect(find.text(AppStrings.fadenAbort), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await tearDownFaden(tester);
    });

    testWidgets('"Kenne ich nicht" answers at once; the next passage follows', (tester) async {
      await pumpFaden(tester);
      await tester.pump(const Duration(seconds: 1));
      await answer(tester, known: false);
      expect(handler.probes.single.known, isFalse);
      expect(probePlayer.probes, hasLength(2), reason: 'no waiting for the rest of the window');
      expect(find.text(AppStrings.fadenQuestionsLeft(fs.maxProbes - 2)), findsOneWidget);
      await tearDownFaden(tester);
    });

    testWidgets('the passages heard are listed, one more per probe, with their answers', (tester) async {
      await pumpFaden(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(heardRows(), findsNothing);
      await answer(tester, known: false);
      expect(heardRows(), findsOneWidget);
      expect(find.text(AppStrings.fadenHeardTitle), findsOneWidget);
      expect(find.text(passage(probeAt(0))), findsOneWidget);
      expect(find.text(AppStrings.fadenHeardUnknown), findsOneWidget);

      await answer(tester, known: true);
      expect(heardRows(), findsNWidgets(2));
      expect(find.text(AppStrings.fadenHeardKnown), findsOneWidget);
      expect(handler.probes.map((p) => p.known), [false, true]);

      // No answer at all: listed as not recognised once the window lapses.
      await tester.pump(const Duration(milliseconds: fs.defaultProbeLen + fs.answerWindow + 100));
      expect(heardRows(), findsNWidgets(3));
      expect(find.text(AppStrings.fadenHeardUnknown), findsNWidgets(2));
      await tearDownFaden(tester);
    });

    testWidgets('"Nochmal hören" replays the passage and restarts the answer window', (tester) async {
      await pumpFaden(tester);
      await tester.pump(const Duration(seconds: 6));
      final indicator = find.byType(LinearProgressIndicator);
      expect(tester.widget<LinearProgressIndicator>(indicator).value, greaterThan(0.6));
      await tester.tap(find.text(AppStrings.fadenReplay));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(probePlayer.probes, hasLength(2));
      expect(probeAt(1), probeAt(0), reason: 'the same passage again');
      expect(tester.widget<LinearProgressIndicator>(indicator).value, lessThan(0.1));

      // Past the first window (6 s + 8 s > 9 s), still inside the restarted one.
      await tester.pump(const Duration(seconds: 8));
      expect(handler.probes, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(handler.probes.single.known, isFalse, reason: 'still one answer');
      await tearDownFaden(tester);
    });

    testWidgets('a tap on empty space answers nothing', (tester) async {
      await pumpFaden(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.tapAt(Offset(proMax.width / 2, proMax.height - 80));
      await tester.tapAt(const Offset(40, 140));
      await tester.pump(const Duration(milliseconds: 100));
      expect(handler.probes, isEmpty);
      await tester.pump(const Duration(milliseconds: fs.defaultProbeLen + fs.answerWindow));
      expect(handler.probes.single.known, isFalse, reason: 'the window lapsed: not known');
      await tearDownFaden(tester);
    });

    testWidgets('a headphone button still means "Kenne ich"', (tester) async {
      await pumpFaden(tester);
      await tester.pump(const Duration(seconds: 1));
      await handler.play(); // the media button, consumed as an answer in Faden mode
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(handler.probes.single.known, isTrue);
      await tearDownFaden(tester);
    });

    testWidgets('"Abbrechen" returns to the player: no position change, nothing plays (E89)', (tester) async {
      await pumpFaden(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.text(AppStrings.fadenAbort));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(handler.resumes, isEmpty);
      expect(handler.probes, isEmpty);
      expect(handler.fadenModeActive, isFalse);
      expect(find.text('player'), findsOneWidget);
      await tearDownFaden(tester);
    });

    testWidgets('a long press anywhere no longer aborts (E89)', (tester) async {
      await pumpFaden(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.longPressAt(Offset(proMax.width / 2, proMax.height - 80));
      await tester.pump(const Duration(milliseconds: 400));
      expect(handler.resumes, isEmpty);
      expect(find.text(AppStrings.fadenKnown), findsOneWidget, reason: 'still asking');
      expect(handler.fadenModeActive, isTrue);
      await tearDownFaden(tester);
    });

    testWidgets('headphones: 2x is "Kenne ich nicht", 3x is "Nochmal hören" (E85)', (tester) async {
      await pumpFaden(tester);
      await tester.pump(const Duration(seconds: 1));
      await handler.rewind(); // 3x on iOS: skip back
      await tester.pump(const Duration(milliseconds: 50));
      expect(probePlayer.probes, hasLength(2), reason: 'the same passage again');
      expect(probeAt(1), probeAt(0));
      expect(handler.probes, isEmpty);
      await handler.fastForward(); // 2x on iOS: skip forward
      await tester.pump(const Duration(milliseconds: 50));
      expect(handler.probes.single.known, isFalse);
      await handler.skipToPrevious(); // 3x as "previous track" (other headphones)
      await tester.pump(const Duration(milliseconds: 50));
      await handler.skipToNext(); // 2x as "next track"
      await tester.pump(const Duration(milliseconds: 50));
      expect(handler.probes.map((p) => p.known), [false, false]);
      await tearDownFaden(tester);
    });

    testWidgets('sounds: a click for "Kenne ich", a soft tone for "Kenne ich nicht" (E85)', (tester) async {
      await pumpFaden(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(probePlayer.keepAlive, [true], reason: 'near-silence between probes');
      await answer(tester, known: false);
      await answer(tester, known: true);
      expect(probePlayer.cues, [FadenCue.unknown, FadenCue.known]);
      await tearDownFaden(tester);
    });

    testWidgets('the display does not lock itself while the screen is open (E85)', (tester) async {
      final awake = _FakeScreenAwake();
      await pumpFaden(tester, screenAwake: awake);
      expect(awake.calls, [true]);
      await tester.tap(find.text(AppStrings.fadenAbort));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(awake.calls, [true, false]);
      await tearDownFaden(tester);
    });

    testWidgets('holding "Kenne ich" answers instead of aborting', (tester) async {
      await pumpFaden(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.longPress(find.text(AppStrings.fadenKnown));
      await tester.pump(const Duration(milliseconds: 50));
      expect(handler.probes.single.known, isTrue);
      // Probe 1 known (the false-alarm test): the result is that passage,
      // not the last wake point an abort would go to.
      expect(handler.resumes.map(_manifest.globalMsFor), [probeAt(0)]);
      // E88: probe 1 recognised says so.
      expect(find.text(AppStrings.fadenResultStillAwake), findsOneWidget);
      expect(probePlayer.cues.last, FadenCue.result);
      await tearDownFaden(tester);
    });

    testWidgets('nothing recognised says so and starts at the last touch (E88)', (tester) async {
      await pumpFaden(tester);
      for (var i = 0; i < 12 && handler.resumes.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (handler.probes.length < probePlayer.probes.length) await answer(tester, known: false);
      }
      expect(handler.resumes.map(_manifest.globalMsFor), [lo - fs.preroll]);
      await tester.pump();
      expect(find.text(AppStrings.fadenResultNothing), findsOneWidget);
      await tearDownFaden(tester);
    });

    /// Answers like a listener who knows everything up to [knowsUpTo]
    /// until the result shows.
    Future<void> runToResult(WidgetTester tester, int knowsUpTo) async {
      await tester.pump(const Duration(milliseconds: 100));
      for (var i = 0; i < 40 && find.text(AppStrings.fadenResultFound).evaluate().isEmpty; i++) {
        if (handler.probes.length < probePlayer.probes.length) {
          await answer(tester, known: probeAt(probePlayer.probes.length - 1) <= knowsUpTo);
        } else {
          await tester.pump(const Duration(milliseconds: 100));
        }
      }
      expect(find.text(AppStrings.fadenResultFound), findsOneWidget);
    }

    testWidgets('the result names the passage and offers only earlier recognised passages', (tester) async {
      await pumpFaden(tester);
      const knowsUpTo = 20 * 60000;
      await runToResult(tester, knowsUpTo);
      final known = [for (final p in handler.probes) if (p.known) _manifest.globalMsFor(p.position)!];
      final unknown = [for (final p in handler.probes) if (!p.known) _manifest.globalMsFor(p.position)!];
      expect(known.length, greaterThanOrEqualTo(2), reason: 'setup: several passages recognised');
      final result = known.last;
      expect(handler.resumes.map(_manifest.globalMsFor), [result], reason: 'playback starts at the result');
      expect(find.text(passage(result)), findsWidgets);

      // Every recognised passage, the result first; nothing later.
      expect(alternativeRows(), findsNWidgets(known.length));
      for (final p in known) {
        expect(p, lessThanOrEqualTo(result));
        expect(find.descendant(of: alternativeRows(), matching: find.text(passage(p))), findsOneWidget);
      }
      for (final p in unknown.where((p) => p > result)) {
        expect(find.descendant(of: alternativeRows(), matching: find.text(passage(p))), findsNothing);
      }
      expect(find.descendant(of: alternativeRows(), matching: find.text(AppStrings.fadenPlaying)), findsOneWidget);

      // Tapping an earlier one starts there: its own RESUME (undoable
      // through the handler like every RESUME).
      final earlier = known.first;
      await tester.tap(find.descendant(of: alternativeRows(), matching: find.text(passage(earlier))));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(handler.resumes.map(_manifest.globalMsFor), [result, earlier]);
      expect(find.text(AppStrings.fadenLadderEarlier), findsOneWidget);
      await tester.tap(find.text(AppStrings.fadenLadderEarlier));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(handler.resumes.map(_manifest.globalMsFor).last, lo - fs.preroll);

      await tester.tap(find.text(AppStrings.fadenDone));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('player'), findsOneWidget);
      await tearDownFaden(tester);
    });

    testWidgets('"Nochmal prüfen" asks the earliest passage not recognised again (E91)', (tester) async {
      await pumpFaden(tester, longNight: true);
      await runToResult(tester, 20 * 60000);
      final result = m.globalMsFor(handler.resumes.last)!;
      final unknownAfter = [
        for (final p in handler.probes)
          if (!p.known && m.globalMsFor(p.position)! > result) m.globalMsFor(p.position)!,
      ]..sort();
      expect(unknownAfter.first - result, greaterThan(fs.target), reason: 'a long night leaves minutes');
      expect(find.text(AppStrings.fadenRecheck), findsOneWidget);
      await tester.tap(find.text(AppStrings.fadenRecheck));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(probeAt(probePlayer.probes.length - 1), unknownAfter.first);
      expect(find.text(AppStrings.fadenKnown), findsOneWidget, reason: 'asked like any probe');
      expect(handler.fadenModeActive, isTrue, reason: 'the buttons answer again');
      await answer(tester, known: true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(m.globalMsFor(handler.resumes.last), unknownAfter.first, reason: 'moved forward by a "kenne ich"');
      expect(find.text(AppStrings.fadenResultFound), findsOneWidget);
      await tearDownFaden(tester);
    });

    testWidgets('"Abbrechen" during "Nochmal prüfen" lets the result play on where it was', (tester) async {
      await pumpFaden(tester, longNight: true);
      await runToResult(tester, 20 * 60000);
      final resumes = handler.resumes.length;
      await tester.tap(find.text(AppStrings.fadenRecheck));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text(AppStrings.fadenAbort));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(handler.resumes, hasLength(resumes), reason: 'no new position');
      expect(handler.plays, [EventSource.faden]);
      expect(find.text('player'), findsOneWidget);
      await tearDownFaden(tester);
    });

    testWidgets('on the result 3x on the headphones is "Etwas früher anfangen" (E85)', (tester) async {
      await pumpFaden(tester);
      await runToResult(tester, 20 * 60000);
      final before = handler.resumes.length;
      await handler.rewind();
      await tester.pump(const Duration(milliseconds: 100));
      expect(handler.resumes, hasLength(before + 1));
      await tearDownFaden(tester);
    });

    testWidgets('the result frees the headphone buttons before "Fertig"', (tester) async {
      await pumpFaden(tester);
      expect(handler.fadenModeActive, isTrue);
      await runToResult(tester, 20 * 60000);
      expect(find.text(AppStrings.fadenResultFound), findsOneWidget);
      expect(handler.fadenModeActive, isFalse);
      await tearDownFaden(tester);
    });

    testWidgets('on the result, a tap on empty space does nothing', (tester) async {
      await pumpFaden(tester);
      await runToResult(tester, 20 * 60000);
      final resumes = handler.resumes.length;
      await tester.tapAt(Offset(proMax.width / 2, proMax.height - 60));
      await tester.pump(const Duration(milliseconds: 400));
      expect(handler.resumes, hasLength(resumes));
      expect(find.text(AppStrings.fadenResultFound), findsOneWidget);
      await tearDownFaden(tester);
    });

    group('layout does not overflow', () {
      for (final size in [se, proMax]) {
        for (final scale in [1.0, 1.35]) {
          final name = '${size == se ? 'SE' : 'Pro Max'} x$scale';

          void expectOnScreen(WidgetTester tester, Finder finder) {
            final rect = tester.getRect(finder);
            expect(rect.top, greaterThanOrEqualTo(0));
            expect(rect.bottom, lessThanOrEqualTo(size.height), reason: '$finder must stay visible');
          }

          testWidgets('searching, $name', (tester) async {
            await pumpFaden(tester, size: size, textScale: scale);
            await tester.pump(const Duration(seconds: 1));
            for (var i = 0; i < 4; i++) {
              await answer(tester, known: false);
            }
            expect(tester.takeException(), isNull);
            expect(heardRows(), findsWidgets);
            expectOnScreen(tester, find.text(AppStrings.fadenQuestionsLeft(fs.maxProbes - 5)));
            expectOnScreen(tester, find.widgetWithText(OutlinedButton, AppStrings.fadenKnown));
            expectOnScreen(tester, find.widgetWithText(OutlinedButton, AppStrings.fadenUnknown));
            expectOnScreen(tester, find.text(AppStrings.fadenReplay));
            expectOnScreen(tester, find.text(AppStrings.fadenAbort));
            expectOnScreen(tester, find.bySemanticsLabel(AppStrings.fadenAnswerWindow));
            await tearDownFaden(tester);
          });

          testWidgets('result, $name', (tester) async {
            await pumpFaden(tester, size: size, textScale: scale, longNight: true);
            await runToResult(tester, 20 * 60000);
            expect(tester.takeException(), isNull);
            expectOnScreen(tester, find.text(AppStrings.fadenResultFound));
            expectOnScreen(tester, find.text(AppStrings.fadenRecheck));
            expectOnScreen(tester, find.text(AppStrings.fadenDone));
            // "Fertig" is a full-width capsule at the bottom (E76).
            final done = find.widgetWithText(FilledButton, AppStrings.fadenDone);
            expect(tester.getSize(done).width, closeTo(size.width - 48, 0.5));
            expect(tester.getSize(done).height, greaterThanOrEqualTo(56));
            expect(tester.getTopLeft(done).dy, greaterThanOrEqualTo(tester.getBottomLeft(find.byType(ListView)).dy),
                reason: 'below the list, which scrolls above it');
            expectOnScreen(tester, find.text(AppStrings.fadenLadderEarlier));
            // "Nochmal prüfen" first (E91), the recognised passages below it
            // in the same scrolling list.
            await tester.dragUntilVisible(
                find.byKey(const ValueKey('faden-alternative-1')), find.byType(ListView), const Offset(0, -40));
            expectOnScreen(tester, alternativeRows().first);
            await tearDownFaden(tester);
          });
        }
      }
    });
  });
}
