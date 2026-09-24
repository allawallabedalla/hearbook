/// Automatic rewind when playback resumes after a pause (decision E32 in
/// docs/ARCHITEKTUR.md section 13): the longer the pause, the more of the
/// last sentence the listener has forgotten. Pure, no I/O.
///
/// | pause       | rewind |
/// |-------------|--------|
/// | < 10 s      | 0      |
/// | >= 10 s     | 3 s    |
/// | >= 5 min    | 10 s   |
/// | >= 1 h      | 30 s   |
///
/// Every value is far below the 2 min jump threshold (invariant 6), so the
/// rewind is simply part of the PLAY event's position, never a separate
/// jump and never an undo hint.
int autoRewindMs(int pausedForMs) {
  if (pausedForMs >= 60 * 60 * 1000) return 30 * 1000;
  if (pausedForMs >= 5 * 60 * 1000) return 10 * 1000;
  if (pausedForMs >= 10 * 1000) return 3 * 1000;
  return 0;
}

/// The global-ms position playback should resume at, given where it
/// stands ([globalMs]) and how long it was paused ([pausedForMs], null when
/// unknown -- then nothing is rewound). Never before the start of the book.
int autoRewoundGlobalMs({required int globalMs, required int? pausedForMs}) {
  if (pausedForMs == null || pausedForMs <= 0) return globalMs;
  final target = globalMs - autoRewindMs(pausedForMs);
  return target < 0 ? 0 : target;
}
