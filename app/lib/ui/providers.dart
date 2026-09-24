import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../audio/handler.dart';
import '../audio/player.dart';
import '../data/api.dart';
import '../data/book_downloads.dart';
import '../data/db.dart';
import '../data/downloads.dart';
import '../data/journal.dart';
import '../data/library.dart';
import '../data/settings_store.dart';
import '../data/sleep_data_source.dart';
import '../data/storage.dart';
import '../data/sync.dart';
import '../domain/event.dart';
import '../domain/manifest.dart';
import '../domain/position.dart';
import '../domain/resolver.dart';
import '../domain/sleep_onset.dart';

export '../data/library.dart' show BookSummary, ManifestCandidate, BookDetail;

/// Wiring for the singletons main.dart creates before `runApp` (the
/// database file, the audio_service handler, ...). Every provider here is
/// overridden with a concrete value in main.dart's `ProviderScope`; the
/// defaults below only exist so widget tests can override a subset of
/// them without touching the rest.
final appDatabaseProvider =
    Provider<AppDatabase>((ref) => throw UnimplementedError('override in main.dart'));
final journalProvider = Provider<Journal>((ref) => Journal(ref.watch(appDatabaseProvider)));
final settingsStoreProvider =
    Provider<SettingsStore>((ref) => SettingsStore(ref.watch(appDatabaseProvider)));
final deviceIdProvider = Provider<String>((ref) => throw UnimplementedError('override in main.dart'));

/// The app-support directory (path_provider), resolved once in main.dart.
/// Downloads, the library cache and saved covers live below it. Null in
/// tests that do not need files.
final appSupportDirProvider = Provider<Directory?>((ref) => null);

/// Server address and token as stored in the settings.
class ServerConfig {
  final String? url;
  final String? token;

  const ServerConfig({this.url, this.token});

  static const empty = ServerConfig();

  bool get isConfigured => ApiClient.tryCreate(baseUrl: url, token: token) != null;

  @override
  bool operator ==(Object other) => other is ServerConfig && other.url == url && other.token == token;

  @override
  int get hashCode => Object.hash(url, token);
}

/// The stored server settings as read once in main.dart before `runApp`.
final initialServerConfigProvider = Provider<ServerConfig>((ref) => ServerConfig.empty);

/// The live server settings (decision E37). [save] writes the store first,
/// then changes the state, and everything built on it -- API client,
/// downloads, sync, library -- is rebuilt at once, without an app restart.
class ServerConfigController extends Notifier<ServerConfig> {
  @override
  ServerConfig build() => ref.watch(initialServerConfigProvider);

  /// Normalizes [url] (data/api.dart `normalizeServerUrl`) and saves both.
  /// An address that cannot be normalized is saved as typed, so the
  /// settings screen shows what was entered; the API client then stays
  /// null. Returns the saved configuration.
  Future<ServerConfig> save({required String url, required String token}) async {
    final normalized = normalizeServerUrl(url) ?? url.trim();
    final trimmedToken = token.trim();
    final settings = ref.read(settingsStoreProvider);
    await settings.setServerUrl(normalized);
    await settings.setServerToken(trimmedToken);
    final next = ServerConfig(url: normalized, token: trimmedToken);
    if (ref.mounted) state = next;
    return next;
  }
}

final serverConfigProvider =
    NotifierProvider<ServerConfigController, ServerConfig>(ServerConfigController.new);

/// Null until a server URL and token are configured. Rebuilt whenever
/// [serverConfigProvider] changes.
final apiClientProvider = Provider<ApiClient?>((ref) {
  final config = ref.watch(serverConfigProvider);
  return ApiClient.tryCreate(baseUrl: config.url, token: config.token);
});

/// Decision E30: JSON cache of the book list and details. Null without an
/// app-support directory (tests).
final libraryCacheProvider = Provider<LibraryCache?>((ref) {
  final dir = ref.watch(appSupportDirProvider);
  return dir == null ? null : LibraryCache(Directory('${dir.path}/library'));
});

final libraryRepositoryProvider = Provider<LibraryRepository>(
  (ref) => LibraryRepository(api: ref.watch(apiClientProvider), cache: ref.watch(libraryCacheProvider)),
);

/// Downloaded audio (decision E35: `<app support>/audio`, excluded from
/// the iCloud backup). Exists whenever the directory is known, also
/// without a server: downloaded books must play offline.
final downloadManagerProvider = Provider<DownloadManager?>((ref) {
  final dir = ref.watch(appSupportDirProvider);
  if (dir == null) return null;
  return DownloadManager(api: ref.watch(apiClientProvider), targetDir: audioDirIn(dir));
});

/// Whole-book downloads with progress, cancel, retry, delete and storage
/// (decision E34). Null without a [downloadManagerProvider].
final bookDownloadsProvider = ChangeNotifierProvider<BookDownloads?>((ref) {
  final manager = ref.watch(downloadManagerProvider);
  return manager == null ? null : BookDownloads(manager: manager);
});

final syncClientProvider = Provider<SyncClient?>((ref) {
  final api = ref.watch(apiClientProvider);
  if (api == null) return null;
  return SyncClient(db: ref.watch(appDatabaseProvider), journal: ref.watch(journalProvider), api: api);
});

/// Keeps the audio handler's sync client in step with the server settings
/// (E37). Watched once by the app root (main.dart).
final syncWiringProvider = Provider<void>((ref) {
  ref.watch(audioHandlerProvider).syncClient = ref.watch(syncClientProvider);
});

/// Keeps a copy of the book's cover on the device for the lock screen, so it
/// also shows offline; falls back to the last saved copy.
Future<Uri?> saveCoverForLockScreen(String bookId, ApiClient? api, Directory dir) async {
  if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(bookId)) return null;
  final file = File('${dir.path}/covers/$bookId');
  if (api != null) {
    try {
      final bytes = await api.cover(bookId);
      if (bytes != null) {
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes, flush: true);
      }
    } catch (_) {
      // Offline: keep whatever copy we already have.
    }
  }
  return await file.exists() ? file.uri : null;
}

// Fetched once per book; loading it in build() refetched it on every position tick.
// Offline (E30), the copy saved for the lock screen is shown instead.
final coverProvider = FutureProvider.family<Uint8List?, String>((ref, bookId) async {
  final api = ref.watch(apiClientProvider);
  final dir = ref.watch(appSupportDirProvider);
  if (dir != null) {
    final uri = await saveCoverForLockScreen(bookId, api, dir);
    return uri == null ? null : await File.fromUri(uri).readAsBytes();
  }
  if (api == null) return null;
  final bytes = await api.cover(bookId);
  if (bytes == null) return null;
  return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
});

/// "Erscheinungsbild" as read once in main.dart before `runApp`, so the
/// very first frame already has the right look. Defaults to
/// [Appearance.system] for tests that do not override it.
final initialAppearanceProvider = Provider<Appearance>((ref) => Appearance.system);

/// The live "Erscheinungsbild" setting (decision E28). [set] writes to the
/// settings store first and only then changes the state, so what the
/// screen shows is always what is stored.
class AppearanceController extends Notifier<Appearance> {
  @override
  Appearance build() => ref.watch(initialAppearanceProvider);

  Future<void> set(Appearance appearance) async {
    await ref.read(settingsStoreProvider).setAppearance(appearance);
    if (!ref.mounted) return;
    state = appearance;
  }
}

final appearanceProvider =
    NotifierProvider<AppearanceController, Appearance>(AppearanceController.new);

/// The night window in minutes since local midnight (docs/KONZEPT.md
/// "Faden aufnehmen": default 20 to 6 o'clock). It may cross midnight.
class NightWindow {
  final int startMin;
  final int endMin;

  const NightWindow({required this.startMin, required this.endMin});

  static const defaults = NightWindow(startMin: 20 * 60, endMin: 6 * 60);

  @override
  bool operator ==(Object other) =>
      other is NightWindow && other.startMin == startMin && other.endMin == endMin;

  @override
  int get hashCode => Object.hash(startMin, endMin);
}

/// The night window from the settings store, shared by the settings screen
/// (which changes it) and the player (which reads it for Nachtmodus and
/// the handler's SLEEP_HINT hook), so a change applies right away. The
/// setters write the store first, then update the state.
class NightWindowController extends AsyncNotifier<NightWindow> {
  @override
  Future<NightWindow> build() async {
    final settings = ref.watch(settingsStoreProvider);
    return NightWindow(
      startMin: await settings.nightStartMin(),
      endMin: await settings.nightEndMin(),
    );
  }

  Future<void> setStart(int minutes) async {
    final current = await future;
    await ref.read(settingsStoreProvider).setNightStartMin(minutes);
    if (!ref.mounted) return;
    final latest = state.value ?? current;
    state = AsyncData(NightWindow(startMin: minutes, endMin: latest.endMin));
  }

  Future<void> setEnd(int minutes) async {
    final current = await future;
    await ref.read(settingsStoreProvider).setNightEndMin(minutes);
    if (!ref.mounted) return;
    final latest = state.value ?? current;
    state = AsyncData(NightWindow(startMin: latest.startMin, endMin: minutes));
  }
}

final nightWindowProvider =
    AsyncNotifierProvider<NightWindowController, NightWindow>(NightWindowController.new);

/// The stored default sleep-timer duration in minutes, 0 meaning
/// "Kapitelende" (data/settings_store.dart `sleepTimerDefaultMin`, E42).
/// [set] writes the store first, then updates the state.
class SleepTimerDefaultController extends AsyncNotifier<int> {
  @override
  Future<int> build() => ref.watch(settingsStoreProvider).sleepTimerDefaultMin();

  Future<void> set(int minutes) async {
    await ref.read(settingsStoreProvider).setSleepTimerDefaultMin(minutes);
    if (!ref.mounted) return;
    state = AsyncData(minutes);
  }
}

final sleepTimerDefaultProvider =
    AsyncNotifierProvider<SleepTimerDefaultController, int>(SleepTimerDefaultController.new);

/// M6 (docs/ARCHITEKTUR.md section 9): null on a platform without a
/// [SleepDataSource] implementation wired up (there is none yet besides
/// [HealthPluginSleepDataSource], but this stays overridable/nullable the
/// same way [syncClientProvider] is, so tests never need a real plugin
/// instance). Constructing/overriding this alone requests no permission
/// and reads no data -- see [PlayerSessionController.sleepOnsetAdjustment].
final sleepDataSourceProvider = Provider<SleepDataSource?>((ref) => null);

final audioHandlerProvider =
    Provider<FadenAudioHandler>((ref) => throw UnimplementedError('override in main.dart'));

/// Where a book stands, for the library's "Weiterhören" row and the
/// "zuletzt gehört" order (decision E33) -- computed from one journal
/// query, not a Resolver replay per row.
class BookProgress {
  final String bookId;

  /// The resolved position (invariant 1).
  final Position position;

  /// [position] as a fraction of the book (0..1); null while the book's
  /// manifest is unknown or does not contain the position's file.
  final double? fraction;

  /// Wall time of the book's newest event (any device).
  final DateTime lastPlayed;

  const BookProgress({
    required this.bookId,
    required this.position,
    required this.fraction,
    required this.lastPlayed,
  });
}

/// Builds [BookProgress] from journal rows and whatever manifests are known.
Map<String, BookProgress> bookProgressFrom(
  Map<String, BookProgressRow> rows,
  Map<String, Manifest> manifests,
) =>
    {
      for (final row in rows.values)
        row.bookId: BookProgress(
          bookId: row.bookId,
          position: row.position,
          fraction: manifests[row.bookId]?.fractionFor(row.position),
          lastPlayed: DateTime.fromMillisecondsSinceEpoch(row.lastWallMs),
        ),
    };

/// docs/KONZEPT.md "Bibliothek": the book list plus download and
/// reorder-review actions, cache first (decision E30). A missing server
/// (not configured, unreachable) is a valid, handled state --
/// docs/KONZEPT.md Texte-Tabelle "Offline": "Keine Verbindung zum Server.
/// Geladene Bücher spielen weiter."
///
/// [refresh] shows the cached list at once, notifies as soon as the
/// server's list arrives, and only then walks the books' details in the
/// background (bounded concurrency, E30/E34) to learn manifests and
/// download state. [whenIdle] completes once that walk is done.
class LibraryController extends ChangeNotifier {
  final LibraryRepository repository;
  final BookDownloads? downloads;
  final Journal? journal;

  /// How many book details are fetched at the same time.
  final int detailConcurrency;

  bool loading = false;
  bool offline = false;
  List<BookSummary> books = [];

  /// Active manifests known so far (cache or server), per book.
  final Map<String, Manifest> manifests = {};

  /// Per-book progress (E33); see [refreshProgress].
  Map<String, BookProgress> progressByBook = {};

  Future<void>? _refreshing;
  Future<void> _detailsPass = Future.value();
  bool _disposed = false;

  LibraryController({
    required this.repository,
    required this.downloads,
    this.journal,
    this.detailConcurrency = 4,
  }) {
    downloads?.addListener(_notify);
  }

  ApiClient? get api => repository.api;

  /// Whether every file of [bookId] is on the device (legacy view of
  /// [downloadStateFor]).
  Map<String, bool> get downloadedByBook => {
        for (final e in (downloads?.states ?? const <String, BookDownloadState>{}).entries)
          e.key: e.value.isDownloaded,
      };

  /// Running downloads' progress 0..1 (legacy view of [downloadStateFor]).
  Map<String, double?> get downloadProgressByBook => {
        for (final e in (downloads?.states ?? const <String, BookDownloadState>{}).entries)
          if (e.value.isDownloading) e.key: e.value.fraction,
      };

  BookDownloadState downloadStateFor(String bookId) =>
      downloads?.stateFor(bookId) ?? BookDownloadState.unknown;

  /// Books with progress, most recently played first ("zuletzt gehört").
  List<BookSummary> get recentlyPlayed {
    final withProgress = [
      for (final b in books)
        if (progressByBook.containsKey(b.bookId)) b,
    ];
    withProgress.sort((a, b) => progressByBook[b.bookId]!.lastPlayed.compareTo(progressByBook[a.bookId]!.lastPlayed));
    return withProgress;
  }

  /// Completes when the last [refresh]'s background detail walk is done.
  Future<void> whenIdle() async {
    await _refreshing;
    await _detailsPass;
  }

  Future<void> refresh() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    if (books.isEmpty) {
      final cached = await repository.cachedBooks();
      if (cached != null && books.isEmpty) {
        books = cached;
        _notify();
        _detailsPass = _walkDetails(cached, network: false);
      }
    }
    unawaited(refreshProgress());
    if (repository.api == null) {
      offline = true;
      _notify();
      return;
    }
    loading = true;
    _notify();
    var fetched = false;
    try {
      books = await repository.fetchBooks();
      offline = false;
      fetched = true;
    } catch (_) {
      offline = true;
    } finally {
      loading = false;
      _notify();
    }
    if (fetched) {
      final list = books;
      final previous = _detailsPass;
      _detailsPass = previous.then((_) => _walkDetails(list, network: true));
    }
  }

  /// Learns each book's manifest (server first when [network], else the
  /// cache) and its download state, [detailConcurrency] books at a time.
  Future<void> _walkDetails(List<BookSummary> list, {required bool network}) async {
    var next = 0;
    Future<void> worker() async {
      while (next < list.length && !_disposed) {
        final book = list[next++];
        try {
          final detail = network
              ? await repository.detailNetworkFirst(book.bookId)
              : await repository.cachedDetail(book.bookId);
          final manifest = detail?.activeManifest;
          if (manifest == null || _disposed) continue;
          manifests[book.bookId] = manifest;
          await downloads?.refresh(book.bookId, manifest);
        } catch (_) {
          // One unreadable book never stops the others.
        }
      }
    }

    await Future.wait([for (var i = 0; i < detailConcurrency; i++) worker()]);
    if (_disposed) return;
    progressByBook = bookProgressFrom(await _progressRows(), manifests);
    _notify();
  }

  /// Re-reads per-book progress from the journal (one query, E33).
  Future<void> refreshProgress() async {
    final rows = await _progressRows();
    if (_disposed) return;
    progressByBook = bookProgressFrom(rows, manifests);
    _notify();
  }

  Future<Map<String, BookProgressRow>> _progressRows() async {
    final j = journal;
    if (j == null) return const {};
    try {
      return await j.progressRows();
    } catch (_) {
      return const {};
    }
  }

  Future<Manifest?> _manifestFor(String bookId) async {
    final known = manifests[bookId];
    if (known != null) return known;
    final detail = await repository.detailCacheFirst(bookId);
    final manifest = detail?.activeManifest;
    if (manifest != null) manifests[bookId] = manifest;
    return manifest;
  }

  /// Downloads every file of [bookId]'s active manifest, hash-verified
  /// (data/downloads.dart). docs/ARCHITEKTUR.md section 11: "Ein Download
  /// gilt erst als fertig, wenn der Audio-Hash der Datei stimmt." Progress
  /// and failures: [downloadStateFor].
  Future<bool> downloadBook(String bookId) async {
    final dm = downloads;
    if (dm == null) return false;
    final manifest = await _manifestFor(bookId);
    if (manifest == null) return false;
    return dm.download(bookId, manifest);
  }

  Future<bool> retryDownload(String bookId) => downloadBook(bookId);

  void cancelDownload(String bookId) => downloads?.cancel(bookId);

  /// Removes [bookId]'s downloaded files; the book streams again.
  Future<void> deleteDownload(String bookId) async {
    final dm = downloads;
    if (dm == null) return;
    final manifest = await _manifestFor(bookId);
    if (manifest == null) return;
    await dm.deleteBook(bookId, manifest);
  }

  /// Bytes all downloaded audio takes on this device.
  Future<int> totalDownloadedBytes() async => await downloads?.totalBytesOnDisk() ?? 0;

  Future<List<ManifestCandidate>> reviewCandidates(String bookId) async {
    if (repository.api == null) return const [];
    final detail = await repository.fetchDetail(bookId);
    return detail.candidates;
  }

  Future<void> confirmManifest(String bookId, String manifestId) async {
    final client = repository.api;
    if (client == null) return;
    await client.confirmManifest(bookId, manifestId);
    manifests.remove(bookId);
    await refresh();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    downloads?.removeListener(_notify);
    super.dispose();
  }
}

/// docs/ARCHITEKTUR.md section 11: "App-Start: Resolver ausführen, Player
/// an der Position pausiert vorbereiten." Owns the currently-open book's
/// manifest and derived [BookState], keeping the latter in sync with the
/// journal (via `handler.eventsWritten`) without duplicating any Resolver
/// logic itself (invariant 2: state is a pure function of events, computed
/// only by domain/resolver.dart).
class PlayerSessionController extends ChangeNotifier {
  final FadenAudioHandler handler;
  final Journal journal;

  /// Per-book speed (E38); null in tests that do not need it.
  final SettingsStore? settings;

  /// How long [openBook] waits for a sync before resolving (E31). The sync
  /// carries on afterwards; its result reaches the open book through
  /// `handler.remoteEventsPulled`.
  final Duration syncBeforeOpenTimeout;

  String? bookId;
  String? bookTitle;
  Manifest? manifest;
  BookState? bookState;
  bool loading = false;

  /// The just_audio playlist built for the currently open book (same
  /// sources handed to [handler]'s main player) -- kept here so
  /// ui/faden_screen.dart's audio/probe_player.dart can reuse it directly
  /// for probe playback (docs/ARCHITEKTUR.md section 8: "Proben laufen über
  /// einen eigenen Player") instead of re-resolving downloads/server URLs
  /// itself. Null until a book with a configured [DownloadManager] has been
  /// opened.
  List<ja.IndexedAudioSource>? playlistSources;

  /// Pause-index offsets (docs/ARCHITEKTUR.md section 4), per `file_hash`,
  /// exactly as `GET /api/v1/books/{id}/pauses` returns them -- converted
  /// to the global-ms axis Faden-Suche needs (domain/pause_index.dart) by
  /// the caller that actually enters Faden mode. Empty (not null) when the
  /// server is unreachable or the book has no index yet: Faden-Suche then
  /// simply runs without snapping to sentence starts, same as the prototype
  /// (prototype/faden.html: "ohne Einrasten weiter").
  Map<String, List<int>> pauseIndex = {};

  final List<StreamSubscription<Object?>> _subs = [];
  bool _opening = false;
  bool _remoteCheckPending = false;
  bool _disposed = false;

  PlayerSessionController({
    required this.handler,
    required this.journal,
    this.settings,
    this.syncBeforeOpenTimeout = const Duration(seconds: 2),
  }) {
    // E40: a HEARTBEAT never changes anything the UI derives from the
    // Resolver beyond the position, which the UI reads live from
    // `handler.positionStream` -- replaying every event of the book every
    // 5 s would only cost battery.
    _subs.add(handler.eventsWritten.listen((event) {
      if (event.type == EventType.heartbeat) return;
      if (event.bookId != bookId) return;
      unawaited(_refreshBookState());
    }));
    _subs.add(handler.remoteEventsPulled.listen((bookIds) {
      final id = bookId;
      if (id != null && bookIds.contains(id)) unawaited(onRemoteEvents());
    }));
  }

  bool get isOpen => bookId != null;

  Future<void> openBook({
    required String bookId,
    required String bookTitle,
    required Manifest manifest,
    required DownloadManager? downloads,
    required String serverBaseUrl,
    required String serverToken,
    ApiClient? api,
    String? author,
    Directory? coverDir,
  }) async {
    _opening = true;
    loading = true;
    _notify();
    this.bookId = bookId;
    this.bookTitle = bookTitle;
    this.manifest = manifest;
    playlistSources = null;
    pauseIndex = {};

    try {
      // E31: pull what other devices did before resolving, so the player
      // opens where the listener last was on any device. Bounded: offline,
      // the book opens from the local journal right away.
      await handler.syncNow(timeout: syncBeforeOpenTimeout);

      final events = await journal.eventsForBook(bookId);
      final state = events.isEmpty ? _freshBookState(manifest) : resolve(events, manifest);
      bookState = state;

      if (downloads != null) {
        final sources = await buildPlaylist(
          manifest: manifest,
          downloads: downloads,
          serverBaseUrl: serverBaseUrl,
          serverToken: serverToken,
        );
        playlistSources = sources;
        Uri? artUri;
        if (coverDir != null) {
          try {
            artUri = await saveCoverForLockScreen(bookId, api, coverDir).timeout(const Duration(seconds: 3));
          } catch (_) {
            // No cover on the lock screen is fine; opening the book must not wait on it.
          }
        }
        final speed = await settings?.bookSpeed(bookId);
        await handler.openBook(
          bookId: bookId,
          manifest: manifest,
          bookTitle: bookTitle,
          sources: sources,
          initialPosition: state.position,
          author: author,
          artUri: artUri,
          speed: speed,
          syncAfterOpen: false, // synced right above
        );
      }
    } finally {
      _opening = false;
      loading = false;
    }

    if (api != null) {
      try {
        final raw = await api.pauses(bookId);
        pauseIndex = raw.map((key, value) => MapEntry(key, (value as List).cast<int>()));
      } catch (_) {
        // Offline/unreachable: Faden-Suche just runs without snapping.
      }
    }

    _notify();
    if (_remoteCheckPending) {
      _remoteCheckPending = false;
      unawaited(onRemoteEvents());
    }
  }

  /// A sync pulled new events for the open book (E31): re-resolve, and if
  /// nothing plays, move the prepared player to the resolved position --
  /// the handler shows the undo hint "Position vom anderen Gerät
  /// übernommen" for a jump over 2 min (invariant 6).
  Future<void> onRemoteEvents() async {
    if (_opening) {
      _remoteCheckPending = true;
      return;
    }
    await _refreshBookState();
    final state = bookState;
    final m = manifest;
    if (state == null || m == null || state.needsConfirmation) return;
    if (handler.playing || handler.bookId != bookId) return;
    final here = m.globalMsFor(handler.currentPosition());
    final there = m.globalMsFor(state.position);
    if (there == null) return;
    // The player runs a moment past the position its own PAUSE recorded;
    // that difference is not another device's doing.
    if (here != null && (here - there).abs() < _adoptToleranceMs) return;
    await handler.adoptRemotePosition(state.position);
  }

  static const _adoptToleranceMs = 1500;

  /// Changes the speed of the open book and remembers it for that book
  /// (E38). Not journaled.
  Future<void> setSpeed(double speed) async {
    await handler.setSpeed(speed);
    final id = bookId;
    if (id != null) await settings?.setBookSpeed(id, speed);
  }

  Future<void> _refreshBookState() async {
    final id = bookId;
    final m = manifest;
    if (id == null || m == null) return;
    final events = await journal.eventsForBook(id);
    if (events.isEmpty || id != bookId || _disposed) return;
    bookState = resolve(events, m);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    super.dispose();
  }

  /// A book with no events yet (never opened on any device before): the
  /// Resolver requires at least one event, so this is the "nothing has
  /// happened" state -- position at the very start of the first chapter.
  BookState _freshBookState(Manifest manifest) {
    final start = manifest.files.isEmpty
        ? const Position(fileHash: '', offsetMs: 0)
        : Position(fileHash: manifest.files.first.fileHash, offsetMs: 0);
    return BookState(
      position: start,
      globalMs: 0,
      lastAwake: start,
      stop: start,
      sleepSuspected: false,
      history: const [],
      finished: false,
      needsConfirmation: false,
      sessionId: '', // no session yet -- matches no event, see sleepOnsetAdjustment
    );
  }

  /// M6 (docs/ARCHITEKTUR.md section 9): the local sleep-onset adjustment
  /// to [lo]/[hi] (both global ms, as computed by the caller that is about
  /// to open ui/faden_screen.dart) from [dataSource], gated by the
  /// settings opt-in ([optedIn]). Returns null whenever nothing should
  /// change -- opt-in off, no [dataSource], an unsupported platform,
  /// denied permission, no reading in the session's time range, or a
  /// reading domain/sleep_onset.dart's own validity checks reject -- in
  /// every one of those cases the caller keeps using the original `hi`
  /// verbatim and `prior: null`, byte-for-byte the same as before M6.
  ///
  /// CLAUDE.md invariant 7: [dataSource]'s reading is used here purely
  /// in-memory for this one calculation; this method only ever returns a
  /// value, it never calls [journal] or any other storage/sync/logging
  /// with it.
  Future<SleepPriorAdjustment?> sleepOnsetAdjustment({
    required SleepDataSource? dataSource,
    required bool optedIn,
    required int lo,
    required int hi,
  }) async {
    final id = bookId;
    final m = manifest;
    final state = bookState;
    if (dataSource == null || !optedIn || id == null || m == null || state == null) return null;
    if (!dataSource.isSupported) return null;
    if (!await dataSource.requestPermission()) return null;

    final events = await journal.eventsForBook(id);
    final sessionEvents = [
      for (final e in events)
        if (e.sessionId == state.sessionId) e,
    ];
    if (sessionEvents.isEmpty) return null;

    var sessionMinWallMs = sessionEvents.first.wallMs;
    var sessionMaxWallMs = sessionEvents.first.wallMs;
    final heartbeats = <HeartbeatSample>[];
    for (final e in sessionEvents) {
      if (e.wallMs < sessionMinWallMs) sessionMinWallMs = e.wallMs;
      if (e.wallMs > sessionMaxWallMs) sessionMaxWallMs = e.wallMs;
      if (e.type != EventType.heartbeat) continue;
      final g = m.globalMsFor(e.position);
      if (g != null) heartbeats.add(HeartbeatSample(wallMs: e.wallMs, globalMs: g));
    }

    final onsetWallMs = await dataSource.sleepOnsetWallMs(
      fromWallMs: sessionMinWallMs,
      toWallMs: sessionMaxWallMs,
    );
    if (onsetWallMs == null) return null;

    return adjustForSleepOnset(
      lo: lo,
      hi: hi,
      sleepOnsetWallMs: onsetWallMs,
      sessionMinWallMs: sessionMinWallMs,
      sessionMaxWallMs: sessionMaxWallMs,
      heartbeats: heartbeats,
    );
  }
}

final libraryControllerProvider = ChangeNotifierProvider<LibraryController>((ref) {
  final controller = LibraryController(
    repository: ref.watch(libraryRepositoryProvider),
    downloads: ref.watch(bookDownloadsProvider),
    journal: ref.watch(journalProvider),
  );
  // Progress changes with every local intent/pause (not heartbeats, E40)
  // and with every sync that brought other devices' events (E31/E33).
  final handler = ref.watch(audioHandlerProvider);
  final subs = [
    handler.eventsWritten
        .where((e) => e.type != EventType.heartbeat)
        .listen((_) => unawaited(controller.refreshProgress())),
    handler.remoteEventsPulled.listen((_) => unawaited(controller.refreshProgress())),
  ];
  ref.onDispose(() {
    for (final sub in subs) {
      unawaited(sub.cancel());
    }
  });
  // Rebuilt after a server change (E37): load at once, cache first, so an
  // open library never shows an empty list. Shared with the screen's own
  // refresh call (refresh() runs one pass at a time).
  unawaited(controller.refresh());
  return controller;
});

final playerSessionProvider = ChangeNotifierProvider<PlayerSessionController>(
  (ref) => PlayerSessionController(
    handler: ref.watch(audioHandlerProvider),
    journal: ref.watch(journalProvider),
    settings: ref.watch(settingsStoreProvider),
  ),
);

/// Result of [BookOpener.open].
enum OpenBookResult {
  /// The book is open in the player (paused at its resolved position).
  opened,

  /// It already was the open book; nothing was touched (playback goes on).
  alreadyOpen,

  /// Neither the cache nor the server knows the book's active manifest
  /// (never opened or listed while online, or it has none yet).
  unavailable,
}

/// Opens a book by id, cache first (decision E30): the cached detail
/// opens it at once -- fully offline for a downloaded book -- and a fresh
/// detail is fetched in the background. Used by the app start (main.dart)
/// and the library.
class BookOpener {
  final Ref _ref;

  BookOpener(this._ref);

  Future<OpenBookResult> open(String bookId) async {
    final session = _ref.read(playerSessionProvider);
    final handler = _ref.read(audioHandlerProvider);
    if (session.bookId == bookId && handler.bookId == bookId && session.manifest != null) {
      return OpenBookResult.alreadyOpen;
    }
    final repository = _ref.read(libraryRepositoryProvider);
    final cached = await repository.cachedDetail(bookId);
    final detail = cached ?? await repository.detailCacheFirst(bookId);
    final manifest = detail?.activeManifest;
    if (detail == null || manifest == null || manifest.files.isEmpty) return OpenBookResult.unavailable;

    await _ref.read(settingsStoreProvider).setLastOpenedBookId(bookId);
    await _openWith(detail, manifest);
    if (cached != null) unawaited(_refreshInBackground(bookId, manifest.manifestId));
    return OpenBookResult.opened;
  }

  Future<void> _openWith(BookDetail detail, Manifest manifest) {
    final api = _ref.read(apiClientProvider);
    final config = _ref.read(serverConfigProvider);
    return _ref.read(playerSessionProvider).openBook(
          bookId: detail.bookId,
          bookTitle: detail.title,
          manifest: manifest,
          downloads: _ref.read(downloadManagerProvider),
          serverBaseUrl: api?.baseUrl ?? '',
          serverToken: config.token ?? '',
          api: api,
          author: detail.author,
          coverDir: _ref.read(appSupportDirProvider),
        );
  }

  /// Refreshes the cached detail; if the server's active manifest changed
  /// meanwhile (e.g. chapters appended, invariant 4) and nothing plays,
  /// the book is prepared again with the new manifest.
  Future<void> _refreshInBackground(String bookId, String openedManifestId) async {
    final BookDetail fresh;
    try {
      fresh = await _ref.read(libraryRepositoryProvider).fetchDetail(bookId);
    } catch (_) {
      return; // offline: the cached detail stays
    }
    final manifest = fresh.activeManifest;
    if (manifest == null || manifest.files.isEmpty || manifest.manifestId == openedManifestId) return;
    final session = _ref.read(playerSessionProvider);
    final handler = _ref.read(audioHandlerProvider);
    if (session.bookId != bookId || handler.playing || handler.fadenModeActive) return;
    await _openWith(fresh, manifest);
  }
}

final bookOpenerProvider = Provider<BookOpener>(BookOpener.new);
