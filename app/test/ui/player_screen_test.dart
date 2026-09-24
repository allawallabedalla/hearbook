// Tests ui/player_screen.dart and the details sheet it opens:
// - no layout overflow on an iPhone SE (375x667) and an iPhone 15 Pro Max
//   (430x932) at text scale 1.0 and 1.35, with and without "Faden
//   aufnehmen", with a long title (decision E44);
// - the details sheet takes the player's night colours in Nachtmodus and
//   cannot be opened, or used, while the night lock is on (E46);
// - buffering and playback errors from the handler's status (E39);
// - German speed labels and the minute-level remaining time.

import 'package:faden/audio/playback_status.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/domain/resolver.dart';
import 'package:faden/l10n/strings.dart';
import 'package:faden/ui/cover.dart';
import 'package:faden/ui/details_sheet.dart';
import 'package:faden/ui/format.dart';
import 'package:faden/ui/library_screen.dart';
import 'package:faden/ui/mini_player.dart';
import 'package:faden/ui/player_screen.dart';
import 'package:faden/ui/providers.dart';
import 'package:faden/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_audio_handler.dart';

final _manifest = Manifest(manifestId: 'm1', files: [
  for (var i = 0; i < 24; i++)
    ManifestFile(idx: i, fileHash: 'h$i', durationMs: (20 + i) * 60000, title: 'Kapitel ${i + 1}: Ein Titel'),
]);

BookState _state({required bool sleepSuspected}) => BookState(
      position: const Position(fileHash: 'h1', offsetMs: 5 * 60000),
      globalMs: 25 * 60000,
      lastAwake: const Position(fileHash: 'h1', offsetMs: 0),
      stop: const Position(fileHash: 'h1', offsetMs: 5 * 60000),
      sleepSuspected: sleepSuspected,
      history: const [Position(fileHash: 'h0', offsetMs: 60000)],
      finished: false,
      needsConfirmation: false,
      sessionId: 's1',
    );

const _se = Size(375, 667);
const _proMax = Size(430, 932);
const _longTitle = 'Die unglaublich lange Geschichte vom Faden, der nie riss';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );

  late AppDatabase db;
  late FakeAudioHandler handler;
  late PlayerSessionController session;

  Future<void> pumpPlayer(
    WidgetTester tester, {
    Size size = _proMax,
    double textScale = 1.0,
    bool night = false,
    bool sleepSuspected = false,
    String title = 'Der Zauberberg',
    String? author = 'Thomas Mann',
  }) async {
    await tester.runAsync(() async {
      db = AppDatabase.memory();
      final journal = Journal(db);
      final store = SettingsStore(db);
      if (night) {
        // start == end: always night (signals/night.dart).
        await store.setNightStartMin(0);
        await store.setNightEndMin(0);
      } else {
        final now = DateTime.now();
        final minute = now.hour * 60 + now.minute;
        await store.setNightStartMin((minute + 120) % 1440);
        await store.setNightEndMin((minute + 180) % 1440);
      }
      handler = FakeAudioHandler(journal);
      session = PlayerSessionController(handler: handler, journal: journal);
    });
    session
      ..bookId = 'book-1'
      ..bookTitle = title
      ..bookAuthor = author
      ..manifest = _manifest
      ..bookState = _state(sleepSuspected: sleepSuspected);

    const dpr = 3.0;
    tester.view.physicalSize = size * dpr;
    tester.view.devicePixelRatio = dpr;
    // Status bar and home indicator of the two phones.
    tester.view.padding = size == _se
        ? const FakeViewPadding(top: 20 * dpr)
        : const FakeViewPadding(top: 59 * dpr, bottom: 34 * dpr);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          audioHandlerProvider.overrideWithValue(handler),
          playerSessionProvider.overrideWith((ref) => session),
        ],
        child: MaterialApp(
          theme: fadenThemeFor(FadenTokens.day),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          onGenerateRoute: (_) => PlayerScreen.route(instant: true),
          onGenerateInitialRoutes: (_) => [PlayerScreen.route(instant: true)],
        ),
      ),
    );
    // The night window loads from drift (real async).
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
  }

  Future<void> tearDownPlayer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await handler.dispose();
      await db.close();
    });
  }

  void expectOnScreen(WidgetTester tester, Finder finder, Size size) {
    final rect = tester.getRect(finder);
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(size.height), reason: '$finder must stay visible');
  }

  group('layout does not overflow', () {
    for (final size in [_se, _proMax]) {
      for (final scale in [1.0, 1.35]) {
        for (final sleepSuspected in [false, true]) {
          final name = '${size == _se ? 'SE' : 'Pro Max'} x$scale${sleepSuspected ? ', sleep suspected' : ''}';
          testWidgets(name, (tester) async {
            await pumpPlayer(
              tester,
              size: size,
              textScale: scale,
              sleepSuspected: sleepSuspected,
              title: _longTitle,
            );
            // An overflow is reported as an exception and fails the test.
            expect(tester.takeException(), isNull);
            expect(find.text(_longTitle), findsOneWidget);
            expect(find.text('Thomas Mann'), findsOneWidget);
            expectOnScreen(tester, find.byType(PlayerMainButton), size);
            expectOnScreen(tester, find.bySemanticsLabel(AppStrings.seekBackAction), size);
            expectOnScreen(tester, find.bySemanticsLabel(AppStrings.seekForwardAction), size);
            if (sleepSuspected) expectOnScreen(tester, find.text(AppStrings.resumeFromStop), size);
            final title = tester.widget<Text>(find.text(_longTitle));
            expect(title.maxLines, 2);
            await tearDownPlayer(tester);
          });
        }
      }
    }

    testWidgets('night, SE x1.35, sleep suspected', (tester) async {
      await pumpPlayer(tester, size: _se, textScale: 1.35, night: true, sleepSuspected: true);
      expect(tester.takeException(), isNull);
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('Der Zauberberg'), findsNothing, reason: 'Nachtmodus: only thread and buttons');
      expectOnScreen(tester, find.byType(PlayerMainButton), _se);
      await tearDownPlayer(tester);
    });
  });

  testWidgets('cover scales with the screen; no cover shows initials, not the title again', (tester) async {
    await pumpPlayer(tester, size: _proMax);
    final large = tester.getSize(find.byType(CoverMonogram)).width;
    expect(large, lessThanOrEqualTo(_proMax.width - 48));
    expect(find.text('DZ'), findsOneWidget);
    expect(find.text('Der Zauberberg'), findsOneWidget);
    await tearDownPlayer(tester);

    await pumpPlayer(tester, size: _se);
    final small = tester.getSize(find.byType(CoverMonogram)).width;
    expect(small, lessThan(large));
    await tearDownPlayer(tester);
  });

  testWidgets('remaining time is minute-level, with the chapter', (tester) async {
    await pumpPlayer(tester);
    final remaining = _manifest.totalDurationMs - 25 * 60000;
    expect(find.text(AppStrings.remainingTime(formatRemaining(remaining))), findsOneWidget);
    expect(formatRemaining(remaining), matches(RegExp(r'^\d+ Std\.( \d+ Min\.)?$')));
    expect(find.text(AppStrings.chapterOfTotal(2, 24)), findsOneWidget);
    await tearDownPlayer(tester);
  });

  testWidgets('accessibility: labelled buttons, thread value and a real "Ab Stopp" button', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpPlayer(tester, sleepSuspected: true);
    expect(find.bySemanticsLabel(AppStrings.seekBackAction), findsOneWidget);
    expect(find.bySemanticsLabel(AppStrings.seekForwardAction), findsOneWidget);
    expect(find.bySemanticsLabel(AppStrings.mainButtonRecordThread), findsWidgets);
    expect(find.byTooltip(AppStrings.libraryTitle), findsOneWidget);
    final thread = tester.getSemantics(find.byType(PlayerThread));
    expect(thread.label, AppStrings.threadLabel);
    expect(thread.value, AppStrings.threadValue(3));
    final button = find.widgetWithText(TextButton, AppStrings.resumeFromStop);
    expect(button, findsOneWidget);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(fadenMinTapTarget));
    semantics.dispose();
    await tearDownPlayer(tester);
  });

  group('motion', () {
    Finder slideAbovePlayer() =>
        find.ancestor(of: find.byType(PlayerBody, skipOffstage: false), matching: find.byType(SlideTransition));

    testWidgets('a swipe down slides the player away to the library; the mini player brings it back',
        (tester) async {
      await pumpPlayer(tester);
      final before = tester.getTopLeft(find.byType(PlayerBody)).dy;
      await tester.fling(find.byType(PlayerBody), const Offset(0, 300), 1500);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getTopLeft(find.byType(PlayerBody)).dy, greaterThan(before + 50), reason: 'sliding down');
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(MiniPlayer), matching: find.text('Der Zauberberg')));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsNothing);
      expect(find.byType(PlayerBody), findsOneWidget);
      await tearDownPlayer(tester);
    });

    testWidgets('with reduced motion the switch is immediate', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await pumpPlayer(tester);
      await tester.fling(find.byType(PlayerBody), const Offset(0, 300), 1500);
      final before = tester.getTopLeft(find.byType(PlayerBody)).dy;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(slideAbovePlayer(), findsNothing);
      expect(tester.getTopLeft(find.byType(PlayerBody, skipOffstage: false)).dy, before);
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      await tearDownPlayer(tester);
    });
  });

  group('playback status', () {
    testWidgets('buffering shows a spinner inside the main button', (tester) async {
      await pumpPlayer(tester);
      expect(find.descendant(of: find.byType(PlayerMainButton), matching: find.byType(CircularProgressIndicator)),
          findsNothing);
      handler.emitStatus(playing: true, buffering: true);
      await tester.pump();
      await tester.pump();
      expect(find.descendant(of: find.byType(PlayerMainButton), matching: find.byType(CircularProgressIndicator)),
          findsOneWidget);
      handler.emitStatus(buffering: false);
      await tester.pump();
      await tester.pump();
      expect(find.descendant(of: find.byType(PlayerMainButton), matching: find.byIcon(Icons.pause)), findsOneWidget);
      await tearDownPlayer(tester);
    });

    testWidgets('an error shows "Kann nicht abspielen" once, with a retry', (tester) async {
      await pumpPlayer(tester);
      handler.emitStatus(error: const PlaybackFailure(code: 1, message: 'Connection refused'));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.playbackError), findsOneWidget);
      expect(find.textContaining('Connection'), findsNothing, reason: 'no raw platform text');
      handler.emitStatus(buffering: false); // same error again: no second SnackBar
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.playbackError), findsOneWidget);
      await tester.tap(find.text(AppStrings.libraryRetry));
      await tester.pumpAndSettle();
      expect(handler.calls.last, (action: 'play', source: EventSource.ui));
      await tearDownPlayer(tester);
    });
  });

  group('details sheet', () {
    Future<void> openSheet(WidgetTester tester) async {
      await tester.tap(find.bySemanticsLabel(AppStrings.detailsOpen));
      await tester.pumpAndSettle();
    }

    testWidgets('uses the night colours in Nachtmodus', (tester) async {
      await pumpPlayer(tester, night: true);
      await openSheet(tester);
      expect(find.byType(DetailsSheetContent), findsOneWidget);
      expect(tester.widget<Material>(find.byKey(detailsSheetSurfaceKey)).color, FadenTokens.night.grund);
      final inSheet = tester.element(find.byType(DetailsSheetContent));
      expect(FadenTokens.of(inSheet), same(FadenTokens.night));
      expect(Theme.of(inSheet).colorScheme.inverseSurface.computeLuminance(), lessThan(0.05),
          reason: 'the undo SnackBar stays dark at night');
      await tearDownPlayer(tester);
    });

    testWidgets('uses the day colours by day', (tester) async {
      await pumpPlayer(tester);
      await openSheet(tester);
      expect(tester.widget<Material>(find.byKey(detailsSheetSurfaceKey)).color, FadenTokens.day.grund);
      await tearDownPlayer(tester);
    });

    testWidgets('cannot be opened while the night lock is on', (tester) async {
      await pumpPlayer(tester, night: true);
      await tester.pump(const Duration(seconds: 11));
      expect(find.text(AppStrings.lockedHint), findsOneWidget);
      await tester.tap(find.bySemanticsLabel(AppStrings.detailsOpen));
      await tester.pumpAndSettle();
      await tester.fling(find.byType(PlayerBody), const Offset(0, -300), 1500);
      await tester.pumpAndSettle();
      expect(find.byType(DetailsSheetContent), findsNothing);
      await tearDownPlayer(tester);
    });

    testWidgets('its scrubber does nothing once the lock engages', (tester) async {
      await pumpPlayer(tester, night: true);
      await openSheet(tester);
      await tester.pump(const Duration(seconds: 11));
      await tester.pump();
      await tester.pump();
      expect(find.text(AppStrings.lockedHint), findsNWidgets(2), reason: 'player and sheet');
      await tester.tap(find.byType(Slider), warnIfMissed: false);
      await tester.pump();
      expect(handler.seeks, isEmpty);
      await tearDownPlayer(tester);
    });

    testWidgets('scrubbing the chapter seeks through the handler, with a readout', (tester) async {
      await pumpPlayer(tester);
      await openSheet(tester);
      expect(find.text('Kapitel 2: Ein Titel'), findsOneWidget);
      expect(find.text(AppStrings.scrubberRemaining(formatClock(21 * 60000 - 5 * 60000))), findsOneWidget);
      final slider = find.byType(Slider);
      final gesture = await tester.startGesture(tester.getCenter(slider));
      await tester.pump();
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(handler.seeks, hasLength(1));
      expect(handler.seeks.single, startsWith('to:'));
      await tearDownPlayer(tester);
    });

    testWidgets('speed labels are German and fixed-width', (tester) async {
      await pumpPlayer(tester);
      await openSheet(tester);
      for (final label in ['0,75×', '1×', '1,25×', '1,5×', '2×']) {
        expect(find.text(label), findsOneWidget);
      }
      final before = tester.getRect(find.text('1,5×'));
      await tester.tap(find.text('1,5×'));
      await tester.pump();
      await tester.pump();
      expect(handler.speeds, [1.5]);
      expect(tester.getRect(find.text('1,5×')).center, before.center, reason: 'no width jump on selection');
      await tearDownPlayer(tester);
    });

    testWidgets('a chosen sleep timer stays marked while it counts down', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPlayer(tester);
      handler.fakePlaying = true;
      await openSheet(tester);
      await tester.tap(find.text(AppStrings.sleepTimerMinutes(15)));
      await tester.pump();
      await tester.pump(const Duration(minutes: 3));
      await tester.pump();
      expect(tester.getSemantics(find.text(AppStrings.sleepTimerMinutes(15))), isSemantics(isSelected: true));
      expect(tester.getSemantics(find.text(AppStrings.sleepTimerMinutes(30))), isSemantics(isSelected: false));
      expect(find.text(AppStrings.sleepTimerRunning('12:00')), findsOneWidget);
      handler.fakePlaying = false;
      semantics.dispose();
      await tearDownPlayer(tester);
    });

    testWidgets('history comes before the chapters; the chapter list marks the current one', (tester) async {
      await pumpPlayer(tester);
      await openSheet(tester);
      final history = tester.getTopLeft(find.text(AppStrings.detailsHistory)).dy;
      final chapters = tester.getTopLeft(find.text(AppStrings.detailsChapters)).dy;
      expect(history, lessThan(chapters));
      await tester.scrollUntilVisible(find.text(AppStrings.detailsAllChapters(24)), 200,
          scrollable: find.byType(Scrollable).last);
      await tester.tap(find.text(AppStrings.detailsAllChapters(24)));
      await tester.pumpAndSettle();
      expect(find.byType(ChapterList), findsOneWidget);
      final current = tester.widget<Text>(find.text('Kapitel 2: Ein Titel').last);
      expect(current.style?.fontWeight, FontWeight.w700);
      await tester.tap(find.text('Kapitel 4: Ein Titel'));
      await tester.pumpAndSettle();
      expect(handler.seeks, ['chapter:3']);
      await tearDownPlayer(tester);
    });

    testWidgets('offers the library (the night player has no app bar)', (tester) async {
      await pumpPlayer(tester, night: true);
      await openSheet(tester);
      expect(find.widgetWithText(TextButton, AppStrings.libraryTitle), findsOneWidget);
      await tearDownPlayer(tester);
    });
  });
}
