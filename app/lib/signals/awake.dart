/// Rate limiter for `AWAKE` events, docs/ARCHITEKTUR.md section 5's events
/// table: "AWAKE | Berührung, Lautstärke, Timer verlängert (höchstens 1 pro
/// 10 s)". Section 9 lists three distinct triggers (screen touch, volume
/// change, sleep-timer extension) that all funnel through the *same*
/// `AWAKE` event type, and the "(höchstens 1 pro 10 s)" parenthetical sits
/// after all three -- read as one shared cooldown across every trigger
/// combined, not a separate 10s budget per trigger. A single [AwakeGate]
/// instance (owned by audio/handler.dart) is meant to be asked by every
/// trigger, so that is exactly what this enforces.
///
/// Kept Flutter-free (no imports at all) so it is directly unit-testable.
class AwakeGate {
  final Duration minInterval;
  int? _lastEmitMs;

  AwakeGate({this.minInterval = const Duration(seconds: 10)});

  /// Whether an `AWAKE` event may be written now for wall-clock [nowMs].
  /// If true, this also starts the cooldown -- call it right before
  /// actually writing the event, never speculatively (a caller that checks
  /// this and then decides not to write must not call it again to "undo"
  /// the cooldown; there is no such method by design, matching the
  /// journal's own event-before-action rule: this gate's job is the
  /// opposite direction, "should I even attempt to write").
  bool shouldEmit(int nowMs) {
    final last = _lastEmitMs;
    if (last != null && nowMs - last < minInterval.inMilliseconds) return false;
    _lastEmitMs = nowMs;
    return true;
  }
}
