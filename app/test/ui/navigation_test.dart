// Tests the app's navigation (decision E60), from the real app root
// (main.dart's FadenApp and its start screen): the library is the base
// route without a back button; with a book open at app start the player
// lies on top of it, so the first screen is still the player; closing the
// player (chevron, swipe down, "Bibliothek" in the night view's details
// sheet) lands in the library; picking a book shows exactly one player.

import 'package:faden/audio/playback_status.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/library.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/domain/resolver.dart';
import 'package:faden/l10n/strings.dart';
import 'package:faden/main.dart';
import 'package:faden/ui/details_sheet.dart';
import 'package:faden/ui/library_screen.dart';
import 'package:faden/ui/mini_player.dart';
import 'package:faden/ui/player_screen.dart';
import 'package:faden/ui/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_audio_handler.dart';
import 'fake_screen_brightness.dart';

final _manifest = Manifest(manifestId: 'm1', files: [
  for (var i = 0; i < 3; i++) ManifestFile(idx: i, fileHash: 'h$i', durationMs: 20 * 60000),
]);

const _state = BookState(
  position: Position(fileHash: 'h1', offsetMs: 60000),
  globalMs: 21 * 60000,
  lastAwake: Position(fileHash: 'h1', offsetMs: 0),
  stop: Position(fileHash: 'h1', offsetMs: 60000),
  sleepSuspected: false,
  history: [],
  finished: false,
  needsConfirmation: false,
  sessionId: 's1',
);

const _books = [
  BookSummary(bookId: 'book-1', title: 'Der Zauberberg', author: 'Thomas Mann', durationMs: 60 * 60000, serverStatus: 'ok'),
  BookSummary(bookId: 'book-2', title: 'Momo', author: 'Michael Ende', durationMs: 60 * 60000, serverStatus: 'ok'),
];

/// Shows exactly the books above (no cache, server or journal behind it).
class _FixedLibraryController extends LibraryController {
  _FixedLibraryController() : super(repository: LibraryRepository(api: null, cache: null), downloads: null) {
    books = _books;
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> refreshProgress() async {}
}

/// A session the fake opener below can fill as opening a book would.
class _Session extends PlayerSessionController {
  _Session({required super.handler, required super.journal});

  void opened(String bookId) {
    this
      ..bookId = bookId
      ..bookTitle = _books.firstWhere((b) => b.bookId == bookId).title
      ..manifest = _manifest
      ..bookState = _state;
    notifyListeners();
  }
}

/// Opens any book at once, as the cache would (E30), into the session.
class _FakeOpener extends BookOpener {
  final _Session session;
  final List<String> opened = [];

  _FakeOpener(super.ref, this.session);

  @override
  Future<OpenBookResult> open(String bookId, {void Function()? onStarted}) async {
    opened.add(bookId);
    session.opened(bookId);
    onStarted?.call();
    return OpenBookResult.opened;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(const MethodChannel('com.ryanheise.audio_session'), (call) async => null);
  // connectivity_plus (main.dart listens for network changes).
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/connectivity'),
    (call) async => ['wifi'],
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel('dev.fluttercommunity.plus/connectivity_status'),
    (call) async => null,
  );

  late AppDatabase db;
  late FakeAudioHandler handler;
  late _Session session;
  late _FakeOpener opener;

  Future<void> pumpApp(WidgetTester tester, {String? lastBookId, bool night = false}) async {
    await tester.runAsync(() async {
      db = AppDatabase.memory();
      final journal = Journal(db);
      if (lastBookId != null) await SettingsStore(db).setLastOpenedBookId(lastBookId);
      handler = FakeAudioHandler(journal);
      session = _Session(handler: handler, journal: journal);
    });
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final brightness = FakeScreenBrightness(night ? 0.1 : 0.8);
    addTearDown(brightness.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          deviceIdProvider.overrideWithValue('dev-test'),
          audioHandlerProvider.overrideWithValue(handler),
          playerSessionProvider.overrideWith((ref) => session),
          libraryControllerProvider.overrideWith((ref) => _FixedLibraryController()),
          bookOpenerProvider.overrideWith((ref) => opener = _FakeOpener(ref, session)),
          screenBrightnessSourceProvider.overrideWithValue(brightness),
          initialNightModeProvider.overrideWithValue(night),
          serverReachableProvider.overrideWithValue(() async => true),
        ],
        child: const FadenApp(),
      ),
    );
    // The start screen reads the last book from drift (real async).
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  Future<void> tearDownApp(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await handler.dispose();
      await db.close();
    });
  }

  Finder anyPlayer() => find.byType(PlayerScreen, skipOffstage: false);

  testWidgets('with a book open before, the app starts in the player, on top of the library', (tester) async {
    await pumpApp(tester, lastBookId: 'book-1');
    expect(opener.opened, ['book-1']);
    expect(find.byType(PlayerBody), findsOneWidget, reason: '"Start ist der Player"');
    expect(find.byType(LibraryScreen), findsNothing);
    expect(find.byType(LibraryScreen, skipOffstage: false), findsOneWidget, reason: 'the library lies below');

    await tester.tap(find.byTooltip(AppStrings.playerClose));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(anyPlayer(), findsNothing);
    expect(find.byType(BackButton), findsNothing, reason: 'the library is the base');
    expect(find.byTooltip(AppStrings.settingsTitle), findsOneWidget, reason: 'settings stay reachable');
    expect(find.byType(MiniPlayer), findsOneWidget);
    await tearDownApp(tester);
  });

  testWidgets('without a book open before, the app starts in the library, without a back button', (tester) async {
    await pumpApp(tester);
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(anyPlayer(), findsNothing);
    expect(find.byType(BackButton), findsNothing);
    expect(Navigator.of(tester.element(find.byType(LibraryScreen))).canPop(), isFalse);
    await tearDownApp(tester);
  });

  testWidgets('with the player closed, a playback error still shows, in the library', (tester) async {
    await pumpApp(tester, lastBookId: 'book-1');
    await tester.tap(find.byTooltip(AppStrings.playerClose));
    await tester.pumpAndSettle();
    handler.emitStatus(error: const PlaybackFailure(code: 1));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(LibraryScreen), matching: find.text(AppStrings.playbackError)),
        findsOneWidget);
    await tearDownApp(tester);
  });

  testWidgets('a swipe down closes the player onto the library', (tester) async {
    await pumpApp(tester, lastBookId: 'book-1');
    await tester.fling(find.byType(PlayerBody), const Offset(0, 300), 1500);
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(anyPlayer(), findsNothing);
    await tearDownApp(tester);
  });

  testWidgets('at night, the details sheet\'s "Bibliothek" closes the player', (tester) async {
    await pumpApp(tester, lastBookId: 'book-1', night: true);
    expect(find.byType(AppBar), findsNothing, reason: 'the night player has no app bar');
    await tester.tap(find.bySemanticsLabel(AppStrings.detailsOpen));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, AppStrings.libraryTitle));
    await tester.pumpAndSettle();
    expect(find.byType(DetailsSheetContent), findsNothing);
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(anyPlayer(), findsNothing);
    await tearDownApp(tester);
  });

  testWidgets('the mini player opens the player; picking a book shows exactly one player', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('Momo'));
    await tester.pumpAndSettle();
    expect(opener.opened, ['book-2']);
    expect(anyPlayer(), findsOneWidget);
    expect(find.byType(PlayerBody), findsOneWidget);

    await tester.tap(find.byTooltip(AppStrings.playerClose));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(MiniPlayer), matching: find.text('Momo')));
    await tester.pumpAndSettle();
    expect(anyPlayer(), findsOneWidget);

    await tester.tap(find.byTooltip(AppStrings.playerClose));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byType(BookRow), matching: find.text('Der Zauberberg')).first);
    await tester.pumpAndSettle();
    expect(opener.opened, ['book-2', 'book-1']);
    expect(anyPlayer(), findsOneWidget, reason: 'never two players stacked');
    // Asking again while it is in front brings back the same one.
    showPlayerScreen(Navigator.of(tester.element(find.byType(PlayerBody))));
    await tester.pumpAndSettle();
    expect(anyPlayer(), findsOneWidget);

    await tester.tap(find.byTooltip(AppStrings.playerClose));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryScreen), findsOneWidget);
    expect(Navigator.of(tester.element(find.byType(LibraryScreen))).canPop(), isFalse);
    await tearDownApp(tester);
  });
}
