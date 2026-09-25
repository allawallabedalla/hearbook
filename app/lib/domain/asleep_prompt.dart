/// "Eingeschlafen?" (decision E84). Pure, no I/O.
///
/// The book keeps playing, or it stopped by itself (chapter or book end,
/// sleep timer, headphones, the system), and nobody touched anything for a
/// long time. When the listener comes back -- the app returns to the
/// foreground, or the first touch while it was open -- Faden asks once
/// whether they fell asleep, instead of letting that touch quietly count
/// as an awake proof and erase the suspicion.
///
/// [ListeningStretchTracker] follows the journaled events of the open book
/// and knows how long playback ran since the last awake proof (wall time
/// while playing) and where that proof was. [asleepPromptDue] decides.
library;

import 'event.dart';
import 'pause_reason.dart';

/// Asks after this much listening since the last awake proof, day or night.
const int asleepPromptAfterMs = 60 * 60000;

/// In the night window it already asks after this much (the first touch
/// after 20 min without an awake proof must not erase the suspicion, the
/// audit's finding 4).
const int nightStretchSuspectMs = 20 * 60000;

/// Where the current listening stretch stands.
enum StretchState {
  /// Nothing played since the last awake proof, or it was stopped
  /// consciously (the on-screen button): nothing to ask.
  idle,

  /// The book is playing.
  playing,

  /// It stopped without anybody doing it on the screen: the sleep timer,
  /// the headphones or lock screen, the system, a lost connection, a call,
  /// an error, or the end of the book.
  stoppedByItself,
}

/// A snapshot of the listening since the last awake proof.
class ListeningStretch {
  /// Bumped by every awake proof, so "only once per stretch" is exact.
  final int id;
  final StretchState state;

  /// Playing time (wall clock) since the last awake proof.
  final int listenedMs;

  /// Global ms of the last awake proof; null before anything played.
  final int? lastAwakeGlobalMs;

  /// Wall time listening last happened (now while playing, else the stop).
  final int? lastListenWallMs;

  /// The stretch stopped with a pause in the car (CarPlay).
  final bool stoppedInCar;

  /// Why it stopped by itself (the sleep timer, ...); null while playing
  /// and at the book end.
  final PauseReason? stopReason;

  /// It stopped at the end of the book (E92): "Nein" confirms the end.
  final bool endedAtBookEnd;

  const ListeningStretch({
    required this.id,
    required this.state,
    required this.listenedMs,
    this.lastAwakeGlobalMs,
    this.lastListenWallMs,
    this.stoppedInCar = false,
    this.stopReason,
    this.endedAtBookEnd = false,
  });
}

/// Follows the events of the open book, in the order they are journaled.
class ListeningStretchTracker {
  int _id = 0;
  StretchState _state = StretchState.idle;
  int _listenedMs = 0;
  int? _playingSinceWallMs;
  int? _lastAwakeGlobalMs;
  int? _lastListenWallMs;
  bool _stoppedInCar = false;
  PauseReason? _stopReason;
  bool _bookEnd = false;

  /// Feeds one journaled event; [globalMs] is its position in the active
  /// manifest (null if unknown).
  void onEvent(Event e, {required int? globalMs}) {
    final now = e.wallMs;
    switch (e.type) {
      case EventType.heartbeat:
      case EventType.probe:
      case EventType.sleepHint:
        return;
      case EventType.finished:
        // Section 5 counts FINISHED as awake proof; for the stretch it is
        // just the end of the book, which a sleeper reaches too.
        _stop(now, car: e.data['route'] == carRouteName, reason: null);
        if (_state == StretchState.stoppedByItself) _bookEnd = true;
        return;
      case EventType.pause:
        if (e.isAwakeProof) {
          _awake(now, globalMs);
          _state = StretchState.idle;
          _playingSinceWallMs = null;
          return;
        }
        _stop(now, car: e.data['route'] == carRouteName, reason: pauseReasonOf(e));
        return;
      case EventType.play:
      case EventType.resume:
        _awake(now, globalMs);
        _state = StretchState.playing;
        _stopReason = null;
        _playingSinceWallMs = now;
        _lastListenWallMs = now;
        return;
      case EventType.seek:
      case EventType.undo:
      case EventType.awake:
        _awake(now, globalMs);
        if (_state == StretchState.playing) {
          _playingSinceWallMs = now;
        } else {
          _state = StretchState.idle;
        }
        return;
    }
  }

  void _awake(int now, int? globalMs) {
    _id++;
    _listenedMs = 0;
    _lastAwakeGlobalMs = globalMs;
    _stoppedInCar = false;
    _stopReason = null;
    _bookEnd = false;
    _lastListenWallMs = now;
  }

  void _stop(int now, {required bool car, required PauseReason? reason}) {
    final since = _playingSinceWallMs;
    if (_state == StretchState.playing && since != null && now > since) _listenedMs += now - since;
    _playingSinceWallMs = null;
    if (_state == StretchState.playing) {
      _state = StretchState.stoppedByItself;
      _lastListenWallMs = now;
      _stoppedInCar = car;
      _stopReason = reason;
    }
  }

  /// Another book was opened: nothing of this one counts.
  void reset() {
    _id++;
    _state = StretchState.idle;
    _listenedMs = 0;
    _playingSinceWallMs = null;
    _lastAwakeGlobalMs = null;
    _lastListenWallMs = null;
    _stoppedInCar = false;
    _stopReason = null;
    _bookEnd = false;
  }

  /// Rebuilds the stretch from this device's journaled events of the open
  /// book, oldest first (decision E93: it survives an app restart). A
  /// stretch that was still playing when the app ended stopped at its last
  /// event (usually a heartbeat).
  void restore(List<Event> events, {required int? Function(Event e) globalMsOf}) {
    reset();
    int? lastWallMs;
    for (final e in events) {
      onEvent(e, globalMs: globalMsOf(e));
      if (lastWallMs == null || e.wallMs > lastWallMs) lastWallMs = e.wallMs;
    }
    if (_state == StretchState.playing && lastWallMs != null) _stop(lastWallMs, car: false, reason: null);
  }

  ListeningStretch snapshot(int nowWallMs) {
    final since = _playingSinceWallMs;
    final running = _state == StretchState.playing && since != null && nowWallMs > since ? nowWallMs - since : 0;
    return ListeningStretch(
      id: _id,
      state: _state,
      listenedMs: _listenedMs + running,
      lastAwakeGlobalMs: _lastAwakeGlobalMs,
      lastListenWallMs: _state == StretchState.playing ? nowWallMs : _lastListenWallMs,
      stoppedInCar: _stoppedInCar,
      stopReason: _state == StretchState.stoppedByItself ? _stopReason : null,
      endedAtBookEnd: _state == StretchState.stoppedByItself && _bookEnd,
    );
  }
}

/// Whether and why "Eingeschlafen?" asks.
enum AsleepAsk { no, overAnHour, nightStretch }

/// The decision (E84): over an hour of listening since the last awake
/// proof, or [nightStretchSuspectMs] when [inNightWindow] (the stretch's
/// last listening lay in the night window); only while it plays or after
/// it stopped by itself; never with CarPlay as the output ([carRoute]) or
/// after a stop in the car (driving), never twice for the same stretch
/// ([askedStretchId]) and never while a Faden search runs.
AsleepAsk asleepPromptDue({
  required ListeningStretch stretch,
  required bool inNightWindow,
  required bool carRoute,
  required int? askedStretchId,
  required bool fadenActive,
}) {
  if (fadenActive || carRoute || stretch.stoppedInCar) return AsleepAsk.no;
  if (stretch.state == StretchState.idle) return AsleepAsk.no;
  if (askedStretchId == stretch.id) return AsleepAsk.no;
  if (stretch.lastAwakeGlobalMs == null) return AsleepAsk.no;
  if (stretch.listenedMs >= asleepPromptAfterMs) return AsleepAsk.overAnHour;
  if (inNightWindow && stretch.listenedMs >= nightStretchSuspectMs) return AsleepAsk.nightStretch;
  return AsleepAsk.no;
}

/// Which body text the question shows.
enum AsleepBody { playingOverAnHour, stoppedOverAnHour, playingMinutes, stoppedMinutes }

/// The body text for [ask]: "Du hörst seit über einer Stunde …" while it
/// plays, "Es lief über eine Stunde …" after it stopped; in the night
/// window below an hour with the whole minutes.
({AsleepBody key, int minutes}) asleepPromptBody(AsleepAsk ask, {required bool playing, required int listenedMs}) {
  final minutes = listenedMs ~/ 60000;
  final hour = ask == AsleepAsk.overAnHour;
  final key = playing
      ? (hour ? AsleepBody.playingOverAnHour : AsleepBody.playingMinutes)
      : (hour ? AsleepBody.stoppedOverAnHour : AsleepBody.stoppedMinutes);
  return (key: key, minutes: minutes);
}
