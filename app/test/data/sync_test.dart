import 'package:dio/dio.dart';
import 'package:faden/core/hlc.dart';
import 'package:faden/data/api.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/sync.dart';
import 'package:faden/domain/event.dart';
import 'package:flutter_test/flutter_test.dart';

Event _event(String id, {int pt = 1000, String bookId = 'book-1'}) => Event(
      eventId: id,
      deviceId: 'dev-a',
      sessionId: 's1',
      bookId: bookId,
      manifestId: 'm1',
      type: EventType.heartbeat,
      fileHash: 'f1',
      offsetMs: 0,
      hlc: Hlc(pt: pt, c: 0),
      wallMs: pt,
      tzMin: 0,
      source: EventSource.ui,
    );

Map<String, dynamic> _serverEvent(String id, int seq, {int pt = 1000}) => {
      ..._event(id, pt: pt).toJson(),
      'seq': seq,
      'skew_flag': false,
    };

void main() {
  late AppDatabase db;
  late Journal journal;

  setUp(() {
    db = AppDatabase.memory();
    journal = Journal(db);
  });
  tearDown(() => db.close());

  group('push', () {
    test('pushes unsynced events and marks the whole batch synced', () async {
      await journal.record(_event('e1'), () async {});
      await journal.record(_event('e2', pt: 2000), () async {});

      var pushedCount = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.method == 'POST') {
              pushedCount = (options.data as List).length;
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'accepted': 2, 'duplicates': 0, 'max_seq': 2},
                ),
              );
            } else {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'events': <dynamic>[], 'has_more': false},
                ),
              );
            }
          },
        ),
      );

      final sync = SyncClient(db: db, journal: journal, api: ApiClient(dio));
      final summary = await sync.sync();

      expect(pushedCount, 2);
      expect(summary.pushed.accepted, 2);
      expect(summary.pushed.duplicates, 0);
      expect(await journal.unsyncedEvents(), isEmpty);
    });

    test('duplicates still count as synced (server already has them)', () async {
      await journal.record(_event('e1'), () async {});

      final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.method == 'POST') {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'accepted': 0, 'duplicates': 1, 'max_seq': 5},
                ),
              );
            } else {
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'events': <dynamic>[], 'has_more': false},
                ),
              );
            }
          },
        ),
      );

      final sync = SyncClient(db: db, journal: journal, api: ApiClient(dio));
      final summary = await sync.sync();

      expect(summary.pushed.duplicates, 1);
      expect(await journal.unsyncedEvents(), isEmpty);
    });

    test('nothing unsynced: push makes no request', () async {
      var requests = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requests++;
            // Any request here must be the pull, not a push (empty body).
            if (options.path == '/api/v1/events' && options.method == 'POST') {
              fail('push should not run with nothing unsynced');
            }
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {'events': <dynamic>[], 'has_more': false},
              ),
            );
          },
        ),
      );
      final sync = SyncClient(db: db, journal: journal, api: ApiClient(dio));
      await sync.sync();
      expect(requests, 1); // just the pull
    });
  });

  group('pull', () {
    test('pages until has_more is false, storing every event locally', () async {
      var call = 0;
      final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            call++;
            if (call == 1) {
              expect(options.queryParameters['since'], 0);
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'events': [_serverEvent('r1', 1), _serverEvent('r2', 2)],
                    'has_more': true,
                  },
                ),
              );
            } else {
              expect(options.queryParameters['since'], 2);
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'events': [_serverEvent('r3', 3)],
                    'has_more': false,
                  },
                ),
              );
            }
          },
        ),
      );

      final sync = SyncClient(db: db, journal: journal, api: ApiClient(dio));
      final summary = await sync.sync();

      expect(call, 2);
      expect(summary.pulled, 3);
      final events = await journal.eventsForBook('book-1');
      expect(events.map((e) => e.eventId).toSet(), {'r1', 'r2', 'r3'});
    });

    test('cursor is persisted and reused by the next sync() call', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'events': [_serverEvent('r1', 9)],
                'has_more': false,
              },
            ),
          ),
        ),
      );
      await SyncClient(db: db, journal: journal, api: ApiClient(dio)).sync();

      // A brand new SyncClient sharing the same db must pick up since=9.
      int? seenSince;
      final dio2 = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio2.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            seenSince = options.queryParameters['since'] as int?;
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {'events': <dynamic>[], 'has_more': false},
              ),
            );
          },
        ),
      );
      await SyncClient(db: db, journal: journal, api: ApiClient(dio2)).sync();

      expect(seenSince, 9);
    });
  });
}
