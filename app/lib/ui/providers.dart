import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../audio/handler.dart';
import '../audio/player.dart';
import '../data/api.dart';
import '../data/db.dart';
import '../data/downloads.dart';
import '../data/journal.dart';
import '../data/settings_store.dart';
import '../data/sleep_data_source.dart';
import '../data/sync.dart';
import '../domain/event.dart';
import '../domain/manifest.dart';
import '../domain/position.dart';
import '../domain/resolver.dart';
import '../domain/sleep_onset.dart';

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

/// Null until docs/KONZEPT.md's "Einstellungen" screen has a server URL
/// and token (settings_screen.dart writes both, then main.dart is
/// restarted / the provider re-overridden on next launch).
final apiClientProvider = Provider<ApiClient?>((ref) => null);
final downloadManagerProvider = Provider<DownloadManager?>((ref) => null);
final syncClientProvider = Provider<SyncClient?>((ref) => null);

// Fetched once per book; loading it in build() refetched it on every position tick.
final coverProvider = FutureProvider.family<Uint8List?, String>((ref, bookId) async {
  final api = ref.watch(apiClientProvider);
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

/// M6 (docs/ARCHITEKTUR.md section 9): null on a platform without a
/// [SleepDataSource] implementation wired up (there is none yet besides
/// [HealthPluginSleepDataSource], but this stays overridable/nullable the
/// same way [syncClientProvider] is, so tests never need a real plugin
/// instance). Constructing/overriding this alone requests no permission
/// and reads no data -- see [PlayerSessionController.sleepOnsetAdjustment].
final sleepDataSourceProvider = Provider<SleepDataSource?>((ref) => null);

final audioHandlerProvider =
    Provider<FadenAudioHandler>((ref) => throw UnimplementedError('override in main.dart'));

/// One row of `GET /api/v1/books` (server/src/faden_server/api.py
/// `list_books`), plus the local download state
/// docs/KONZEPT.md's Bibliothek screen shows alongside it.
class BookSummary {
  final String bookId;
  final String title;
  final String? author;
  final int? durationMs;

  /// Server status: `ok`, `needs_review`, `pending`, `incomplete`, `empty`.
  final String serverStatus;

  const BookSummary({
    required this.bookId,
    required this.title,
    required this.author,
    required this.durationMs,
    required this.serverStatus,
  });

  factory BookSummary.fromJson(Map<String, dynamic> json) => BookSummary(
        bookId: json['book_id'] as String,
        title: json['title'] as String,
        author: json['author'] as String?,
        durationMs: json['duration_ms'] as int?,
        serverStatus: json['status'] as String,
      );

  bool get needsReview => serverStatus == 'needs_review' || serverStatus == 'pending';
}

/// One manifest candidate offered by `GET /api/v1/books/{id}` when the
/// book's status is `needs_review`/`pending` (docs/KONZEPT.md: "Reihenfolge
/// prüfen" -- "die App lässt wählen", docs/ARCHITEKTUR.md section 3.2/10).
class ManifestCandidate {
  final Manifest manifest;
  final String status;

  const ManifestCandidate({required this.manifest, required this.status});

  factory ManifestCandidate.fromJson(Map<String, dynamic> json) => ManifestCandidate(
        manifest: Manifest.fromJson(json),
        status: json['status'] as String,
      );
}

/// docs/KONZEPT.md "Bibliothek": the book list plus download and
/// reorder-review actions. `null` `api`/`downloads` (server not configured
/// yet) is a valid, handled state -- docs/KONZEPT.md Texte-Tabelle
/// "Offline": "Keine Verbindung zum Server. Geladene Bücher spielen
/// weiter."
class LibraryController extends ChangeNotifier {
  final ApiClient? api;
  final DownloadManager? downloads;

  bool loading = false;
  bool offline = false;
  List<BookSummary> books = [];
  final Map<String, bool> downloadedByBook = {};
  final Map<String, double?> downloadProgressByBook = {};

  LibraryController({required this.api, required this.downloads});

  Future<void> refresh() async {
    final client = api;
    if (client == null) {
      offline = true;
      notifyListeners();
      return;
    }
    loading = true;
    notifyListeners();
    try {
      final raw = await client.listBooks();
      books = raw.map(BookSummary.fromJson).toList();
      offline = false;
      for (final book in books) {
        await _refreshDownloadState(book);
      }
    } catch (_) {
      offline = true;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> _refreshDownloadState(BookSummary book) async {
    final dm = downloads;
    final client = api;
    if (dm == null || client == null) return;
    try {
      final detail = await client.bookDetail(book.bookId);
      final active = detail['active_manifest'] as Map<String, dynamic>?;
      if (active == null) return;
      final manifest = Manifest.fromJson(active);
      var allDownloaded = manifest.files.isNotEmpty;
      for (final file in manifest.files) {
        if (!await dm.isDownloaded(file.fileHash)) {
          allDownloaded = false;
          break;
        }
      }
      downloadedByBook[book.bookId] = allDownloaded;
    } catch (_) {
      // Leave unknown -- the library list itself already loaded.
    }
  }

  /// Downloads every file of [bookId]'s active manifest, hash-verified
  /// (data/downloads.dart). docs/ARCHITEKTUR.md section 11: "Ein Download
  /// gilt erst als fertig, wenn der Audio-Hash der Datei stimmt."
  Future<bool> downloadBook(String bookId) async {
    final client = api;
    final dm = downloads;
    if (client == null || dm == null) return false;
    downloadProgressByBook[bookId] = 0;
    notifyListeners();
    try {
      final detail = await client.bookDetail(bookId);
      final active = detail['active_manifest'] as Map<String, dynamic>?;
      if (active == null) return false;
      final manifest = Manifest.fromJson(active);
      for (var i = 0; i < manifest.files.length; i++) {
        final file = manifest.files[i];
        if (await dm.isDownloaded(file.fileHash)) continue;
        final result = await dm.download(file.fileHash);
        if (!result.ok) {
          downloadProgressByBook.remove(bookId);
          notifyListeners();
          return false;
        }
        downloadProgressByBook[bookId] = (i + 1) / manifest.files.length;
        notifyListeners();
      }
      downloadedByBook[bookId] = true;
      return true;
    } catch (_) {
      return false;
    } finally {
      downloadProgressByBook.remove(bookId);
      notifyListeners();
    }
  }

  Future<List<ManifestCandidate>> reviewCandidates(String bookId) async {
    final client = api;
    if (client == null) return const [];
    final detail = await client.bookDetail(bookId);
    final candidates = (detail['candidates'] as List).cast<Map<String, dynamic>>();
    return candidates.map(ManifestCandidate.fromJson).toList();
  }

  Future<void> confirmManifest(String bookId, String manifestId) async {
    final client = api;
    if (client == null) return;
    await client.confirmManifest(bookId, manifestId);
    await refresh();
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

  PlayerSessionController({required this.handler, required this.journal}) {
    handler.eventsWritten.listen((_) => _refreshBookState());
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
  }) async {
    loading = true;
    notifyListeners();
    this.bookId = bookId;
    this.bookTitle = bookTitle;
    this.manifest = manifest;
    playlistSources = null;
    pauseIndex = {};

    final events = await journal.eventsForBook(bookId);
    final state = events.isEmpty
        ? _freshBookState(manifest)
        : resolve(events, manifest);
    bookState = state;

    if (downloads != null) {
      final sources = await buildPlaylist(
        manifest: manifest,
        downloads: downloads,
        serverBaseUrl: serverBaseUrl,
        serverToken: serverToken,
      );
      playlistSources = sources;
      await handler.openBook(
        bookId: bookId,
        manifest: manifest,
        bookTitle: bookTitle,
        sources: sources,
        initialPosition: state.position,
      );
    }

    if (api != null) {
      try {
        final raw = await api.pauses(bookId);
        pauseIndex = raw.map((key, value) => MapEntry(key, (value as List).cast<int>()));
      } catch (_) {
        // Offline/unreachable: Faden-Suche just runs without snapping.
      }
    }

    loading = false;
    notifyListeners();
  }

  Future<void> _refreshBookState() async {
    final id = bookId;
    final m = manifest;
    if (id == null || m == null) return;
    final events = await journal.eventsForBook(id);
    if (events.isEmpty) return;
    bookState = resolve(events, m);
    notifyListeners();
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

/// Directory downloaded audio files live in (data/downloads.dart's
/// `targetDir`), resolved once in main.dart.
Directory downloadsDirFor(Directory appSupportDir) => Directory('${appSupportDir.path}/audio');

final libraryControllerProvider = ChangeNotifierProvider<LibraryController>(
  (ref) => LibraryController(api: ref.watch(apiClientProvider), downloads: ref.watch(downloadManagerProvider)),
);

final playerSessionProvider = ChangeNotifierProvider<PlayerSessionController>(
  (ref) => PlayerSessionController(handler: ref.watch(audioHandlerProvider), journal: ref.watch(journalProvider)),
);
