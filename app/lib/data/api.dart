import 'dart:io';

import 'package:dio/dio.dart';

import '../domain/event.dart';

/// One entry of `rejected` in the `POST /api/v1/events` response: the
/// server validates per event and stores the valid ones, reporting each
/// invalid one by its [index] in the pushed batch.
class RejectedEvent {
  final int index;
  final String? eventId;
  final String error;

  const RejectedEvent({required this.index, required this.eventId, required this.error});

  factory RejectedEvent.fromJson(Map<String, dynamic> json) => RejectedEvent(
        index: json['index'] as int,
        eventId: json['event_id'] as String?,
        error: json['error'] as String? ?? '',
      );
}

/// Response shape of `POST /api/v1/events` (docs/ARCHITEKTUR.md section 6).
class PushEventsResult {
  final int accepted;
  final int duplicates;

  /// Empty when the server sent no `rejected` field (older servers).
  final List<RejectedEvent> rejected;

  /// Null when the server stored nothing new (e.g. every event rejected).
  final int? maxSeq;

  const PushEventsResult({
    required this.accepted,
    required this.duplicates,
    this.rejected = const [],
    required this.maxSeq,
  });
}

/// Response shape of `GET /api/v1/events` (section 6). Each entry in
/// [events] is a raw event body plus the server-added `seq` and
/// `skew_flag` fields.
class PullEventsResult {
  final List<Map<String, dynamic>> events;
  final bool hasMore;

  const PullEventsResult({required this.events, required this.hasMore});
}

/// Thin client for the endpoints in docs/ARCHITEKTUR.md section 10. Holds
/// no local state beyond the `Dio` instance: retries, caching, the local
/// journal and the sync cursor are the caller's job (data/journal.dart,
/// data/sync.dart).
class ApiClient {
  final Dio _dio;

  ApiClient(Dio dio) : _dio = dio;

  /// Builds a client for [baseUrl], attaching `Authorization: Bearer
  /// [token]` to every request (section 10: every endpoint but `/health`
  /// requires it; sending it there too is harmless).
  factory ApiClient.create({required String baseUrl, required String token}) {
    return ApiClient(
      Dio(
        BaseOptions(
          baseUrl: baseUrl,
          headers: {'Authorization': 'Bearer $token'},
        ),
      ),
    );
  }

  Future<bool> health() async {
    final res = await _dio.get<Map<String, dynamic>>('/api/v1/health');
    return res.data?['status'] == 'ok';
  }

  Future<List<Map<String, dynamic>>> listBooks() async {
    final res = await _dio.get<List<dynamic>>('/api/v1/books');
    return (res.data ?? const []).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> bookDetail(String bookId) async {
    final res = await _dio.get<Map<String, dynamic>>('/api/v1/books/$bookId');
    return res.data!;
  }

  /// Cover image bytes, or null if the book has none (server returns 404).
  Future<List<int>?> cover(String bookId) async {
    try {
      final res = await _dio.get<List<int>>(
        '/api/v1/books/$bookId/cover',
        options: Options(responseType: ResponseType.bytes),
      );
      return res.data;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  /// Pause-index offsets per `file_hash` for the book's active manifest.
  Future<Map<String, dynamic>> pauses(String bookId) async {
    final res = await _dio.get<Map<String, dynamic>>('/api/v1/books/$bookId/pauses');
    return res.data ?? const {};
  }

  Future<void> confirmManifest(String bookId, String manifestId) async {
    await _dio.post<void>('/api/v1/books/$bookId/manifests/$manifestId/confirm');
  }

  /// Downloads the raw audio bytes for [fileHash] to [destination].
  /// data/downloads.dart verifies the file's audio-hash afterwards
  /// (section 11: a download only counts as done once that matches).
  Future<void> downloadFile(
    String fileHash,
    File destination, {
    void Function(int received, int total)? onProgress,
  }) {
    return _dio.download(
      '/api/v1/files/$fileHash',
      destination.path,
      onReceiveProgress: onProgress,
    );
  }

  /// Pushes up to 500 events (section 6). Callers chunk larger batches.
  Future<PushEventsResult> pushEvents(List<Event> events) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/api/v1/events',
      data: events.map((e) => e.toJson()).toList(),
    );
    final data = res.data!;
    return PushEventsResult(
      accepted: data['accepted'] as int,
      duplicates: data['duplicates'] as int,
      rejected: [
        for (final r in (data['rejected'] as List?) ?? const [])
          RejectedEvent.fromJson(r as Map<String, dynamic>),
      ],
      maxSeq: data['max_seq'] as int?,
    );
  }

  Future<PullEventsResult> pullEvents({required int since, int limit = 500}) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/api/v1/events',
      queryParameters: {'since': since, 'limit': limit},
    );
    final data = res.data!;
    return PullEventsResult(
      events: (data['events'] as List).cast<Map<String, dynamic>>(),
      hasMore: data['has_more'] as bool,
    );
  }

  Future<void> rescan() async {
    await _dio.post<void>('/api/v1/rescan');
  }
}
