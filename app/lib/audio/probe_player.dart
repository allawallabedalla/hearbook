import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:just_audio/just_audio.dart' as ja;

/// The Faden-Suche's own player (docs/ARCHITEKTUR.md section 8: "Proben
/// laufen über einen eigenen Player, der Hauptplayer ist pausiert"): a
/// second just_audio instance that plays the cue tone and each probe
/// without ever touching the main player behind audio/handler.dart.
///
/// Not itself unit-tested (like audio/handler.dart and audio/player.dart,
/// it is a thin adapter around real platform audio); the search interaction
/// this drives is covered by ui/faden_search_controller_test.dart against
/// fake `playTone`/`playProbe`/`stopProbe` functions instead.
class ProbePlayer {
  final ja.AudioPlayer _player;
  List<ja.IndexedAudioSource>? _bookSources;

  /// Bumped by everything that takes over the player ([playTone],
  /// [playProbe], [stop]), so a probe's own timer never pauses what plays
  /// after it: the next tone and probe after an early answer, or the same
  /// probe replayed ("Nochmal hören", E64).
  int _generation = 0;

  ProbePlayer({ja.AudioPlayer? player}) : _player = player ?? ja.AudioPlayer();

  /// The book's playlist, built the same way as the main player's
  /// (audio/player.dart's `buildPlaylist`) so a probe's `(fileIndex,
  /// offsetMs)` plays back exactly like the main player would.
  void open(List<ja.IndexedAudioSource> sources) {
    _bookSources = sources;
  }

  /// docs/KONZEPT.md "Faden aufnehmen": "Ein leiser Ton, dann eine 6 s lange
  /// Hörprobe." Plays the bundled cue tone (assets/sounds/ton.wav, see
  /// docs/ARCHITEKTUR.md section 13) once and waits for it to finish.
  /// Swallows playback errors -- a missing/failed tone must never block the
  /// search itself, only the probe that follows matters.
  Future<void> playTone() async {
    _generation++;
    try {
      await _player.setAsset('assets/sounds/ton.wav');
      await _player.play();
      await _player.processingStateStream
          .firstWhere((s) => s == ja.ProcessingState.completed)
          .timeout(const Duration(seconds: 2), onTimeout: () => ja.ProcessingState.completed);
    } catch (_) {
      // Best-effort cue only.
    }
  }

  /// Plays up to [probeLenMs] of the book at `(fileIndex, offsetMs)`,
  /// stopping at the file's own end if that comes first
  /// (docs/ARCHITEKTUR.md section 8: "Eine Probe endet spätestens am
  /// Dateiende"). [fileDurationMs] is the manifest's duration of that file:
  /// just_audio does not guarantee `duration` is known right after loading
  /// (notably for streamed files), so the manifest value is the bound that
  /// always applies; the player's own duration only tightens it further if
  /// it is known and shorter. Returns once playback has stopped. Swallows playback
  /// errors -- a failed probe simply plays silence, and the listener then
  /// answers "kenne ich nicht" via the normal answer-window timeout
  /// (ui/faden_search_controller.dart), same as if they had not recognised
  /// it.
  Future<void> playProbe({
    required int fileIndex,
    required int offsetMs,
    required int probeLenMs,
    required int fileDurationMs,
  }) async {
    final sources = _bookSources;
    if (sources == null || fileIndex < 0 || fileIndex >= sources.length) return;
    final generation = ++_generation;
    try {
      await _player.setAudioSources(
        sources,
        initialIndex: fileIndex,
        initialPosition: Duration(milliseconds: offsetMs),
      );
      final playFor = Duration(
        milliseconds: probePlayMs(
          offsetMs: offsetMs,
          probeLenMs: probeLenMs,
          fileDurationMs: fileDurationMs,
          playerDurationMs: _player.duration?.inMilliseconds,
        ),
      );
      // just_audio's play() future completes only once playback is paused
      // or the whole playlist has completed (or at once if already
      // playing, e.g. right after the cue tone), so it is started but not
      // awaited: the probe-length timer alone bounds the probe.
      unawaited(_player.play().catchError((Object _) {}));
      await Future.any<void>([
        Future<void>.delayed(playFor),
        _player.processingStateStream.firstWhere((s) => s == ja.ProcessingState.completed),
      ]);
    } catch (_) {
      // Best-effort playback only.
    } finally {
      // Unless something newer owns the player by now.
      if (generation == _generation) await _pause();
    }
  }

  /// How long a probe at [offsetMs] may play: [probeLenMs], cut at the end
  /// of the file (the shorter of the manifest's [fileDurationMs] and the
  /// player's reported [playerDurationMs], if any), never negative.
  @visibleForTesting
  static int probePlayMs({
    required int offsetMs,
    required int probeLenMs,
    required int fileDurationMs,
    int? playerDurationMs,
  }) {
    var fileEnd = fileDurationMs;
    if (playerDurationMs != null && playerDurationMs < fileEnd) fileEnd = playerDurationMs;
    final remaining = fileEnd - offsetMs;
    final playFor = remaining < probeLenMs ? remaining : probeLenMs;
    return playFor < 0 ? 0 : playFor;
  }

  Future<void> stop() {
    _generation++;
    return _pause();
  }

  Future<void> _pause() async {
    try {
      await _player.pause();
    } catch (_) {
      // Nothing to stop, or the platform already tore it down.
    }
  }

  Future<void> dispose() => _player.dispose();
}
