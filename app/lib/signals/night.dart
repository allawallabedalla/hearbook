import 'dart:async';

/// Whether device-local wall time [nowWallMs] (with UTC offset [tzMin]
/// minutes, matching the event field `tz_min`) falls in the night window
/// `[nightStartMin, nightEndMin)` (minutes since local midnight).
/// Mirrors domain/resolver.dart's private `_inNightWindow`, but as a
/// public, present-tense check: the Resolver asks "was this past event in
/// the window", this asks "is it the window right now" for the UI
/// (docs/KONZEPT.md "Nachtmodus": "Aktiv im Nachtfenster ...").
bool isInNightWindow({
  required int nowWallMs,
  required int tzMin,
  required int nightStartMin,
  required int nightEndMin,
}) {
  final localMinuteOfDay = ((nowWallMs + tzMin * 60000) ~/ 60000) % (24 * 60);
  final minute = localMinuteOfDay < 0 ? localMinuteOfDay + 24 * 60 : localMinuteOfDay;
  if (nightStartMin == nightEndMin) return true; // degenerate config: always "night"
  return nightStartMin < nightEndMin
      ? (minute >= nightStartMin && minute < nightEndMin)
      : (minute >= nightStartMin || minute < nightEndMin);
}

/// docs/KONZEPT.md "Nachtmodus": "Aktiv im Nachtfenster oder bei laufendem
/// Sleep-Timer." Night mode is a UI/behaviour choice the app makes, never
/// the OS "dark mode" setting.
bool isNightModeActive({required bool inNightWindow, required bool sleepTimerRunning}) =>
    inNightWindow || sleepTimerRunning;

/// Screen-button lock during night mode (docs/KONZEPT.md "Nachtmodus"):
/// "Nach 10 s ohne Berührung sind die Bildschirmtasten gesperrt; entsperren
/// durch 1 s Halten. Kopfhörertasten funktionieren immer." The last part
/// means this controller only ever gates on-screen controls -- media-button
/// handling (audio/handler.dart) never asks it anything.
class ScreenLockController {
  final Duration idleTimeout;
  final Duration holdToUnlock;

  Timer? _idleTimer;
  Timer? _holdTimer;
  bool _locked = false;

  final StreamController<bool> _lockedController = StreamController<bool>.broadcast();

  ScreenLockController({
    this.idleTimeout = const Duration(seconds: 10),
    this.holdToUnlock = const Duration(seconds: 1),
  }) {
    _resetIdleTimer();
  }

  bool get locked => _locked;

  /// Emits the new [locked] value on every lock/unlock transition.
  Stream<bool> get lockedStream => _lockedController.stream;

  /// Call on any touch of the (unlocked) screen: postpones the lock.
  /// A no-op while already locked -- only [startUnlockHold] can unlock.
  void onInteraction() {
    if (_locked) return;
    _resetIdleTimer();
  }

  /// Call when a long-press begins on the (locked) screen. If held for
  /// [holdToUnlock] without [cancelUnlockHold], the screen unlocks.
  void startUnlockHold() {
    if (!_locked) return;
    _holdTimer?.cancel();
    _holdTimer = Timer(holdToUnlock, _unlock);
  }

  /// Call when a long-press is released or interrupted before completing.
  void cancelUnlockHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  void _resetIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(idleTimeout, _lock);
  }

  void _lock() {
    if (_locked) return;
    _locked = true;
    _lockedController.add(true);
  }

  void _unlock() {
    _locked = false;
    _lockedController.add(false);
    _resetIdleTimer();
  }

  void dispose() {
    _idleTimer?.cancel();
    _holdTimer?.cancel();
    unawaited(_lockedController.close());
  }
}
