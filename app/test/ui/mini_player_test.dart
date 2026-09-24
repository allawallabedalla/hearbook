// Tests ui/mini_player.dart (decision E29): it shows the open book, its
// button goes through the handler's journaled playFrom/pauseFrom with
// source ui (invariant 3), and with sleep suspected it opens the player
// instead of resuming from the stop point. The player route is a stub
// here, registered under PlayerScreen.routeName, so showPlayerScreen finds
// it without building the real player.

import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/domain/resolver.dart';
import 'package:faden/l10n/strings.dart';
import 'package:faden/ui/format.dart';
import 'package:faden/ui/mini_player.dart';
import 'package:faden/ui/player_screen.dart';
import 'package:faden/ui/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_audio_handler.dart';

const _manifest = Manifest(manifestId: 'm1', files: [
  ManifestFile(idx: 0, fileHash: 'h0', durationMs: 20 * 60000),
  ManifestFile(idx: 1, fileHash: 'h1', durationMs: 25 * 60000),
]);

BookState _state({required bool sleepSuspected}) => BookState(
      position: const Position(fileHash: 'h1', offsetMs: 5 * 60000),
      globalMs: 25 * 60000,
      lastAwake: const Position(fileHash: 'h1', offsetMs: 0),
      stop: const Position(fileHash: 'h1', offsetMs: 5 * 60000),
      sleepSuspected: sleepSuspected,
      history: const [],
      finished: false,
      needsConfirmation: false,
      sessionId: 's1',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );

  group('miniPlayerAction', () {
    test('pauses while playing, even with sleep suspected', () {
      expect(miniPlayerAction(playing: true, sleepSuspected: false), MiniPlayerAction.pause);
      expect(miniPlayerAction(playing: true, sleepSuspected: true), MiniPlayerAction.pause);
    });

    test('plays when paused and no sleep is suspected', () {
      expect(miniPlayerAction(playing: false, sleepSuspected: false), MiniPlayerAction.play);
    });

    test('opens the player instead of playing when sleep is suspected', () {
      expect(miniPlayerAction(playing: false, sleepSuspected: true), MiniPlayerAction.openPlayer);
    });
  });

  group('MiniPlayer widget', () {
    late AppDatabase db;
    late FakeAudioHandler handler;
    late PlayerSessionController session;

    /// Stack: stub player route (root) -> "library" with the mini player.
    Future<void> pumpLibrary(
      WidgetTester tester, {
      bool open = true,
      bool sleepSuspected = false,
      bool playing = false,
    }) async {
      await tester.runAsync(() async {
        db = AppDatabase.memory();
        final journal = Journal(db);
        handler = FakeAudioHandler(journal);
        session = PlayerSessionController(handler: handler, journal: journal);
      });
      handler.fakePlaying = playing;
      if (open) {
        session.bookId = 'book-1';
        session.bookTitle = 'Der Zauberberg';
        session.manifest = _manifest;
        session.bookState = _state(sleepSuspected: sleepSuspected);
      }
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            audioHandlerProvider.overrideWithValue(handler),
            playerSessionProvider.overrideWith((ref) => session),
          ],
          child: MaterialApp(navigatorKey: navigatorKey, home: const SizedBox()),
        ),
      );
      navigatorKey.currentState!.pushAndRemoveUntil(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: PlayerScreen.routeName),
          builder: (_) => const Scaffold(body: Text('player-stub')),
        ),
        (_) => false,
      );
      await tester.pumpAndSettle();
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('library'), bottomNavigationBar: MiniPlayer()),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> tearDownHandler(WidgetTester tester) async {
      await tester.runAsync(() async {
        await handler.dispose();
        await db.close();
      });
    }

    testWidgets('renders nothing while no book is open', (tester) async {
      await pumpLibrary(tester, open: false);
      expect(find.text('library'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
      await tearDownHandler(tester);
    });

    testWidgets('shows the title and the remaining time', (tester) async {
      await pumpLibrary(tester);
      expect(find.text('Der Zauberberg'), findsOneWidget);
      // No cover (no API): a monogram, not the title a second time.
      expect(find.text('DZ'), findsOneWidget);
      expect(find.text(AppStrings.remainingTime(formatRemaining(20 * 60000))), findsOneWidget);
      expect(find.text(AppStrings.remainingTime('20 Min.')), findsOneWidget);
      await tearDownHandler(tester);
    });

    testWidgets('play goes through playFrom(ui) and stays on the screen', (tester) async {
      await pumpLibrary(tester);
      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pumpAndSettle();
      expect(handler.calls, [(action: 'play', source: EventSource.ui)]);
      expect(find.text('library'), findsOneWidget);
      await tearDownHandler(tester);
    });

    testWidgets('pause goes through pauseFrom(ui)', (tester) async {
      await pumpLibrary(tester, playing: true);
      await tester.tap(find.byIcon(Icons.pause));
      await tester.pumpAndSettle();
      expect(handler.calls, [(action: 'pause', source: EventSource.ui)]);
      await tearDownHandler(tester);
    });

    testWidgets('while playing with sleep suspected, the button still pauses', (tester) async {
      await pumpLibrary(tester, sleepSuspected: true, playing: true);
      await tester.tap(find.byIcon(Icons.pause));
      await tester.pumpAndSettle();
      expect(handler.calls, [(action: 'pause', source: EventSource.ui)]);
      await tearDownHandler(tester);
    });

    testWidgets('with sleep suspected the button opens the player instead of playing',
        (tester) async {
      await pumpLibrary(tester, sleepSuspected: true);
      expect(find.byIcon(Icons.play_arrow), findsNothing);
      await tester.tap(find.byIcon(Icons.route));
      await tester.pumpAndSettle();
      expect(handler.calls, isEmpty);
      expect(find.text('player-stub'), findsOneWidget);
      expect(find.text('library'), findsNothing);
      await tearDownHandler(tester);
    });

    testWidgets('buffering shows a spinner inside the button, which still pauses', (tester) async {
      await pumpLibrary(tester, playing: true);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      handler.emitStatus(buffering: true);
      await tester.pump();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.pause), findsNothing);
      await tester.tap(find.byType(CircularProgressIndicator));
      await tester.pump();
      expect(handler.calls, [(action: 'pause', source: EventSource.ui)]);
      handler.emitStatus(buffering: false);
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.pause), findsOneWidget);
      await tearDownHandler(tester);
    });

    testWidgets('tapping the bar returns to the single player route', (tester) async {
      await pumpLibrary(tester);
      await tester.tap(find.text(AppStrings.remainingTime('20 Min.')));
      await tester.pumpAndSettle();
      expect(handler.calls, isEmpty);
      expect(find.text('player-stub'), findsOneWidget);
      expect(find.text('library'), findsNothing);
      await tearDownHandler(tester);
    });
  });
}
