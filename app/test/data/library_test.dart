import 'dart:io';

import 'package:dio/dio.dart';
import 'package:faden/data/api.dart';
import 'package:faden/data/library.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _detail(String id) => {
      'book_id': id,
      'title': 'Buch $id',
      'author': 'Autorin',
      'status': 'ok',
      'active_manifest': {
        'manifest_id': 'm-$id',
        'status': 'active',
        'files': [
          {'idx': 0, 'file_hash': 'h0', 'duration_ms': 1000, 'title': 'Prolog'},
          {'idx': 1, 'file_hash': 'h1', 'duration_ms': 2000, 'title': null},
        ],
      },
      'candidates': <dynamic>[],
    };

/// Answers like the server while [online], otherwise fails the way an
/// unreachable NAS does.
class _Server {
  bool online = true;
  int requests = 0;

  /// Answer genre calls like a server that refuses them (or is too old).
  bool refuse = false;
  final List<RequestOptions> puts = [];

  ApiClient get api {
    final dio = Dio(BaseOptions(baseUrl: 'http://nas.local:8787'));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      requests++;
      if (!online) {
        h.reject(DioException.connectionTimeout(timeout: ApiClient.connectTimeout, requestOptions: o));
        return;
      }
      if (o.path == '/api/v1/books') {
        h.resolve(Response(requestOptions: o, statusCode: 200, data: [
          {'book_id': 'b1', 'title': 'Buch b1', 'author': null, 'duration_ms': 3000, 'status': 'ok'},
          {'book_id': 'b2', 'title': 'Buch b2', 'author': null, 'duration_ms': 3000, 'status': 'ok', 'genre': 'Romane'},
        ]));
      } else if (o.method == 'PUT' && o.path.endsWith('/genre')) {
        puts.add(o);
        if (refuse) {
          h.reject(DioException.badResponse(
            statusCode: 422,
            requestOptions: o,
            response: Response(requestOptions: o, statusCode: 422),
          ));
          return;
        }
        h.resolve(Response(requestOptions: o, statusCode: 200, data: {'genre': (o.data as Map)['genre']}));
      } else if (o.path == '/api/v1/genres') {
        if (refuse) {
          h.reject(DioException.badResponse(
            statusCode: 404,
            requestOptions: o,
            response: Response(requestOptions: o, statusCode: 404),
          ));
          return;
        }
        h.resolve(Response(requestOptions: o, statusCode: 200, data: ['Humor', 'Romane']));
      } else {
        h.resolve(Response(requestOptions: o, statusCode: 200, data: _detail(o.path.split('/').last)));
      }
    }));
    return ApiClient(dio);
  }
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('faden-library-cache'));
  tearDown(() => dir.delete(recursive: true));

  test('every fetch fills the cache; with the server down, the cache answers (E30)', () async {
    final server = _Server();
    final repo = LibraryRepository(api: server.api, cache: LibraryCache(dir));
    await repo.fetchBooks();
    await repo.fetchDetail('b1');

    server.online = false;
    expect(() => repo.fetchBooks(), throwsA(isA<DioException>()));
    final books = await repo.cachedBooks();
    expect(books!.first.title, 'Buch b1');

    final detail = await repo.detailNetworkFirst('b1');
    expect(detail!.activeManifest!.manifestId, 'm-b1');
    expect(detail.activeManifest!.files.first.title, 'Prolog');
    expect((await repo.detailCacheFirst('b1'))!.title, 'Buch b1');
  });

  test('cache first does not touch the server when a copy exists', () async {
    final server = _Server();
    final repo = LibraryRepository(api: server.api, cache: LibraryCache(dir));
    await repo.fetchDetail('b1');
    final before = server.requests;
    expect((await repo.detailCacheFirst('b1'))!.bookId, 'b1');
    expect(server.requests, before);
  });

  test('works without any server configured, from the cache alone', () async {
    await LibraryCache(dir).saveBookDetail('b1', _detail('b1'));
    final repo = LibraryRepository(api: null, cache: LibraryCache(dir));
    expect((await repo.detailCacheFirst('b1'))!.activeManifest!.files, hasLength(2));
    expect(await repo.detailCacheFirst('unknown'), isNull);
    expect(() => repo.fetchBooks(), throwsStateError);
  });

  test('a damaged cache file is a miss, and unsafe ids are never files', () async {
    final cache = LibraryCache(dir);
    await dir.create(recursive: true);
    await File('${dir.path}/book-b1.json').writeAsString('{not json');
    expect(await cache.loadBookDetail('b1'), isNull);
    await cache.saveBookDetail('../evil', _detail('x'));
    expect(await cache.loadBookDetail('../evil'), isNull);
    expect(await File('${dir.parent.path}/evil.json').exists(), isFalse);
  });

  group('genre (E70)', () {
    test('parsed when present, null when the server sends none (older servers)', () {
      final withGenre = BookSummary.fromJson(
          {'book_id': 'b', 'title': 'T', 'author': null, 'duration_ms': 1, 'status': 'ok', 'genre': 'Humor'});
      final without = BookSummary.fromJson({'book_id': 'b', 'title': 'T', 'author': null, 'duration_ms': 1, 'status': 'ok'});
      final nulled = BookSummary.fromJson(
          {'book_id': 'b', 'title': 'T', 'author': null, 'duration_ms': 1, 'status': 'ok', 'genre': null});
      expect(withGenre.genre, 'Humor');
      expect(without.genre, isNull);
      expect(nulled.genre, isNull);
      expect(BookDetail.fromJson({..._detail('b1'), 'genre': 'Sachbuch'}).genre, 'Sachbuch');
      expect(BookDetail.fromJson(_detail('b1')).genre, isNull);
    });

    test('setGenre PUTs, then writes the answer into the cached list and detail', () async {
      final server = _Server();
      final repo = LibraryRepository(api: server.api, cache: LibraryCache(dir));
      await repo.fetchBooks();
      await repo.fetchDetail('b1');

      expect(await repo.setGenre('b1', 'Humor'), 'Humor');
      expect(server.puts.single.path, '/api/v1/books/b1/genre');
      expect(server.puts.single.data, {'genre': 'Humor'});
      final cached = await repo.cachedBooks();
      expect({for (final b in cached!) b.bookId: b.genre}, {'b1': 'Humor', 'b2': 'Romane'});
      expect((await repo.cachedDetail('b1'))!.genre, 'Humor');

      // Back to automatic: null until the server's lookup found one.
      expect(await repo.setGenre('b2', null), isNull);
      expect(server.puts.last.data, {'genre': null});
      expect((await repo.cachedBooks())!.firstWhere((b) => b.bookId == 'b2').genre, isNull);
    });

    test('a refused change leaves the cache alone and throws', () async {
      final server = _Server();
      final repo = LibraryRepository(api: server.api, cache: LibraryCache(dir));
      await repo.fetchBooks();
      server.refuse = true;
      await expectLater(repo.setGenre('b2', 'Humor'), throwsA(isA<DioException>()));
      expect((await repo.cachedBooks())!.firstWhere((b) => b.bookId == 'b2').genre, 'Romane');
    });

    test('without a server there is nothing to change', () async {
      final repo = LibraryRepository(api: null, cache: LibraryCache(dir));
      expect(() => repo.setGenre('b1', 'Humor'), throwsStateError);
    });

    test('labels come from the server, else the known list', () async {
      final server = _Server();
      final repo = LibraryRepository(api: server.api, cache: null);
      expect(await repo.genreLabels(), ['Humor', 'Romane']);
      server.refuse = true;
      expect(await repo.genreLabels(), knownGenres);
      expect(await LibraryRepository(api: null, cache: null).genreLabels(), knownGenres);
    });
  });
}
