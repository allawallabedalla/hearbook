// Tests ui/player_screen.dart and the details sheet it opens:
// - no layout overflow on an iPhone SE (375x667) and an iPhone 15 Pro Max
//   (430x932) at text scale 1.0 and 1.35, with and without "Faden
//   aufnehmen", with a long title (decision E44);
// - the night view follows the display brightness (E54), not the night
//   window or the sleep timer; it shows title and chapter dimmed, no cover,
//   and has no button lock -- the player and the details sheet stay usable;
// - the details sheet takes the player's night colours in the night view
//   (E46);
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
import 'fake_screen_brightness.dart';

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
  late FakeScreenBrightness brightness;

  Future<void> pumpPlayer(
    WidgetTester tester, {
    Size size = _proMax,
    double textScale = 1.0,
    bool night = false,
    bool nightWindow = false,
    bool sleepSuspected = false,
    String title = 'Der Zauberberg',
    String? author = 'Thomas Mann',
    bool serverReachable = true,
    PlaybackFailure? initialError,
  }) async {
    await tester.runAsync(() async {
      db = AppDatabase.memory();
      final journal = Journal(db);
      final store = SettingsStore(db);
      if (nightWindow) {
        // start == end: always in the night window (signals/night.dart).
        await store.setNightStartMin(0);
        await store.setNightEndMin(0);
      } else {
        final now = DateTime.now();
        final minute = now.hour * 60 + now.minute;
        await store.setNightStartMin((minute + 120) % 1440);
        await store.setNightEndMin((minute + 180) % 1440);
      }
      handler = FakeAudioHandler(journal)..fakeError = initialError;
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

    // The night view follows the display brightness (E54).
    brightness = FakeScreenBrightness(night ? 0.1 : 0.8);
    addTearDown(brightness.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          screenBrightnessSourceProvider.overrideWithValue(brightness),
          initialNightModeProvider.overrideWithValue(night),
          appDatabaseProvider.overrideWithValue(db),
          audioHandlerProvider.overrideWithValue(handler),
          playerSessionProvider.overrideWith((ref) => session),
          serverReachableProvider.overrideWithValue(() async => serverReachable),
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
      expect(find.byType(CoverMonogram), findsNothing, reason: 'night view: no cover');
      expectOnScreen(tester, find.text('Der Zauberberg'), _se);
      expectOnScreen(tester, find.byType(PlayerMainButton), _se);
      expectOnScreen(tester, find.text(AppStrings.resumeFromStop), _se);
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

  group('not downloaded while the server is off (E58)', () {
    testWidgets('says "Nicht geladen – der Server ist gerade nicht erreichbar."', (tester) async {
      await pumpPlayer(tester, serverReachable: false);
      handler.emitStatus(error: const PlaybackFailure(code: 1, message: 'No route to host', notDownloaded: true));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.offlineNotDownloaded), findsOneWidget);
      expect(find.text(AppStrings.playbackError), findsNothing);
      handler.emitStatus(buffering: false); // same error again: no second SnackBar
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.offlineNotDownloaded), findsOneWidget);
      await tearDownPlayer(tester);
    });

    testWidgets('a streamed chapter failing with the server up is a plain playback error', (tester) async {
      await pumpPlayer(tester, serverReachable: true);
      handler.emitStatus(error: const PlaybackFailure(code: 1, notDownloaded: true));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.playbackError), findsOneWidget);
      expect(find.text(AppStrings.offlineNotDownloaded), findsNothing);
      await tearDownPlayer(tester);
    });

    testWidgets('a downloaded chapter failing is a plain playback error, even offline', (tester) async {
      await pumpPlayer(tester, serverReachable: false);
      handler.emitStatus(error: const PlaybackFailure(code: 1));
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.playbackError), findsOneWidget);
      await tearDownPlayer(tester);
    });

    testWidgets('an error from before the player was shown is announced too', (tester) async {
      // E.g. the app start opened a book that is not downloaded, at night.
      await pumpPlayer(
        tester,
        serverReachable: false,
        initialError: const PlaybackFailure(code: 1, notDownloaded: true),
      );
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.offlineNotDownloaded), findsOneWidget);
      await tearDownPlayer(tester);
    });
  });

  group('night view (display brightness, E54)', () {
    Color scaffoldColor(WidgetTester tester) =>
        tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor!;

    Future<void> setBrightness(WidgetTester tester, double value) async {
      brightness.emit(value);
      await tester.pump();
      await tester.pump();
    }

    testWidgets('turns on below 30 % and off only above 35 %', (tester) async {
      await pumpPlayer(tester);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(CoverMonogram), findsOneWidget);
      expect(scaffoldColor(tester), FadenTokens.day.grund);

      await setBrightness(tester, 0.2);
      expect(find.byType(AppBar), findsNothing);
      expect(find.ancestor(of: find.byType(CoverMonogram), matching: find.byType(Opacity)), findsOneWidget,
          reason: 'night view: cover dimmed (E59)');
      expect(scaffoldColor(tester), FadenTokens.night.grund);

      await setBrightness(tester, 0.33);
      expect(scaffoldColor(tester), FadenTokens.night.grund, reason: 'no flicker between 30 and 35 %');

      await setBrightness(tester, 0.4);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(CoverMonogram), findsOneWidget);
      expect(scaffoldColor(tester), FadenTokens.day.grund);

      await setBrightness(tester, 0.32);
      expect(scaffoldColor(tester), FadenTokens.day.grund, reason: 'no flicker between 30 and 35 %');
      await tearDownPlayer(tester);
    });

    testWidgets('the night window and a running sleep timer no longer switch it on', (tester) async {
      await pumpPlayer(tester, nightWindow: true);
      expect(scaffoldColor(tester), FadenTokens.day.grund);
      expect(find.byType(CoverMonogram), findsOneWidget);
      handler.fakePlaying = true;
      await tester.tap(find.bySemanticsLabel(AppStrings.detailsOpen));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppStrings.sleepTimerMinutes(15)));
      await tester.pump();
      await tester.pump();
      expect(tester.widget<Material>(find.byKey(detailsSheetSurfaceKey)).color, FadenTokens.day.grund);
      expect(scaffoldColor(tester), FadenTokens.day.grund);
      handler.fakePlaying = false;
      await tearDownPlayer(tester);
    });

    testWidgets('the night window still drives SLEEP_HINT, whatever the brightness', (tester) async {
      await pumpPlayer(tester, nightWindow: true);
      expect(handler.isInNightWindow?.call(), isTrue, reason: 'bright screen, but in the window');
      await tearDownPlayer(tester);

      await pumpPlayer(tester, night: true);
      expect(handler.isInNightWindow?.call(), isFalse, reason: 'dark screen, but outside the window');
      await tearDownPlayer(tester);
    });

    testWidgets('shows a dimmed cover, title and chapter small and dimmed', (tester) async {
      await pumpPlayer(tester, night: true);
      final dim = find.ancestor(of: find.byType(BookCover), matching: find.byType(Opacity));
      expect(dim, findsOneWidget);
      expect(tester.widget<Opacity>(dim).opacity, lessThan(0.6));
      expect(find.text('Thomas Mann'), findsNothing);
      for (final text in ['Der Zauberberg', 'Kapitel 2: Ein Titel']) {
        final widget = tester.widget<Text>(find.text(text).first);
        expect(widget.style?.color, FadenTokens.night.tinteLeise, reason: text);
        expect(widget.style?.fontSize, inInclusiveRange(FadenTypeSizes.caption, FadenTypeSizes.body), reason: text);
        expect(widget.maxLines, inInclusiveRange(1, 2), reason: text);
      }
      final thread = tester.getTopLeft(find.byType(PlayerThread)).dy;
      expect(tester.getBottomLeft(find.text('Kapitel 2: Ein Titel').first).dy, lessThanOrEqualTo(thread),
          reason: 'title and chapter sit above the thread');
      await tearDownPlayer(tester);
    });

    testWidgets('has no button lock: player and details sheet stay usable after 10+ s', (tester) async {
      await pumpPlayer(tester, night: true);
      await tester.pump(const Duration(seconds: 15));
      expect(find.textContaining('Gesperrt'), findsNothing);

      await tester.tap(find.byType(PlayerMainButton));
      await tester.pump();
      expect(handler.calls.last, (action: 'play', source: EventSource.ui));
      await tester.tap(find.bySemanticsLabel(AppStrings.seekBackAction));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel(AppStrings.seekForwardAction));
      await tester.pump();
      expect(handler.seeks, ['by:-30', 'by:30']);

      await tester.tap(find.bySemanticsLabel(AppStrings.detailsOpen));
      await tester.pumpAndSettle();
      expect(find.byType(DetailsSheetContent), findsOneWidget);
      await tester.pump(const Duration(seconds: 15));
      expect(find.textContaining('Gesperrt'), findsNothing);
      final gesture = await tester.startGesture(tester.getCenter(
          find.descendant(of: find.byType(DetailsSheetContent), matching: find.byType(Slider))));
      await tester.pump();
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(handler.seeks.last, startsWith('to:'));
      await tearDownPlayer(tester);
    });

    testWidgets('a swipe up opens the details sheet', (tester) async {
      await pumpPlayer(tester, night: true);
      await tester.pump(const Duration(seconds: 15));
      await tester.fling(find.byType(PlayerBody), const Offset(0, -300), 1500);
      await tester.pumpAndSettle();
      expect(find.byType(DetailsSheetContent), findsOneWidget);
      await tearDownPlayer(tester);
    });
  });

  testWidgets('the player itself has a chapter scrubber that seeks through the handler (E59)', (tester) async {
    await pumpPlayer(tester);
    final slider = find.descendant(of: find.byType(PlayerBody), matching: find.byType(Slider));
    expect(slider, findsOneWidget);
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

    testWidgets('scrubbing the chapter seeks through the handler, with a readout', (tester) async {
      await pumpPlayer(tester);
      await openSheet(tester);
      Finder inSheet(Finder f) => find.descendant(of: find.byType(DetailsSheetContent), matching: f);
      expect(inSheet(find.text('Kapitel 2: Ein Titel')), findsOneWidget);
      expect(inSheet(find.text(AppStrings.scrubberRemaining(formatClock(21 * 60000 - 5 * 60000)))), findsOneWidget);
      final slider = inSheet(find.byType(Slider));
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
