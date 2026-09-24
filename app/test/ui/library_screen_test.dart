// Tests ui/library_screen.dart (decision E48): search, order and the
// "Weiterhören" section; the first-launch state without a server; and the
// "Reihenfolge prüfen" dialog, which shows each candidate's real file
// order instead of "Option 1 · 12 · needs_review".

import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/library.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/l10n/strings.dart';
import 'package:faden/ui/library_screen.dart';
import 'package:faden/ui/providers.dart';
import 'package:faden/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  _FixedLibraryController({required List<BookSummary> books, required Map<String, BookProgress> progress})
      : super(repository: LibraryRepository(api: null, cache: null), downloads: null) {
    this.books = books;
    progressByBook = progress;
  }

  @override
  Future<void> refresh() async {}

  @override
  Future<void> refreshProgress() async {}
}

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

    Future<void> pumpLibrary(WidgetTester tester, LibraryController controller) async {
      await tester.runAsync(() async {
        db = AppDatabase.memory();
        handler = FakeAudioHandler(Journal(db));
      });
      tester.view.physicalSize = const Size(430 * 3, 1400 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            audioHandlerProvider.overrideWithValue(handler),
            libraryControllerProvider.overrideWith((ref) => controller),
          ],
          child: const MaterialApp(home: LibraryScreen()),
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

    testWidgets('"Weiterhören" lists unfinished recent books above all books', (tester) async {
      await pumpLibrary(tester, _FixedLibraryController(books: _books, progress: _progressByBook));
      expect(find.text(AppStrings.libraryContinueSection), findsOneWidget);
      expect(find.text(AppStrings.libraryAllBooks), findsOneWidget);
      // Momo and Zauberberg appear twice (Weiterhören + all), Über Nacht once.
      expect(find.text('Momo'), findsNWidgets(2));
      expect(find.text('Der Zauberberg'), findsNWidgets(2));
      expect(find.text('Über Nacht'), findsOneWidget);
      final section = top(tester, AppStrings.libraryContinueSection);
      final all = top(tester, AppStrings.libraryAllBooks);
      final firstMomo = tester.getTopLeft(find.text('Momo').first).dy;
      final firstZauber = tester.getTopLeft(find.text('Der Zauberberg').first).dy;
      expect(section, lessThan(firstMomo));
      expect(firstMomo, lessThan(firstZauber));
      expect(firstZauber, lessThan(all));
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
      expect(find.text('Der Zauberberg'), findsOneWidget);
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
      expect(top(tester, 'Anonyme Briefe'), lessThan(top(tester, 'Über Nacht')));
      expect(top(tester, 'Halbe Sachen'), lessThan(top(tester, 'Momo')));
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

    testWidgets('offline with known books shows the small banner', (tester) async {
      final controller = _FixedLibraryController(books: _books, progress: const {})..offline = true;
      await pumpLibrary(tester, controller);
      expect(find.text(AppStrings.offlineBanner), findsOneWidget);
      expect(find.text('Momo'), findsOneWidget);
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
