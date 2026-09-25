// Tests ui/faden_session_host.dart's AsleepPromptHost (decision E84):
// "Eingeschlafen?" after a long stretch without a touch. The first touch
// asks instead of acting (no AWAKE, no button underneath), "Ja" stops the
// book and starts the search, "Nein" is an awake proof; never in the car,
// once per stretch; 20 min are enough in the night window.

import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/domain/asleep_prompt.dart';
import 'package:faden/domain/pause_reason.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/l10n/strings.dart';
import 'package:faden/ui/faden_session.dart';
import 'package:faden/ui/faden_session_host.dart';
import 'package:faden/ui/providers.dart';
import 'package:faden/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_audio_handler.dart';

const int _min = 60000;

class _StretchHandler extends FakeAudioHandler {
  _StretchHandler(super.journal);

  ListeningStretch fakeStretch = const ListeningStretch(id: 1, state: StretchState.idle, listenedMs: 0);
  bool fakeCar = false;
  int asleepPauses = 0;
  final List<Position> resumes = [];

  @override
  ListeningStretch get stretch => fakeStretch;

  @override
  bool get carRoute => fakeCar;

  @override
  Future<ListeningStretch> pauseForAsleepSearch() async {
    asleepPauses++;
    fakePlaying = false;
    return fakeStretch;
  }

  @override
  Position currentPosition() => const Position(fileHash: 'h1', offsetMs: 70 * _min);

  @override
  Future<void> resumeFromStop(Position target, {required int? fileIndex}) async => resumes.add(target);
}

class _RecordingStarter extends FadenStarter {
  _RecordingStarter(super.ref);

  final List<ListeningStretch> fromStretchCalls = [];

  @override
  Future<FadenSession?> fromStretch(ListeningStretch stretch) async {
    fromStretchCalls.add(stretch);
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );

  late AppDatabase db;
  late _StretchHandler handler;
  late _RecordingStarter starter;
  late int taps;

  Future<void> pumpHost(
    WidgetTester tester, {
    required ListeningStretch stretch,
    bool playing = true,
    bool night = false,
    bool car = false,
    FadenTokens tokens = FadenTokens.day,
  }) async {
    taps = 0;
    await tester.runAsync(() async {
      db = AppDatabase.memory();
      final store = SettingsStore(db);
      if (night) {
        // start == end: always in the night window (signals/night.dart).
        await store.setNightStartMin(0);
        await store.setNightEndMin(0);
      } else {
        final now = DateTime.now();
        final minute = now.hour * 60 + now.minute;
        await store.setNightStartMin((minute + 120) % 1440);
        await store.setNightEndMin((minute + 180) % 1440);
      }
      handler = _StretchHandler(Journal(db))
        ..fakeStretch = stretch
        ..fakePlaying = playing
        ..fakeCar = car
        ..fakeLoadedBookId = 'book-1';
    });
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          audioHandlerProvider.overrideWithValue(handler),
          fadenStarterProvider.overrideWith((ref) => starter = _RecordingStarter(ref)),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: fadenThemeFor(tokens),
          builder: (context, child) => AsleepPromptHost(navigatorKey: navigatorKey, child: child!),
          home: Scaffold(
            body: Center(child: TextButton(onPressed: () => taps++, child: const Text('under'))),
          ),
        ),
      ),
    );
    // The night window loads from drift (real async).
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Future<void> tearDownHost(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await handler.dispose();
      await db.close();
    });
  }

  ListeningStretch playingFor(int minutes, {int id = 7}) => ListeningStretch(
        id: id,
        state: StretchState.playing,
        listenedMs: minutes * _min,
        lastAwakeGlobalMs: 0,
        lastListenWallMs: DateTime.now().millisecondsSinceEpoch,
      );

  ListeningStretch stoppedAfter(int minutes, {PauseReason reason = PauseReason.timer}) => ListeningStretch(
        id: 8,
        state: StretchState.stoppedByItself,
        listenedMs: minutes * _min,
        lastAwakeGlobalMs: 0,
        lastListenWallMs: DateTime.now().millisecondsSinceEpoch,
        stopReason: reason,
      );

  testWidgets('after an hour the first touch asks, and reaches nothing else (no AWAKE)', (tester) async {
    await pumpHost(tester, stretch: playingFor(65));
    await tester.tap(find.text('under'));
    await tester.pumpAndSettle();
    expect(taps, 0, reason: 'the touch never reached the button');
    expect(handler.awakeCalls, 0, reason: 'no awake proof before the answer');
    expect(find.text(AppStrings.asleepPromptTitle), findsOneWidget);
    expect(find.text(AppStrings.asleepPromptPlayingHour), findsOneWidget);
    expect(find.text(AppStrings.asleepPromptYes), findsOneWidget);
    expect(find.text(AppStrings.asleepPromptNo), findsOneWidget);
    await tearDownHost(tester);
  });

  testWidgets('"Nein, weiterhören" is an awake proof; asked once per stretch', (tester) async {
    await pumpHost(tester, stretch: playingFor(65));
    await tester.tap(find.text('under'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.asleepPromptNo));
    await tester.pumpAndSettle();
    expect(handler.awakeCalls, 1);
    expect(handler.asleepPauses, 0);
    // Same stretch: the next touch is an ordinary touch.
    await tester.tap(find.text('under'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(find.text(AppStrings.asleepPromptTitle), findsNothing);
    await tearDownHost(tester);
  });

  testWidgets('"Ja, Stelle suchen" stops the book and searches from the last touch', (tester) async {
    await pumpHost(tester, stretch: playingFor(65));
    await tester.tap(find.text('under'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.asleepPromptYes));
    await tester.pumpAndSettle();
    expect(handler.asleepPauses, 1);
    expect(starter.fromStretchCalls.single.lastAwakeGlobalMs, 0);
    expect(handler.awakeCalls, 0);
    await tearDownHost(tester);
  });

  testWidgets('dismissed while it still plays counts as "Nein"', (tester) async {
    await pumpHost(tester, stretch: playingFor(65));
    await tester.tap(find.text('under'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10)); // the barrier
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.asleepPromptTitle), findsNothing);
    expect(handler.awakeCalls, 1);
    await tearDownHost(tester);
  });

  testWidgets('stopped by the timer: dismissed changes nothing, "Nein" continues where it stopped', (tester) async {
    await pumpHost(tester, stretch: stoppedAfter(62), playing: false);
    await tester.tap(find.text('under'));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.asleepPromptStoppedHour), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(handler.awakeCalls, 0);
    expect(handler.resumes, isEmpty, reason: 'the position is never lost');
    await tearDownHost(tester);

    await pumpHost(tester, stretch: stoppedAfter(62), playing: false);
    await tester.tap(find.text('under'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.asleepPromptNo));
    await tester.pumpAndSettle();
    expect(handler.resumes, [const Position(fileHash: 'h1', offsetMs: 70 * _min)]);
    await tearDownHost(tester);
  });

  testWidgets('never with CarPlay as the output', (tester) async {
    await pumpHost(tester, stretch: playingFor(90), car: true);
    await tester.tap(find.text('under'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(find.text(AppStrings.asleepPromptTitle), findsNothing);
    await tearDownHost(tester);
  });

  testWidgets('by day not before an hour', (tester) async {
    await pumpHost(tester, stretch: playingFor(40));
    await tester.tap(find.text('under'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(find.text(AppStrings.asleepPromptTitle), findsNothing);
    await tearDownHost(tester);
  });

  for (final tokens in [FadenTokens.day, FadenTokens.night]) {
    testWidgets('in the night window after 20 min, with the minutes (${tokens.isDark ? 'dark' : 'light'})',
        (tester) async {
      await pumpHost(tester, stretch: playingFor(25), night: true, tokens: tokens);
      await tester.tap(find.text('under'));
      await tester.pumpAndSettle();
      expect(taps, 0);
      expect(find.text(AppStrings.asleepPromptPlayingMinutes(25)), findsOneWidget);
      expect(tester.takeException(), isNull);
      final yes = find.widgetWithText(FilledButton, AppStrings.asleepPromptYes);
      expect(tester.getSize(yes).height, greaterThanOrEqualTo(fadenMinTapTarget));
      await tearDownHost(tester);
    });
  }

  testWidgets('back in front: asks at once, without a touch', (tester) async {
    await pumpHost(tester, stretch: playingFor(70));
    for (final state in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    for (final state in [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.asleepPromptTitle), findsOneWidget);
    expect(taps, 0);
    await tearDownHost(tester);
  });
}
