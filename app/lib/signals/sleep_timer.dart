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

  const SleepTimerState({
    required this.running,
    required this.mode,
    required this.remaining,
    required this.volumeFactor,
  });

  static const idle =
      SleepTimerState(running: false, mode: null, remaining: Duration.zero, volumeFactor: 1.0);
}

/// Sleep-timer countdown, docs/KONZEPT.md "Nachtmodus". Scope note (M4):
/// this only runs the countdown, the last-30s fade and the last-minute
/// "extend instead of act" mechanic. It intentionally does *not* emit a
/// `SLEEP_HINT` event on expiry, nor an `AWAKE` event on an extend -- both
/// belong to the "Wach-Signale" work in docs/ARCHITEKTUR.md section 9,
/// scoped to M5. [onExpire] here is expected to just pause playback
/// (already a plain `PAUSE`/`source=timer` event via the journal, which
/// M3's domain layer already models), and an extend is a local UI/timer
/// effect only.
class SleepTimerController {
  /// docs/KONZEPT.md: "Die letzten 30 s werden leiser."
  final Duration fadeWindow;

  /// docs/KONZEPT.md: "In der letzten Minute verlängert jede
  /// Kopfhörertaste den Timer um die gewählte Dauer, statt zu pausieren."
  final Duration lastMinuteWindow;

  final void Function() onExpire;
  final void Function(double volumeFactor) onVolumeChange;

  Timer? _ticker;
  bool _running = false;
  SleepTimerMode? _mode;
  Duration _remaining = Duration.zero;
  Duration _extendBy = Duration.zero;
  double _volumeFactor = 1.0;

  final StreamController<SleepTimerState> _controller =
      StreamController<SleepTimerState>.broadcast();

  SleepTimerController({
    required this.onExpire,
    required this.onVolumeChange,
    this.fadeWindow = const Duration(seconds: 30),
    this.lastMinuteWindow = const Duration(minutes: 1),
  });

  SleepTimerState get state => SleepTimerState(
        running: _running,
        mode: _mode,
        remaining: _remaining,
        volumeFactor: _volumeFactor,
      );

  Stream<SleepTimerState> get stateStream => _controller.stream;

  /// Starts (or replaces) the timer. [duration] is both the initial
  /// countdown and the amount a last-minute interaction extends it by.
  void start(Duration duration, {required SleepTimerMode mode}) {
    _mode = mode;
    _extendBy = duration;
    _remaining = duration;
    _setVolumeFactor(1.0);
    _running = true;
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _emit();
  }

  void cancel() {
    if (!_running) return;
    _ticker?.cancel();
    _running = false;
    _mode = null;
    _remaining = Duration.zero;
    _setVolumeFactor(1.0);
    _emit();
  }

  /// True while an interaction (screen tap or headphone button) should
  /// extend the timer instead of doing its normal action (last minute
  /// only, docs/KONZEPT.md).
  bool get inLastMinute => _running && _remaining <= lastMinuteWindow;

  /// Consumes an interaction as an extend if [inLastMinute]. Returns
  /// whether it did (the caller then must not also treat the interaction
  /// as a normal play/pause/media-button action).
  bool extendIfInLastMinute() {
    if (!inLastMinute) return false;
    _remaining = _extendBy;
    _setVolumeFactor(1.0);
    _emit();
    return true;
  }

  void _tick() {
    if (!_running) return;
    final next = _remaining - const Duration(seconds: 1);
    if (next <= Duration.zero) {
      _remaining = Duration.zero;
      _running = false;
      _mode = null;
      _ticker?.cancel();
      _setVolumeFactor(1.0); // restored for the next playback
      _emit();
      onExpire();
      return;
    }
    _remaining = next;
    _setVolumeFactor(
      next <= fadeWindow ? (next.inMilliseconds / fadeWindow.inMilliseconds).clamp(0.0, 1.0) : 1.0,
    );
    _emit();
  }

  void _setVolumeFactor(double factor) {
    if (_volumeFactor == factor) return;
    _volumeFactor = factor;
    onVolumeChange(factor);
  }

  void _emit() => _controller.add(state);

  void dispose() {
    _ticker?.cancel();
    unawaited(_controller.close());
  }
}
