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
// - German speed labels and the minute-level remaining time;
// - the sleep timer on the player itself (E61): the moon button starts and
//   stops the shared timer and shows what is left; it is a moon with "zzz"
//   (E69);
// - the Hell/Dunkel toggle in the player's top bar (E69), hidden at night;
// - closing the player (E60): chevron, swipe down, slide and reduced motion;
//   the drag down follows the finger 1:1 and closes or springs back on
//   release (E63), never starting on the chapter scrubber.

import 'dart:math' as math;

import 'package:faden/audio/playback_status.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/domain/resolver.dart';
import 'package:faden/l10n/strings.dart';
import 'package:faden/ui/controls.dart';
import 'package:faden/ui/cover.dart';
import 'package:faden/ui/details_sheet.dart';
import 'package:faden/ui/format.dart';
import 'package:faden/ui/library_screen.dart';
import 'package:faden/signals/sleep_timer.dart';
import 'package:faden/ui/mini_player.dart';
import 'package:faden/ui/playback_announcer.dart';
import 'package:faden/ui/player_screen.dart';
import 'package:faden/ui/providers.dart';
import 'package:faden/ui/routes.dart';
import 'package:faden/ui/theme.dart';
import 'package:faden/ui/thread_progress.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
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

BookState _state({required bool sleepSuspected, Position position = const Position(fileHash: 'h1', offsetMs: 5 * 60000)}) =>
    BookState(
      position: position,
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
    bool underLibrary = false,
    Position? position,
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
      ..bookState = position == null
          ? _state(sleepSuspected: sleepSuspected)
          : _state(sleepSuspected: sleepSuspected, position: position);

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
          // As in main.dart: SnackBars come from above the navigator (E60).
          builder: (context, child) => PlaybackAnnouncer(
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
          ),
          onGenerateRoute: (_) => PlayerScreen.route(instant: true),
          // The app's stack (E60): the library below the player.
          onGenerateInitialRoutes: (_) => [
            if (underLibrary) LibraryScreen.route(),
            PlayerScreen.route(instant: true),
          ],
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
            expectOnScreen(tester, find.byType(SleepTimerButton), size);
            expectOnScreen(tester, find.byType(AppearanceToggle), size);
            if (sleepSuspected) expectOnScreen(tester, find.text(AppStrings.resumeFromStop), size);
            final title = tester.widget<Text>(find.text(_longTitle));
            expect(title.maxLines, 2);
            await tearDownPlayer(tester);
          });

          testWidgets('night, $name', (tester) async {
            await pumpPlayer(
              tester,
              size: size,
              textScale: scale,
              night: true,
              sleepSuspected: sleepSuspected,
              title: _longTitle,
            );
            expect(tester.takeException(), isNull);
            expectOnScreen(tester, find.byType(PlayerMainButton), size);
            expectOnScreen(tester, find.bySemanticsLabel(AppStrings.seekBackAction), size);
            expectOnScreen(tester, find.byType(SleepTimerButton), size);
            expectOnScreen(tester, find.byType(PlayerThread), size);
            expect(find.byType(AppearanceToggle), findsNothing, reason: 'the night view is always dark');
            if (sleepSuspected) expectOnScreen(tester, find.text(AppStrings.resumeFromStop), size);
            await tearDownPlayer(tester);
          });
        }
      }
    }

    for (final night in [false, true]) {
      testWidgets('${night ? 'night' : 'day'}, SE x1.35, sleep suspected, a "Kapitelende" timer running',
          (tester) async {
        await pumpPlayer(tester, size: _se, textScale: 1.35, night: night, sleepSuspected: true, title: _longTitle);
        final container = ProviderScope.containerOf(tester.element(find.byType(PlayerBody)));
        container.read(sleepTimerProvider).startChapterEnd();
        await tester.pump();
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.descendant(of: find.byType(SleepTimerButton), matching: find.text(AppStrings.sleepTimerChapterEnd)),
            findsOneWidget);
        expectOnScreen(tester, find.byType(SleepTimerButton), _se);
        expectOnScreen(tester, find.byType(PlayerMainButton), _se);
        expectOnScreen(tester, find.text(AppStrings.resumeFromStop), _se);
        container.read(sleepTimerProvider).cancel();
        await tearDownPlayer(tester);
      });
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

  group('redesign (E71–E74)', () {
    for (final night in [false, true]) {
      testWidgets('${night ? 'night' : 'day'}: the main button is a squircle, ${night ? 'only its outline' : 'filled'}',
          (tester) async {
        await pumpPlayer(tester, night: night, sleepSuspected: night);
        final button = find.descendant(of: find.byType(PlayerMainButton), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton));
        final style = tester.widget<ButtonStyleButton>(button).style!;
        expect(style.shape?.resolve({}), isA<ContinuousRectangleBorder>());
        final size = tester.getSize(find.byType(PlayerMainButton));
        expect(size.width, greaterThanOrEqualTo(fadenMainButtonSize));
        if (night) {
          expect(tester.widget(button), isA<OutlinedButton>(), reason: '"Faden aufnehmen" as a squircle ring');
        } else {
          expect(tester.widget(button), isA<FilledButton>());
        }
        await tearDownPlayer(tester);
      });
    }

    testWidgets('±30 s and the bar buttons sit on tiles with full tap targets (E72)', (tester) async {
      await pumpPlayer(tester);
      for (final label in [AppStrings.seekBackAction, AppStrings.seekForwardAction]) {
        final tile = find.ancestor(of: find.bySemanticsLabel(label), matching: find.byType(FadenTileButton));
        expect(tile, findsOneWidget, reason: label);
        expect(tester.getSize(tile).height, greaterThanOrEqualTo(fadenMinTapTarget));
      }
      expect(find.ancestor(of: find.byTooltip(AppStrings.playerClose), matching: find.byType(FadenTileButton)),
          findsOneWidget);
      expect(find.descendant(of: find.byType(AppearanceToggle), matching: find.byType(FadenTileButton)), findsOneWidget);
      expect(find.descendant(of: find.byType(SleepTimerButton), matching: find.byType(FadenTileButton)), findsOneWidget);
      final surface = tester.widget<Material>(find
          .descendant(of: find.byType(AppearanceToggle), matching: find.byType(Material))
          .first);
      expect(surface.color, FadenTokens.day.karte);
      await tearDownPlayer(tester);
    });

    testWidgets('"Als Nächstes" peeks up at the bottom and opens the details (E74)', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPlayer(tester);
      expect(find.text(AppStrings.playerNextUp), findsOneWidget);
      // Chapter 2 is playing; its title already says "Kapitel 3", so no
      // label in front.
      expect(find.text('Kapitel 3: Ein Titel'), findsOneWidget);
      final peek = tester.getSemantics(find.bySemanticsLabel(AppStrings.detailsOpen));
      expect(peek.value, '${AppStrings.playerNextUp} Kapitel 3: Ein Titel');
      // Beside the sleep timer, as high as the grip row it replaces.
      final strip = tester.getRect(find.text(AppStrings.playerNextUp));
      final moon = tester.getRect(find.byType(SleepTimerButton));
      expect(strip.right, lessThan(moon.left));
      await tester.tap(find.text(AppStrings.playerNextUp));
      await tester.pumpAndSettle();
      expect(find.byType(DetailsSheetContent), findsOneWidget);
      semantics.dispose();
      await tearDownPlayer(tester);
    });

    testWidgets('on the last chapter nothing peeks; the bare grip stays', (tester) async {
      await pumpPlayer(tester, position: const Position(fileHash: 'h23', offsetMs: 0));
      expect(find.text(AppStrings.playerNextUp), findsNothing);
      await tester.tap(find.bySemanticsLabel(AppStrings.detailsOpen));
      await tester.pumpAndSettle();
      expect(find.byType(DetailsSheetContent), findsOneWidget);
      await tearDownPlayer(tester);
    });

    for (final night in [false, true]) {
      testWidgets('${night ? 'night' : 'day'}, SE x1.35: "Als Nächstes" costs no height and fits beside a running timer',
          (tester) async {
        await pumpPlayer(tester, size: _se, textScale: 1.35, night: night);
        expect(tester.takeException(), isNull);
        expect(find.text(AppStrings.playerNextUp), findsOneWidget);
        final strip = tester.getRect(find.ancestor(of: find.text(AppStrings.playerNextUp), matching: find.byType(InkWell)).first);
        expect(strip.height, fadenMinTapTarget);
        expectOnScreen(tester, find.byType(PlayerMainButton), _se);
        final container = ProviderScope.containerOf(tester.element(find.byType(PlayerBody)));
        container.read(sleepTimerProvider).startChapterEnd();
        await tester.pump();
        await tester.pump();
        expect(tester.takeException(), isNull);
        final peek = find.text(AppStrings.playerNextUp);
        if (peek.evaluate().isNotEmpty) {
          expect(tester.getRect(peek).right, lessThan(tester.getRect(find.byType(SleepTimerButton)).left));
        }
        expectOnScreen(tester, find.byType(SleepTimerButton), _se);
        container.read(sleepTimerProvider).cancel();
        await tearDownPlayer(tester);
      });
    }
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
    expect(find.byTooltip(AppStrings.playerClose), findsOneWidget);
    expect(tester.getSize(find.byTooltip(AppStrings.playerClose)).height, greaterThanOrEqualTo(fadenMinTapTarget));
    final moon = find.bySemanticsLabel(AppStrings.detailsSleepTimer);
    expect(moon, findsOneWidget);
    expect(tester.getSize(moon).width, greaterThanOrEqualTo(fadenMinTapTarget));
    expect(tester.getSize(moon).height, greaterThanOrEqualTo(fadenMinTapTarget));
    final thread = tester.getSemantics(find.byType(PlayerThread));
    expect(thread.label, AppStrings.threadLabel);
    expect(thread.value, AppStrings.threadValue(3));
    final button = find.widgetWithText(TextButton, AppStrings.resumeFromStop);
    expect(button, findsOneWidget);
    expect(tester.getSize(button).height, greaterThanOrEqualTo(fadenMinTapTarget));
    semantics.dispose();
    await tearDownPlayer(tester);
  });

  group('audit fixes (E65)', () {
    testWidgets('the book\'s time left is the thread\'s caption, right under the cover (E71)', (tester) async {
      await pumpPlayer(tester);
      final remaining = find.text(AppStrings.remainingTime(formatRemaining(_manifest.totalDurationMs - 25 * 60000)));
      expect(remaining, findsOneWidget);
      final ring = tester.getRect(find.byType(PlayerThread));
      expect(tester.getTopLeft(remaining).dy, inInclusiveRange(ring.bottom, ring.bottom + 12));
      expect(tester.getCenter(remaining).dx, closeTo(ring.center.dx, 0.5), reason: 'centred under the cover');
      expect(tester.getBottomLeft(remaining).dy, lessThan(tester.getTopLeft(find.text('Der Zauberberg')).dy),
          reason: 'between the cover and the title');
      await tearDownPlayer(tester);
    });

    testWidgets('the thread wraps the cover; scrubber and its times share one left and right edge (E71)',
        (tester) async {
      await pumpPlayer(tester);
      final ring = tester.getRect(find.byType(PlayerThread));
      final cover = tester.getRect(find.byType(CoverMonogram));
      expect(find.descendant(of: find.byType(PlayerThread), matching: find.byType(ThreadRing)), findsOneWidget);
      expect(ring.width, closeTo(ring.height, 0.5), reason: 'a rounded square');
      expect(cover.left - ring.left, ThreadRing.inset);
      expect(ring.right - cover.right, ThreadRing.inset);
      expect(cover.top - ring.top, ThreadRing.inset);
      expect(ring.bottom - cover.bottom, ThreadRing.inset);
      final slider = find.descendant(of: find.byType(PlayerBody), matching: find.byType(Slider));
      final track = tester.getRect(slider);
      final body = tester.getRect(find.byType(PlayerBody));
      expect(track.left, body.left + 24);
      expect(track.right, body.right - 24);
      expect(tester.getTopLeft(find.text(formatClock(5 * 60000)).last).dx, track.left);
      expect(tester.getTopRight(find.text(AppStrings.scrubberRemaining(formatClock(16 * 60000))).last).dx,
          closeTo(track.right, 0.5));
      expect(tester.getSize(slider).height, greaterThanOrEqualTo(44), reason: 'still easy to grab');
      await tearDownPlayer(tester);
    });

    testWidgets('without room for a cover the thread runs straight, edge to edge with the scrubber (E71)',
        (tester) async {
      await pumpPlayer(tester, size: _se, textScale: 1.35, sleepSuspected: true, title: _longTitle);
      expect(tester.takeException(), isNull);
      expect(find.byType(CoverMonogram), findsNothing);
      expect(find.byType(ThreadRing), findsNothing);
      final thread = tester.getRect(find.byType(PlayerThread));
      final track = tester.getRect(find.descendant(of: find.byType(PlayerBody), matching: find.byType(Slider)));
      expect(thread.left, track.left);
      expect(thread.right, track.right);
      expect(thread.bottom, lessThan(tester.getTopLeft(find.text(_longTitle)).dy));
      await tearDownPlayer(tester);
    });

    testWidgets('"Faden aufnehmen" under the button is part of it; "Ab Stopp" is in the house font', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPlayer(tester, sleepSuspected: true);
      final body = tester.widget<PlayerBody>(find.byType(PlayerBody));
      final caption = find.descendant(of: find.byType(PlayerBody), matching: find.text(AppStrings.mainButtonRecordThread));
      expect(caption, findsOneWidget);
      final tap = tester.widget<GestureDetector>(
          find.ancestor(of: caption, matching: find.byType(GestureDetector)).first);
      expect(tap.onTap, same(body.onMainButton), reason: 'a tap on the name is a tap on the button');
      expect(find.bySemanticsLabel(AppStrings.mainButtonRecordThread), findsOneWidget,
          reason: 'one VoiceOver element, the button');
      final gap = tester.getTopLeft(caption).dy - tester.getBottomLeft(find.byType(PlayerMainButton)).dy;
      expect(gap, inInclusiveRange(0, 8));
      final resume = tester.widget<TextButton>(find.widgetWithText(TextButton, AppStrings.resumeFromStop));
      expect(resume.style?.textStyle?.resolve({})?.fontFamily, fadenFontFamily);
      semantics.dispose();
      await tearDownPlayer(tester);
    });

    testWidgets('the details grip keeps 3:1 against the background', (tester) async {
      for (final night in [false, true]) {
        // On the last chapter there is nothing to peek at: the bare grip.
        await pumpPlayer(tester, night: night, position: const Position(fileHash: 'h23', offsetMs: 60000));
        expect(find.text(AppStrings.playerNextUp), findsNothing);
        final tokens = night ? FadenTokens.night : FadenTokens.day;
        final grip = tester.widget<Container>(find.descendant(
            of: find.bySemanticsLabel(AppStrings.detailsOpen), matching: find.byType(Container)));
        final color = (grip.decoration! as BoxDecoration).color!;
        final l1 = color.computeLuminance();
        final l2 = tokens.grund.computeLuminance();
        final ratio = (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
        expect(ratio, greaterThanOrEqualTo(3), reason: night ? 'night' : 'day');
        await tearDownPlayer(tester);
      }
    });

    testWidgets('±30 s, a speed and a sleep-timer choice tick (haptics)', (tester) async {
      final haptics = <String>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments as String);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpPlayer(tester);
      await tester.tap(find.bySemanticsLabel(AppStrings.seekBackAction));
      await tester.pump();
      expect(haptics, ['HapticFeedbackType.lightImpact']);
      await tester.tap(find.bySemanticsLabel(AppStrings.detailsOpen));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1,5×'));
      await tester.pump();
      expect(haptics.last, 'HapticFeedbackType.selectionClick');
      haptics.clear();
      await tester.tap(find.byType(SleepTimerRow));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, AppStrings.sleepTimerMinutes(30)));
      await tester.pumpAndSettle();
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      ProviderScope.containerOf(tester.element(find.byType(PlayerBody))).read(sleepTimerProvider).cancel();
      await tearDownPlayer(tester);
    });

    testWidgets('while the book is still opening, the player shows its title and a spinner', (tester) async {
      await pumpPlayer(tester);
      session.bookState = null;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      session.notifyListeners();
      await tester.pump();
      expect(find.byType(PlayerBody), findsNothing);
      expect(find.byType(PlayerLoading), findsOneWidget);
      expect(find.text('Der Zauberberg'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byTooltip(AppStrings.playerClose), findsOneWidget, reason: 'the way back stays');
      await tearDownPlayer(tester);
    });
  });

  group('closing the player (E60)', () {
    testWidgets('a swipe down slides the player down onto the library; the mini player brings it back',
        (tester) async {
      await pumpPlayer(tester, underLibrary: true);
      expect(find.byType(LibraryScreen), findsNothing, reason: 'covered by the player');
      final before = tester.getTopLeft(find.byType(PlayerBody)).dy;
      await tester.fling(find.byType(PlayerBody), const Offset(0, 300), 1500);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getTopLeft(find.byType(PlayerBody)).dy, greaterThan(before + 50), reason: 'sliding down');
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing, reason: 'closed, not kept below');
      expect(find.byType(BackButton), findsNothing, reason: 'the library is the base');
      await tester.tap(find.descendant(of: find.byType(MiniPlayer), matching: find.text('Der Zauberberg')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getTopLeft(find.byType(PlayerBody)).dy, greaterThan(before + 50), reason: 'sliding up');
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsNothing);
      expect(find.byType(PlayerBody), findsOneWidget);
      await tearDownPlayer(tester);
    });

    testWidgets('the down chevron closes it', (tester) async {
      await pumpPlayer(tester, underLibrary: true);
      await tester.tap(find.byTooltip(AppStrings.playerClose));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
      await tearDownPlayer(tester);
    });

    testWidgets('with reduced motion it closes at once, without sliding', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await pumpPlayer(tester, underLibrary: true);
      await tester.fling(find.byType(PlayerBody), const Offset(0, 300), 1500);
      await tester.pump();
      expect(find.byType(PlayerBody, skipOffstage: false), findsNothing);
      expect(find.byType(LibraryScreen), findsOneWidget);
      await tearDownPlayer(tester);
    });

    testWidgets('alone on the stack, closing puts the library in its place', (tester) async {
      await pumpPlayer(tester);
      await tester.tap(find.byTooltip(AppStrings.playerClose));
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
      await tearDownPlayer(tester);
    });
  });

  group('dragging the player down (E63)', () {
    double playerTop(WidgetTester tester) => tester.getTopLeft(find.byType(PlayerBody)).dy;

    test('closes past a quarter of the height or on a fast fling down', () {
      expect(playerDragCloses(draggedPx: 100, velocity: 0, height: 800), isFalse);
      expect(playerDragCloses(draggedPx: 200, velocity: 0, height: 800), isTrue);
      expect(playerDragCloses(draggedPx: 30, velocity: 800, height: 800), isTrue);
      expect(playerDragCloses(draggedPx: 400, velocity: -800, height: 800), isFalse, reason: 'flung back up');
    });

    for (final night in [false, true]) {
      testWidgets('${night ? 'night' : 'day'}: the whole player follows the finger 1:1, the library behind it',
          (tester) async {
        await pumpPlayer(tester, underLibrary: true, night: night);
        final before = playerTop(tester);
        final gesture = await tester.startGesture(tester.getCenter(find.text('Der Zauberberg')));
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 90));
        await tester.pump();
        expect(playerTop(tester), moreOrLessEquals(before + 120, epsilon: 0.5));
        if (!night) {
          expect(tester.getTopLeft(find.byTooltip(AppStrings.playerClose)).dy, greaterThan(100),
              reason: 'the app bar moves with it');
        }
        expect(find.byType(LibraryScreen), findsOneWidget, reason: 'visible behind the player');
        expect(find.byType(MiniPlayer), findsOneWidget);

        await gesture.moveBy(const Offset(0, -500));
        await tester.pump();
        expect(playerTop(tester), moreOrLessEquals(before, epsilon: 0.5), reason: 'clamped at its place');
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.byType(PlayerBody), findsOneWidget);
        expect(find.byType(LibraryScreen), findsNothing);
        await tearDownPlayer(tester);
      });
    }

    testWidgets('a short, slow drag springs back; the player stays', (tester) async {
      await pumpPlayer(tester, underLibrary: true);
      final before = playerTop(tester);
      await tester.timedDrag(find.text('Der Zauberberg'), const Offset(0, 150), const Duration(seconds: 1));
      await tester.pump();
      expect(playerTop(tester), greaterThan(before + 100), reason: 'springs back from where it was let go');
      await tester.pumpAndSettle();
      expect(playerTop(tester), moreOrLessEquals(before, epsilon: 0.5));
      expect(find.byType(PlayerBody), findsOneWidget);
      expect(find.byType(LibraryScreen), findsNothing);
      await tearDownPlayer(tester);
    });

    testWidgets('a long drag closes it, sliding on from the finger\'s position', (tester) async {
      await pumpPlayer(tester, underLibrary: true);
      final before = playerTop(tester);
      final route = ModalRoute.of(tester.element(find.byType(PlayerBody)))!;
      var popped = false;
      route.popped.then((_) => popped = true);
      await tester.timedDrag(find.text('Der Zauberberg'), const Offset(0, 300), const Duration(seconds: 1));
      await tester.pump();
      expect(playerTop(tester), greaterThanOrEqualTo(before + 300), reason: 'no jump back before closing');
      await tester.pumpAndSettle();
      expect(popped, isTrue);
      // Popped exactly once: the library below is still there.
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
      await tearDownPlayer(tester);
    });

    testWidgets('a short, fast fling down closes it', (tester) async {
      await pumpPlayer(tester, underLibrary: true);
      await tester.fling(find.text('Der Zauberberg'), const Offset(0, 80), 1500);
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
      await tearDownPlayer(tester);
    });

    testWidgets('drags on the chapter scrubber do not move the player', (tester) async {
      await pumpPlayer(tester, underLibrary: true);
      final before = playerTop(tester);
      final slider = find.descendant(of: find.byType(PlayerBody), matching: find.byType(Slider));
      final sideways = await tester.startGesture(tester.getCenter(slider));
      await sideways.moveBy(const Offset(40, 0));
      await tester.pump();
      await sideways.moveBy(const Offset(40, 30));
      await tester.pump();
      expect(playerTop(tester), before);
      await sideways.up();
      await tester.pumpAndSettle();
      expect(handler.seeks, hasLength(1), reason: 'the scrubber still seeks');

      final down = await tester.startGesture(tester.getCenter(slider));
      await down.moveBy(const Offset(0, 40));
      await tester.pump();
      await down.moveBy(const Offset(0, 200));
      await tester.pump();
      expect(playerTop(tester), before, reason: 'a drag down never starts on the scrubber');
      await down.up();
      await tester.pumpAndSettle();
      expect(find.byType(PlayerBody), findsOneWidget);
      await tearDownPlayer(tester);
    });

    testWidgets('with reduced motion it does not follow the finger, and closes on release past the threshold',
        (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      await pumpPlayer(tester, underLibrary: true);
      final before = playerTop(tester);
      final gesture = await tester.startGesture(tester.getCenter(find.text('Der Zauberberg')));
      await gesture.moveBy(const Offset(0, 40));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 260));
      await tester.pump();
      expect(playerTop(tester), before);
      await gesture.up();
      await tester.pump();
      expect(find.byType(PlayerBody, skipOffstage: false), findsNothing);
      expect(find.byType(LibraryScreen), findsOneWidget);
      await tearDownPlayer(tester);
    });
  });

  group('Hell/Dunkel on the player (E69)', () {
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
    }

    Finder toggleIcon(IconData icon) => find.descendant(of: find.byType(AppearanceToggle), matching: find.byIcon(icon));

    testWidgets('a moon by light, a sun in the dark; a tap switches and stores the look', (tester) async {
      final haptics = <String>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') haptics.add(call.arguments as String);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpPlayer(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(PlayerBody)));
      final store = SettingsStore(db);
      Color background() => tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor!;

      // In the top bar, on the right, at least 44 pt.
      final toggle = find.byType(AppearanceToggle);
      expect(find.descendant(of: find.byType(AppBar), matching: toggle), findsOneWidget);
      expect(tester.getCenter(toggle).dx, greaterThan(430 / 2));
      expect(tester.getSize(toggle).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(toggle).height, greaterThanOrEqualTo(44));
      expect(toggleIcon(CupertinoIcons.moon), findsOneWidget);
      expect(find.bySemanticsLabel(AppStrings.playerAppearanceDark), findsOneWidget);
      expect(background(), FadenTokens.day.grund);

      await tester.tap(toggle);
      await settle(tester);
      expect(haptics, ['HapticFeedbackType.selectionClick']);
      expect(container.read(appearanceProvider), Appearance.dark);
      expect(await tester.runAsync(store.appearance), Appearance.dark);
      expect(toggleIcon(CupertinoIcons.sun_max), findsOneWidget);
      expect(find.bySemanticsLabel(AppStrings.playerAppearanceLight), findsOneWidget);
      expect(background(), FadenTokens.night.grund);

      await tester.tap(toggle);
      await settle(tester);
      expect(container.read(appearanceProvider), Appearance.light);
      expect(await tester.runAsync(store.appearance), Appearance.light);
      expect(toggleIcon(CupertinoIcons.moon), findsOneWidget);
      await tearDownPlayer(tester);
    });

    testWidgets('"Wie iPhone" on a dark phone shows the sun, and a tap picks Hell', (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await pumpPlayer(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(PlayerBody)));
      expect(container.read(appearanceProvider), Appearance.system);
      expect(toggleIcon(CupertinoIcons.sun_max), findsOneWidget);
      await tester.tap(find.byType(AppearanceToggle));
      await settle(tester);
      expect(container.read(appearanceProvider), Appearance.light);
      expect(toggleIcon(CupertinoIcons.moon), findsOneWidget);
      await tearDownPlayer(tester);
    });

    testWidgets('not in the night view', (tester) async {
      await pumpPlayer(tester, night: true);
      expect(find.byType(AppearanceToggle), findsNothing);
      await tearDownPlayer(tester);
    });
  });

  group('sleep timer on the player (E61)', () {
    Finder moon() => find.byType(SleepTimerButton);
    Finder inMoon(Finder f) => find.descendant(of: moon(), matching: f);

    for (final night in [false, true]) {
      testWidgets('${night ? 'night' : 'day'}: starts the shared timer, counts down, and "Aus" stops it',
          (tester) async {
        await pumpPlayer(tester, night: night);
        handler.fakePlaying = true;
        final timer = ProviderScope.containerOf(tester.element(moon())).read(sleepTimerProvider);
        expect(inMoon(find.byType(Text)), findsNothing, reason: 'just the moon while off');
        expect(inMoon(find.byIcon(CupertinoIcons.moon_zzz)), findsOneWidget, reason: 'a moon with "zzz" (E69)');

        await tester.tap(moon());
        await tester.pumpAndSettle();
        for (final label in [
          for (final m in sleepTimerPresetMinutes) AppStrings.sleepTimerMinutes(m),
          AppStrings.sleepTimerChapterEnd,
          AppStrings.sleepTimerOff,
        ]) {
          expect(find.widgetWithText(ListTile, label), findsOneWidget, reason: label);
        }
        expect(tester.widget<Material>(find.byKey(detailsSheetSurfaceKey)).color,
            night ? FadenTokens.night.grund : FadenTokens.day.grund);
        await tester.tap(find.widgetWithText(ListTile, AppStrings.sleepTimerMinutes(15)));
        await tester.pumpAndSettle();
        expect(find.byType(SleepTimerChoices), findsNothing, reason: 'a choice closes the sheet');
        expect(timer.state.running, isTrue);
        expect(timer.state.mode, SleepTimerMode.fixed);
        expect(inMoon(find.text(AppStrings.sleepTimerMinutes(15))), findsOneWidget);

        await tester.pump(const Duration(minutes: 3));
        await tester.pump();
        expect(inMoon(find.text(AppStrings.sleepTimerMinutes(12))), findsOneWidget);
        final semantics = tester.ensureSemantics();
        expect(tester.getSemantics(moon()),
            isSemantics(label: AppStrings.detailsSleepTimer, value: AppStrings.sleepTimerMinutes(12), isButton: true));
        semantics.dispose();

        // The details sheet shows the very same timer, as one row (E65).
        await tester.tap(find.bySemanticsLabel(AppStrings.detailsOpen));
        await tester.pumpAndSettle();
        expect(find.descendant(of: find.byType(SleepTimerRow), matching: find.text(AppStrings.sleepTimerMinutes(12))),
            findsOneWidget);
        Navigator.of(tester.element(find.byType(DetailsSheetContent))).pop();
        await tester.pumpAndSettle();

        await tester.tap(moon());
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(ListTile, AppStrings.sleepTimerOff));
        await tester.pumpAndSettle();
        expect(timer.state.running, isFalse);
        expect(inMoon(find.byType(Text)), findsNothing);
        handler.fakePlaying = false;
        await tearDownPlayer(tester);
      });
    }

    testWidgets('"Kapitelende" shows as such; a timer from the details sheet shows on the button', (tester) async {
      await pumpPlayer(tester);
      await tester.tap(moon());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, AppStrings.sleepTimerChapterEnd));
      await tester.pumpAndSettle();
      expect(inMoon(find.text(AppStrings.sleepTimerChapterEnd)), findsOneWidget);

      // The details sheet's row opens the very same choice (E65).
      await tester.tap(find.bySemanticsLabel(AppStrings.detailsOpen));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.byType(SleepTimerRow), matching: find.text(AppStrings.sleepTimerChapterEnd)),
          findsOneWidget);
      await tester.tap(find.byType(SleepTimerRow));
      await tester.pumpAndSettle();
      expect(find.byType(SleepTimerChoices), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, AppStrings.sleepTimerMinutes(45)));
      await tester.pumpAndSettle();
      expect(find.byType(SleepTimerChoices), findsNothing);
      expect(find.byType(DetailsSheetContent), findsOneWidget, reason: 'back in the details');
      expect(inMoon(find.text(AppStrings.sleepTimerMinutes(45))), findsOneWidget);
      await tester.tap(find.byType(SleepTimerRow));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, AppStrings.sleepTimerOff));
      await tester.pumpAndSettle();
      expect(inMoon(find.byType(Text)), findsNothing);
      expect(find.descendant(of: find.byType(SleepTimerRow), matching: find.text(AppStrings.sleepTimerOff)),
          findsOneWidget);
      await tearDownPlayer(tester);
    });

    testWidgets('the timer outlives the player: it keeps running once the player is closed', (tester) async {
      await pumpPlayer(tester, underLibrary: true);
      final timer = ProviderScope.containerOf(tester.element(moon())).read(sleepTimerProvider);
      await tester.tap(moon());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, AppStrings.sleepTimerMinutes(30)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(AppStrings.playerClose));
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
      expect(timer.state.running, isTrue);
      expect(handler.onLastMinuteExtend, isNotNull, reason: 'headphone buttons still extend it');
      timer.cancel();
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
      await tester.tap(find.byType(SleepTimerButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, AppStrings.sleepTimerMinutes(15)));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel(AppStrings.detailsOpen));
      await tester.pumpAndSettle();
      expect(tester.widget<Material>(find.byKey(detailsSheetSurfaceKey)).color, FadenTokens.day.grund);
      expect(scaffoldColor(tester), FadenTokens.day.grund);
      handler.fakePlaying = false;
      await tearDownPlayer(tester);
    });

    testWidgets('shows a dimmed cover, title and chapter small and dimmed; the chapter only once (E65)',
        (tester) async {
      await pumpPlayer(tester, night: true);
      final dim = find.ancestor(of: find.byType(BookCover), matching: find.byType(Opacity));
      expect(dim, findsOneWidget);
      expect(tester.widget<Opacity>(dim).opacity, lessThan(0.6));
      expect(find.text('Thomas Mann'), findsNothing);
      expect(find.text('Kapitel 2: Ein Titel'), findsOneWidget, reason: 'the scrubber names it, the header not again');
      for (final text in ['Der Zauberberg', 'Kapitel 2: Ein Titel']) {
        final widget = tester.widget<Text>(find.text(text));
        expect(widget.style?.color, FadenTokens.night.tinteLeise, reason: text);
        expect(widget.style?.fontSize, inInclusiveRange(FadenTypeSizes.caption, FadenTypeSizes.body), reason: text);
        expect(widget.maxLines, inInclusiveRange(1, 2), reason: text);
      }
      // The dimmed thread wraps the dimmed cover (E71); the title below.
      expect(find.descendant(of: find.byType(PlayerThread), matching: find.byType(BookCover)), findsOneWidget);
      expect(tester.widget<ThreadRing>(find.byType(ThreadRing)).dim, isTrue);
      final ring = tester.getBottomLeft(find.byType(PlayerThread)).dy;
      expect(tester.getTopLeft(find.text('Der Zauberberg')).dy, greaterThanOrEqualTo(ring),
          reason: 'the title sits under the thread');
      expect(find.textContaining('noch '), findsNothing, reason: 'no remaining time at night');
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
      await tester.fling(find.byType(PlayerScreen), const Offset(0, -300), 1500);
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

    testWidgets('one sleep-timer row opens the moon\'s choice; the chosen one stays marked (E65)', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPlayer(tester);
      handler.fakePlaying = true;
      await openSheet(tester);
      Finder inSheet(Finder f) => find.descendant(of: find.byType(DetailsSheetContent), matching: f);
      expect(inSheet(find.text(AppStrings.sleepTimerMinutes(15))), findsNothing, reason: 'no second set of presets');
      expect(inSheet(find.textContaining('Starten')), findsNothing);
      expect(tester.getSemantics(find.byType(SleepTimerRow)),
          isSemantics(label: AppStrings.detailsSleepTimer, value: AppStrings.sleepTimerOff, isButton: true));
      await tester.tap(find.byType(SleepTimerRow));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, AppStrings.sleepTimerMinutes(15)));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 3));
      await tester.pump();
      expect(inSheet(find.text(AppStrings.sleepTimerMinutes(12))), findsOneWidget);
      await tester.tap(find.byType(SleepTimerRow));
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.sleepTimerRunning('12:00')), findsOneWidget);
      Finder check(String label) =>
          find.descendant(of: find.widgetWithText(ListTile, label), matching: find.byIcon(Icons.check));
      expect(check(AppStrings.sleepTimerMinutes(15)), findsOneWidget);
      expect(check(AppStrings.sleepTimerMinutes(30)), findsNothing);
      handler.fakePlaying = false;
      semantics.dispose();
      await tearDownPlayer(tester);
    });

    testWidgets('the chapter scrubber has a VoiceOver label (E65)', (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpPlayer(tester);
      await openSheet(tester);
      final slider = find.descendant(of: find.byType(DetailsSheetContent), matching: find.byType(Slider));
      final node = tester.getSemantics(slider).getSemanticsData();
      expect(node.flagsCollection.isSlider, isTrue, reason: 'one element: the label on the slider itself');
      expect(node.label, contains(AppStrings.scrubberLabel));
      expect(node.value, formatClock(5 * 60000));
      semantics.dispose();
      await tearDownPlayer(tester);
    });

    for (final night in [false, true]) {
      testWidgets('${night ? 'night' : 'day'}: the selected speed is ${night ? 'a ring' : 'filled'} (E65)',
          (tester) async {
        await pumpPlayer(tester, night: night);
        await openSheet(tester);
        final tokens = night ? FadenTokens.night : FadenTokens.day;
        final box = tester.widget<DecoratedBox>(
            find.ancestor(of: find.text('1×'), matching: find.byType(DecoratedBox)).first);
        final decoration = box.decoration as BoxDecoration;
        if (night) {
          expect(decoration.color, Colors.transparent);
          expect((decoration.border! as Border).top.color, tokens.faden);
          expect(tester.widget<Text>(find.text('1×')).style?.color, tokens.faden);
        } else {
          expect(decoration.color, tokens.faden);
          expect(decoration.border, isNull);
        }
        await tearDownPlayer(tester);
      });
    }

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
