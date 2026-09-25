import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/book_downloads.dart';
import '../domain/manifest.dart';
import '../l10n/strings.dart';
import 'controls.dart';
import 'cover.dart';
import 'format.dart';
import 'mini_player.dart';
import 'player_screen.dart';
import 'providers.dart';
import 'routes.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// docs/KONZEPT.md "Screens": "4. Bibliothek". Decision E48: "Weiterhören"
/// on top (the last books heard, from the journal, E33), then all books
/// with search and a chosen order; each row has a cover thumbnail, the
/// author, the book's progress as a thin thread with the time left (or
/// "neu"/"gehört"), and a quiet download state. The app's base (decision
/// E60): the root route, no back button; the player is pushed on top of
/// it and closes back onto it. Shows the mini player at the bottom while a
/// book is open (decision E29).
///
/// Decision E65: a large title that collapses into the bar like on the
/// iPhone; "Weiterhören" as larger cards, and its books are not repeated
/// under "Alle Bücher" (a search still lists every match). A tap on a
/// book shows the player at once and opens the book behind it.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  /// The library as the root of the stack (E60), without a transition.
  static Route<void> route() => BaseRoute<void>(builder: (_) => const LibraryScreen());

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final _search = TextEditingController();
  String _query = '';

  /// Books shown under "Weiterhören".
  static const continueCount = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(libraryControllerProvider).refresh());
    });
    _search.addListener(() {
      if (_search.text != _query) setState(() => _query = _search.text);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(libraryControllerProvider);
    final view = ref.watch(libraryViewProvider);
    final viewController = ref.read(libraryViewProvider.notifier);
    final titleBar = LargeTitleBar(
      title: AppStrings.libraryTitle,
      actions: [
        if (controller.books.isNotEmpty)
          // Order, then "Liste / Nach Autor" (E70), in one quiet menu.
          PopupMenuButton<Object>(
            tooltip: AppStrings.librarySortTooltip,
            icon: const Icon(Icons.swap_vert),
            onSelected: (choice) {
              if (choice is LibrarySort) viewController.setSort(choice);
              if (choice is LibraryGrouping) viewController.setGrouping(choice);
            },
            itemBuilder: (context) => [
              for (final option in LibrarySort.values)
                CheckedPopupMenuItem<Object>(
                  value: option,
                  checked: option == view.sort,
                  child: Text(librarySortLabel(option)),
                ),
              const PopupMenuDivider(),
              for (final option in LibraryGrouping.values)
                CheckedPopupMenuItem<Object>(
                  value: option,
                  checked: option == view.grouping,
                  child: Text(libraryGroupingLabel(option)),
                ),
            ],
          ),
        IconButton(
          tooltip: AppStrings.settingsTitle,
          icon: const Icon(Icons.settings_outlined),
          onPressed: _openSettings,
        ),
      ],
    );
    return Scaffold(
      bottomNavigationBar: const MiniPlayer(),
      body: RefreshIndicator(
        onRefresh: controller.refresh,
        edgeOffset: MediaQuery.paddingOf(context).top + kToolbarHeight,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [titleBar, ..._body(controller, view)],
        ),
      ),
    );
  }

  List<Widget> _body(LibraryController controller, LibraryView view) {
    final configured = ref.watch(serverConfigProvider).isConfigured;
    if (controller.books.isEmpty) {
      if (!configured) {
        // First launch: nothing to retry yet, only something to set up.
        return [
          _EmptyState(
            icon: Icons.menu_book_outlined,
            title: AppStrings.setupTitle,
            body: AppStrings.setupBody,
            action: FilledButton(onPressed: _openSettings, child: Text(AppStrings.setupAction)),
          ),
        ];
      }
      if (controller.offline) {
        return [
          _EmptyState(
            icon: Icons.cloud_off_outlined,
            title: AppStrings.offlineNotice,
            action: FilledButton(onPressed: controller.refresh, child: Text(AppStrings.libraryRetry)),
            secondary: TextButton(onPressed: _openSettings, child: Text(AppStrings.settingsTitle)),
          ),
        ];
      }
      if (controller.loading) {
        return const [SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator()))];
      }
      return [
        _EmptyState(
          icon: Icons.menu_book_outlined,
          title: AppStrings.libraryEmpty,
          body: AppStrings.libraryEmptyHint,
        ),
      ];
    }

    final progress = controller.progressByBook;
    final continueBooks = _query.isEmpty ? continueListening(controller) : const <BookSummary>[];
    // "Weiterhören" books are not repeated below (E65); a search lists
    // every match, so it never hides a book.
    final shownAbove = {for (final b in continueBooks) b.bookId};
    final rest = [
      for (final b in controller.books)
        if (!shownAbove.contains(b.bookId)) b,
    ];
    // Filters (E70) belong to "Alle Bücher" only and sit right above it;
    // a search ignores them and finds every book.
    final genres = genresIn(controller.books);
    final genre = genres.contains(view.genre) ? view.genre : null;
    final showFilters = _query.isEmpty && rest.isNotEmpty;
    final arranged = arrangeBooks(
      books: rest,
      progress: progress,
      sort: view.sort,
      query: _query,
      status: view.status,
      genre: genre,
    );
    final entries = libraryEntries(arranged, view.grouping);

    return [
      if (controller.offline) const SliverToBoxAdapter(child: _OfflineBanner()),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: AppStrings.librarySearchHint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: AppStrings.cancelAction,
                      icon: const Icon(Icons.close),
                      onPressed: _search.clear,
                    ),
            ),
          ),
        ),
      ),
      if (continueBooks.isNotEmpty) ...[
        SliverToBoxAdapter(child: _SectionHeader(AppStrings.libraryContinueSection)),
        SliverList.list(children: [for (final b in continueBooks) ContinueCard(book: b)]),
        if (rest.isNotEmpty) SliverToBoxAdapter(child: _SectionHeader(AppStrings.libraryAllBooks)),
      ],
      if (showFilters)
        SliverToBoxAdapter(
          child: LibraryFilterBar(
            status: view.status,
            genre: genre,
            showGenre: genres.isNotEmpty,
            onStatus: ref.read(libraryViewProvider.notifier).setStatus,
            onGenre: () => _chooseGenreFilter(genres, genre),
          ),
        ),
      if (arranged.isEmpty && (showFilters || continueBooks.isEmpty))
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              showFilters ? AppStrings.libraryFilterEmpty : AppStrings.libraryNoMatches,
              textAlign: TextAlign.center,
            ),
          ),
        )
      else
        SliverList.builder(
          itemCount: entries.length,
          itemBuilder: (context, i) {
            final entry = entries[i];
            final book = entry.book;
            return book != null ? BookRow(book: book) : _AuthorHeader(entry.author);
          },
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ];
  }

  /// "Genre ▾" (E70): every genre in the library, or all of them.
  Future<void> _chooseGenreFilter(List<String> genres, String? current) async {
    final choice = await showModalBottomSheet<({String? genre})>(
      context: context,
      builder: (context) => _ChoiceSheet(
        options: [
          (label: AppStrings.libraryFilterAllGenres, value: null),
          for (final g in genres) (label: g, value: g),
        ],
        selected: current,
      ),
    );
    if (choice == null || !mounted) return;
    ref.read(libraryViewProvider.notifier).setGenre(choice.genre);
  }

  /// "Weiterhören": the most recently played books that are not finished.
  List<BookSummary> continueListening(LibraryController controller) =>
      controller.continueListening.take(continueCount).toList();
}

/// A large title that collapses into the bar as the list scrolls, like an
/// iPhone navigation bar (decision E65): expanded, the title stands large
/// and left-aligned under the bar; scrolled away, a small centred title
/// fades into the bar. Driven by the scroll position only, no animation.
class LargeTitleBar extends StatelessWidget {
  final String title;
  final List<Widget> actions;

  const LargeTitleBar({super.key, required this.title, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final largeHeight = MediaQuery.textScalerOf(context).scale(FadenTypeSizes.display) * 1.25 + 14;
    return SliverAppBar(
      pinned: true,
      // The base of the app (E60): nothing to go back to.
      automaticallyImplyLeading: false,
      expandedHeight: kToolbarHeight + largeHeight,
      actions: actions,
      flexibleSpace: _CollapsingTitle(title: title, largeHeight: largeHeight),
    );
  }
}

class _CollapsingTitle extends StatelessWidget {
  final String title;
  final double largeHeight;

  const _CollapsingTitle({required this.title, required this.largeHeight});

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    final settings = context.dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
    // 1 fully expanded, 0 collapsed into the bar.
    var expanded = 1.0;
    var barHeight = MediaQuery.paddingOf(context).top + kToolbarHeight;
    if (settings != null) {
      barHeight = settings.minExtent;
      final range = settings.maxExtent - settings.minExtent;
      expanded = range <= 0 ? 0 : ((settings.currentExtent - settings.minExtent) / range).clamp(0.0, 1.0);
    }
    final smallOpacity = ((0.35 - expanded) / 0.35).clamp(0.0, 1.0);
    final topPadding = MediaQuery.paddingOf(context).top;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: barHeight,
          child: Padding(
            padding: EdgeInsets.only(top: topPadding, left: 120, right: 120),
            child: ExcludeSemantics(
              excluding: smallOpacity < 0.5,
              child: Opacity(
                opacity: smallOpacity,
                child: Center(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: tokens.tinte, fontSize: FadenTypeSizes.body, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.bottomLeft,
              minHeight: largeHeight,
              maxHeight: largeHeight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: ExcludeSemantics(
                    excluding: smallOpacity >= 0.5,
                    child: Semantics(
                      header: true,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tokens.tinte,
                          fontSize: FadenTypeSizes.display,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String librarySortLabel(LibrarySort sort) => switch (sort) {
  LibrarySort.recent => AppStrings.librarySortRecent,
  LibrarySort.title => AppStrings.librarySortTitle,
  LibrarySort.author => AppStrings.librarySortAuthor,
  LibrarySort.length => AppStrings.librarySortLength,
};

String libraryGroupingLabel(LibraryGrouping grouping) => switch (grouping) {
  LibraryGrouping.list => AppStrings.libraryGroupList,
  LibraryGrouping.author => AppStrings.libraryGroupAuthor,
};

String libraryStatusLabel(LibraryStatusFilter status) => switch (status) {
  LibraryStatusFilter.all => AppStrings.libraryFilterAll,
  LibraryStatusFilter.started => AppStrings.libraryFilterStarted,
  LibraryStatusFilter.unstarted => AppStrings.libraryFilterUnstarted,
  LibraryStatusFilter.finished => AppStrings.libraryFilterFinished,
};

/// Where a book stands, exactly as its row says it (E70): "neu" (never
/// played, or no share known yet), "gehört" (from 99.5 %, [isFinished]),
/// else started.
enum ListeningState { unstarted, started, finished }

ListeningState listeningStateOf(BookProgress? progress) {
  final fraction = progress?.fraction;
  if (fraction == null || fraction <= 0) return ListeningState.unstarted;
  if (isFinished(progress)) return ListeningState.finished;
  return ListeningState.started;
}

/// Whether [book] passes the status filter "Alle · Läuft · Neu · Gehört"
/// (E70).
bool matchesStatus(BookSummary book, BookProgress? progress, LibraryStatusFilter status) {
  final state = listeningStateOf(progress);
  return switch (status) {
    LibraryStatusFilter.all => true,
    LibraryStatusFilter.started => state == ListeningState.started,
    LibraryStatusFilter.unstarted => state == ListeningState.unstarted,
    LibraryStatusFilter.finished => state == ListeningState.finished,
  };
}

/// The genres [books] have, in the server's order ([knownGenres]), any
/// other label after them alphabetically. Empty when no book has one: then
/// there is no genre filter (E70).
List<String> genresIn(List<BookSummary> books) {
  final present = {for (final b in books) ?b.genre};
  return [
    for (final g in knownGenres)
      if (present.contains(g)) g,
    ...(present.difference(knownGenres.toSet()).toList()..sort()),
  ];
}

/// The key an author is ordered by (E70): the last word of the name as a
/// guess at the surname ("Thomas Mann" → "mann"), folded like the search.
String authorSortKey(String author) {
  final words = author.trim().split(RegExp(r'\s+'));
  return foldForSearch(words.last.replaceAll(RegExp(r'[.,;:]+$'), ''));
}

/// Orders two author names by [authorSortKey], then by the whole name.
int compareAuthors(String a, String b) {
  final c = authorSortKey(a).compareTo(authorSortKey(b));
  return c != 0 ? c : foldForSearch(a).compareTo(foldForSearch(b));
}

/// Filters [books] and orders them by [sort]. Pure, so it is tested
/// without widgets.
///
/// A [query] (title or author, case- and umlaut-folding) searches every
/// book and ignores [status] and [genre]; without one, both filter (E70).
/// "Zuletzt gehört": books with progress, newest first, then the rest by
/// title. "Autor": by surname ([authorSortKey]), books without one last,
/// then by title. "Länge": shortest first, unknown lengths last.
List<BookSummary> arrangeBooks({
  required List<BookSummary> books,
  required Map<String, BookProgress> progress,
  required LibrarySort sort,
  String query = '',
  LibraryStatusFilter status = LibraryStatusFilter.all,
  String? genre,
}) {
  final q = foldForSearch(query.trim());
  final list = [
    for (final b in books)
      if (q.isNotEmpty
          ? foldForSearch(b.title).contains(q) || foldForSearch(b.author ?? '').contains(q)
          : matchesStatus(b, progress[b.bookId], status) && (genre == null || b.genre == genre))
        b,
  ];
  int byTitle(BookSummary a, BookSummary b) => foldForSearch(a.title).compareTo(foldForSearch(b.title));
  switch (sort) {
    case LibrarySort.title:
      list.sort(byTitle);
    case LibrarySort.author:
      list.sort((a, b) {
        final aa = a.author?.trim() ?? '';
        final ba = b.author?.trim() ?? '';
        if (aa.isEmpty != ba.isEmpty) return aa.isEmpty ? 1 : -1;
        final c = aa.isEmpty ? 0 : compareAuthors(aa, ba);
        return c != 0 ? c : byTitle(a, b);
      });
    case LibrarySort.length:
      list.sort((a, b) {
        final la = a.durationMs;
        final lb = b.durationMs;
        if (la != null && lb != null && la != lb) return la.compareTo(lb);
        if ((la == null) != (lb == null)) return la == null ? 1 : -1;
        return byTitle(a, b);
      });
    case LibrarySort.recent:
      list.sort((a, b) {
        final pa = progress[a.bookId]?.lastPlayed;
        final pb = progress[b.bookId]?.lastPlayed;
        if (pa != null && pb != null) return pb.compareTo(pa);
        if (pa != null) return -1;
        if (pb != null) return 1;
        return byTitle(a, b);
      });
  }
  return list;
}

/// One author's books under "Nach Autor" (E70); [author] null collects
/// the books without one ("Unbekannt").
class AuthorGroup {
  final String? author;
  final List<BookSummary> books;

  const AuthorGroup(this.author, this.books);
}

/// Groups [arranged] by author (E70): groups by surname ([compareAuthors]),
/// "Unbekannt" last; inside a group the books keep their order from
/// [arrangeBooks], i.e. the chosen sort. Names that differ only in case or
/// spaces are one author, shown as first met.
List<AuthorGroup> groupByAuthor(List<BookSummary> arranged) {
  final groups = <String, AuthorGroup>{};
  final unknown = <BookSummary>[];
  for (final b in arranged) {
    final author = b.author?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
    if (author.isEmpty) {
      unknown.add(b);
    } else {
      groups.putIfAbsent(foldForSearch(author), () => AuthorGroup(author, [])).books.add(b);
    }
  }
  final sorted = groups.values.toList()..sort((a, b) => compareAuthors(a.author!, b.author!));
  return [...sorted, if (unknown.isNotEmpty) AuthorGroup(null, unknown)];
}

/// One line of "Alle Bücher": a book, or (grouped by author) a header.
class LibraryEntry {
  final BookSummary? book;
  final String? author;

  const LibraryEntry.book(BookSummary this.book) : author = null;
  const LibraryEntry.header(this.author) : book = null;
}

/// The lines of "Alle Bücher" for [grouping] (E70).
List<LibraryEntry> libraryEntries(List<BookSummary> arranged, LibraryGrouping grouping) {
  if (grouping == LibraryGrouping.list) return [for (final b in arranged) LibraryEntry.book(b)];
  return [
    for (final g in groupByAuthor(arranged)) ...[
      LibraryEntry.header(g.author),
      for (final b in g.books) LibraryEntry.book(b),
    ],
  ];
}

/// Lower case with umlauts and ß folded, so "uber" finds "Über".
String foldForSearch(String s) => s
    .toLowerCase()
    .replaceAll('ä', 'a')
    .replaceAll('ö', 'o')
    .replaceAll('ü', 'u')
    .replaceAll('ß', 'ss')
    .replaceAll(RegExp(r'[éèê]'), 'e')
    .replaceAll(RegExp(r'[áàâ]'), 'a');

class _SectionHeader extends StatelessWidget {
  final String text;

  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: SectionTitle(text),
      );
}

/// An author's name above their books under "Nach Autor" (E70); null is
/// "Unbekannt". Smaller than the section titles it sits under.
class _AuthorHeader extends StatelessWidget {
  final String? author;

  const _AuthorHeader(this.author);

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 2),
      child: Semantics(
        header: true,
        child: Text(
          author ?? AppStrings.libraryUnknownAuthor,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: tokens.tinte, fontSize: FadenTypeSizes.body, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

/// The filters above "Alle Bücher" (E70): "Alle · Läuft · Neu · Gehört",
/// one choice, and "Genre ▾" while any book has a genre. Small pills in
/// one row that scrolls sideways when it does not fit; each pill's tap
/// area is the row's full 56 dp height.
class LibraryFilterBar extends StatelessWidget {
  final LibraryStatusFilter status;
  final String? genre;
  final bool showGenre;
  final ValueChanged<LibraryStatusFilter> onStatus;
  final VoidCallback onGenre;

  const LibraryFilterBar({
    super.key,
    required this.status,
    required this.genre,
    required this.showGenre,
    required this.onStatus,
    required this.onGenre,
  });

  @override
  Widget build(BuildContext context) {
    final pill = MediaQuery.textScalerOf(context).scale(FadenTypeSizes.caption) * 1.3 + 16;
    return SizedBox(
      height: math.max(fadenMinTapTarget, pill + 12),
      // Five pills at most: built all at once, so VoiceOver finds each.
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final option in LibraryStatusFilter.values)
              _FilterPill(label: libraryStatusLabel(option), selected: option == status, onTap: () => onStatus(option)),
            if (showGenre)
              _FilterPill(
                label: genre ?? AppStrings.libraryFilterGenre,
                selected: genre != null,
                dropdown: true,
                onTap: onGenre,
              ),
          ],
        ),
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  final String label;
  final bool selected;
  final bool dropdown;
  final VoidCallback onTap;

  const _FilterPill({required this.label, required this.selected, required this.onTap, this.dropdown = false});

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    // At night a ring, not a lit surface (E65), like the segments.
    final outline = tokens.isDark;
    final color = !selected ? tokens.tinte : (outline ? tokens.faden : tokens.grund);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          unawaited(HapticFeedback.selectionClick());
          onTap();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: selected && !outline ? tokens.faden : tokens.flaeche,
                border: Border.all(color: selected && outline ? tokens.faden : Colors.transparent, width: 1.5),
                borderRadius: BorderRadius.circular(100),
              ),
              child: Padding(
                padding: EdgeInsets.fromLTRB(14, 6, dropdown ? 8 : 14, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: FadenTypeSizes.caption,
                        color: color,
                        fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                    if (dropdown) Icon(Icons.expand_more, size: 18, color: color),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A plain list of choices in a bottom sheet, the current one ticked; pops
/// `(genre: value)` for the one tapped (a record, so null can be chosen).
class _ChoiceSheet extends StatelessWidget {
  final List<({String label, String? value})> options;
  final String? selected;

  const _ChoiceSheet({required this.options, required this.selected});

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final o in options)
            ListTile(
              minTileHeight: fadenMinTapTarget,
              title: Text(o.label),
              selected: o.value == selected,
              trailing: o.value == selected ? Icon(Icons.check, color: tokens.faden) : null,
              onTap: () {
                unawaited(HapticFeedback.selectionClick());
                Navigator.of(context).pop((genre: o.value));
              },
            ),
        ],
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner();

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: tokens.flaeche, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          // On the raised surface: 4.5:1 at night too (E65).
          Icon(Icons.cloud_off_outlined, size: 18, color: tokens.leiseAufFlaeche),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              AppStrings.offlineBanner,
              style: TextStyle(color: tokens.leiseAufFlaeche, fontSize: FadenTypeSizes.caption),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;
  final Widget? secondary;

  const _EmptyState({required this.icon, required this.title, this.body, this.action, this.secondary});

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    // Part of the scroll view, so pull-to-refresh works here too.
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 40, 32, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(icon, size: 48, color: tokens.faden),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(color: tokens.tinte, fontSize: FadenTypeSizes.title),
            ),
            if (body != null) ...[
              const SizedBox(height: 8),
              Text(
                body!,
                textAlign: TextAlign.center,
                style: TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.body),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 24), Center(child: action)],
            if (secondary != null) ...[const SizedBox(height: 8), Center(child: secondary)],
          ],
        ),
      ),
    );
  }
}

/// Not openable on the server ("unvollständig", "keine Dateien").
bool _unavailable(BookSummary book) => book.serverStatus == 'incomplete' || book.serverStatus == 'empty';

/// A tap on a book, from its row or its "Weiterhören" card.
///
/// "Reihenfolge prüfen" (invariant 4) loads the server's candidates with a
/// spinner in the row, and says so when it cannot (offline, nothing to
/// choose, a failed request) instead of doing nothing (decision E65).
///
/// Opening (E65): the player slides up as soon as the book is known to
/// open and shows its loading state; the sync wait and the lock-screen
/// cover happen behind it. Until then the row shows a spinner, and taps on
/// other books are ignored, so a double tap never opens twice. Still one
/// player only ([showPlayerScreen], E29/E60).
Future<void> openBookFromLibrary(BuildContext context, WidgetRef ref, BookSummary book) async {
  final messenger = ScaffoldMessenger.of(context);
  final controller = ref.read(libraryControllerProvider);
  final busy = ref.read(libraryBusyBookProvider.notifier);
  void say(String text) => messenger.showSnackBar(SnackBar(content: Text(text)));

  if (book.needsReview) {
    await _reviewOrder(context, controller, busy, book, say);
    return;
  }
  if (_unavailable(book)) {
    // Not openable, so say why instead of doing nothing.
    say(book.serverStatus == 'empty' ? AppStrings.libraryEmptyExplain : AppStrings.libraryIncompleteExplain);
    return;
  }
  if (!busy.begin(book.bookId)) return;
  final navigator = Navigator.of(context);
  final opener = ref.read(bookOpenerProvider);
  var shown = false;
  void show() {
    if (shown) return;
    shown = true;
    // The one player slides up over the library (E29, E60).
    showPlayerScreen(navigator);
  }

  try {
    // Cache first (decision E30): opens offline, too.
    final result = await opener.open(book.bookId, onStarted: show);
    if (result == OpenBookResult.unavailable) {
      say(AppStrings.libraryOpenFailed);
      return;
    }
    show();
  } catch (_) {
    // A player left waiting for a book that never came goes again.
    final player = PlayerRoute.activeIn(navigator);
    if (shown && player != null && player.isCurrent) navigator.pop();
    say(AppStrings.libraryOpenFailed);
  } finally {
    busy.end(book.bookId);
  }
}

Future<void> _reviewOrder(
  BuildContext context,
  LibraryController controller,
  LibraryBusyBookController busy,
  BookSummary book,
  void Function(String text) say,
) async {
  if (controller.api == null || controller.offline) {
    say(AppStrings.reviewOffline);
    return;
  }
  if (!busy.begin(book.bookId)) return;
  final List<ManifestCandidate> candidates;
  try {
    candidates = await controller.reviewCandidates(book.bookId);
  } catch (_) {
    say(AppStrings.reviewLoadFailed);
    return;
  } finally {
    busy.end(book.bookId);
  }
  if (candidates.isEmpty) {
    say(AppStrings.reviewNothingToChoose);
    return;
  }
  if (!context.mounted) return;
  final manifestId = await showReviewDialog(context, candidates);
  if (manifestId == null || !busy.begin(book.bookId)) return;
  try {
    await controller.confirmManifest(book.bookId, manifestId);
    say(AppStrings.confirmManifestSuccess);
  } catch (_) {
    say(AppStrings.confirmManifestFailed);
  } finally {
    busy.end(book.bookId);
  }
}

/// Long press on a book (E70): "Genre ändern" (only with the server) and,
/// once something is on the device, delete its download (the progress
/// stays).
Future<void> _showBookActions(
  BuildContext context,
  LibraryController controller,
  BookSummary book,
  BookDownloadState download,
) async {
  final online = controller.api != null && !controller.offline;
  final canDelete = download.bytesOnDisk > 0;
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (context) {
      final tokens = FadenTokens.of(context);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              enabled: online,
              minTileHeight: fadenMinTapTarget,
              leading: const Icon(Icons.sell_outlined),
              title: Text(AppStrings.genreChange),
              // Offline it says why it is greyed out.
              subtitle: Text(online ? (book.genre ?? AppStrings.genreNone) : AppStrings.genreOffline),
              onTap: () => Navigator.of(context).pop('genre'),
            ),
            if (canDelete)
              ListTile(
                minTileHeight: fadenMinTapTarget,
                leading: Icon(Icons.delete_outline, color: tokens.fehler),
                title: Text(AppStrings.downloadDeleteWithSize(formatBytes(download.bytesOnDisk))),
                onTap: () => Navigator.of(context).pop('delete'),
              ),
            ListTile(
              minTileHeight: fadenMinTapTarget,
              leading: const Icon(Icons.close),
              title: Text(AppStrings.cancelAction),
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );
    },
  );
  if (!context.mounted) return;
  if (action == 'delete') {
    await controller.deleteDownload(book.bookId);
  } else if (action == 'genre') {
    await changeGenre(context, controller, book);
  }
}

/// "Genre ändern" (E70): the server's labels and "Automatisch"; the
/// choice goes to the server and then into the list and cache. A failure
/// says so and changes nothing.
Future<void> changeGenre(BuildContext context, LibraryController controller, BookSummary book) async {
  final messenger = ScaffoldMessenger.of(context);
  final labels = await controller.genreLabels();
  if (!context.mounted) return;
  final choice = await showModalBottomSheet<({String? genre})>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _ChoiceSheet(
      options: [(label: AppStrings.genreAutomatic, value: null), for (final g in labels) (label: g, value: g)],
      selected: book.genre,
    ),
  );
  if (choice == null || choice.genre == book.genre && choice.genre != null) return;
  try {
    await controller.setGenre(book.bookId, choice.genre);
  } catch (_) {
    messenger.showSnackBar(SnackBar(content: Text(AppStrings.genreChangeFailed)));
  }
}

/// A "Weiterhören" book (decision E65): a larger card with a bigger cover
/// and title, set apart by a hairline frame, so the section does not look
/// like the list below it. Same tap, long press and download control as a
/// [BookRow].
class ContinueCard extends ConsumerWidget {
  final BookSummary book;

  const ContinueCard({super.key, required this.book});

  static const double coverSize = 88;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(libraryControllerProvider);
    final busy = ref.watch(libraryBusyBookProvider) == book.bookId;
    final tokens = FadenTokens.of(context);
    final download = controller.downloadStateFor(book.bookId);
    final progress = controller.progressByBook[book.bookId];
    final author = book.author?.trim();
    final onlineOnly = BookRow.onlineOnly(controller, book, download);
    final radius = BorderRadius.circular(16);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: tokens.grund,
        shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: tokens.linie)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => openBookFromLibrary(context, ref, book),
          onLongPress: () => _showBookActions(context, controller, book, download),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
            child: Row(
              children: [
                Opacity(
                  opacity: onlineOnly ? 0.5 : 1,
                  child: BookCover(bookId: book.bookId, title: book.title, size: coverSize, radius: 8, thumbnail: true),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: FadenTypeSizes.title, color: tokens.tinte, height: 1.2),
                      ),
                      if (author != null && author.isNotEmpty)
                        Text(
                          author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise),
                        ),
                      const SizedBox(height: 8),
                      _StatusLine(
                        book: book,
                        progress: progress,
                        download: download,
                        tokens: tokens,
                        onlineOnly: onlineOnly,
                        threadWidth: 72,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                busy
                    ? const _BusySpinner()
                    : _DownloadControl(book: book, download: download, controller: controller, tokens: tokens),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A book being opened or reviewed (E65), in place of its download control.
class _BusySpinner extends StatelessWidget {
  const _BusySpinner();

  @override
  Widget build(BuildContext context) => Semantics(
    label: AppStrings.libraryOpening,
    child: const SizedBox.square(
      dimension: fadenMinTapTarget,
      child: Center(child: SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))),
    ),
  );
}

/// One book: cover, title, author, progress, download state.
class BookRow extends ConsumerWidget {
  final BookSummary book;

  const BookRow({super.key, required this.book});

  static const double coverSize = 56;

  /// Decision E58: while the server is unreachable, a book that is not
  /// fully downloaded cannot play; the row is dimmed and says "nur online".
  static bool onlineOnly(LibraryController controller, BookSummary book, BookDownloadState download) =>
      controller.offline && book.serverStatus == 'ok' && !download.isDownloaded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(libraryControllerProvider);
    final busy = ref.watch(libraryBusyBookProvider) == book.bookId;
    final tokens = FadenTokens.of(context);
    final download = controller.downloadStateFor(book.bookId);
    final progress = controller.progressByBook[book.bookId];
    final author = book.author?.trim();
    final canDelete = download.bytesOnDisk > 0;
    final dimmed = _unavailable(book) || onlineOnly(controller, book, download);

    Widget row = InkWell(
      onTap: () => openBookFromLibrary(context, ref, book),
      onLongPress: () => _showBookActions(context, controller, book, download),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(
          children: [
            Opacity(
              opacity: dimmed ? 0.5 : 1,
              child: BookCover(bookId: book.bookId, title: book.title, size: coverSize, radius: 6, thumbnail: true),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: FadenTypeSizes.body, color: dimmed ? tokens.tinteLeise : tokens.tinte),
                  ),
                  if (author != null && author.isNotEmpty)
                    Text(
                      author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise),
                    ),
                  const SizedBox(height: 4),
                  _StatusLine(
                    book: book,
                    progress: progress,
                    download: download,
                    tokens: tokens,
                    onlineOnly: onlineOnly(controller, book, download),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            busy
                ? const _BusySpinner()
                : _DownloadControl(book: book, download: download, controller: controller, tokens: tokens),
          ],
        ),
      ),
    );

    if (canDelete) {
      // Swipe left to delete the download (the progress stays).
      row = Dismissible(
        key: ValueKey('dismiss-${book.bookId}'),
        direction: DismissDirection.endToStart,
        confirmDismiss: (_) async {
          if (await confirmDeleteDownload(context, book.title) && context.mounted) {
            await controller.deleteDownload(book.bookId);
          }
          return false;
        },
        background: Container(
          color: tokens.fehler,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            AppStrings.downloadDeleteWithSize(formatBytes(download.bytesOnDisk)),
            style: TextStyle(color: tokens.grund, fontSize: FadenTypeSizes.caption),
          ),
        ),
        child: row,
      );
    }
    return row;
  }
}

class _StatusLine extends StatelessWidget {
  final BookSummary book;
  final BookProgress? progress;
  final BookDownloadState download;
  final FadenTokens tokens;
  final bool onlineOnly;

  /// Length of the little progress thread.
  final double threadWidth;

  const _StatusLine({
    required this.book,
    required this.progress,
    required this.download,
    required this.tokens,
    this.onlineOnly = false,
    this.threadWidth = 48,
  });

  @override
  Widget build(BuildContext context) {
    final small = TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinteLeise);
    if (book.needsReview) {
      return Text(AppStrings.libraryFolderChanged, style: small.copyWith(color: tokens.faden));
    }
    if (book.serverStatus == 'incomplete') return Text(AppStrings.libraryStatusIncomplete, style: small);
    if (book.serverStatus == 'empty') return Text(AppStrings.libraryStatusEmpty, style: small);
    if (download.hasFailed) {
      return Text(AppStrings.libraryDownloadFailed, style: small.copyWith(color: tokens.fehler));
    }
    if (download.isDownloading) {
      // What is left, not what arrived (E62); "Lädt …" until a first
      // file size gives the estimate a basis.
      final rest = download.remainingBytes;
      return Text(
        rest == null ? AppStrings.libraryDownloading : AppStrings.downloadRemaining(formatRemainingBytes(rest)),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: small,
      );
    }
    final fraction = progress?.fraction;
    String text;
    double? thread;
    if (progress == null || fraction == null || fraction <= 0) {
      text = AppStrings.libraryStatusNew;
    } else if (fraction >= 0.995) {
      text = AppStrings.libraryProgressFinished;
    } else {
      thread = fraction;
      final total = book.durationMs;
      text = total == null
          ? AppStrings.threadValue((fraction * 100).floor())
          : AppStrings.remainingTime(formatRemaining((total * (1 - fraction)).round(), coarse: true));
    }
    if (onlineOnly) text = AppStrings.libraryOnlineOnly(text);
    return Row(
      children: [
        if (thread != null) ...[
          SizedBox(
            width: threadWidth,
            height: 2,
            child: ColoredBox(
              color: tokens.tinteLeiseFaden,
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: thread,
                child: ColoredBox(color: tokens.faden),
              ),
            ),
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: small),
        ),
      ],
    );
  }
}

class _DownloadControl extends StatelessWidget {
  final BookSummary book;
  final BookDownloadState download;
  final LibraryController controller;
  final FadenTokens tokens;

  const _DownloadControl({required this.book, required this.download, required this.controller, required this.tokens});

  @override
  Widget build(BuildContext context) {
    const box = fadenMinTapTarget;
    if (book.needsReview) {
      return SizedBox.square(
        dimension: box,
        child: Icon(Icons.rule_outlined, size: 22, color: tokens.faden),
      );
    }
    if (book.serverStatus != 'ok' || controller.downloads == null) return const SizedBox(width: 12);
    switch (download.status) {
      case BookDownloadStatus.downloading:
        return SizedBox.square(
          dimension: box,
          child: IconButton(
            tooltip: AppStrings.downloadCancel,
            onPressed: () => controller.cancelDownload(book.bookId),
            // The status line says what is left (E62); the button only stops.
            icon: Icon(Icons.stop_circle_outlined, size: 26, color: tokens.faden),
          ),
        );
      case BookDownloadStatus.failed:
        return SizedBox.square(
          dimension: box,
          child: IconButton(
            tooltip: AppStrings.libraryRetry,
            onPressed: () => unawaited(controller.retryDownload(book.bookId)),
            icon: Icon(Icons.refresh, color: tokens.fehler),
          ),
        );
      case BookDownloadStatus.done:
        // Quiet: the state, not an action (delete is a swipe or long press).
        return SizedBox.square(
          dimension: box,
          child: Icon(
            Icons.download_done,
            size: 20,
            color: tokens.tinteLeise,
            semanticLabel: AppStrings.libraryStatusDownloaded,
          ),
        );
      case BookDownloadStatus.none:
      case BookDownloadStatus.partial:
        return SizedBox.square(
          dimension: box,
          child: IconButton(
            tooltip: AppStrings.libraryDownloadAction,
            onPressed: () => unawaited(controller.downloadBook(book.bookId)),
            icon: Icon(Icons.arrow_circle_down_outlined, color: tokens.faden),
          ),
        );
    }
  }
}

/// "Reihenfolge prüfen" (invariant 4: an order never changes silently).
/// Shows each candidate's actual file order -- position, title tag and
/// track number -- starting just before the first place where the
/// candidates differ, so the choice is about what really differs. Returns
/// the chosen manifest id, or null.
Future<String?> showReviewDialog(BuildContext context, List<ManifestCandidate> candidates) {
  return showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(AppStrings.reviewDialogTitle),
      scrollable: true,
      content: SizedBox(
        width: double.maxFinite,
        child: ReviewCandidates(
          candidates: candidates,
          onChoose: (manifestId) => Navigator.of(dialogContext).pop(manifestId),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: Text(AppStrings.reviewDialogCancel)),
      ],
    ),
  );
}

class ReviewCandidates extends StatelessWidget {
  final List<ManifestCandidate> candidates;
  final ValueChanged<String> onChoose;

  /// Files shown per candidate.
  static const window = 8;

  const ReviewCandidates({super.key, required this.candidates, required this.onChoose});

  /// First playlist position at which the candidates' files differ.
  static int firstDifference(List<Manifest> manifests) {
    if (manifests.length < 2) return 0;
    final shortest = manifests.map((m) => m.files.length).reduce((a, b) => a < b ? a : b);
    for (var i = 0; i < shortest; i++) {
      final hash = manifests.first.files[i].fileHash;
      if (manifests.any((m) => m.files[i].fileHash != hash)) return i;
    }
    return shortest;
  }

  /// "3. Der Anfang · Track 3".
  static String fileLine(int position, ManifestFile file) {
    final title = file.title?.trim();
    final name = (title == null || title.isEmpty) ? AppStrings.reviewUntitled : title;
    final track = file.track;
    return track == null ? '${position + 1}. $name' : '${position + 1}. $name · ${AppStrings.reviewTrack(track)}';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    final small = TextStyle(fontSize: FadenTypeSizes.caption, color: tokens.tinte);
    final from = (firstDifference([for (final c in candidates) c.manifest]) - 1).clamp(0, 1 << 30);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(AppStrings.reviewDialogBody),
        for (var i = 0; i < candidates.length; i++) ...[
          const SizedBox(height: 20),
          Text(
            AppStrings.reviewDialogOption(i + 1),
            style: TextStyle(fontSize: FadenTypeSizes.body, color: tokens.tinte, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          if (from > 0) Text('…', style: small),
          for (final entry in candidates[i].manifest.files.asMap().entries.skip(from).take(window))
            Text(fileLine(entry.key, entry.value), style: small, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (candidates[i].manifest.files.length > from + window)
            Text(
              AppStrings.reviewMoreFiles(candidates[i].manifest.files.length - from - window),
              style: small.copyWith(color: tokens.tinteLeise),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () => onChoose(candidates[i].manifest.manifestId),
              child: Text(AppStrings.reviewDialogChoose),
            ),
          ),
        ],
      ],
    );
  }
}
