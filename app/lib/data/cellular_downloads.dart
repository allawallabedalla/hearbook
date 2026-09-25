import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;

import '../domain/manifest.dart';
import 'book_downloads.dart';
import 'offline_books.dart' show ConnectivityCheck, allowsAutoDownload;

/// Chapter-wise downloads over mobile data (decision E66): while the open
/// book plays without Wi-Fi, its current and next chapter file are fetched,
/// rolling forward as playback advances. Whole books still load on Wi-Fi
/// only (E56); downloads are not events, nothing here is journaled.

/// What kind of network the phone is on, for downloads.
enum NetworkKind {
  /// Wi-Fi or Ethernet without a cellular link ([allowsAutoDownload]).
  wifi,

  /// Anything else that carries traffic: mobile data, a VPN or an
  /// unknown interface without Wi-Fi, or Wi-Fi and mobile at once. Treated
  /// as metered, so it never loads without the setting and the listener's
  /// consent.
  cellular,

  /// No network.
  offline,
}

NetworkKind networkKindOf(List<ConnectivityResult> results) {
  if (allowsAutoDownload(results)) return NetworkKind.wifi;
  if (results.any((r) => r != ConnectivityResult.none)) return NetworkKind.cellular;
  return NetworkKind.offline;
}

/// The files to fetch now over mobile data (decision E66): of the chapter
/// at [currentIndex] and the one after it, those not in [localFiles], in
/// playback order -- so never more than current + next beyond what is on
/// the device. Nothing unless the setting is [enabled], the book is
/// [playing] and the phone is on [NetworkKind.cellular] (on Wi-Fi the
/// normal behaviour applies). Pure.
List<String> chapterFilesToFetch({
  required Manifest manifest,
  required int currentIndex,
  required Set<String> localFiles,
  required NetworkKind network,
  required bool enabled,
  required bool playing,
}) {
  if (!enabled || !playing || network != NetworkKind.cellular) return const [];
  if (currentIndex < 0 || currentIndex >= manifest.files.length) return const [];
  return [
    for (final file in manifest.files.skip(currentIndex).take(2))
      if (!localFiles.contains(file.fileHash)) file.fileHash,
  ];
}

/// Assumed bit rate when the server sends no file sizes (servers before
/// E66): 64 kbit/s, a common rate for spoken-word MP3s.
const fallbackBitsPerSecond = 64000;

/// A size estimate for the confirmation dialog: bytes per hour of the book
/// and of one chapter. [approximate] when a size came from the assumed
/// bit rate instead of the manifest.
class CellularEstimate {
  final int bytesPerHour;
  final int chapterNumber;
  final int chapterBytes;
  final bool approximate;

  const CellularEstimate({
    required this.bytesPerHour,
    required this.chapterNumber,
    required this.chapterBytes,
    required this.approximate,
  });

  /// From the real sizes of [manifest] (all files with a size and a
  /// duration), else from [fallbackBitsPerSecond]; the chapter is
  /// [chapterIndex] (0-based), with its own size when known.
  factory CellularEstimate.of(Manifest manifest, int chapterIndex) {
    var bytes = 0;
    var ms = 0;
    for (final f in manifest.files) {
      final size = f.sizeBytes;
      if (size == null || size <= 0 || f.durationMs <= 0) continue;
      bytes += size;
      ms += f.durationMs;
    }
    final measured = bytes > 0 && ms > 0;
    final bytesPerMs = measured ? bytes / ms : fallbackBitsPerSecond / 8 / 1000;
    final file = manifest.files[chapterIndex.clamp(0, manifest.files.length - 1)];
    final ownSize = file.sizeBytes;
    final chapterKnown = ownSize != null && ownSize > 0;
    return CellularEstimate(
      bytesPerHour: (bytesPerMs * 3600 * 1000).round(),
      chapterNumber: file.idx + 1,
      chapterBytes: chapterKnown ? ownSize : (file.durationMs * bytesPerMs).round(),
      approximate: !measured || !chapterKnown,
    );
  }
}

/// The once-per-session question before loading over mobile data
/// (decision E66). A session is the app process: the answer lives in
/// memory, except "Nicht wieder anzeigen", which is stored and makes
/// every later session count as agreed.
enum CellularDecision { allowed, declined, ask }

class CellularConsent {
  /// The stored "Nicht wieder anzeigen" (settings_store.dart).
  final Future<bool> Function() hintOff;
  final Future<void> Function(bool off) setHintOff;

  bool? _session;

  CellularConsent({required this.hintOff, required this.setHintOff});

  Future<CellularDecision> decision() async {
    final session = _session;
    if (session != null) return session ? CellularDecision.allowed : CellularDecision.declined;
    return await hintOff() ? CellularDecision.allowed : CellularDecision.ask;
  }

  /// "Laden": no more questions this session; with [dontShowAgain], none
  /// in later sessions either.
  Future<void> accept({required bool dontShowAgain}) async {
    _session = true;
    if (dontShowAgain) await setHintOff(true);
  }

  /// "Nicht jetzt": no mobile-data downloads and no question for the rest
  /// of this session.
  void decline() => _session = false;
}

/// The open book as the downloader sees it.
class ChapterPlayback {
  final String bookId;
  final Manifest manifest;
  final int currentIndex;
  final bool playing;

  const ChapterPlayback({
    required this.bookId,
    required this.manifest,
    required this.currentIndex,
    required this.playing,
  });
}

/// A question waiting for the listener: the dialog shows it once the app
/// is in the foreground.
class CellularPrompt {
  final String bookId;
  final CellularEstimate estimate;

  const CellularPrompt({required this.bookId, required this.estimate});
}

/// Runs the chapter-wise downloads (decision E66). Like [AutoDownloader],
/// one pass at a time; a [trigger] during a pass asks for one more.
/// Triggers: playback starts, the chapter changes, a network change, the
/// app returning to the foreground, the setting, the dialog's answer.
class ChapterDownloader {
  /// "Über Mobilfunk kapitelweise laden", read on every pass.
  final Future<bool> Function() enabled;
  final ConnectivityCheck connectivity;
  final Future<bool> Function() serverReachable;
  final CellularConsent consent;
  final BookDownloads downloads;

  /// The open book and where it plays; null when none is open.
  final ChapterPlayback? Function() playback;

  final ValueNotifier<CellularPrompt?> _prompt = ValueNotifier(null);

  /// Books whose chapter download the listener stopped (library): left
  /// alone for the rest of the session.
  final Set<String> _stopped = {};
  bool _stopping = false;
  Future<void>? _running;
  bool _again = false;

  ChapterDownloader({
    required this.enabled,
    required this.connectivity,
    required this.serverReachable,
    required this.consent,
    required this.downloads,
    required this.playback,
  });

  /// The question to ask, if one waits (null otherwise).
  ValueListenable<CellularPrompt?> get prompt => _prompt;

  /// Starts a pass, or queues one more. Never throws.
  Future<void> trigger() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _loop().whenComplete(() => _running = null);
  }

  void onNetworkChanged(List<ConnectivityResult> results) {
    if (networkKindOf(results) == NetworkKind.cellular) unawaited(trigger());
  }

  /// The dialog's answer.
  Future<void> answer({required bool load, bool dontShowAgain = false}) async {
    _prompt.value = null;
    if (load) {
      await consent.accept(dontShowAgain: dontShowAgain);
      unawaited(trigger());
    } else {
      consent.decline();
    }
  }

  /// The setting was switched off: stops a running chapter download.
  void stop() {
    _prompt.value = null;
    final open = playback();
    if (open == null || !downloads.isChapterRun(open.bookId)) return;
    _stopping = true;
    downloads.cancel(open.bookId);
  }

  void dispose() => _prompt.dispose();

  Future<void> _loop() async {
    do {
      _again = false;
      try {
        await _pass();
      } catch (_) {
        // Best effort: the next trigger tries again.
      }
    } while (_again);
  }

  Future<void> _pass() async {
    final open = playback();
    final on = await enabled();
    if (!on || open == null) {
      _prompt.value = null;
      return;
    }
    final network = networkKindOf(await _network());
    final window = open.manifest.files.skip(open.currentIndex < 0 ? open.manifest.files.length : open.currentIndex).take(2);
    final local = <String>{
      for (final f in window)
        if (await downloads.manager.isDownloaded(f.fileHash)) f.fileHash,
    };
    final wanted = _stopped.contains(open.bookId)
        ? const <String>[]
        : chapterFilesToFetch(
            manifest: open.manifest,
            currentIndex: open.currentIndex,
            localFiles: local,
            network: network,
            enabled: on,
            playing: open.playing,
          );
    if (wanted.isEmpty) {
      _prompt.value = null;
      return;
    }
    final state = downloads.stateFor(open.bookId);
    if (state.isDownloading) return; // a whole-book download, or ours still ending
    switch (await consent.decision()) {
      case CellularDecision.declined:
        _prompt.value = null;
        return;
      case CellularDecision.ask:
        final first = open.manifest.indexOf(wanted.first);
        _prompt.value = CellularPrompt(bookId: open.bookId, estimate: CellularEstimate.of(open.manifest, first));
        return;
      case CellularDecision.allowed:
        _prompt.value = null;
    }
    if (!await serverReachable()) return;
    final result = await downloads.downloadChapters(
      open.bookId,
      open.manifest,
      wanted,
      stillWanted: (fileHash) => _stillWanted(open.bookId, fileHash),
    );
    switch (result) {
      case ChapterRunResult.done:
        _again = true; // playback may have moved on meanwhile
      case ChapterRunResult.cancelled:
        if (!_stopping) _stopped.add(open.bookId);
      case ChapterRunResult.superseded:
      case ChapterRunResult.busy:
      case ChapterRunResult.failed:
        break;
    }
    _stopping = false;
  }

  /// Before each file of a run: still the current or the next chapter?
  bool _stillWanted(String bookId, String fileHash) {
    final open = playback();
    if (open == null || open.bookId != bookId) return false;
    final idx = open.manifest.indexOf(fileHash);
    return idx >= open.currentIndex && idx <= open.currentIndex + 1;
  }

  Future<List<ConnectivityResult>> _network() async {
    try {
      return await connectivity();
    } catch (_) {
      return const [];
    }
  }
}
