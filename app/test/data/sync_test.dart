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

    test('rejected events are marked done too: they never block later events', () async {
      await journal.record(_event('e1'), () async {});
      await journal.record(_event('bad', pt: 2000), () async {});
      await journal.record(_event('e3', pt: 3000), () async {});

      final pushes = <List<String>>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.method == 'POST') {
              pushes.add([for (final e in options.data as List) (e as Map)['event_id'] as String]);
              handler.resolve(
                Response(
                  requestOptions: options,
                  statusCode: 200,
                  data: {
                    'accepted': 2,
                    'duplicates': 0,
                    'rejected': [
                      {'index': 1, 'event_id': 'bad', 'error': 'invalid offset_ms'},
                    ],
                    'max_seq': 2,
                  },
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
      expect(summary.pushed.accepted, 2);
      expect(summary.pushed.rejectedEventIds, ['bad']);
      expect(await journal.unsyncedEvents(), isEmpty);

      // The rejected event is not pushed again on the next run ...
      await journal.record(_event('e4', pt: 4000), () async {});
      await sync.sync();
      expect(pushes, [
        ['e1', 'bad', 'e3'],
        ['e4'],
      ]);
      // ... and stays in the append-only local journal (invariant 2).
      final ids = (await journal.eventsForBook('book-1')).map((e) => e.eventId);
      expect(ids, ['e1', 'bad', 'e3', 'e4']);
    });

    test('a rejected entry without event_id is identified by its batch index', () async {
      await journal.record(_event('e1'), () async {});
      await journal.record(_event('e2', pt: 2000), () async {});
      final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: options.method == 'POST'
                  ? {
                      'accepted': 0,
                      'duplicates': 0,
                      'rejected': [
                        {'index': 0, 'event_id': null, 'error': 'missing event_id'},
                        {'index': 1, 'event_id': null, 'error': 'bad type'},
                      ],
                      'max_seq': null,
                    }
                  : {'events': <dynamic>[], 'has_more': false},
            ),
          ),
        ),
      );
      final summary = await SyncClient(db: db, journal: journal, api: ApiClient(dio)).sync();
      expect(summary.pushed.rejectedEventIds, ['e1', 'e2']);
      expect(await journal.unsyncedEvents(), isEmpty);
    });

    test('a response without "rejected" (older server) is treated as none rejected', () async {
      await journal.record(_event('e1'), () async {});
      final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: options.method == 'POST'
                  ? {'accepted': 1, 'duplicates': 0, 'max_seq': 1}
                  : {'events': <dynamic>[], 'has_more': false},
            ),
          ),
        ),
      );
      final summary = await SyncClient(db: db, journal: journal, api: ApiClient(dio)).sync();
      expect(summary.pushed.rejectedEventIds, isEmpty);
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

    test('reports each pulled HLC via onRemoteHlc before the event is stored', () async {
      final dio = Dio(BaseOptions(baseUrl: 'https://faden.example'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'events': [_serverEvent('r1', 1, pt: 5000), _serverEvent('r2', 2, pt: 7000)],
                'has_more': false,
              },
            ),
          ),
        ),
      );
      final seen = <Hlc>[];
      final storedWhenSeen = <int>[];
      final sync = SyncClient(db: db, journal: journal, api: ApiClient(dio))
        ..onRemoteHlc = (hlc) {
          seen.add(hlc);
          // Synchronous callback: record how many rows existed at that point.
          journal.eventsForBook('book-1').then((e) => storedWhenSeen.add(e.length));
        };
      await sync.sync();
      expect(seen, const [Hlc(pt: 5000, c: 0), Hlc(pt: 7000, c: 0)]);
      expect(storedWhenSeen.first, 0); // r1 reported before it was stored
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
