// Tests the provider-level core: heartbeat skip in PlayerSessionController
// (E40), cache-first library and book opening (E30), per-book progress
// (E33), live server settings (E37) and speed per book (E38).

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:faden/audio/handler.dart';
import 'package:faden/core/hlc.dart';
import 'package:faden/data/api.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/library.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/domain/event.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/domain/position.dart';
import 'package:faden/ui/providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _CountingJournal extends Journal {
  _CountingJournal(super.db);

  int reads = 0;

  @override
  Future<List<Event>> eventsForBook(String bookId) {
    reads++;
    return super.eventsForBook(bookId);
  }
}

/// A handler whose eventsWritten the test drives directly.
class _ScriptedHandler extends FadenAudioHandler {
  _ScriptedHandler(Journal journal) : super(journal: journal, deviceId: 'dev-a');

  final written = StreamController<Event>.broadcast();

  @override
  Stream<Event> get eventsWritten => written.stream;
}

Event _event(String id, EventType type, {int pt = 1000, String book = 'book-1', int offset = 0}) => Event(
      eventId: id,
      deviceId: 'dev-a',
      sessionId: 's1',
      bookId: book,
      manifestId: 'm1',
      type: type,
      fileHash: 'h0',
      offsetMs: offset,
      hlc: Hlc(pt: pt, c: 0),
      wallMs: pt,
      tzMin: 0,
      source: EventSource.ui,
    );

Map<String, dynamic> _detail(String id) => {
      'book_id': id,
      'title': 'Buch $id',
      'author': 'Autorin',
      'status': 'ok',
      'active_manifest': {
        'manifest_id': 'm1',
        'status': 'active',
        'files': [
          {'idx': 0, 'file_hash': 'h0', 'duration_ms': 60000, 'title': 'Eins'},
          {'idx': 1, 'file_hash': 'h1', 'duration_ms': 60000, 'title': null},
        ],
      },
      'candidates': <dynamic>[],
    };

/// A fake server; [online] false makes every request fail like an
/// unreachable NAS. [detailGate] holds detail answers back.
class _Server {
  bool online = true;
  Completer<void>? detailGate;

  ApiClient get api {
    final dio = Dio(BaseOptions(baseUrl: 'http://nas.local:8787'));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) async {
      if (!online) {
        h.reject(DioException.connectionError(requestOptions: o, reason: 'unreachable'));
        return;
      }
      if (o.path == '/api/v1/books') {
        h.resolve(Response(requestOptions: o, statusCode: 200, data: [
          {'book_id': 'book-1', 'title': 'Buch book-1', 'author': null, 'duration_ms': 120000, 'status': 'ok'},
          {'book_id': 'book-2', 'title': 'Buch book-2', 'author': null, 'duration_ms': 120000, 'status': 'ok'},
        ]));
        return;
      }
      if (o.path.startsWith('/api/v1/books/') && o.path.split('/').length == 5) {
        await detailGate?.future;
        h.resolve(Response(requestOptions: o, statusCode: 200, data: _detail(o.path.split('/').last)));
        return;
      }
      h.reject(DioException.badResponse(
        statusCode: 404,
        requestOptions: o,
        response: Response(requestOptions: o, statusCode: 404),
      ));
    }));
    return ApiClient(dio);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );

  late AppDatabase db;
  late Directory dir;

  setUp(() async {
    db = AppDatabase.memory();
    dir = await Directory.systemTemp.createTemp('faden-core-providers');
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  group('PlayerSessionController (E40)', () {
    test('a HEARTBEAT write does not replay the journal; other events do', () async {
      final journal = _CountingJournal(db);
      final handler = _ScriptedHandler(journal);
      final session = PlayerSessionController(handler: handler, journal: journal);
      session
        ..bookId = 'book-1'
        ..manifest = const Manifest(manifestId: 'm1', files: [ManifestFile(idx: 0, fileHash: 'h0', durationMs: 60000)]);
      await journal.record(_event('p', EventType.play), () async {});

      handler.written.add(_event('hb', EventType.heartbeat, pt: 2000));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(journal.reads, 0);

      handler.written.add(_event('pause', EventType.pause, pt: 3000));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(journal.reads, 1);
      expect(session.bookState, isNotNull);

      // Another book's event is not this session's business either.
      handler.written.add(_event('x', EventType.seek, book: 'book-2'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(journal.reads, 1);

      session.dispose();
      await handler.written.close();
      await handler.dispose();
    });

    test('setSpeed applies and stores the speed for the open book (E38)', () async {
      final journal = Journal(db);
      final handler = FadenAudioHandler(journal: journal, deviceId: 'dev-a');
      final settings = SettingsStore(db);
      final session = PlayerSessionController(handler: handler, journal: journal, settings: settings);
      session.bookId = 'book-1';
      await session.setSpeed(1.25);
      expect(handler.speed, 1.25);
      expect(await settings.bookSpeed('book-1'), 1.25);
      expect(await settings.bookSpeed('book-2'), 1.0);
      session.dispose();
      await handler.dispose();
    });
  });

  group('cache first (E30)', () {
    late FadenAudioHandler handler;
    late _Server server;
    late ProviderContainer container;

    setUp(() {
      server = _Server();
      handler = FadenAudioHandler(journal: Journal(db), deviceId: 'dev-a');
    });
    tearDown(() async {
      container.dispose();
      await handler.dispose();
    });

    ProviderContainer make({required ApiClient? api}) => ProviderContainer(overrides: [
          appDatabaseProvider.overrideWithValue(db),
          audioHandlerProvider.overrideWithValue(handler),
          appSupportDirProvider.overrideWithValue(dir),
          apiClientProvider.overrideWithValue(api),
          // No real audio in tests: the player preparation is skipped.
          downloadManagerProvider.overrideWithValue(null),
        ]);

    test('the last book opens from the cache when the server is unreachable', () async {
      container = make(api: server.api);
      await container.read(libraryRepositoryProvider).fetchDetail('book-1'); // was online once
      server.online = false;

      final result = await container.read(bookOpenerProvider).open('book-1');

      expect(result, OpenBookResult.opened);
      final session = container.read(playerSessionProvider);
      expect(session.bookId, 'book-1');
      expect(session.bookTitle, 'Buch book-1');
      expect(session.manifest!.files.first.title, 'Eins');
      expect(await container.read(settingsStoreProvider).lastOpenedBookId(), 'book-1');
      expect(await container.read(bookOpenerProvider).open('never-seen'), OpenBookResult.unavailable);
    });

    test('onStarted runs once the new book is in the session, before it is resolved (E65)', () async {
      container = make(api: server.api);
      final opener = container.read(bookOpenerProvider);
      expect(await opener.open('book-1'), OpenBookResult.opened);
      final session = container.read(playerSessionProvider);
      expect(session.bookState, isNotNull);

      String? startedWith;
      Object? stateAtStart = 'unset';
      var calls = 0;
      final result = await opener.open('book-2', onStarted: () {
        calls++;
        startedWith = session.bookId;
        stateAtStart = session.bookState;
      });
      expect(result, OpenBookResult.opened);
      expect(calls, 1);
      expect(startedWith, 'book-2');
      expect(stateAtStart, isNull, reason: 'never the previous book\'s state under the new title');
      expect(session.bookState, isNotNull);

      calls = 0;
      server.online = false;
      expect(await opener.open('never-seen', onStarted: () => calls++), OpenBookResult.unavailable);
      expect(calls, 0);
    });

    test('the library lists at once, before any book detail has arrived', () async {
      container = make(api: server.api);
      final library = container.read(libraryControllerProvider);
      server.detailGate = Completer<void>();
      var notifiedWithBooks = false;
      library.addListener(() {
        if (library.books.isNotEmpty && !library.loading) notifiedWithBooks = true;
      });

      await library.refresh();
      expect(notifiedWithBooks, isTrue);
      expect(library.books.map((b) => b.bookId), ['book-1', 'book-2']);
      expect(library.manifests, isEmpty); // details still on their way

      server.detailGate!.complete();
      await library.whenIdle();
      expect(library.manifests.keys.toSet(), {'book-1', 'book-2'});
    });

    test('offline, the library shows the cached list and marks itself offline', () async {
      container = make(api: server.api);
      await container.read(libraryControllerProvider).refresh();
      await container.read(libraryControllerProvider).whenIdle();
      container.dispose();

      server.online = false;
      container = make(api: server.api);
      final library = container.read(libraryControllerProvider);
      await library.refresh();
      await library.whenIdle();
      expect(library.offline, isTrue);
      expect(library.books, hasLength(2));
      expect(library.manifests.keys.toSet(), {'book-1', 'book-2'});
    });

    test('per-book progress: fraction and last played from one journal query (E33)', () async {
      final journal = Journal(db);
      await journal.record(_event('p', EventType.play, pt: 5000, offset: 0), () async {});
      await journal.record(
        Event(
          eventId: 'q',
          deviceId: 'dev-a',
          sessionId: 's1',
          bookId: 'book-1',
          manifestId: 'm1',
          type: EventType.pause,
          fileHash: 'h1',
          offsetMs: 30000,
          hlc: const Hlc(pt: 9000, c: 0),
          wallMs: 9000,
          tzMin: 0,
          source: EventSource.ui,
        ),
        () async {},
      );
      container = make(api: server.api);
      final library = container.read(libraryControllerProvider);
      await library.refresh();
      await library.whenIdle();

      final progress = library.progressByBook['book-1']!;
      expect(progress.position, const Position(fileHash: 'h1', offsetMs: 30000));
      expect(progress.fraction, closeTo(0.75, 1e-9));
      expect(progress.lastPlayed, DateTime.fromMillisecondsSinceEpoch(9000));
      expect(library.recentlyPlayed.map((b) => b.bookId), ['book-1']);
    });
  });

  group('live server settings (E37)', () {
    test('saving normalizes the address and rebuilds client, sync and handler wiring', () async {
      final handler = FadenAudioHandler(journal: Journal(db), deviceId: 'dev-a');
      final container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(db),
        audioHandlerProvider.overrideWithValue(handler),
      ]);
      addTearDown(() async {
        container.dispose();
        await handler.dispose();
      });
      container.listen(syncWiringProvider, (_, _) {}, fireImmediately: true);
      expect(container.read(apiClientProvider), isNull);
      expect(handler.syncClient, isNull);

      await container.read(serverConfigProvider.notifier).save(url: ' nas.local:8787/ ', token: ' secret ');

      expect(container.read(apiClientProvider)!.baseUrl, 'http://nas.local:8787');
      expect(await SettingsStore(db).serverUrl(), 'http://nas.local:8787');
      expect(await SettingsStore(db).serverToken(), 'secret');
      container.read(syncWiringProvider);
      expect(handler.syncClient, same(container.read(syncClientProvider)));
      expect(handler.syncClient, isNotNull);
    });
  });

  test('LibraryRepository re-export keeps BookSummary reachable from providers.dart', () {
    expect(BookSummary.fromJson({'book_id': 'b', 'title': 't', 'status': 'ok'}).bookId, 'b');
    expect(BookDetail.fromJson(_detail('b')).activeManifest!.files, hasLength(2));
    expect(LibraryCache(dir).dir, dir);
  });
}
