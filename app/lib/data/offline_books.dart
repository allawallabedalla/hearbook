import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

import '../domain/event.dart';
import '../domain/manifest.dart';
import '../domain/resolver.dart';
import 'book_downloads.dart';
import 'journal.dart';

/// Reads the phone's current network (connectivity_plus's
/// `checkConnectivity`); a function so tests can answer without the plugin.
typedef ConnectivityCheck = Future<List<ConnectivityResult>> Function();

/// Whether [results] allow an automatic download (decision E56): Wi-Fi or
/// Ethernet, and never while a cellular link is reported -- when both are
/// listed it is unclear which one carries the traffic, so no.
bool allowsAutoDownload(List<ConnectivityResult> results) =>
    (results.contains(ConnectivityResult.wifi) || results.contains(ConnectivityResult.ethernet)) &&
    !results.contains(ConnectivityResult.mobile);

/// Downloads the books the listener is most likely to want tonight (the
/// NAS is off at night): the open book and the next one from
/// "Weiterhören" (decision E56), while the server is reachable and the
/// phone is on Wi-Fi. Runs in the background only; nothing awaits it
/// before playback or UI.
///
/// One pass at a time: a [trigger] while a pass runs asks for exactly one
/// more pass afterwards (the open book may have changed meanwhile), and
/// [BookDownloads.download] itself never runs the same book twice.
class AutoDownloader {
  /// The "Aktuelle Bücher automatisch laden" setting, read on every pass.
  final Future<bool> Function() enabled;
  final ConnectivityCheck connectivity;

  /// A cheap reachability check (the server's `/health`). Never throws.
  final Future<bool> Function() serverReachable;

  /// Book ids to keep on the device, most important first.
  final Future<List<String>> Function() candidates;
  final Future<Manifest?> Function(String bookId) manifestFor;
  final BookDownloads downloads;

  final Set<String> _started = {};
  Future<void>? _running;
  bool _again = false;

  AutoDownloader({
    required this.enabled,
    required this.connectivity,
    required this.serverReachable,
    required this.candidates,
    required this.manifestFor,
    required this.downloads,
  });

  /// Books this downloader is downloading right now.
  Set<String> get running => Set.unmodifiable(_started);

  /// Starts a pass, or queues one more if a pass is running. Completes
  /// when no pass is left. Never throws.
  Future<void> trigger() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  /// A network change (main.dart): Wi-Fi starts a pass; anything else stops
  /// the downloads this class started (cellular never). Downloads the
  /// listener started stay untouched.
  void onNetworkChanged(List<ConnectivityResult> results) {
    if (allowsAutoDownload(results)) {
      unawaited(trigger());
      return;
    }
    for (final id in [..._started]) {
      downloads.cancel(id);
    }
  }

  Future<void> _loop() async {
    do {
      _again = false;
      try {
        await _pass();
      } catch (_) {
        // Best effort: the next trigger tries again.
      }
    } while (_again);
  }

  Future<void> _pass() async {
    if (!await enabled()) return;
    if (!allowsAutoDownload(await _network())) return;
    if (!await serverReachable()) return;
    for (final bookId in await candidates()) {
      final manifest = await manifestFor(bookId);
      if (manifest == null || manifest.files.isEmpty) continue;
      final state = await downloads.refresh(bookId, manifest);
      // A chapter run over mobile data (E66) gives way to the whole book.
      if (state.isDownloaded || (state.isDownloading && !downloads.isChapterRun(bookId))) continue;
      // The phone may have left the Wi-Fi during the previous book.
      if (!await enabled() || !allowsAutoDownload(await _network())) return;
      _started.add(bookId);
      try {
        await downloads.download(bookId, manifest);
      } finally {
        _started.remove(bookId);
      }
    }
  }

  Future<List<ConnectivityResult>> _network() async {
    try {
      return await connectivity();
    } catch (_) {
      return const [];
    }
  }
}

/// Removes the downloaded audio of books heard to the end (decision E57).
/// "Finished" is the Resolver's `finished` only -- the end reached without
/// sleep suspicion (invariant 5); a book whose end came while the listener
/// probably slept keeps its files. Only audio files go: events, positions,
/// the library cache and the pause index stay.
///
/// A book still loaded in the player keeps its files until another book is
/// opened or the app starts again ([isLoaded]): its playlist points at
/// them, and replaying the last chapter must keep working.
class FinishedCleanup {
  final Journal journal;
  final BookDownloads downloads;
  final Future<Manifest?> Function(String bookId) manifestFor;

  /// The night window from the settings, for the Resolver's sleep rule.
  final Future<ResolverSettings> Function() resolverSettings;
  final bool Function(String bookId) isLoaded;

  FinishedCleanup({
    required this.journal,
    required this.downloads,
    required this.manifestFor,
    required this.resolverSettings,
    required this.isLoaded,
  });

  /// Whether the Resolver says [bookId] is finished (and its position is
  /// in the active manifest), resolved against [manifest] or else
  /// [manifestFor]. False when anything is unknown.
  Future<bool> isFinished(String bookId, [Manifest? manifest]) async {
    final m = manifest ?? await manifestFor(bookId);
    if (m == null) return false;
    return _finished(bookId, m);
  }

  Future<bool> _finished(String bookId, Manifest manifest) async {
    try {
      final events = await journal.eventsForBook(bookId);
      if (!events.any((e) => e.type == EventType.finished)) return false;
      final state = resolve(events, manifest, settings: await resolverSettings());
      return state.finished && !state.needsConfirmation;
    } catch (_) {
      return false; // e.g. no intent event yet: not finished
    }
  }

  /// Deletes [bookId]'s downloaded files if it is finished and not loaded
  /// in the player. Returns whether anything was deleted. Never throws.
  Future<bool> cleanBook(String bookId) async {
    try {
      if (isLoaded(bookId)) return false;
      final manifest = await manifestFor(bookId);
      if (manifest == null || manifest.files.isEmpty) return false;
      final state = await downloads.refresh(bookId, manifest);
      if (state.bytesOnDisk <= 0 && !state.isDownloading) return false;
      if (!await _finished(bookId, manifest)) return false;
      if (isLoaded(bookId)) return false;
      await downloads.deleteBook(bookId, manifest);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Start-up pass over every book with a `FINISHED` event (only those can
  /// be finished). Returns the ids whose files were deleted.
  Future<Set<String>> cleanAll() async {
    final deleted = <String>{};
    try {
      for (final bookId in await journal.bookIdsWithEvent(EventType.finished)) {
        if (await cleanBook(bookId)) deleted.add(bookId);
      }
    } catch (_) {
      // Housekeeping never keeps the app from starting.
    }
    return deleted;
  }
}
