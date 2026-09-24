import 'package:just_audio/just_audio.dart';

import '../data/downloads.dart';
import '../domain/manifest.dart';

/// Per-chapter metadata carried on the just_audio playlist as each
/// [IndexedAudioSource]'s `tag` (see [AudioSource.uri]'s `tag` parameter).
/// Kept minimal and free of `package:audio_service` so this file stays a
/// pure just_audio adapter (docs/ARCHITEKTUR.md section 11:
/// "player.dart (just_audio)"); audio/handler.dart is what turns a chapter
/// index into a lock-screen `MediaItem`.
class ChapterTag {
  final String fileHash;
  final int idx; // 0-based position in the manifest

  const ChapterTag({required this.fileHash, required this.idx});
}

/// Builds the just_audio playlist for [manifest], in manifest order.
/// docs/ARCHITEKTUR.md section 11: "Playlist = alle Dateien des aktiven
/// Manifests; lokale Datei, sonst Stream-URL mit Token-Header." A file
/// already downloaded and hash-verified (data/downloads.dart) plays from
/// disk; everything else streams from the server with the bearer token as
/// an HTTP header (just_audio proxies this locally so the header is never
/// exposed to the OS media session).
Future<List<IndexedAudioSource>> buildPlaylist({
  required Manifest manifest,
  required DownloadManager downloads,
  required String serverBaseUrl,
  required String serverToken,
}) async {
  final sources = <IndexedAudioSource>[];
  for (final file in manifest.files) {
    final tag = ChapterTag(fileHash: file.fileHash, idx: file.idx);
    if (await downloads.isDownloaded(file.fileHash)) {
      sources.add(AudioSource.uri(Uri.file(downloads.pathFor(file.fileHash).path), tag: tag));
    } else {
      final uri = Uri.parse('$serverBaseUrl/api/v1/files/${file.fileHash}');
      sources.add(AudioSource.uri(uri, headers: {'Authorization': 'Bearer $serverToken'}, tag: tag));
    }
  }
  return sources;
}

/// Whether the chapter at [index] of [sources] streams from the server
/// rather than playing a downloaded file (decision E58). False for an
/// index outside the playlist.
bool streamsFromServer(List<IndexedAudioSource> sources, int? index) {
  if (index == null || index < 0 || index >= sources.length) return false;
  final source = sources[index];
  return source is UriAudioSource && source.uri.scheme != 'file';
}
