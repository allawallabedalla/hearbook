import 'dart:async';

import 'package:flutter/material.dart';
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
import 'settings_screen.dart';
import 'theme.dart';

/// docs/KONZEPT.md "Screens": "4. Bibliothek". Decision E48: "Weiterhören"
/// on top (the last books heard, from the journal, E33), then all books
/// with search and a chosen order; each row has a cover thumbnail, the
/// author, the book's progress as a thin thread with the time left (or
/// "neu"/"gehört"), and a quiet download state. Reached from the player
/// via a small icon or a swipe down; shows the mini player at the bottom
/// while a book is open (decision E29).
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

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
    final sort = ref.watch(librarySortProvider);
    return Scaffold(
      bottomNavigationBar: const MiniPlayer(),
      appBar: AppBar(
        title: Text(AppStrings.libraryTitle),
        actions: [
          if (controller.books.isNotEmpty)
            PopupMenuButton<LibrarySort>(
              tooltip: AppStrings.librarySortTooltip,
              icon: const Icon(Icons.swap_vert),
              initialValue: sort,
              onSelected: ref.read(librarySortProvider.notifier).set,
              itemBuilder: (context) => [
                for (final option in LibrarySort.values)
                  CheckedPopupMenuItem<LibrarySort>(
                    value: option,
                    checked: option == sort,
                    child: Text(librarySortLabel(option)),
                  ),
              ],
            ),
          IconButton(
            tooltip: AppStrings.settingsTitle,
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: controller.refresh,
        child: _body(controller, sort),
      ),
    );
  }

  Widget _body(LibraryController controller, LibrarySort sort) {
    final configured = ref.watch(serverConfigProvider).isConfigured;
    if (controller.books.isEmpty) {
      if (!configured) {
        // First launch: nothing to retry yet, only something to set up.
        return _EmptyState(
          icon: Icons.menu_book_outlined,
          title: AppStrings.setupTitle,
          body: AppStrings.setupBody,
          action: FilledButton(onPressed: _openSettings, child: Text(AppStrings.setupAction)),
        );
      }
      if (controller.offline) {
        return _EmptyState(
          icon: Icons.cloud_off_outlined,
          title: AppStrings.offlineNotice,
          action: FilledButton(onPressed: controller.refresh, child: Text(AppStrings.libraryRetry)),
          secondary: TextButton(onPressed: _openSettings, child: Text(AppStrings.settingsTitle)),
        );
      }
      if (controller.loading) return const Center(child: CircularProgressIndicator());
      return _EmptyState(
        icon: Icons.menu_book_outlined,
        title: AppStrings.libraryEmpty,
        body: AppStrings.libraryEmptyHint,
      );
    }

    final progress = controller.progressByBook;
    final arranged = arrangeBooks(books: controller.books, progress: progress, sort: sort, query: _query);
    final continueBooks = _query.isEmpty ? continueListening(controller) : const <BookSummary>[];

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
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
          SliverList.list(children: [for (final b in continueBooks) BookRow(book: b)]),
          SliverToBoxAdapter(child: _SectionHeader(AppStrings.libraryAllBooks)),
        ],
        if (arranged.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(AppStrings.libraryNoMatches, textAlign: TextAlign.center),
            ),
          )
        else
          SliverList.builder(
            itemCount: arranged.length,
            itemBuilder: (context, i) => BookRow(book: arranged[i]),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  /// "Weiterhören": the most recently played books that are not finished.
  List<BookSummary> continueListening(LibraryController controller) =>
      controller.continueListening.take(continueCount).toList();
}

String librarySortLabel(LibrarySort sort) => switch (sort) {
      LibrarySort.recent => AppStrings.librarySortRecent,
      LibrarySort.title => AppStrings.librarySortTitle,
      LibrarySort.author => AppStrings.librarySortAuthor,
    };

/// Filters [books] by [query] (title or author, case- and umlaut-folding)
/// and orders them by [sort]. Pure, so it is tested without widgets.
/// "Zuletzt gehört": books with progress, newest first, then the rest by
/// title. "Autor": by author, books without one last, then by title.
List<BookSummary> arrangeBooks({
  required List<BookSummary> books,
  required Map<String, BookProgress> progress,
  required LibrarySort sort,
  String query = '',
}) {
  final q = foldForSearch(query.trim());
  final list = [
    for (final b in books)
      if (q.isEmpty || foldForSearch(b.title).contains(q) || foldForSearch(b.author ?? '').contains(q)) b,
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
        final c = foldForSearch(aa).compareTo(foldForSearch(ba));
        return c != 0 ? c : byTitle(a, b);
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
          Icon(Icons.cloud_off_outlined, size: 18, color: tokens.tinteLeise),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              AppStrings.offlineBanner,
              style: TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.caption),
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
    // A list, so pull-to-refresh works here too.
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(32, 72, 32, 32),
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
    );
  }
}

/// One book: cover, title, author, progress, download state.
class BookRow extends ConsumerWidget {
  final BookSummary book;

  const BookRow({super.key, required this.book});

  static const double coverSize = 56;

  bool get _unavailable => book.serverStatus == 'incomplete' || book.serverStatus == 'empty';

  /// Decision E58: while the server is unreachable, a book that is not
  /// fully downloaded cannot play; the row is dimmed and says "nur online".
  static bool onlineOnly(LibraryController controller, BookSummary book, BookDownloadState download) =>
      controller.offline && book.serverStatus == 'ok' && !download.isDownloaded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(libraryControllerProvider);
    final tokens = FadenTokens.of(context);
    final download = controller.downloadStateFor(book.bookId);
    final progress = controller.progressByBook[book.bookId];
    final author = book.author?.trim();
    final canDelete = download.bytesOnDisk > 0;
    final dimmed = _unavailable || onlineOnly(controller, book, download);

    Widget row = InkWell(
      onTap: () => _onTap(context, ref, controller),
      onLongPress: canDelete ? () => _showActions(context, controller, download) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
        child: Row(
          children: [
            Opacity(
              opacity: dimmed ? 0.5 : 1,
              child: BookCover(
                bookId: book.bookId,
                title: book.title,
                size: coverSize,
                radius: 6,
                thumbnail: true,
              ),
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
                    style: TextStyle(
                      fontSize: FadenTypeSizes.body,
                      color: dimmed ? tokens.tinteLeise : tokens.tinte,
                    ),
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
            _DownloadControl(book: book, download: download, controller: controller, tokens: tokens),
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

  Future<void> _showActions(BuildContext context, LibraryController controller, BookDownloadState download) async {
    final delete = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: Icon(Icons.delete_outline, color: FadenTokens.of(context).fehler),
              title: Text(AppStrings.downloadDeleteWithSize(formatBytes(download.bytesOnDisk))),
              onTap: () => Navigator.of(context).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: Text(AppStrings.cancelAction),
              onTap: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ),
    );
    if (delete == true) await controller.deleteDownload(book.bookId);
  }

  Future<void> _onTap(BuildContext context, WidgetRef ref, LibraryController controller) async {
    final messenger = ScaffoldMessenger.of(context);
    if (book.needsReview) {
      final candidates = await controller.reviewCandidates(book.bookId);
      if (!context.mounted || candidates.isEmpty) return;
      final manifestId = await showReviewDialog(context, candidates);
      if (manifestId == null) return;
      await controller.confirmManifest(book.bookId, manifestId);
      messenger.showSnackBar(SnackBar(content: Text(AppStrings.confirmManifestSuccess)));
      return;
    }
    if (_unavailable) {
      // Not openable, so say why instead of doing nothing.
      messenger.showSnackBar(SnackBar(
        content: Text(
          book.serverStatus == 'empty' ? AppStrings.libraryEmptyExplain : AppStrings.libraryIncompleteExplain,
        ),
      ));
      return;
    }
    // Cache first (decision E30): opens offline, too.
    final result = await ref.read(bookOpenerProvider).open(book.bookId);
    if (!context.mounted) return;
    if (result == OpenBookResult.unavailable) {
      messenger.showSnackBar(SnackBar(content: Text(AppStrings.libraryOpenFailed)));
      return;
    }
    // Back to the one root player instead of stacking a new one on top
    // (decision E29).
    showPlayerScreen(Navigator.of(context));
  }
}

class _StatusLine extends StatelessWidget {
  final BookSummary book;
  final BookProgress? progress;
  final BookDownloadState download;
  final FadenTokens tokens;
  final bool onlineOnly;

  const _StatusLine({
    required this.book,
    required this.progress,
    required this.download,
    required this.tokens,
    this.onlineOnly = false,
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
      return Text(AppStrings.downloadProgress(formatBytes(download.receivedBytes)), style: small);
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
            width: 48,
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
        Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: small)),
      ],
    );
  }
}

class _DownloadControl extends StatelessWidget {
  final BookSummary book;
  final BookDownloadState download;
  final LibraryController controller;
  final FadenTokens tokens;

  const _DownloadControl({
    required this.book,
    required this.download,
    required this.controller,
    required this.tokens,
  });

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
            icon: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.square(
                  dimension: 26,
                  child: CircularProgressIndicator(value: download.fraction, strokeWidth: 2.5),
                ),
                Icon(Icons.stop_rounded, size: 14, color: tokens.faden),
              ],
            ),
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
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(AppStrings.reviewDialogCancel),
        ),
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
