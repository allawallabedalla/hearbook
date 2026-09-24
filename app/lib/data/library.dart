import 'dart:convert';
import 'dart:io';

import '../domain/manifest.dart';
import 'api.dart';

/// One row of `GET /api/v1/books` (server/src/faden_server/api.py
/// `list_books`).
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

/// `GET /api/v1/books/{id}`: the book with its active manifest (null while
/// it has none) and any candidates awaiting review.
class BookDetail {
  final String bookId;
  final String title;
  final String? author;
  final String status;
  final Manifest? activeManifest;
  final List<ManifestCandidate> candidates;

  const BookDetail({
    required this.bookId,
    required this.title,
    required this.author,
    required this.status,
    required this.activeManifest,
    required this.candidates,
  });

  factory BookDetail.fromJson(Map<String, dynamic> json) {
    final active = json['active_manifest'] as Map<String, dynamic>?;
    return BookDetail(
      bookId: json['book_id'] as String,
      title: json['title'] as String? ?? '',
      author: json['author'] as String?,
      status: json['status'] as String? ?? 'ok',
      activeManifest: active == null ? null : Manifest.fromJson(active),
      candidates: [
        for (final c in (json['candidates'] as List?) ?? const [])
          ManifestCandidate.fromJson(c as Map<String, dynamic>),
      ],
    );
  }
}

/// Decision E30: the last server answers for the book list and each book's
/// detail/manifest, as JSON files under the app-support directory, so the
/// app starts and a downloaded book opens and plays fully offline
/// (docs/KONZEPT.md "Unterwegs"). A pure cache of server data: never the
/// source of any progress (that stays the event journal, invariant 2).
class LibraryCache {
  final Directory dir;

  LibraryCache(this.dir);

  static final _safeId = RegExp(r'^[A-Za-z0-9._-]+$');

  File get _booksFile => File('${dir.path}/books.json');

  File? _detailFile(String bookId) {
    if (!_safeId.hasMatch(bookId) || bookId.startsWith('.')) return null;
    return File('${dir.path}/book-$bookId.json');
  }

  Future<List<Map<String, dynamic>>?> loadBookList() async {
    final raw = await _read(_booksFile);
    if (raw is! List) return null;
    return raw.cast<Map<String, dynamic>>();
  }

  Future<void> saveBookList(List<Map<String, dynamic>> books) => _write(_booksFile, books);

  Future<Map<String, dynamic>?> loadBookDetail(String bookId) async {
    final file = _detailFile(bookId);
    if (file == null) return null;
    final raw = await _read(file);
    return raw is Map<String, dynamic> ? raw : null;
  }

  Future<void> saveBookDetail(String bookId, Map<String, dynamic> detail) async {
    final file = _detailFile(bookId);
    if (file == null) return;
    await _write(file, detail);
  }

  Future<Object?> _read(File file) async {
    try {
      if (!await file.exists()) return null;
      return jsonDecode(await file.readAsString());
    } catch (_) {
      return null; // a damaged cache file is just a cache miss
    }
  }

  /// Write-then-rename, so a crash mid-write never leaves a half file.
  Future<void> _write(File file, Object json) async {
    try {
      await dir.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(json), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // Caching is best effort; the fetched data is still returned.
    }
  }
}

/// Book list and details, cache first (decision E30). Every successful
/// fetch refreshes the cache; reads fall back to it whenever the server is
/// not configured, slow or unreachable.
class LibraryRepository {
  final ApiClient? api;

  /// Null in contexts without an app-support directory (tests): then
  /// nothing is cached.
  final LibraryCache? cache;

  LibraryRepository({required this.api, required this.cache});

  Future<List<BookSummary>?> cachedBooks() async {
    final raw = await cache?.loadBookList();
    if (raw == null) return null;
    try {
      return raw.map(BookSummary.fromJson).toList();
    } catch (_) {
      return null;
    }
  }

  /// Fetches the book list from the server and caches it. Throws when no
  /// server is configured or it cannot be reached.
  Future<List<BookSummary>> fetchBooks() async {
    final client = api;
    if (client == null) throw StateError('no server configured');
    final raw = await client.listBooks();
    final books = raw.map(BookSummary.fromJson).toList();
    await cache?.saveBookList(raw);
    return books;
  }

  Future<BookDetail?> cachedDetail(String bookId) async {
    final raw = await cache?.loadBookDetail(bookId);
    if (raw == null) return null;
    try {
      return BookDetail.fromJson(raw);
    } catch (_) {
      return null;
    }
  }

  /// Fetches one book's detail from the server and caches it. Throws when
  /// no server is configured or it cannot be reached.
  Future<BookDetail> fetchDetail(String bookId) async {
    final client = api;
    if (client == null) throw StateError('no server configured');
    final raw = await client.bookDetail(bookId);
    final detail = BookDetail.fromJson(raw);
    await cache?.saveBookDetail(bookId, raw);
    return detail;
  }

  /// The cached detail if there is one, otherwise a fetch; null when
  /// neither works.
  Future<BookDetail?> detailCacheFirst(String bookId) async {
    final cached = await cachedDetail(bookId);
    if (cached != null) return cached;
    try {
      return await fetchDetail(bookId);
    } catch (_) {
      return null;
    }
  }

  /// A fresh detail from the server, or the cached one when the server
  /// cannot be reached; null when neither works.
  Future<BookDetail?> detailNetworkFirst(String bookId) async {
    try {
      return await fetchDetail(bookId);
    } catch (_) {
      return cachedDetail(bookId);
    }
  }
}
