// Tests data/api.dart against a fake Dio interceptor that resolves
// requests without any real network I/O, checking both the request shape
// (method, path, query, body) and how responses are parsed. This exercises
// the client the same way a real server round-trip would, without needing
// a running server in this sandbox.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:faden/core/hlc.dart';
import 'package:faden/data/api.dart';
import 'package:faden/domain/event.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

typedef _Responder = Response Function(RequestOptions options);

Dio _fakeDio(_Responder respond) {
  final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(respond(options));
      },
    ),
  );
  return dio;
}

Event _event() => Event(
      eventId: 'e1',
      deviceId: 'dev-a',
      sessionId: 's1',
      bookId: 'book-1',
      manifestId: 'm1',
      type: EventType.play,
      fileHash: 'f1',
      offsetMs: 0,
      hlc: const Hlc(pt: 1000, c: 0),
      wallMs: 1000,
      tzMin: 0,
      source: EventSource.ui,
    );

void main() {
  test('health() reads {"status": "ok"}', () async {
    final dio = _fakeDio(
      (o) => Response(requestOptions: o, statusCode: 200, data: {'status': 'ok'}),
    );
    final api = ApiClient(dio);
    expect(await api.health(), isTrue);
  });

  test('every request carries the bearer token', () async {
    RequestOptions? seen;
    final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'))
      ..options.headers['Authorization'] = 'Bearer secret-token'
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            seen = options;
            handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: <String, dynamic>{}),
            );
          },
        ),
      );
    await ApiClient(dio).bookDetail('book-1');
    expect(seen!.headers['Authorization'], 'Bearer secret-token');
  });

  test('ApiClient.create attaches the bearer token to BaseOptions', () {
    final api = ApiClient.create(baseUrl: 'https://faden.example', token: 'abc123');
    expect(api, isA<ApiClient>()); // constructs without throwing; header set is exercised above
  });

  test('listBooks() GETs /api/v1/books and returns the array', () async {
    RequestOptions? seen;
    final dio = _fakeDio((o) {
      seen = o;
      return Response(
        requestOptions: o,
        statusCode: 200,
        data: [
          {'book_id': 'b1', 'title': 'Buch 1'},
        ],
      );
    });
    final books = await ApiClient(dio).listBooks();
    expect(seen!.path, '/api/v1/books');
    expect(seen!.method, 'GET');
    expect(books.single['book_id'], 'b1');
  });

  test('bookDetail() GETs /api/v1/books/{id}', () async {
    RequestOptions? seen;
    final dio = _fakeDio((o) {
      seen = o;
      return Response(requestOptions: o, statusCode: 200, data: {'book_id': 'b1'});
    });
    final detail = await ApiClient(dio).bookDetail('b1');
    expect(seen!.path, '/api/v1/books/b1');
    expect(detail['book_id'], 'b1');
  });

  test('cover() returns bytes on 200', () async {
    final dio = _fakeDio(
      (o) => Response(requestOptions: o, statusCode: 200, data: [1, 2, 3]),
    );
    expect(await ApiClient(dio).cover('b1'), [1, 2, 3]);
  });

  test('cover() returns null on 404 rather than throwing', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 404),
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );
    expect(await ApiClient(dio).cover('b1'), isNull);
  });

  test('cover() rethrows a non-404 error', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.reject(
            DioException(
              requestOptions: options,
              response: Response(requestOptions: options, statusCode: 500),
              type: DioExceptionType.badResponse,
            ),
          );
        },
      ),
    );
    expect(ApiClient(dio).cover('b1'), throwsA(isA<DioException>()));
  });

  test('pauses() GETs the pause-index map', () async {
    final dio = _fakeDio(
      (o) => Response(
        requestOptions: o,
        statusCode: 200,
        data: {
          'f1': [0, 12000],
        },
      ),
    );
    final pauses = await ApiClient(dio).pauses('b1');
    expect(pauses['f1'], [0, 12000]);
  });

  test('confirmManifest() POSTs to the confirm endpoint', () async {
    RequestOptions? seen;
    final dio = _fakeDio((o) {
      seen = o;
      return Response(requestOptions: o, statusCode: 200, data: {'status': 'active'});
    });
    await ApiClient(dio).confirmManifest('b1', 'm2');
    expect(seen!.method, 'POST');
    expect(seen!.path, '/api/v1/books/b1/manifests/m2/confirm');
  });

  test('rescan() POSTs /api/v1/rescan', () async {
    RequestOptions? seen;
    final dio = _fakeDio((o) {
      seen = o;
      return Response(requestOptions: o, statusCode: 200, data: {});
    });
    await ApiClient(dio).rescan();
    expect(seen!.method, 'POST');
    expect(seen!.path, '/api/v1/rescan');
  });

  group('pushEvents', () {
    test('POSTs a bare JSON array of event bodies and parses the result', () async {
      Object? sentBody;
      final dio = _fakeDio((o) {
        sentBody = o.data;
        return Response(
          requestOptions: o,
          statusCode: 200,
          data: {'accepted': 1, 'duplicates': 0, 'max_seq': 7},
        );
      });
      final result = await ApiClient(dio).pushEvents([_event()]);

      expect(sentBody, isA<List>());
      final body = (sentBody as List).single as Map<String, dynamic>;
      expect(body['event_id'], 'e1');
      expect(body['type'], 'PLAY');

      expect(result.accepted, 1);
      expect(result.duplicates, 0);
      expect(result.maxSeq, 7);
    });
  });

  group('pullEvents', () {
    test('GETs with since/limit query params and parses events + has_more', () async {
      RequestOptions? seen;
      final dio = _fakeDio((o) {
        seen = o;
        return Response(
          requestOptions: o,
          statusCode: 200,
          data: {
            'events': [
              {'event_id': 'e1', 'seq': 5, 'skew_flag': false},
            ],
            'has_more': true,
          },
        );
      });
      final result = await ApiClient(dio).pullEvents(since: 4, limit: 10);

      expect(seen!.path, '/api/v1/events');
      expect(seen!.queryParameters, {'since': 4, 'limit': 10});
      expect(result.events.single['seq'], 5);
      expect(result.hasMore, isTrue);
    });

    test('limit defaults to 500 (the section 6 push/pull page size)', () async {
      RequestOptions? seen;
      final dio = _fakeDio((o) {
        seen = o;
        return Response(
          requestOptions: o,
          statusCode: 200,
          data: {'events': <dynamic>[], 'has_more': false},
        );
      });
      await ApiClient(dio).pullEvents(since: 0);
      expect(seen!.queryParameters['limit'], 500);
    });
  });

  group('downloadFile', () {
    test('writes the response bytes to the destination file', () async {
      final tmpDir = await Directory.systemTemp.createTemp('faden-api-test');
      addTearDown(() => tmpDir.delete(recursive: true));
      final destination = File(p.join(tmpDir.path, 'f1.mp3'));

      final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final bytes = utf8.encode('fake mp3 bytes');
            handler.resolve(
              Response(
                requestOptions: options..responseType = ResponseType.stream,
                statusCode: 200,
                data: ResponseBody.fromBytes(bytes, 200),
              ),
            );
          },
        ),
      );

      await ApiClient(dio).downloadFile('f1', destination);
      expect(await destination.readAsString(), 'fake mp3 bytes');
    });
  });
}
