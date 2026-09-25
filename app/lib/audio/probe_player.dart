import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:just_audio/just_audio.dart' as ja;

/// Short sounds of the Faden search (decision E85), bundled in
/// assets/sounds/ and generated locally like the cue tone (E18).
enum FadenCue {
  /// "Kenne ich": a short click.
  known('assets/sounds/klick.wav'),

  /// "Kenne ich nicht", or no answer in time: a soft, lower tone.
  unknown('assets/sounds/ton_nein.wav'),

  /// The result: a rising double tone before playback starts there.
  result('assets/sounds/ton_ergebnis.wav');

  final String asset;

  const FadenCue(this.asset);
}

/// The Faden-Suche's own player (docs/ARCHITEKTUR.md section 8: "Proben
/// laufen über einen eigenen Player, der Hauptplayer ist pausiert"): a
/// second just_audio instance that plays the cue tone and each probe
/// without ever touching the main player behind audio/handler.dart.
///
/// Decision E85: while [keepAlive] is on (the search runs), it never goes
/// quiet -- between probes it loops near-silence, so iOS keeps a locked
/// phone's app running and the answer window's timer fires. It also plays
/// the feedback sounds ([playCue]).
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

  /// Near-silence instead of a pause between sounds (E85).
  bool _keepAlive = false;

  /// How long a probe may take to start (loading a streamed chapter)
  /// before its time runs anyway.
  static const Duration maxStartWait = Duration(seconds: 8);

  ProbePlayer({ja.AudioPlayer? player}) : _player = player ?? ja.AudioPlayer();

  /// The book's playlist, built the same way as the main player's
  /// (audio/player.dart's `buildPlaylist`) so a probe's `(fileIndex,
  /// offsetMs)` plays back exactly like the main player would.
  void open(List<ja.IndexedAudioSource> sources) {
    _bookSources = sources;
  }

  /// While on, the player loops near-silence whenever nothing else plays
  /// (E85); off, it simply pauses (the result plays on the main player).
  Future<void> setKeepAlive(bool on) async {
    if (_keepAlive == on) return;
    _keepAlive = on;
    _generation++;
    await _idle();
  }

  /// docs/KONZEPT.md "Faden aufnehmen": "Ein leiser Ton, dann eine 6 s lange
  /// Hörprobe." Plays the bundled cue tone (assets/sounds/ton.wav, see
  /// docs/ARCHITEKTUR.md section 13) once and waits for it to finish.
  /// Swallows playback errors -- a missing/failed tone must never block the
  /// search itself, only the probe that follows matters.
  Future<void> playTone() => _playAsset('assets/sounds/ton.wav');

  /// A feedback sound (E85), played once; waits for it to finish.
  Future<void> playCue(FadenCue cue) => _playAsset(cue.asset);

  Future<void> _playAsset(String asset) async {
    final generation = ++_generation;
    try {
      await _player.setLoopMode(ja.LoopMode.off);
      await _player.setAsset(asset);
      unawaited(_player.play().catchError((Object _) {}));
      await _player.processingStateStream
          .firstWhere((s) => s == ja.ProcessingState.completed)
          .timeout(const Duration(seconds: 2), onTimeout: () => ja.ProcessingState.completed);
    } catch (_) {
      // Best-effort sound only.
    } finally {
      if (generation == _generation) await _idle();
    }
  }

  /// Plays up to [probeLenMs] of the book at `(fileIndex, offsetMs)`,
  /// stopping at the file's own end if that comes first
  /// (docs/ARCHITEKTUR.md section 8: "Eine Probe endet spätestens am
  /// Dateiende"). [fileDurationMs] is the manifest's duration of that file:
  /// just_audio does not guarantee `duration` is known right after loading
  /// (notably for streamed files), so the manifest value is the bound that
  /// always applies; the player's own duration only tightens it further if
  /// it is known and shorter.
  ///
  /// [onPlaying] is called once the probe actually plays (E85: a streamed
  /// chapter can take seconds to load, and the answer window must not run
  /// meanwhile); the probe's own length counts from then too. Returns once
  /// playback has stopped. Swallows playback errors -- a failed probe
  /// simply plays silence, and the listener then answers "kenne ich nicht"
  /// via the normal answer-window timeout.
  Future<void> playProbe({
    required int fileIndex,
    required int offsetMs,
    required int probeLenMs,
    required int fileDurationMs,
    void Function()? onPlaying,
  }) async {
    final sources = _bookSources;
    if (sources == null || fileIndex < 0 || fileIndex >= sources.length) {
      onPlaying?.call();
      return;
    }
    final generation = ++_generation;
    var started = false;
    void start() {
      if (started || generation != _generation) return;
      started = true;
      onPlaying?.call();
    }

    try {
      await _player.setLoopMode(ja.LoopMode.off);
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
      // or the whole playlist has completed, so it is started but not
      // awaited: the probe-length timer alone bounds the probe.
      unawaited(_player.play().catchError((Object _) {}));
      await _player.playerStateStream
          .firstWhere((s) => s.playing && s.processingState == ja.ProcessingState.ready)
          .timeout(maxStartWait);
      start();
      await Future.any<void>([
        Future<void>.delayed(playFor),
        _player.processingStateStream.firstWhere((s) => s == ja.ProcessingState.completed),
      ]);
    } catch (_) {
      // Best-effort playback only.
    } finally {
      start(); // never leaves the answer window waiting
      // Unless something newer owns the player by now.
      if (generation == _generation) await _idle();
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

  /// Ends whatever plays (an early answer, the search ended): near-silence
  /// while [setKeepAlive] is on, otherwise quiet.
  Future<void> stop() {
    _generation++;
    return _idle();
  }

  Future<void> _idle() async {
    // Whatever takes the player over next (a tone, a probe) wins: the
    // silence never starts after it.
    final generation = _generation;
    try {
      if (_keepAlive) {
        await _player.setLoopMode(ja.LoopMode.one);
        if (generation != _generation) return;
        await _player.setAsset('assets/sounds/stille.wav');
        if (generation != _generation) return;
        unawaited(_player.play().catchError((Object _) {}));
      } else {
        await _player.pause();
      }
    } catch (_) {
      // Nothing to stop, or the platform already tore it down.
    }
  }

  Future<void> dispose() => _player.dispose();
}
