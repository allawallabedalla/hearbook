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

  ProbePlayer({ja.AudioPlayer? player}) : _player = player ?? ja.AudioPlayer();

  /// The book's playlist, built the same way as the main player's
  /// (audio/player.dart's `buildPlaylist`) so a probe's `(fileIndex,
  /// offsetMs)` plays back exactly like the main player would.
  void open(List<ja.IndexedAudioSource> sources) {
    _bookSources = sources;
  }

  /// docs/KONZEPT.md "Faden aufnehmen": "Ein leiser Ton, dann eine 4 s lange
  /// Hörprobe." Plays the bundled cue tone (assets/sounds/ton.wav, see
  /// docs/ARCHITEKTUR.md section 13) once and waits for it to finish.
  /// Swallows playback errors -- a missing/failed tone must never block the
  /// search itself, only the probe that follows matters.
  Future<void> playTone() async {
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
  /// Dateiende"). Returns once playback has stopped. Swallows playback
  /// errors -- a failed probe simply plays silence, and the listener then
  /// answers "kenne ich nicht" via the normal answer-window timeout
  /// (ui/faden_search_controller.dart), same as if they had not recognised
  /// it.
  Future<void> playProbe({
    required int fileIndex,
    required int offsetMs,
    required int probeLenMs,
  }) async {
    final sources = _bookSources;
    if (sources == null || fileIndex < 0 || fileIndex >= sources.length) return;
    try {
      await _player.setAudioSources(
        sources,
        initialIndex: fileIndex,
        initialPosition: Duration(milliseconds: offsetMs),
      );
      await _player.play();
      final fileDuration = _player.duration;
      final maxPlayFor = Duration(milliseconds: probeLenMs);
      final remainingInFile =
          fileDuration == null ? maxPlayFor : fileDuration - Duration(milliseconds: offsetMs);
      final playFor = remainingInFile < maxPlayFor ? remainingInFile : maxPlayFor;
      await Future.any([
        Future<void>.delayed(playFor < Duration.zero ? Duration.zero : playFor),
        _player.processingStateStream.firstWhere((s) => s == ja.ProcessingState.completed),
      ]);
    } catch (_) {
      // Best-effort playback only.
    } finally {
      await stop();
    }
  }

  Future<void> stop() async {
    try {
      await _player.pause();
    } catch (_) {
      // Nothing to stop, or the platform already tore it down.
    }
  }

  Future<void> dispose() => _player.dispose();
}
