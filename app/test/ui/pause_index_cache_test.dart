// Decision E55: the pause index (sentence starts for Faden-Suche) is cached
// per book and manifest whenever it is fetched, and used when the server
// cannot be reached -- the NAS is off at night -- but never for another
// manifest.

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:faden/data/api.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/library.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/ui/providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_audio_handler.dart';

/// Answers `/api/v1/books/<id>/pauses` with [pauses], or fails like an
/// unreachable server while [down] is true.
class _PausesServer {
  bool down = false;
  Map<String, dynamic> pauses = const {};
  int requests = 0;

  ApiClient client() {
    final dio = Dio(BaseOptions(baseUrl: 'http://nas.local:8787'));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requests++;
      if (down) {
        handler.reject(DioException.connectionError(requestOptions: options, reason: 'No route to host'));
        return;
      }
      handler.resolve(Response(requestOptions: options, statusCode: 200, data: pauses));
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

  const m1 = Manifest(manifestId: 'm1', files: [
    ManifestFile(idx: 0, fileHash: 'h1', durationMs: 60000),
    ManifestFile(idx: 1, fileHash: 'h2', durationMs: 60000),
  ]);
  const m2 = Manifest(manifestId: 'm2', files: [
    ManifestFile(idx: 0, fileHash: 'h1', durationMs: 60000),
    ManifestFile(idx: 1, fileHash: 'h2', durationMs: 60000),
    ManifestFile(idx: 2, fileHash: 'h3', durationMs: 60000),
  ]);

  late Directory dir;
  late AppDatabase db;
  late FakeAudioHandler handler;
  late PlayerSessionController session;
  late _PausesServer server;
  late LibraryRepository repository;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('faden_pauses_');
    db = AppDatabase.memory();
    final journal = Journal(db);
    handler = FakeAudioHandler(journal);
    session = PlayerSessionController(handler: handler, journal: journal);
    server = _PausesServer()
      ..pauses = {
        'h1': [0, 4200, 9100],
        'h2': [0, 3000],
      };
    final api = server.client();
    repository = LibraryRepository(api: api, cache: LibraryCache(Directory('${dir.path}/library')));
  });

  tearDown(() async {
    session.dispose();
    await handler.dispose();
    await db.close();
    dir.deleteSync(recursive: true);
  });

  Future<void> open(Manifest manifest) async {
    await session.openBook(
      bookId: 'book-1',
      bookTitle: 'Buch',
      manifest: manifest,
      downloads: null,
      serverBaseUrl: 'http://nas.local:8787',
      serverToken: 'token',
      api: repository.api,
      library: repository,
    );
    await session.pauseIndexRefresh;
  }

  test('online, the fetched index is used and cached', () async {
    await open(m1);
    expect(session.pauseIndex, {
      'h1': [0, 4200, 9100],
      'h2': [0, 3000],
    });
    expect(await repository.cachedPauseIndex('book-1', manifestId: 'm1'), session.pauseIndex);
  });

  test('when the API throws, the cached copy is served', () async {
    await open(m1);
    server.down = true;
    final before = server.requests;

    await open(m1);

    expect(server.requests, greaterThan(before), reason: 'the server was asked first');
    expect(session.pauseIndex, {
      'h1': [0, 4200, 9100],
      'h2': [0, 3000],
    });
  });

  test('the cached copy is there before the network answers', () async {
    await open(m1);
    server.down = true;

    final opening = session.openBook(
      bookId: 'book-1',
      bookTitle: 'Buch',
      manifest: m1,
      downloads: null,
      serverBaseUrl: 'http://nas.local:8787',
      serverToken: 'token',
      api: repository.api,
      library: repository,
    );
    await opening;
    // openBook has returned; the server fetch may still be running.
    expect(session.pauseIndex['h1'], [0, 4200, 9100]);
    await session.pauseIndexRefresh;
  });

  test('not across a manifest change: another manifest gets no cached offsets', () async {
    await open(m1);
    server.down = true;

    await open(m2);

    expect(session.pauseIndex, isEmpty);
    expect(await repository.cachedPauseIndex('book-1', manifestId: 'm2'), isNull);
  });

  test('a fresh fetch for the new manifest replaces the cached one', () async {
    await open(m1);
    server.pauses = {
      'h1': [0, 5000],
      'h3': [0, 7000],
    };
    await open(m2);
    server.down = true;

    await open(m2);

    expect(session.pauseIndex, {
      'h1': [0, 5000],
      'h3': [0, 7000],
    });
    expect(await repository.cachedPauseIndex('book-1', manifestId: 'm1'), isNull,
        reason: 'the cache now belongs to m2');
  });

  test('without any cache and offline, Faden-Suche runs without snapping', () async {
    server.down = true;
    await open(m1);
    expect(session.pauseIndex, isEmpty);
  });
}
