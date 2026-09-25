// Tests ui/library_screen.dart (decision E48): search, order and the
// "Weiterhören" section; the first-launch state without a server; a
// running download saying what is left (E62), with cancel and retry; the
// library as the base route without a back button (E60); and the
// "Reihenfolge prüfen" dialog, which shows each candidate's real file
// order instead of "Option 1 · 12 · needs_review".

import 'dart:async';
import 'dart:io';

import 'package:faden/data/api.dart' show ApiClient;
import 'package:faden/data/book_downloads.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/downloads.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/library.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/domain/resolver.dart' show BookState;
import 'package:faden/l10n/strings.dart';
import 'package:faden/ui/cover.dart';
import 'package:faden/ui/library_screen.dart';
import 'package:faden/ui/player_screen.dart';
import 'package:faden/ui/providers.dart';
import 'package:faden/ui/settings_screen.dart';
import 'package:faden/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'fake_audio_handler.dart';

const _hour = 3600 * 1000;

BookSummary _book(String id, String title, String? author, {String status = 'ok'}) => BookSummary(
      bookId: id,
      title: title,
      author: author,
      durationMs: 10 * _hour,
      serverStatus: status,
    );

final _books = [
  _book('b-zauber', 'Der Zauberberg', 'Thomas Mann'),
  _book('b-momo', 'Momo', 'Michael Ende'),
  _book('b-ueber', 'Über Nacht', 'Anna Weber'),
  _book('b-anon', 'Anonyme Briefe', null),
  _book('b-halb', 'Halbe Sachen', 'Bert Brecht', status: 'incomplete'),
];

BookProgress _progress(String id, double fraction, int minutesAgo) => BookProgress(
      bookId: id,
      position: Position(fileHash: 'h-$id', offsetMs: 0),
      fraction: fraction,
      lastPlayed: DateTime(2026, 9, 24, 12).subtract(Duration(minutes: minutesAgo)),
    );

final _progressByBook = {
  'b-momo': _progress('b-momo', 0.5, 10),
  'b-zauber': _progress('b-zauber', 0.2, 60),
  'b-ueber': _progress('b-ueber', 1.0, 5), // finished: not under "Weiterhören"
};

/// A controller that shows exactly what the test sets (no cache, server
/// or journal behind it).
class _FixedLibraryController extends LibraryController {
  _FixedLibraryController({
    required List<BookSummary> books,
    required Map<String, BookProgress> progress,
    super.downloads,
  }) : super(repository: LibraryRepository(api: null, cache: null)) {
    this.books = books;
    progressByBook = progress;
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> refreshProgress() async {}
}

/// Download states the test sets; records cancels and (re)starts.
class _FakeDownloads extends BookDownloads {
  _FakeDownloads() : super(manager: DownloadManager(api: null, targetDir: Directory('unused')));

  final Map<String, BookDownloadState> fixed = {};
  final List<String> cancelled = [];
  final List<String> started = [];

  void put(String bookId, BookDownloadState state) {
    fixed[bookId] = state;
    notifyListeners();
  }

  @override
  BookDownloadState stateFor(String bookId) => fixed[bookId] ?? BookDownloadState.unknown;

  @override
  Map<String, BookDownloadState> get states => Map.unmodifiable(fixed);

  @override
  void cancel(String bookId) => cancelled.add(bookId);

  @override
  Future<bool> download(String bookId, Manifest manifest) async {
    started.add(bookId);
    return false;
  }
}

ManifestCandidate _candidate(String id, List<String> hashes) => ManifestCandidate(
      status: 'needs_review',
      manifest: Manifest(manifestId: id, files: [
        for (var i = 0; i < hashes.length; i++) ManifestFile(idx: i, fileHash: hashes[i], durationMs: 60000),
      ]),
    );

/// A library with a server behind it for "Reihenfolge prüfen" only.
class _ReviewController extends _FixedLibraryController {
  _ReviewController({required super.books}) : super(progress: const {});

  final _api = ApiClient.tryCreate(baseUrl: 'http://nas.local:8000', token: 'secret-token-1234');
  Completer<List<ManifestCandidate>>? gate;
  List<ManifestCandidate> candidates = const [];
  bool failFetch = false;
  bool failConfirm = false;
  int fetches = 0;
  final List<String> confirmed = [];

  @override
  ApiClient? get api => _api;

  @override
  Future<List<ManifestCandidate>> reviewCandidates(String bookId) async {
    fetches++;
    if (failFetch) throw Exception('offline');
    return gate?.future ?? candidates;
  }

  @override
  Future<void> confirmManifest(String bookId, String manifestId) async {
    confirmed.add(manifestId);
    if (failConfirm) throw Exception('409');
  }
}

/// A session the gated opener below fills as opening a book would.
class _Session extends PlayerSessionController {
  _Session({required super.handler, required super.journal});

  void show(String bookId, String title, {required bool resolved}) {
    this
      ..bookId = bookId
      ..bookTitle = title
      ..manifest = const Manifest(manifestId: 'm', files: [ManifestFile(idx: 0, fileHash: 'h', durationMs: 60000)])
      ..bookState = resolved
          ? const BookState(
              position: Position(fileHash: 'h', offsetMs: 0),
              globalMs: 0,
              lastAwake: Position(fileHash: 'h', offsetMs: 0),
              stop: Position(fileHash: 'h', offsetMs: 0),
              sleepSuspected: false,
              history: [],
              finished: false,
              needsConfirmation: false,
              sessionId: 's',
            )
          : null;
    notifyListeners();
  }
}

/// Opens in two steps the test releases: the book is known ([start], the
/// player may show), then resolved ([finish]).
class _GatedOpener extends BookOpener {
  _GatedOpener(super.ref);

  final List<String> opened = [];
  final _started = Completer<void>();
  final _finished = Completer<void>();

  void start() => _started.complete();
  void finish() => _finished.complete();

  @override
  Future<OpenBookResult> open(String bookId, {void Function()? onStarted}) async {
    opened.add(bookId);
    await _started.future;
    final session = _session!;
    session.show(bookId, 'Momo', resolved: false);
    onStarted?.call();
    await _finished.future;
    session.show(bookId, 'Momo', resolved: true);
    return OpenBookResult.opened;
  }
}

_Session? _session;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );

  group('arrangeBooks', () {
    List<String> titles(List<BookSummary> books) => [for (final b in books) b.title];

    test('"Zuletzt gehört": newest progress first, then the rest by title', () {
      expect(titles(arrangeBooks(books: _books, progress: _progressByBook, sort: LibrarySort.recent)), [
        'Über Nacht',
        'Momo',
        'Der Zauberberg',
        'Anonyme Briefe',
        'Halbe Sachen',
      ]);
    });

    test('by title, ignoring umlauts', () {
      expect(titles(arrangeBooks(books: _books, progress: const {}, sort: LibrarySort.title)), [
        'Anonyme Briefe',
        'Der Zauberberg',
        'Halbe Sachen',
        'Momo',
        'Über Nacht',
      ]);
    });

    test('by author, books without one last', () {
      expect(titles(arrangeBooks(books: _books, progress: const {}, sort: LibrarySort.author)), [
        'Über Nacht', // Anna Weber
        'Halbe Sachen', // Bert Brecht
        'Momo', // Michael Ende
        'Der Zauberberg', // Thomas Mann
        'Anonyme Briefe',
      ]);
    });

    test('search matches title or author, case and umlauts folded', () {
      expect(titles(arrangeBooks(books: _books, progress: const {}, sort: LibrarySort.title, query: 'ZAUBER')),
          ['Der Zauberberg']);
      expect(titles(arrangeBooks(books: _books, progress: const {}, sort: LibrarySort.title, query: 'ende')),
          ['Momo']);
      expect(titles(arrangeBooks(books: _books, progress: const {}, sort: LibrarySort.title, query: 'uber n')),
          ['Über Nacht']);
    });
  });

  group('LibraryScreen', () {
    late AppDatabase db;
    late FakeAudioHandler handler;
    late _Session session;

    Future<void> pumpLibrary(
      WidgetTester tester,
      LibraryController controller, {
      bool withNavigator = false,
      FadenTokens tokens = FadenTokens.day,
      List<Override> extra = const [],
    }) async {
      await tester.runAsync(() async {
        db = AppDatabase.memory();
        handler = FakeAudioHandler(Journal(db));
        session = _Session(handler: handler, journal: Journal(db));
      });
      _session = session;
      tester.view.physicalSize = const Size(430 * 3, 1400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            audioHandlerProvider.overrideWithValue(handler),
            libraryControllerProvider.overrideWith((ref) => controller),
            playerSessionProvider.overrideWith((ref) => session),
            ...extra,
          ],
          child: MaterialApp(
            theme: fadenThemeFor(tokens),
            home: withNavigator ? null : const LibraryScreen(),
            onGenerateRoute: withNavigator ? (_) => LibraryScreen.route() : null,
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> tearDownLibrary(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await handler.dispose();
        await db.close();
      });
    }

    double top(WidgetTester tester, String text) => tester.getTopLeft(find.text(text).last).dy;

    testWidgets('offline, books that are not downloaded say "nur online" (E58)', (tester) async {
      final controller = _FixedLibraryController(books: _books, progress: _progressByBook)..offline = true;
      await pumpLibrary(tester, controller);
      expect(find.text(AppStrings.libraryOnlineOnly(AppStrings.libraryStatusNew)), findsOneWidget,
          reason: 'Anonyme Briefe, never played');
      expect(find.text(AppStrings.libraryStatusIncomplete), findsOneWidget,
          reason: 'an incomplete book keeps its own explanation');
      await tearDownLibrary(tester);
    });

    testWidgets('online, no row says "nur online"', (tester) async {
      await pumpLibrary(tester, _FixedLibraryController(books: _books, progress: _progressByBook));
      expect(find.text(AppStrings.libraryOnlineOnly(AppStrings.libraryStatusNew)), findsNothing);
      expect(find.text(AppStrings.libraryStatusNew), findsOneWidget);
      await tearDownLibrary(tester);
    });

    testWidgets('"Weiterhören" lists unfinished recent books as cards above all books, not twice (E65)',
        (tester) async {
      await pumpLibrary(tester, _FixedLibraryController(books: _books, progress: _progressByBook));
      expect(find.text(AppStrings.libraryContinueSection), findsOneWidget);
      expect(find.text(AppStrings.libraryAllBooks), findsOneWidget);
      // Momo and Zauberberg as cards only, not repeated in the list.
      expect(find.text('Momo'), findsOneWidget);
      expect(find.text('Der Zauberberg'), findsOneWidget);
      expect(find.text('Über Nacht'), findsOneWidget);
      expect(find.ancestor(of: find.text('Momo'), matching: find.byType(ContinueCard)), findsOneWidget);
      expect(find.ancestor(of: find.text('Der Zauberberg'), matching: find.byType(ContinueCard)), findsOneWidget);
      expect(find.byType(BookRow), findsNWidgets(3));
      final section = top(tester, AppStrings.libraryContinueSection);
      final all = top(tester, AppStrings.libraryAllBooks);
      final momo = top(tester, 'Momo');
      final zauber = top(tester, 'Der Zauberberg');
      expect(section, lessThan(momo));
      expect(momo, lessThan(zauber));
      expect(zauber, lessThan(all));
      // Set apart from the rows: a larger cover and title.
      expect(tester.getSize(find.descendant(of: find.byType(ContinueCard).first, matching: find.byType(BookCover))).width,
          greaterThan(BookRow.coverSize));
      expect(tester.widget<Text>(find.text('Momo')).style?.fontSize, FadenTypeSizes.title);
      // Progress, finished and new books, and the author at caption size.
      expect(find.text(AppStrings.remainingTime('5 Std.')), findsWidgets);
      expect(find.text(AppStrings.libraryProgressFinished), findsOneWidget);
      expect(find.text(AppStrings.libraryStatusNew), findsOneWidget);
      expect(tester.widget<Text>(find.text('Michael Ende').first).style?.fontSize, 14);
      await tearDownLibrary(tester);
    });

    testWidgets('search filters and hides "Weiterhören"', (tester) async {
      await pumpLibrary(tester, _FixedLibraryController(books: _books, progress: _progressByBook));
      await tester.enterText(find.byType(TextField), 'mann');
      await tester.pump();
      expect(find.text(AppStrings.libraryContinueSection), findsNothing);
      // A "Weiterhören" book is still found (E65): the results are complete.
      expect(find.text('Der Zauberberg'), findsOneWidget);
      expect(find.ancestor(of: find.text('Der Zauberberg'), matching: find.byType(BookRow)), findsOneWidget);
      expect(find.text('Momo'), findsNothing);
      await tester.enterText(find.byType(TextField), 'xyz');
      await tester.pump();
      expect(find.text(AppStrings.libraryNoMatches), findsOneWidget);
      await tearDownLibrary(tester);
    });

    testWidgets('the sort menu reorders all books', (tester) async {
      await pumpLibrary(tester, _FixedLibraryController(books: _books, progress: _progressByBook));
      expect(top(tester, 'Über Nacht'), lessThan(top(tester, 'Anonyme Briefe')));
      await tester.tap(find.byTooltip(AppStrings.librarySortTooltip));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppStrings.librarySortTitle));
      await tester.pumpAndSettle();
      expect(top(tester, 'Anonyme Briefe'), lessThan(top(tester, 'Halbe Sachen')));
      expect(top(tester, 'Halbe Sachen'), lessThan(top(tester, 'Über Nacht')));
      await tearDownLibrary(tester);
    });

    testWidgets('an incomplete book explains itself on tap', (tester) async {
      await pumpLibrary(tester, _FixedLibraryController(books: _books, progress: const {}));
      await tester.tap(find.text('Halbe Sachen'));
      await tester.pump();
      expect(find.text(AppStrings.libraryIncompleteExplain), findsOneWidget);
      await tearDownLibrary(tester);
    });

    testWidgets('first launch without a server offers "Server einrichten"', (tester) async {
      await pumpLibrary(tester, _FixedLibraryController(books: const [], progress: const {}));
      expect(find.text(AppStrings.setupTitle), findsOneWidget);
      expect(find.text(AppStrings.libraryRetry), findsNothing, reason: 'nothing to retry yet');
      await tester.tap(find.text(AppStrings.setupAction));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      await tearDownLibrary(tester);
    });

    testWidgets('a running download says what is left, not what arrived (E62); cancel and retry work',
        (tester) async {
      final downloads = _FakeDownloads()
        ..put(
          'b-momo',
          const BookDownloadState(
            status: BookDownloadStatus.downloading,
            filesDone: 3,
            filesTotal: 10,
            receivedBytes: 80 * 1000 * 1000,
            fraction: 0.25,
            remainingBytes: 237 * 1000 * 1000,
          ),
        )
        ..put('b-anon', const BookDownloadState(status: BookDownloadStatus.downloading, filesTotal: 4))
        ..put('b-zauber', const BookDownloadState(status: BookDownloadStatus.failed, filesTotal: 4, error: 'x'));
      final controller = _FixedLibraryController(books: _books, progress: const {}, downloads: downloads)
        ..manifests['b-zauber'] = const Manifest(manifestId: 'm', files: [
          ManifestFile(idx: 0, fileHash: 'h', durationMs: 1000),
        ]);
      await pumpLibrary(tester, controller);

      final momo = find.ancestor(of: find.text('Momo'), matching: find.byType(BookRow));
      expect(find.descendant(of: momo, matching: find.text(AppStrings.downloadRemaining('240 MB'))), findsOneWidget);
      expect(find.textContaining('80 MB'), findsNothing, reason: 'not the received amount');
      expect(find.descendant(of: momo, matching: find.byType(CircularProgressIndicator)), findsNothing,
          reason: 'no progress ring');
      // No estimate yet: a plain "Lädt …".
      final anon = find.ancestor(of: find.text('Anonyme Briefe'), matching: find.byType(BookRow));
      expect(find.descendant(of: anon, matching: find.text(AppStrings.libraryDownloading)), findsOneWidget);

      await tester.tap(find.descendant(of: momo, matching: find.byTooltip(AppStrings.downloadCancel)));
      await tester.pump();
      expect(downloads.cancelled, ['b-momo']);

      final zauber = find.ancestor(of: find.text('Der Zauberberg'), matching: find.byType(BookRow));
      expect(find.descendant(of: zauber, matching: find.text(AppStrings.libraryDownloadFailed)), findsOneWidget);
      await tester.tap(find.descendant(of: zauber, matching: find.byTooltip(AppStrings.libraryRetry)));
      await tester.pump();
      expect(downloads.started, ['b-zauber']);

      downloads.put('b-momo', const BookDownloadState(status: BookDownloadStatus.downloading, remainingBytes: 1500000000));
      await tester.pump();
      expect(find.text(AppStrings.downloadRemaining('1,5 GB')), findsOneWidget);
      await tearDownLibrary(tester);
    });

    testWidgets('is the base: no back button, settings in the app bar (E60)', (tester) async {
      await pumpLibrary(tester, _FixedLibraryController(books: _books, progress: const {}));
      expect(find.byType(BackButton), findsNothing);
      expect(find.byTooltip(AppStrings.settingsTitle), findsOneWidget);
      expect(find.byTooltip(AppStrings.librarySortTooltip), findsOneWidget);
      await tearDownLibrary(tester);
    });

    testWidgets('a large title collapses into the bar as the list scrolls (E65)', (tester) async {
      final many = [for (var i = 0; i < 30; i++) _book('b$i', 'Buch $i', 'Autor $i')];
      await pumpLibrary(tester, _FixedLibraryController(books: many, progress: const {}));
      Text title(int i) => tester.widget<Text>(find.text(AppStrings.libraryTitle).at(i));
      double opacityOf(int i) => tester
          .widget<Opacity>(find.ancestor(of: find.text(AppStrings.libraryTitle).at(i), matching: find.byType(Opacity)))
          .opacity;
      // [0] the small title in the bar, [1] the large one below it.
      expect(title(1).style?.fontSize, FadenTypeSizes.display);
      expect(tester.getTopLeft(find.text(AppStrings.libraryTitle).at(1)).dx, 16, reason: 'left-aligned');
      expect(opacityOf(0), 0, reason: 'expanded: only the large title');
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pump();
      expect(opacityOf(0), 1, reason: 'collapsed: the small title in the bar');
      await tearDownLibrary(tester);
    });

    testWidgets('a tap shows the player at once, with a spinner in the row; further taps wait (E65)',
        (tester) async {
      late _GatedOpener opener;
      final controller = _FixedLibraryController(books: _books, progress: const {});
      await pumpLibrary(
        tester,
        controller,
        withNavigator: true,
        extra: [bookOpenerProvider.overrideWith((ref) => opener = _GatedOpener(ref))],
      );
      await tester.tap(find.text('Momo'));
      await tester.pump();
      expect(opener.opened, ['b-momo']);
      final momo = find.ancestor(of: find.text('Momo'), matching: find.byType(BookRow));
      expect(find.descendant(of: momo, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      // A second tap, on another book, while the first is still opening.
      await tester.tap(find.text('Anonyme Briefe'));
      await tester.pump();
      expect(opener.opened, ['b-momo'], reason: 'never two openings at once');

      opener.start();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(PlayerScreen), findsOneWidget, reason: 'up before the book is ready (sync, cover)');
      expect(find.byType(PlayerLoading), findsOneWidget);
      expect(find.descendant(of: find.byType(PlayerLoading), matching: find.text('Momo')), findsOneWidget);

      opener.finish();
      await tester.pumpAndSettle();
      expect(find.byType(PlayerScreen), findsOneWidget, reason: 'still one player');
      expect(find.byType(PlayerLoading), findsNothing);
      expect(find.byType(PlayerBody), findsOneWidget);
      await tearDownLibrary(tester);
    });

    testWidgets('"Reihenfolge prüfen" says why it cannot, shows a spinner and reports errors (E65)', (tester) async {
      final review = [
        BookSummary(bookId: 'b-review', title: 'Umsortiert', author: null, durationMs: _hour, serverStatus: 'needs_review'),
      ];
      Finder spinner() => find.byType(CircularProgressIndicator);

      // Offline: no server to ask.
      var controller = _ReviewController(books: review)..offline = true;
      await pumpLibrary(tester, controller);
      await tester.tap(find.text('Umsortiert'));
      await tester.pump();
      expect(find.text(AppStrings.reviewOffline), findsOneWidget);
      expect(controller.fetches, 0);
      await tearDownLibrary(tester);

      // The candidates are loading: a spinner in the row; none offered.
      controller = _ReviewController(books: review)..gate = Completer<List<ManifestCandidate>>();
      await pumpLibrary(tester, controller);
      await tester.tap(find.text('Umsortiert'));
      await tester.pump();
      expect(spinner(), findsOneWidget);
      controller.gate!.complete(const []);
      await tester.pump();
      await tester.pump();
      expect(spinner(), findsNothing);
      expect(find.text(AppStrings.reviewNothingToChoose), findsOneWidget);
      await tearDownLibrary(tester);

      // Loading fails.
      controller = _ReviewController(books: review)..failFetch = true;
      await pumpLibrary(tester, controller);
      await tester.tap(find.text('Umsortiert'));
      await tester.pump();
      await tester.pump();
      expect(find.text(AppStrings.reviewLoadFailed), findsOneWidget);
      await tearDownLibrary(tester);

      // Confirming fails.
      controller = _ReviewController(books: review)
        ..candidates = [_candidate('m-a', ['h1', 'h2']), _candidate('m-b', ['h2', 'h1'])]
        ..failConfirm = true;
      await pumpLibrary(tester, controller);
      await tester.tap(find.text('Umsortiert'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppStrings.reviewDialogChoose).first);
      await tester.pump();
      await tester.pump();
      expect(controller.confirmed, ['m-a']);
      expect(find.text(AppStrings.confirmManifestFailed), findsOneWidget);
      expect(find.text(AppStrings.confirmManifestSuccess), findsNothing);
      await tearDownLibrary(tester);
    });

    testWidgets('offline with known books shows the small banner', (tester) async {
      final controller = _FixedLibraryController(books: _books, progress: const {})..offline = true;
      await pumpLibrary(tester, controller);
      expect(find.text(AppStrings.offlineBanner), findsOneWidget);
      expect(find.text('Momo'), findsOneWidget);
      await tearDownLibrary(tester);
    });

    testWidgets('secondary text on the raised surfaces keeps 4.5:1 at night (E65)', (tester) async {
      final controller = _FixedLibraryController(books: _books, progress: const {})..offline = true;
      await pumpLibrary(tester, controller, tokens: FadenTokens.night);
      final banner = tester.widget<Text>(find.text(AppStrings.offlineBanner));
      expect(banner.style?.color, FadenTokens.night.tinte);
      final theme = Theme.of(tester.element(find.byType(TextField)));
      expect(theme.inputDecorationTheme.hintStyle?.color, FadenTokens.night.tinte);
      await tearDownLibrary(tester);
    });
  });

  group('review dialog', () {
    ManifestCandidate candidate(String id, List<(String hash, String? title, int? track)> files) =>
        ManifestCandidate(
          status: 'needs_review',
          manifest: Manifest(manifestId: id, files: [
            for (var i = 0; i < files.length; i++)
              ManifestFile(
                idx: i,
                fileHash: files[i].$1,
                durationMs: 60000,
                title: files[i].$2,
                track: files[i].$3,
              ),
          ]),
        );

    testWidgets('shows each candidate\'s file order and returns the chosen one', (tester) async {
      final candidates = [
        candidate('m-a', [('h1', 'Anfang', 1), ('h2', 'Mitte', 2), ('h3', null, 3)]),
        candidate('m-b', [('h1', 'Anfang', 1), ('h3', null, 3), ('h2', 'Mitte', 2)]),
      ];
      String? chosen;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => chosen = await showReviewDialog(context, candidates),
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text(AppStrings.reviewDialogOption(1)), findsOneWidget);
      expect(find.text(AppStrings.reviewDialogOption(2)), findsOneWidget);
      // Starting one file before the first difference.
      expect(find.text('1. Anfang · ${AppStrings.reviewTrack(1)}'), findsNWidgets(2));
      expect(find.text('2. Mitte · ${AppStrings.reviewTrack(2)}'), findsOneWidget);
      expect(find.text('3. ${AppStrings.reviewUntitled} · ${AppStrings.reviewTrack(3)}'), findsOneWidget);
      expect(find.text('2. ${AppStrings.reviewUntitled} · ${AppStrings.reviewTrack(3)}'), findsOneWidget);
      expect(find.text('3. Mitte · ${AppStrings.reviewTrack(2)}'), findsOneWidget);
      expect(find.textContaining('needs_review'), findsNothing);
      expect(find.textContaining('Option'), findsNothing);

      await tester.tap(find.text(AppStrings.reviewDialogChoose).last);
      await tester.pumpAndSettle();
      expect(chosen, 'm-b');
    });

    test('firstDifference finds where the orders part', () {
      final a = Manifest(manifestId: 'a', files: [
        for (final h in ['1', '2', '3', '4']) ManifestFile(idx: 0, fileHash: h, durationMs: 1),
      ]);
      final b = Manifest(manifestId: 'b', files: [
        for (final h in ['1', '2', '4', '3']) ManifestFile(idx: 0, fileHash: h, durationMs: 1),
      ]);
      expect(ReviewCandidates.firstDifference([a, b]), 2);
      expect(ReviewCandidates.firstDifference([a]), 0);
    });
  });
}
