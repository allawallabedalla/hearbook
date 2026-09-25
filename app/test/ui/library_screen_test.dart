// Tests ui/library_screen.dart (decision E48): search, order and the
// "Weiterhören" section; the status and genre filters, "Nach Autor" and
// "Genre ändern" (E70); the first-launch state without a server; a
// running download saying what is left (E62), with cancel and retry; the
// library as the base route without a back button (E60); and the
// "Reihenfolge prüfen" dialog, which shows each candidate's real file
// order instead of "Option 1 · 12 · needs_review".

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:faden/data/api.dart' show ApiClient;
import 'package:faden/data/book_downloads.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/downloads.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/library.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/domain/resolver.dart' show BookState;
import 'package:faden/l10n/strings.dart';
import 'package:faden/ui/controls.dart';
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
import 'fake_screen_brightness.dart';

const _hour = 3600 * 1000;

BookSummary _book(String id, String title, String? author,
        {String status = 'ok', String? genre, int? durationMs = 10 * _hour}) =>
    BookSummary(
      bookId: id,
      title: title,
      author: author,
      durationMs: durationMs,
      serverStatus: status,
      genre: genre,
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

/// A library with a server behind it for "Genre ändern" only (E70).
class _GenreController extends _FixedLibraryController {
  _GenreController({required super.books}) : super(progress: const {});

  final _api = ApiClient.tryCreate(baseUrl: 'http://nas.local:8000', token: 'secret-token-1234');
  bool fail = false;
  final List<(String, String?)> changes = [];

  @override
  ApiClient? get api => _api;

  @override
  Future<List<String>> genreLabels() async => knownGenres;

  @override
  Future<void> setGenre(String bookId, String? genre) async {
    changes.add((bookId, genre));
    if (fail) throw Exception('422');
    books = [for (final b in books) b.bookId == bookId ? b.withGenre(genre) : b];
    notifyListeners();
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

    test('by author\'s surname (E70), books without one last', () {
      expect(titles(arrangeBooks(books: _books, progress: const {}, sort: LibrarySort.author)), [
        'Halbe Sachen', // Bert Brecht
        'Momo', // Michael Ende
        'Der Zauberberg', // Thomas Mann
        'Über Nacht', // Anna Weber
        'Anonyme Briefe',
      ]);
    });

    test('by length (E70): shortest first, unknown lengths last', () {
      final books = [
        _book('a', 'Lang', null, durationMs: 20 * _hour),
        _book('b', 'Unbekannt lang', null, durationMs: null),
        _book('c', 'Kurz', null, durationMs: 2 * _hour),
        _book('d', 'Auch kurz', null, durationMs: 2 * _hour),
      ];
      expect(titles(arrangeBooks(books: books, progress: const {}, sort: LibrarySort.length)),
          ['Auch kurz', 'Kurz', 'Lang', 'Unbekannt lang']);
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

  group('filters (E70)', () {
    List<String> titles(List<BookSummary> books) => [for (final b in books) b.title];
    List<String> filtered(LibraryStatusFilter status, {String? genre, String query = ''}) => titles(arrangeBooks(
          books: _books,
          progress: _progressByBook,
          sort: LibrarySort.title,
          status: status,
          genre: genre,
          query: query,
        ));

    test('status as the rows say it: "neu", started, "gehört"', () {
      expect(listeningStateOf(null), ListeningState.unstarted);
      expect(listeningStateOf(_progress('x', 0, 1)), ListeningState.unstarted);
      expect(listeningStateOf(_progress('x', 0.3, 1)), ListeningState.started);
      expect(listeningStateOf(_progress('x', 0.996, 1)), ListeningState.finished);
      // Progress whose share is not known yet reads "neu", as in its row.
      final unknownShare = BookProgress(
        bookId: 'x',
        position: const Position(fileHash: 'h', offsetMs: 1),
        fraction: null,
        lastPlayed: DateTime(2026),
      );
      expect(listeningStateOf(unknownShare), ListeningState.unstarted);
    });

    test('"Alle · Läuft · Neu · Gehört"', () {
      expect(filtered(LibraryStatusFilter.all), hasLength(5));
      expect(filtered(LibraryStatusFilter.started), ['Der Zauberberg', 'Momo']);
      expect(filtered(LibraryStatusFilter.unstarted), ['Anonyme Briefe', 'Halbe Sachen']);
      expect(filtered(LibraryStatusFilter.finished), ['Über Nacht']);
    });

    test('genre filters too; a search ignores both filters', () {
      final books = [
        _book('k', 'Krimi', 'A', genre: 'Krimi & Thriller'),
        _book('h', 'Witz', 'B', genre: 'Humor'),
        _book('n', 'Ohne', 'C'),
      ];
      List<String> of({String? genre, LibraryStatusFilter status = LibraryStatusFilter.all, String query = ''}) =>
          titles(arrangeBooks(
            books: books,
            progress: const {},
            sort: LibrarySort.title,
            status: status,
            genre: genre,
            query: query,
          ));
      expect(of(genre: 'Humor'), ['Witz']);
      expect(of(genre: 'Humor', status: LibraryStatusFilter.finished), isEmpty);
      expect(of(genre: 'Humor', status: LibraryStatusFilter.finished, query: 'krimi'), ['Krimi']);
      expect(filtered(LibraryStatusFilter.finished, query: 'momo'), ['Momo']);
    });

    test('genresIn lists the library\'s genres in the server\'s order', () {
      expect(genresIn(_books), isEmpty);
      expect(
        genresIn([
          _book('1', 'A', null, genre: 'Humor'),
          _book('2', 'B', null, genre: 'Krimi & Thriller'),
          _book('3', 'C', null, genre: 'Humor'),
          _book('4', 'D', null, genre: 'Lyrik'),
          _book('5', 'E', null),
        ]),
        ['Krimi & Thriller', 'Humor', 'Lyrik'],
      );
    });
  });

  group('"Nach Autor" (E70)', () {
    test('the surname is the last word of the name', () {
      expect(authorSortKey('Thomas Mann'), 'mann');
      expect(authorSortKey('  Ursula K. Le Guin '), 'guin');
      expect(authorSortKey('Homer'), 'homer');
      expect(authorSortKey('Anna Österreich'), 'osterreich');
    });

    test('groups by surname, "Unbekannt" last, each keeping the chosen order', () {
      final books = [
        _book('1', 'Zeta', 'Thomas Mann'),
        _book('2', 'Alpha', 'Heinrich Mann'),
        _book('3', 'Zulu', 'thomas  mann'),
        _book('4', 'Gamma', null),
        _book('5', 'Delta', 'Bert Brecht'),
        _book('6', 'Epsilon', '  '),
      ];
      final byTitle = arrangeBooks(books: books, progress: const {}, sort: LibrarySort.title);
      final groups = groupByAuthor(byTitle);
      expect([for (final g in groups) g.author], ['Bert Brecht', 'Heinrich Mann', 'Thomas Mann', null]);
      expect([for (final b in groups[2].books) b.title], ['Zeta', 'Zulu'], reason: 'case and spaces fold');
      expect([for (final b in groups[3].books) b.title], ['Epsilon', 'Gamma']);

      final entries = libraryEntries(byTitle, LibraryGrouping.author);
      expect(entries.first.author, 'Bert Brecht');
      expect(entries.first.book, isNull);
      expect(entries, hasLength(books.length + groups.length));
      expect(libraryEntries(byTitle, LibraryGrouping.list).every((e) => e.book != null), isTrue);
    });
  });

  test('LibraryController.setGenre updates the list after the server said yes', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://nas.local:8787'))
      ..interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {'genre': (o.data as Map)['genre']}));
      }));
    final controller = LibraryController(
      repository: LibraryRepository(api: ApiClient(dio), cache: null),
      downloads: null,
    )..books = [_book('b1', 'Eins', null), _book('b2', 'Zwei', null, genre: 'Romane')];
    var notified = 0;
    controller.addListener(() => notified++);
    await controller.setGenre('b1', 'Humor');
    expect({for (final b in controller.books) b.bookId: b.genre}, {'b1': 'Humor', 'b2': 'Romane'});
    expect(notified, 1);
    controller.dispose();
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
      Size size = const Size(430, 1400),
      double textScale = 1.0,
    }) async {
      await tester.runAsync(() async {
        db = AppDatabase.memory();
        handler = FakeAudioHandler(Journal(db));
        session = _Session(handler: handler, journal: Journal(db));
      });
      _session = session;
      tester.view.physicalSize = size * 3;
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
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
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

    Future<void> settleStore(WidgetTester tester) async {
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pumpAndSettle();
      }
    }

    List<String> rowTitles(WidgetTester tester) => [
          for (final row in tester.widgetList<BookRow>(find.byType(BookRow))) row.book.title,
        ];

    testWidgets('status chips sit above "Alle Bücher", filter only that list and are remembered (E70)',
        (tester) async {
      await pumpLibrary(tester, _FixedLibraryController(books: _books, progress: _progressByBook));
      for (final label in ['Alle', 'Läuft', 'Neu', 'Gehört']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.byType(LibraryFilterBar), findsOneWidget);
      expect(find.text(AppStrings.libraryFilterGenre), findsNothing, reason: 'no book has a genre');
      final chips = tester.getRect(find.byType(LibraryFilterBar));
      expect(chips.top, greaterThan(top(tester, AppStrings.libraryAllBooks)));
      expect(chips.bottom, lessThanOrEqualTo(tester.getTopLeft(find.byType(BookRow).first).dy));
      expect(tester.getSemantics(find.bySemanticsLabel('Alle')), isSemantics(isSelected: true, isButton: true));

      await tester.tap(find.text('Gehört'));
      await settleStore(tester);
      expect(rowTitles(tester), ['Über Nacht']);
      // "Weiterhören" stays as it was.
      expect(find.byType(ContinueCard), findsNWidgets(2));

      await tester.tap(find.text('Neu'));
      await settleStore(tester);
      expect(rowTitles(tester), ['Anonyme Briefe', 'Halbe Sachen']);

      // The started books are all under "Weiterhören": nothing left here.
      await tester.tap(find.text('Läuft'));
      await settleStore(tester);
      expect(find.byType(BookRow), findsNothing);
      expect(find.text(AppStrings.libraryFilterEmpty), findsOneWidget);
      expect(find.byType(LibraryFilterBar), findsOneWidget, reason: 'the way back stays');
      expect((await tester.runAsync(SettingsStore(db).libraryView))!.status, LibraryStatusFilter.started);

      // A search finds every book, whatever the filter, and hides the chips.
      await tester.enterText(find.byType(TextField), 'nacht');
      await tester.pump();
      expect(rowTitles(tester), ['Über Nacht']);
      expect(find.byType(LibraryFilterBar), findsNothing);
      await tearDownLibrary(tester);
    });

    testWidgets('a remembered filter is there on the next start (E70)', (tester) async {
      await pumpLibrary(
        tester,
        _FixedLibraryController(books: _books, progress: _progressByBook),
        extra: [
          initialLibraryViewProvider.overrideWithValue(const LibraryView(status: LibraryStatusFilter.finished)),
        ],
      );
      expect(rowTitles(tester), ['Über Nacht']);
      await tearDownLibrary(tester);
    });

    testWidgets('"Genre ▾" lists the library\'s genres and filters by one (E70)', (tester) async {
      final books = [
        _book('k', 'Mord im Nebel', 'Ada Krimi', genre: 'Krimi & Thriller'),
        _book('h', 'Lachen', 'Bo Witz', genre: 'Humor'),
        _book('n', 'Ohne Genre', 'Cy Leer'),
      ];
      await pumpLibrary(tester, _FixedLibraryController(books: books, progress: const {}));
      expect(rowTitles(tester), ['Lachen', 'Mord im Nebel', 'Ohne Genre']);
      // The test font is wide: the row scrolls sideways to "Genre ▾".
      await tester.ensureVisible(find.text(AppStrings.libraryFilterGenre));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppStrings.libraryFilterGenre));
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.libraryFilterAllGenres), findsOneWidget);
      expect(find.text('Krimi & Thriller'), findsOneWidget);
      expect(find.text('Humor'), findsOneWidget);
      expect(find.text('Romane'), findsNothing, reason: 'only genres the library has');
      await tester.tap(find.text('Humor'));
      await settleStore(tester);
      expect(rowTitles(tester), ['Lachen']);
      expect(find.descendant(of: find.byType(LibraryFilterBar), matching: find.text('Humor')), findsOneWidget);
      expect((await tester.runAsync(SettingsStore(db).libraryView))!.genre, 'Humor');

      await tester.tap(find.text('Humor'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppStrings.libraryFilterAllGenres));
      await settleStore(tester);
      expect(rowTitles(tester), hasLength(3));
      await tearDownLibrary(tester);
    });

    testWidgets('"Nach Autor" groups under author headers, "Unbekannt" last (E70)', (tester) async {
      await pumpLibrary(tester, _FixedLibraryController(books: _books, progress: const {}));
      await tester.tap(find.byTooltip(AppStrings.librarySortTooltip));
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.librarySortLength), findsOneWidget);
      await tester.tap(find.text(AppStrings.libraryGroupAuthor));
      await settleStore(tester);
      expect(find.text(AppStrings.libraryUnknownAuthor), findsOneWidget);
      // Header and the row's own author line.
      expect(find.text('Bert Brecht'), findsNWidgets(2));
      final order = ['Bert Brecht', 'Michael Ende', 'Thomas Mann', 'Anna Weber'];
      for (var i = 0; i + 1 < order.length; i++) {
        expect(tester.getTopLeft(find.text(order[i]).first).dy, lessThan(tester.getTopLeft(find.text(order[i + 1]).first).dy));
      }
      expect(top(tester, 'Anna Weber'), lessThan(top(tester, AppStrings.libraryUnknownAuthor)));
      expect(top(tester, AppStrings.libraryUnknownAuthor), lessThan(top(tester, 'Anonyme Briefe')));
      expect((await tester.runAsync(SettingsStore(db).libraryView))!.grouping, LibraryGrouping.author);
      await tearDownLibrary(tester);
    });

    testWidgets('long press: "Genre ändern" sends the choice, says when it fails, and waits for the server (E70)',
        (tester) async {
      final controller = _GenreController(books: [_book('b-anon', 'Anonyme Briefe', null)]);
      await pumpLibrary(tester, controller);
      await tester.longPress(find.text('Anonyme Briefe'));
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.genreNone), findsOneWidget);
      await tester.tap(find.text(AppStrings.genreChange));
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.genreAutomatic), findsOneWidget);
      for (final g in knownGenres) {
        expect(find.text(g), findsOneWidget, reason: g);
      }
      await tester.tap(find.text('Humor'));
      await tester.pumpAndSettle();
      expect(controller.changes, [('b-anon', 'Humor')]);

      // Back to automatic; the current genre is ticked.
      await tester.longPress(find.text('Anonyme Briefe'));
      await tester.pumpAndSettle();
      expect(find.text('Humor'), findsOneWidget, reason: 'the current genre under the action');
      await tester.tap(find.text(AppStrings.genreChange));
      await tester.pumpAndSettle();
      expect(find.descendant(of: find.widgetWithText(ListTile, 'Humor'), matching: find.byIcon(Icons.check)),
          findsOneWidget);
      controller.fail = true;
      await tester.tap(find.text(AppStrings.genreAutomatic));
      await tester.pumpAndSettle();
      expect(controller.changes.last, ('b-anon', null));
      expect(find.text(AppStrings.genreChangeFailed), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      controller.offline = true;
      controller.notifyListeners();
      await tester.pump();
      await tester.longPress(find.text('Anonyme Briefe'));
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.genreOffline), findsOneWidget);
      expect(tester.widget<ListTile>(find.widgetWithText(ListTile, AppStrings.genreChange)).enabled, isFalse);
      await tester.tap(find.text(AppStrings.genreChange));
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.genreAutomatic), findsNothing);
      await tearDownLibrary(tester);
    });

    for (final tokens in [FadenTokens.day, FadenTokens.night]) {
      testWidgets('${tokens.isDark ? 'dark' : 'day'}: SE x1.35 fits the chips in one row (E70)', (tester) async {
        final books = [
          for (final b in _books) b.withGenre(b.bookId == 'b-anon' ? 'Fantasy & Science-Fiction' : null),
        ];
        await pumpLibrary(
          tester,
          _FixedLibraryController(books: books, progress: _progressByBook),
          size: const Size(375, 667),
          textScale: 1.35,
          tokens: tokens,
        );
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
        await tester.pump();
        expect(tester.takeException(), isNull);
        final bar = tester.getRect(find.byType(LibraryFilterBar));
        expect(bar.height, greaterThanOrEqualTo(fadenMinTapTarget));
        expect(bar.width, lessThanOrEqualTo(375));
        for (final label in ['Alle', 'Läuft', 'Neu', 'Gehört']) {
          final chip = tester.getRect(find.text(label));
          expect(chip.top, greaterThanOrEqualTo(bar.top));
          expect(chip.bottom, lessThanOrEqualTo(bar.bottom), reason: label);
        }
        // "Genre ▾" may sit past the edge; the row scrolls to it.
        await tester.ensureVisible(find.text(AppStrings.libraryFilterGenre));
        await tester.pumpAndSettle();
        await tester.tap(find.text(AppStrings.libraryFilterGenre));
        await tester.pumpAndSettle();
        expect(find.text('Fantasy & Science-Fiction'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tearDownLibrary(tester);
      });
    }

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

  group('redesign (E71–E76)', () {
    late AppDatabase db;
    late FakeAudioHandler handler;
    late _Session session;

    Future<void> pump(
      WidgetTester tester, {
      FadenTokens tokens = FadenTokens.day,
      bool night = false,
      Size size = const Size(430, 1400),
      double textScale = 1.0,
      LibraryView view = const LibraryView(),
      String? openBook,
      List<BookSummary>? books,
    }) async {
      await tester.runAsync(() async {
        db = AppDatabase.memory();
        handler = FakeAudioHandler(Journal(db));
        session = _Session(handler: handler, journal: Journal(db));
      });
      _session = session;
      if (openBook != null) session.show(openBook, 'Der Zauberberg', resolved: true);
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final brightness = FakeScreenBrightness(night ? 0.1 : 0.8);
      addTearDown(brightness.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            audioHandlerProvider.overrideWithValue(handler),
            libraryControllerProvider.overrideWith(
              (ref) => _FixedLibraryController(books: books ?? _books, progress: _progressByBook),
            ),
            playerSessionProvider.overrideWith((ref) => session),
            screenBrightnessSourceProvider.overrideWithValue(brightness),
            initialNightModeProvider.overrideWithValue(night),
            initialLibraryViewProvider.overrideWithValue(view),
          ],
          child: MaterialApp(
            theme: fadenThemeFor(night ? FadenTokens.night : tokens),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
            home: const LibraryScreen(),
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> tearDown(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await handler.dispose();
        await db.close();
      });
    }

    Material cardOf(WidgetTester tester, String title, Type type) => tester.widget<Material>(find
        .descendant(
          of: find.ancestor(of: find.text(title), matching: find.byType(type)),
          matching: find.byType(Material),
        )
        .first);

    testWidgets('the latest "Weiterhören" book is a large card with a bold title and a progress capsule',
        (tester) async {
      await pump(tester);
      final hero = find.byWidgetPredicate((w) => w is ContinueCard && w.hero);
      expect(hero, findsOneWidget);
      expect(tester.widget<ContinueCard>(hero).book.bookId, 'b-momo', reason: 'the most recent one');
      expect(tester.getSize(find.descendant(of: hero, matching: find.byType(BookCover))).width,
          ContinueCard.coverSize);
      final title = tester.widget<Text>(find.text('Momo'));
      expect(title.style?.fontWeight, FontWeight.w700);
      final capsule = find.descendant(of: hero, matching: find.byType(FadenCapsule));
      expect(find.descendant(of: capsule, matching: find.text(AppStrings.libraryPercent(50))), findsOneWidget);
      expect(find.descendant(of: capsule, matching: find.text(AppStrings.remainingTime('5 Std.'))), findsOneWidget);
      // The others are smaller cards.
      final small = find.byWidgetPredicate((w) => w is ContinueCard && !w.hero);
      expect(tester.getSize(find.descendant(of: small, matching: find.byType(BookCover))).width,
          ContinueCard.smallCoverSize);
      // Soft shadow by day instead of a border.
      final decorated = tester.widget<DecoratedBox>(
          find.descendant(of: hero, matching: find.byType(DecoratedBox)).first);
      expect((decorated.decoration as ShapeDecoration).shadows, isNotEmpty);
      await tearDown(tester);
    });

    testWidgets('each book under "Alle Bücher" is its own card, the state as a capsule on the right',
        (tester) async {
      await pump(tester);
      final row = find.ancestor(of: find.text('Über Nacht'), matching: find.byType(BookRow));
      expect(find.descendant(of: row, matching: find.byType(FadenCard)), findsOneWidget);
      final capsule = find.descendant(of: row, matching: find.byType(FadenCapsule));
      expect(find.descendant(of: capsule, matching: find.text(AppStrings.libraryProgressFinished)), findsOneWidget);
      expect(tester.getTopLeft(capsule).dx, greaterThan(tester.getTopRight(find.text('Anna Weber')).dx),
          reason: 'beside the text, not a third line');
      // Cards stand apart by a small gap.
      final rows = tester.widgetList<BookRow>(find.byType(BookRow)).toList();
      final a = tester.getRect(find.byWidget(rows[0]));
      final b = tester.getRect(find.byWidget(rows[1]));
      expect(b.top - a.bottom, greaterThanOrEqualTo(0));
      final cardA = tester.getRect(find.descendant(of: find.byWidget(rows[0]), matching: find.byType(FadenCard)));
      final cardB = tester.getRect(find.descendant(of: find.byWidget(rows[1]), matching: find.byType(FadenCard)));
      expect(cardB.top - cardA.bottom, inInclusiveRange(4, 16));
      await tearDown(tester);
    });

    testWidgets('on a small phone with large text the capsule moves under the author, nothing overflows',
        (tester) async {
      for (final tokens in [FadenTokens.day, FadenTokens.night]) {
        await pump(tester, tokens: tokens, size: const Size(375, 667), textScale: 1.35);
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -500));
        await tester.pump();
        expect(tester.takeException(), isNull);
        final row = find.ancestor(of: find.text('Über Nacht'), matching: find.byType(BookRow));
        final capsule = find.descendant(of: row, matching: find.byType(FadenCapsule));
        expect(tester.getTopLeft(capsule).dy, greaterThan(tester.getBottomLeft(find.text('Anna Weber')).dy));
        await tearDown(tester);
      }
    });

    for (final (name, night, tokens) in [
      ('day', false, FadenTokens.day),
      ('Dunkel', false, FadenTokens.night),
      ('night view', true, FadenTokens.night),
    ]) {
      testWidgets('$name: the open book\'s card is ${night ? 'outlined' : 'filled'} (E73)', (tester) async {
        await pump(tester, tokens: tokens, night: night, openBook: 'b-zauber');
        final card = cardOf(tester, 'Der Zauberberg', ContinueCard);
        final other = cardOf(tester, 'Momo', ContinueCard);
        expect(other.color, tokens.karte);
        final shape = card.shape! as RoundedRectangleBorder;
        if (night) {
          expect(card.color, tokens.karte, reason: 'no lit surface at night');
          expect(shape.side.color, tokens.faden);
        } else {
          expect(card.color, tokens.karteMarkiert);
          expect(shape.side, BorderSide.none);
        }
        await tearDown(tester);
      });
    }

    testWidgets('"Kacheln" shows two columns of large covers, chosen in the menu and remembered (E73)',
        (tester) async {
      await pump(tester);
      await tester.tap(find.byTooltip(AppStrings.librarySortTooltip));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppStrings.libraryGroupGrid));
      await tester.pumpAndSettle();
      expect(find.byType(BookRow), findsNothing);
      expect(find.byType(BookTile), findsNWidgets(3), reason: 'the books not under "Weiterhören"');
      final first = tester.getRect(find.byType(BookTile).at(0));
      final second = tester.getRect(find.byType(BookTile).at(1));
      expect(second.top, first.top, reason: 'side by side');
      expect(second.left, greaterThan(first.right - 1));
      final cover = tester.getSize(find.descendant(of: find.byType(BookTile).first, matching: find.byType(BookCover)));
      expect(cover.width, greaterThan(150), reason: 'large covers');
      expect(tester.getTopLeft(find.text('Anna Weber')).dy,
          greaterThan(tester.getBottomLeft(find.descendant(of: find.byType(BookTile).first, matching: find.byType(BookCover))).dy),
          reason: 'title and author below the cover');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect((await tester.runAsync(SettingsStore(db).libraryView))!.grouping, LibraryGrouping.grid);
      await tearDown(tester);
    });

    testWidgets('"Kacheln" on a small phone with large text does not overflow', (tester) async {
      for (final tokens in [FadenTokens.day, FadenTokens.night]) {
        await pump(
          tester,
          tokens: tokens,
          size: const Size(375, 667),
          textScale: 1.35,
          view: const LibraryView(grouping: LibraryGrouping.grid),
        );
        for (var i = 0; i < 3; i++) {
          await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
          await tester.pump();
          expect(tester.takeException(), isNull);
        }
        await tearDown(tester);
      }
    });

    testWidgets('"Kacheln": the large title shows at rest; scrolled under the bar, content fades out (E94)',
        (tester) async {
      await pump(tester, size: const Size(375, 667), view: const LibraryView(grouping: LibraryGrouping.grid));
      final large = find.byWidgetPredicate(
          (w) => w is Text && w.data == AppStrings.libraryTitle && w.style?.fontSize == FadenTypeSizes.display);
      expect(large, findsOneWidget);
      expect(find.byType(ScrollEdgeFade), findsNothing, reason: 'nothing under the bar yet');
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
      await tester.pumpAndSettle();
      final fade = find.byType(ScrollEdgeFade);
      expect(fade, findsOneWidget);
      final bar = tester.getRect(find.byType(AppBar));
      expect(tester.getRect(fade).top, closeTo(bar.bottom, 0.5), reason: 'right under the collapsed bar');
      expect(tester.getSize(fade).height, ScrollEdgeFade.height);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 900));
      await tester.pumpAndSettle();
      expect(find.byType(ScrollEdgeFade), findsNothing);
      await tearDown(tester);
    });

    testWidgets('bar buttons sit on tiles with a full tap target (E72)', (tester) async {
      await pump(tester);
      for (final tip in [AppStrings.librarySortTooltip, AppStrings.settingsTitle]) {
        final size = tester.getSize(find.byTooltip(tip));
        expect(size.width, greaterThanOrEqualTo(fadenMinTapTarget), reason: tip);
        expect(size.height, greaterThanOrEqualTo(fadenMinTapTarget), reason: tip);
        final tile = find.descendant(of: find.byTooltip(tip), matching: find.byType(FadenTileButton)).evaluate().length +
            find.ancestor(of: find.byTooltip(tip), matching: find.byType(FadenTileButton)).evaluate().length;
        expect(tile, 1, reason: tip);
      }
      await tearDown(tester);
    });

    testWidgets('first launch: "Willkommen bei **Faden**" and a full-width capsule (E76)', (tester) async {
      await pump(tester, books: const []);
      final headline = tester.widget<Text>(find.text(AppStrings.setupTitle));
      final bold = <String>[];
      headline.textSpan!.visitChildren((span) {
        if (span is TextSpan && span.style?.fontWeight == FontWeight.w700 && span.text != null) bold.add(span.text!);
        return true;
      });
      expect(bold, [AppStrings.appTitle]);
      final button = find.widgetWithText(FilledButton, AppStrings.setupAction);
      expect(tester.getSize(button).width, greaterThan(430 - 2 * 24 - 1));
      expect(tester.widget<FilledButton>(button).style?.shape?.resolve({}) ??
          Theme.of(tester.element(button)).filledButtonTheme.style?.shape?.resolve({}), isA<StadiumBorder>());
      await tearDown(tester);
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
