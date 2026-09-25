// The NAS is off every night (20-07 h), when the listener is in bed:
// - decision E56: on Wi-Fi, with the server reachable, the open book and the
//   next "Weiterhören" book download by themselves -- never on cellular,
//   never with the setting off, never twice;
// - decision E57: a finished book (the Resolver's `finished`: end reached
//   without sleep suspicion) loses its downloaded audio -- nothing else --
//   right away when it is not in the player, and on app start.

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:faden/core/hlc.dart';
import 'package:faden/data/api.dart';
import 'package:faden/data/book_downloads.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/library.dart';
import 'package:faden/data/offline_books.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/data/storage.dart';
import 'package:faden/domain/audio_hash_bounds.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/ui/providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_audio_handler.dart';

Uint8List _audio(int seed) => Uint8List.fromList(List.generate(2000 + seed, (i) => (i * seed + 7) % 256));

/// One test book: a single chapter of real (hashable) bytes.
class _Book {
  final String id;
  final Uint8List bytes;
  late final String hash = audioHashBytes(bytes);
  final int durationMs;
  late final Manifest manifest = Manifest(manifestId: 'm-$id', files: [
    ManifestFile(idx: 0, fileHash: hash, durationMs: durationMs),
  ]);

  _Book(this.id, int seed, {this.durationMs = 10 * 60000}) : bytes = _audio(seed);

  Map<String, dynamic> get detail => {
        'book_id': id,
        'title': 'Buch $id',
        'author': null,
        'status': 'ok',
        'active_manifest': {
          'manifest_id': manifest.manifestId,
          'files': [
            for (final f in manifest.files) {'idx': f.idx, 'file_hash': f.fileHash, 'duration_ms': f.durationMs},
          ],
        },
        'candidates': <Object>[],
      };
}

/// A Faden server in memory: health, book list, details, files. Counts the
/// file requests per hash; [gate] holds file answers back.
class _Server {
  final List<_Book> books;
  final Map<String, int> fileRequests = {};
  Completer<void>? gate;

  _Server(this.books);

  ApiClient client() {
    final dio = Dio(BaseOptions(baseUrl: 'http://nas.local:8787'));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) async {
      final path = options.path;
      if (path == '/api/v1/health') {
        handler.resolve(Response(requestOptions: options, statusCode: 200, data: {'status': 'ok'}));
      } else if (path == '/api/v1/books') {
        handler.resolve(Response(requestOptions: options, statusCode: 200, data: [
          for (final b in books)
            {'book_id': b.id, 'title': 'Buch ${b.id}', 'author': null, 'duration_ms': 600000, 'status': 'ok'},
        ]));
      } else if (path.startsWith('/api/v1/files/')) {
        final hash = path.split('/').last;
        fileRequests[hash] = (fileRequests[hash] ?? 0) + 1;
        await gate?.future;
        if (options.cancelToken?.isCancelled ?? false) {
          handler.reject(DioException.requestCancelled(requestOptions: options, reason: 'cancel'));
          return;
        }
        handler.resolve(Response(
          requestOptions: options..responseType = ResponseType.stream,
          statusCode: 200,
          data: ResponseBody.fromBytes(books.firstWhere((b) => b.hash == hash).bytes, 200),
        ));
      } else if (path.startsWith('/api/v1/books/')) {
        final id = path.split('/')[4];
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: books.firstWhere((b) => b.id == id).detail,
        ));
      } else {
        handler.reject(DioException.badResponse(
          statusCode: 404,
          requestOptions: options,
          response: Response(requestOptions: options, statusCode: 404),
        ));
      }
    }));
    return ApiClient(dio);
  }
}

// 2024-01-02 08:00 UTC: daytime, outside the default night window.
const _day = 1704182400000;
var _seq = 0;

Event _event(
  String bookId,
  EventType type, {
  required String fileHash,
  required int offsetMs,
  required int wallMs,
  String session = 's',
  EventSource source = EventSource.ui,
}) {
  _seq++;
  return Event(
    eventId: 'e$_seq-$bookId',
    deviceId: 'dev-a',
    sessionId: '$session-$bookId',
    bookId: bookId,
    manifestId: 'm-$bookId',
    type: type,
    fileHash: fileHash,
    offsetMs: offsetMs,
    hlc: Hlc(pt: wallMs, c: 0),
    wallMs: wallMs,
    tzMin: 0,
    source: source,
  );
}

/// Listened to the middle of [book], then paused.
List<Event> _listenedHalf(_Book book, int wallMs) => [
      _event(book.id, EventType.play, fileHash: book.hash, offsetMs: 0, wallMs: wallMs),
      _event(book.id, EventType.pause, fileHash: book.hash, offsetMs: 5 * 60000, wallMs: wallMs + 5 * 60000),
    ];

/// Heard to the end, awake: FINISHED is the session's last event.
List<Event> _finished(_Book book, int wallMs) => [
      _event(book.id, EventType.play, fileHash: book.hash, offsetMs: 0, wallMs: wallMs),
      _event(book.id, EventType.heartbeat, fileHash: book.hash, offsetMs: 5 * 60000, wallMs: wallMs + 5 * 60000),
      _event(book.id, EventType.finished,
          fileHash: book.hash, offsetMs: 10 * 60000, wallMs: wallMs + 10 * 60000, source: EventSource.system),
    ];

/// The end came, but events after it end on a SLEEP_HINT 5 min later
/// (spec/vectors/08): sleep suspected, so the Resolver says not finished.
List<Event> _endWhileAsleep(_Book book, int wallMs) => [
      _event(book.id, EventType.play, fileHash: book.hash, offsetMs: 0, wallMs: wallMs),
      _event(book.id, EventType.finished,
          fileHash: book.hash, offsetMs: 2 * 60000, wallMs: wallMs + 2 * 60000, source: EventSource.system),
      _event(book.id, EventType.heartbeat, fileHash: book.hash, offsetMs: 5 * 60000, wallMs: wallMs + 5 * 60000),
      _event(book.id, EventType.sleepHint,
          fileHash: book.hash, offsetMs: 8 * 60000, wallMs: wallMs + 8 * 60000, source: EventSource.timer),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );

  test('allowsAutoDownload: Wi-Fi or Ethernet, never with cellular', () {
    expect(allowsAutoDownload([ConnectivityResult.wifi]), isTrue);
    expect(allowsAutoDownload([ConnectivityResult.ethernet]), isTrue);
    expect(allowsAutoDownload([ConnectivityResult.wifi, ConnectivityResult.vpn]), isTrue);
    expect(allowsAutoDownload([ConnectivityResult.mobile]), isFalse);
    expect(allowsAutoDownload([ConnectivityResult.mobile, ConnectivityResult.vpn]), isFalse);
    expect(allowsAutoDownload([ConnectivityResult.wifi, ConnectivityResult.mobile]), isFalse);
    expect(allowsAutoDownload([ConnectivityResult.none]), isFalse);
    expect(allowsAutoDownload(const []), isFalse);
  });

  late Directory dir;
  late AppDatabase db;
  late Journal journal;
  late FakeAudioHandler handler;
  late PlayerSessionController session;
  late ProviderContainer container;
  late List<ConnectivityResult> network;
  late bool serverUp;
  var ready = false;

  Future<void> setUpWith(_Server server, List<Event> events, {String? openBookId}) async {
    dir = Directory.systemTemp.createTempSync('faden_offline_');
    db = AppDatabase.memory();
    journal = Journal(db);
    for (final e in events) {
      await journal.record(e, () async {});
    }
    handler = FakeAudioHandler(journal);
    session = PlayerSessionController(handler: handler, journal: journal)..bookId = openBookId;
    network = [ConnectivityResult.wifi];
    serverUp = true;
    final api = server.client();
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      journalProvider.overrideWithValue(journal),
      appSupportDirProvider.overrideWithValue(dir),
      apiClientProvider.overrideWithValue(api),
      audioHandlerProvider.overrideWithValue(handler),
      playerSessionProvider.overrideWith((ref) => session),
      connectivityCheckProvider.overrideWithValue(() async => network),
      serverReachableProvider.overrideWithValue(() async => serverUp),
    ]);
    ready = true;
  }

  tearDown(() async {
    if (!ready) return;
    ready = false;
    container.dispose();
    await handler.dispose();
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  BookDownloads downloads() => container.read(bookDownloadsProvider)!;

  /// Waits (real time, at most 5 s) until [condition] holds.
  Future<void> until(bool Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail('condition not reached in time');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  group('auto-download (E56)', () {
    // A is open; D was heard to the end after B; B is the next
    // "Weiterhören" book; C is older.
    final a = _Book('A', 3);
    final b = _Book('B', 5);
    final c = _Book('C', 7);
    final d = _Book('D', 11);
    late _Server server;

    Future<void> setUpLibrary() async {
      server = _Server([a, b, c, d]);
      await setUpWith(
        server,
        [
          ..._listenedHalf(c, _day),
          ..._listenedHalf(b, _day + 3600000),
          ..._finished(d, _day + 2 * 3600000),
          ..._listenedHalf(a, _day + 3 * 3600000),
        ],
        openBookId: 'A',
      );
    }

    test('on Wi-Fi: downloads the open book and the next "Weiterhören" book', () async {
      await setUpLibrary();

      await container.read(autoDownloaderProvider)!.trigger();

      expect(downloads().stateFor('A').isDownloaded, isTrue);
      expect(downloads().stateFor('B').isDownloaded, isTrue);
      expect(server.fileRequests.keys.toSet(), {a.hash, b.hash},
          reason: 'not C (not next), not D (finished)');
    });

    test('never on cellular', () async {
      await setUpLibrary();
      network = [ConnectivityResult.mobile];

      await container.read(autoDownloaderProvider)!.trigger();

      expect(server.fileRequests, isEmpty);
      expect(downloads().stateFor('A').isDownloaded, isFalse);
    });

    test('not when the setting is off', () async {
      await setUpLibrary();
      await SettingsStore(db).setAutoDownload(false);

      await container.read(autoDownloaderProvider)!.trigger();

      expect(server.fileRequests, isEmpty);
    });

    test('the setting defaults to on', () async {
      await setUpLibrary();
      expect(await SettingsStore(db).autoDownload(), isTrue);
      expect(await container.read(autoDownloadSettingProvider.future), isTrue);
    });

    test('not while the server is unreachable (no failure left in the library)', () async {
      await setUpLibrary();
      serverUp = false;

      await container.read(autoDownloaderProvider)!.trigger();

      expect(server.fileRequests, isEmpty);
      expect(downloads().stateFor('A').hasFailed, isFalse);
    });

    test('no duplicates: triggers during a running pass start nothing twice', () async {
      await setUpLibrary();
      server.gate = Completer<void>();
      final downloader = container.read(autoDownloaderProvider)!;

      final first = downloader.trigger();
      final second = downloader.trigger();
      await until(() => server.fileRequests.isNotEmpty);
      final third = downloader.trigger();
      // The listener taps "Herunterladen" meanwhile, too.
      final manual = container.read(libraryControllerProvider).downloadBook('A');
      server.gate!.complete();
      await Future.wait([first, second, third, manual]);

      expect(server.fileRequests, {a.hash: 1, b.hash: 1});
      expect(downloads().stateFor('A').isDownloaded, isTrue);
      expect(downloads().stateFor('B').isDownloaded, isTrue);
    });

    test('already downloaded books are not fetched again', () async {
      await setUpLibrary();
      final downloader = container.read(autoDownloaderProvider)!;
      await downloader.trigger();
      server.fileRequests.clear();

      await downloader.trigger();

      expect(server.fileRequests, isEmpty);
    });

    test('leaving the Wi-Fi stops auto-downloads', () async {
      await setUpLibrary();
      server.gate = Completer<void>();
      final downloader = container.read(autoDownloaderProvider)!;

      final pass = downloader.trigger();
      await until(() => server.fileRequests.isNotEmpty);
      expect(downloader.running, {'A'});
      network = [ConnectivityResult.mobile];
      downloader.onNetworkChanged(network);
      server.gate!.complete();
      await pass;

      expect(downloads().stateFor('A').isDownloaded, isFalse);
      expect(downloads().stateFor('A').hasFailed, isFalse, reason: 'a cancel, not a failure');
      expect(server.fileRequests.containsKey(b.hash), isFalse, reason: 'no next book on cellular');
    });

    test('without an open book, the first "Weiterhören" book is the one', () async {
      server = _Server([a, b]);
      await setUpWith(server, [
        ..._listenedHalf(b, _day),
        ..._listenedHalf(a, _day + 3600000),
      ]);

      await container.read(autoDownloaderProvider)!.trigger();

      expect(server.fileRequests.keys.toSet(), {a.hash});
    });
  });

  group('cleanup of finished books (E57)', () {
    final done = _Book('F', 3);
    final asleep = _Book('S', 5);
    final halfway = _Book('N', 7);
    late _Server server;

    /// Puts [book]'s file on the device as a verified download (E34
    /// marker) and caches its detail, as after an online download.
    Future<void> downloaded(_Book book) async {
      final audio = audioDirIn(dir)..createSync(recursive: true);
      File('${audio.path}/${book.hash}.mp3').writeAsBytesSync(book.bytes);
      File('${audio.path}/${book.hash}.ok').writeAsStringSync('${book.bytes.length}');
      await LibraryCache(Directory('${dir.path}/library')).saveBookDetail(book.id, book.detail);
    }

    bool onDisk(_Book book) => File('${audioDirIn(dir).path}/${book.hash}.mp3').existsSync();

    Future<void> setUpBooks() async {
      server = _Server([done, asleep, halfway]);
      await setUpWith(server, [
        ..._finished(done, _day),
        ..._endWhileAsleep(asleep, _day + 3600000),
        ..._listenedHalf(halfway, _day + 2 * 3600000),
      ]);
      for (final book in [done, asleep, halfway]) {
        await downloaded(book);
      }
    }

    test('on start: deletes only finished-without-sleep books, only their audio', () async {
      await setUpBooks();
      final eventsBefore = (await journal.eventsForBook('F')).length;

      final deleted = await container.read(finishedCleanupProvider)!.cleanAll();

      expect(deleted, {'F'});
      expect(onDisk(done), isFalse);
      expect(onDisk(asleep), isTrue, reason: 'end reached with sleep suspected: not finished');
      expect(onDisk(halfway), isTrue, reason: 'not finished');
      expect((await journal.eventsForBook('F')).length, eventsBefore, reason: 'events stay');
      expect(await LibraryCache(Directory('${dir.path}/library')).loadBookDetail('F'), isNotNull,
          reason: 'the library cache stays');
      expect(downloads().stateFor('F').status, BookDownloadStatus.none);
    });

    test('the end reached after over an hour without a touch keeps the files until confirmed (E92)', () async {
      final long = _Book('L', 11, durationMs: 90 * 60000);
      server = _Server([long]);
      await setUpWith(server, [
        _event('L', EventType.play, fileHash: long.hash, offsetMs: 0, wallMs: _day),
        for (var m = 5; m < 90; m += 5)
          _event('L', EventType.heartbeat, fileHash: long.hash, offsetMs: m * 60000, wallMs: _day + m * 60000),
        _event('L', EventType.finished,
            fileHash: long.hash, offsetMs: 90 * 60000, wallMs: _day + 90 * 60000, source: EventSource.system),
      ]);
      await downloaded(long);
      final cleanup = container.read(finishedCleanupProvider)!;
      expect(await cleanup.cleanAll(), isEmpty);
      expect(onDisk(long), isTrue, reason: 'slept through the end: not finished');

      // "Nein, weiterhören": the end confirmed in a session of its own.
      for (final e in [
        _event('L', EventType.resume,
            fileHash: long.hash, offsetMs: 90 * 60000, wallMs: _day + 10 * 3600000, session: 'c'),
        _event('L', EventType.finished,
            fileHash: long.hash, offsetMs: 90 * 60000, wallMs: _day + 10 * 3600000 + 1, session: 'c'),
      ]) {
        await journal.record(e, () async {});
      }
      expect(await cleanup.cleanAll(), {'L'});
      expect(onDisk(long), isFalse);
    });

    test('a book still loaded in the player keeps its files until it is not', () async {
      await setUpBooks();
      handler.fakeLoadedBookId = 'F';
      final cleanup = container.read(finishedCleanupProvider)!;

      expect(await cleanup.cleanBook('F'), isFalse);
      expect(onDisk(done), isTrue);

      handler.fakeLoadedBookId = 'N';
      expect(await cleanup.cleanBook('F'), isTrue);
      expect(onDisk(done), isFalse);
    });

    test('opening another book cleans up the finished one that was loaded', () async {
      await setUpBooks();
      handler.fakeLoadedBookId = 'F';
      final cleanup = container.read(finishedCleanupProvider)!;
      expect(await cleanup.cleanAll(), isEmpty);

      handler.fakeLoadedBookId = 'N';
      expect(await cleanup.cleanBook('F'), isTrue);
      expect(await cleanup.cleanBook('S'), isFalse);
      expect(await cleanup.cleanBook('N'), isFalse);
      expect(onDisk(asleep), isTrue);
      expect(onDisk(halfway), isTrue);
    });

    test('a finish another device synced in cleans up at once (not loaded here)', () async {
      await setUpBooks();
      container.read(offlineWiringProvider);

      handler.emitRemoteEvents({'F', 'N'});
      await until(() => !onDisk(done));

      expect(onDisk(done), isFalse);
      expect(onDisk(halfway), isTrue);
    });

    test('a finished book is never auto-downloaded again', () async {
      await setUpBooks();
      await container.read(finishedCleanupProvider)!.cleanAll();
      session.bookId = 'F';

      await container.read(autoDownloaderProvider)!.trigger();

      expect(server.fileRequests.containsKey(done.hash), isFalse);
      expect(onDisk(done), isFalse);
    });
  });
}
