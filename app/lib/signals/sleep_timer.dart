import 'dart:async';

/// docs/KONZEPT.md "Nachtmodus": "Sleep-Timer: 15, 30, 45, 60 Min oder
/// Kapitelende."
const List<int> sleepTimerPresetMinutes = [15, 30, 45, 60];

enum SleepTimerMode { fixed, chapterEnd }

class SleepTimerState {
  final bool running;
  final SleepTimerMode? mode;
  final Duration remaining;

  /// 1.0 = normal volume; ramps down to 0.0 over the fade window
  /// (docs/KONZEPT.md: "Die letzten 30 s werden leiser").
  final double volumeFactor;

  /// The duration the listener picked for a [SleepTimerMode.fixed] timer
  /// (also what a last-minute extension adds); null otherwise. The UI marks
  /// the chosen preset with it -- [remaining] drifts away from the preset
  /// as the countdown runs.
  final Duration? chosen;

  const SleepTimerState({
    required this.running,
    required this.mode,
    required this.remaining,
    required this.volumeFactor,
    this.chosen,
  });

  static const idle =
      SleepTimerState(running: false, mode: null, remaining: Duration.zero, volumeFactor: 1.0);
}

/// Sleep-timer countdown, docs/KONZEPT.md "Nachtmodus". Runs the
/// countdown, the last-30s fade and the last-minute "extend instead of
/// act" mechanic; [onExpire] pauses playback (audio/handler.dart
/// `pauseForSleepTimerExpiry`: PAUSE plus SLEEP_HINT, decision E13).
///
/// Decision E42:
/// - The countdown only runs while [isPlaying] says so: a paused book does
///   not use up the timer.
/// - "Kapitelende" ([startChapterEnd]) is not a wall-clock time computed at
///   start (wrong at speeds other than 1x and after seeks): it fires when
///   playback actually runs into the next chapter ([onChapterAdvanced],
///   fed from the handler's `chapterAdvanced`). Its countdown and fade
///   follow [chapterRemaining] (already divided by the speed). A last-minute
///   extension lets it run to the end of the following chapter instead.
class SleepTimerController {
  /// docs/KONZEPT.md: "Die letzten 30 s werden leiser."
  final Duration fadeWindow;

  /// docs/KONZEPT.md: "In der letzten Minute verlängert jede
  /// Kopfhörertaste den Timer um die gewählte Dauer, statt zu pausieren."
  final Duration lastMinuteWindow;

  final void Function() onExpire;
  final void Function(double volumeFactor) onVolumeChange;

  /// Whether the book is playing right now; the countdown pauses otherwise.
  final bool Function() isPlaying;

  /// Wall-clock time left in the current chapter at the current speed.
  final Duration Function() chapterRemaining;

  Timer? _ticker;
  bool _running = false;
  SleepTimerMode? _mode;
  Duration _remaining = Duration.zero;
  Duration _extendBy = Duration.zero;
  double _volumeFactor = 1.0;

  /// Chapter changes still to let pass before a "Kapitelende" timer fires
  /// (one per last-minute extension).
  int _chapterChangesToSkip = 0;

  final StreamController<SleepTimerState> _controller =
      StreamController<SleepTimerState>.broadcast();

  SleepTimerController({
    required this.onExpire,
    required this.onVolumeChange,
    bool Function()? isPlaying,
    Duration Function()? chapterRemaining,
    this.fadeWindow = const Duration(seconds: 30),
    this.lastMinuteWindow = const Duration(minutes: 1),
  })  : isPlaying = isPlaying ?? _alwaysPlaying,
        chapterRemaining = chapterRemaining ?? _noChapterInfo;

  static bool _alwaysPlaying() => true;
  static Duration _noChapterInfo() => Duration.zero;

  SleepTimerState get state => SleepTimerState(
        running: _running,
        mode: _mode,
        remaining: _remaining,
        volumeFactor: _volumeFactor,
        chosen: _running && _mode == SleepTimerMode.fixed ? _extendBy : null,
      );

  Stream<SleepTimerState> get stateStream => _controller.stream;

  /// Starts (or replaces) the timer. [duration] is both the initial
  /// countdown and the amount a last-minute interaction extends it by.
  /// `mode: chapterEnd` ignores [duration] and behaves like
  /// [startChapterEnd].
  void start(Duration duration, {SleepTimerMode mode = SleepTimerMode.fixed}) {
    if (mode == SleepTimerMode.chapterEnd) {
      startChapterEnd();
      return;
    }
    _begin(SleepTimerMode.fixed, remaining: duration);
    _extendBy = duration;
    _emit();
  }

  /// "Kapitelende": pauses when playback runs into the next chapter.
  void startChapterEnd() {
    _begin(SleepTimerMode.chapterEnd, remaining: chapterRemaining());
    _emit();
  }

  void _begin(SleepTimerMode mode, {required Duration remaining}) {
    _mode = mode;
    _remaining = remaining;
    _chapterChangesToSkip = 0;
    _setVolumeFactor(1.0);
    _running = true;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void cancel() {
    if (!_running) return;
    _ticker?.cancel();
    _running = false;
    _mode = null;
    _remaining = Duration.zero;
    _chapterChangesToSkip = 0;
    _setVolumeFactor(1.0);
    _emit();
  }

  /// True while a headphone/media button should extend the timer instead
  /// of doing its normal action (last minute only, docs/KONZEPT.md). Screen
  /// buttons always act normally.
  bool get inLastMinute {
    if (!_running) return false;
    if (_mode == SleepTimerMode.chapterEnd && _chapterChangesToSkip > 0) return false;
    return _remaining <= lastMinuteWindow;
  }

  /// Consumes a media-button press as an extend if [inLastMinute]. Returns
  /// whether it did (the caller then must not also treat the press as a
  /// normal play/pause/skip).
  bool extendIfInLastMinute() {
    if (!inLastMinute) return false;
    if (_mode == SleepTimerMode.chapterEnd) {
      _chapterChangesToSkip++;
    } else {
      _remaining = _extendBy;
    }
    _setVolumeFactor(1.0);
    _emit();
    return true;
  }

  /// Playback ran into the next chapter by itself (not a seek). Fires a
  /// "Kapitelende" timer, unless an extension lets this change pass.
  void onChapterAdvanced() {
    if (!_running || _mode != SleepTimerMode.chapterEnd) return;
    if (_chapterChangesToSkip > 0) {
      _chapterChangesToSkip--;
      _remaining = chapterRemaining();
      _emit();
      return;
    }
    _expire();
  }

  void _tick() {
    if (!_running) return;
    if (!isPlaying()) return; // paused: the timer waits too
    if (_mode == SleepTimerMode.chapterEnd) {
      _remaining = chapterRemaining();
      final fading = _chapterChangesToSkip == 0 && _remaining <= fadeWindow;
      _setVolumeFactor(
        fading ? (_remaining.inMilliseconds / fadeWindow.inMilliseconds).clamp(0.0, 1.0) : 1.0,
      );
      _emit();
      return;
    }
    final next = _remaining - const Duration(seconds: 1);
    if (next <= Duration.zero) {
      _expire();
      return;
    }
    _remaining = next;
    _setVolumeFactor(
      next <= fadeWindow ? (next.inMilliseconds / fadeWindow.inMilliseconds).clamp(0.0, 1.0) : 1.0,
    );
    _emit();
  }

  void _expire() {
    _remaining = Duration.zero;
    _running = false;
    _mode = null;
    _chapterChangesToSkip = 0;
    _ticker?.cancel();
    _setVolumeFactor(1.0); // restored for the next playback
    _emit();
    onExpire();
  }

  void _setVolumeFactor(double factor) {
    if (_volumeFactor == factor) return;
    _volumeFactor = factor;
    onVolumeChange(factor);
  }

  void _emit() {
    if (!_controller.isClosed) _controller.add(state);
  }

  void dispose() {
    _ticker?.cancel();
    unawaited(_controller.close());
  }
}
