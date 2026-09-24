import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/strings.dart';
import 'mini_player.dart';
import 'player_screen.dart';
import 'providers.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// docs/KONZEPT.md "Screens": "4. Bibliothek: Liste der Bücher mit Status:
/// geladen, neu, Reihenfolge prüfen." Reached from the player via a small
/// icon (docs/KONZEPT.md "Start ist der Player": "Die Bibliothek erreichst
/// du über ein kleines Symbol."). Shows the mini player at the bottom
/// while a book is open (decision E29).
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(libraryControllerProvider).refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(libraryControllerProvider);
    final tokens = FadenTokens.of(context);
    return Scaffold(
      bottomNavigationBar: const MiniPlayer(),
      appBar: AppBar(
        title: Text(AppStrings.libraryTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: controller.refresh,
        child: _body(context, controller, tokens),
      ),
    );
  }

  Widget _body(BuildContext context, LibraryController controller, FadenTokens tokens) {
    if (controller.offline && controller.books.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 48),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(AppStrings.offlineNotice, textAlign: TextAlign.center),
          ),
          Center(
            child: TextButton(onPressed: controller.refresh, child: Text(AppStrings.libraryRetry)),
          ),
        ],
      );
    }
    if (controller.loading && controller.books.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (controller.books.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 48),
          Center(child: Text(AppStrings.libraryEmpty)),
        ],
      );
    }
    return ListView.builder(
      itemCount: controller.books.length,
      itemBuilder: (context, i) => _BookRow(book: controller.books[i]),
    );
  }
}

class _BookRow extends ConsumerWidget {
  final BookSummary book;

  const _BookRow({required this.book});

  String _statusLabel(LibraryController controller) {
    if (book.needsReview) return AppStrings.libraryFolderChanged;
    switch (book.serverStatus) {
      case 'incomplete':
        return AppStrings.libraryStatusIncomplete;
      case 'empty':
        return AppStrings.libraryStatusEmpty;
      default:
        return (controller.downloadedByBook[book.bookId] ?? false)
            ? AppStrings.libraryStatusDownloaded
            : AppStrings.libraryStatusNew;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(libraryControllerProvider);
    final tokens = FadenTokens.of(context);
    final downloaded = controller.downloadedByBook[book.bookId] ?? false;
    final progress = controller.downloadProgressByBook[book.bookId];

    return ListTile(
      title: Text(book.title),
      subtitle: Text(
        book.author == null ? _statusLabel(controller) : '${book.author} · ${_statusLabel(controller)}',
        style: TextStyle(color: tokens.tinteLeise),
      ),
      trailing: book.needsReview
          ? const Icon(Icons.rule_outlined)
          : progress != null
              ? SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(value: progress, strokeWidth: 2),
                )
              : IconButton(
                  icon: Icon(downloaded ? Icons.check_circle_outline : Icons.download_outlined),
                  onPressed: downloaded ? null : () => controller.downloadBook(book.bookId),
                ),
      onTap: () => _onTap(context, ref, controller),
    );
  }

  Future<void> _onTap(BuildContext context, WidgetRef ref, LibraryController controller) async {
    if (book.needsReview) {
      await _showReviewDialog(context, ref, controller);
      return;
    }
    if (book.serverStatus != 'ok') return;
    await _openPlayer(context, ref);
  }

  Future<void> _openPlayer(BuildContext context, WidgetRef ref) async {
    final api = ref.read(apiClientProvider);
    final downloads = ref.read(downloadManagerProvider);
    final settings = ref.read(settingsStoreProvider);
    if (api == null) return;
    final detail = await api.bookDetail(book.bookId);
    final activeJson = detail['active_manifest'] as Map<String, dynamic>?;
    if (activeJson == null) return;
    final manifest = ManifestCandidate.fromJson(activeJson).manifest;
    final serverUrl = await settings.serverUrl() ?? '';
    final token = await settings.serverToken() ?? '';
    await settings.setLastOpenedBookId(book.bookId);
    await ref.read(playerSessionProvider).openBook(
          bookId: book.bookId,
          bookTitle: book.title,
          manifest: manifest,
          downloads: downloads,
          serverBaseUrl: serverUrl,
          serverToken: token,
          api: api,
        );
    if (!context.mounted) return;
    // Back to the one root player instead of stacking a new one on top
    // (decision E29).
    showPlayerScreen(Navigator.of(context));
  }

  Future<void> _showReviewDialog(
    BuildContext context,
    WidgetRef ref,
    LibraryController controller,
  ) async {
    final candidates = await controller.reviewCandidates(book.bookId);
    if (!context.mounted || candidates.isEmpty) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppStrings.reviewDialogTitle),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(AppStrings.reviewDialogBody),
              const SizedBox(height: 12),
              for (var i = 0; i < candidates.length; i++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(AppStrings.reviewDialogOption(i + 1)),
                  subtitle: Text('${candidates[i].manifest.files.length} · ${candidates[i].status}'),
                  onTap: () async {
                    Navigator.of(dialogContext).pop();
                    await controller.confirmManifest(book.bookId, candidates[i].manifest.manifestId);
                  },
                ),
            ],
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
}
