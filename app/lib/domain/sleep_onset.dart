/// Local sleep-onset adjustment for Faden-Suche (docs/ARCHITEKTUR.md
/// section 9, M6): "Beim Start der Faden-Suche liest die App lokal den
/// Schlafbeginn T im Zeitraum der Session und rechnet T über die
/// HEARTBEAT-Events (Wanduhr -> Position) in globale ms um. Dann gilt: hi =
/// min(stop, pos(T + 5 Min)), prior = pos(T - 10 Min) falls > lo. lo wird
/// nie aus Gesundheitsdaten gesetzt (Invariante 9)."
///
/// Pure: no `dart:io`, no platform channel, nothing journaled -- CLAUDE.md
/// invariant 7 ("Gesundheitsdaten verlassen nie das Gerät und erzeugen
/// keine Events") is a property of how the *caller* uses this module's
/// return value (in-memory, for one `fadenSuche()` call, then discarded),
/// which is exactly what this module being pure and side-effect-free makes
/// possible to verify. See data/sleep_data_source.dart for where the
/// actual (I/O-bound) health-data reading happens, and
/// ui/providers.dart's `PlayerSessionController.sleepOnsetAdjustment` for
/// the only place the two are wired together.
library;

const int hiLookaheadMs = 5 * 60000; // section 9: "T + 5 Min"
const int priorLookbehindMs = 10 * 60000; // section 9: "T - 10 Min"

/// One HEARTBEAT event of the winning session, already converted from
/// `(file_hash, offset_ms)` to global ms (domain/manifest.dart's
/// `globalMsFor`) -- i.e. exactly the "(Wanduhr, Position)" pair section 9
/// means by "HEARTBEAT-Events (Wanduhr -> Position)".
class HeartbeatSample {
  final int wallMs;
  final int globalMs;

  const HeartbeatSample({required this.wallMs, required this.globalMs});
}

/// The result of applying one local sleep-onset reading to a Faden-Suche
/// window. Never smaller than a no-op: when the reading cannot be used at
/// all, [hi] is the original `hi` and [prior] is null, i.e. exactly M5's
/// pre-M6 behaviour.
class SleepPriorAdjustment {
  /// `min(stop, pos(T + 5 Min))`.
  final int hi;

  /// `pos(T - 10 Min)`, only when that is `> lo` (section 9) and also
  /// strictly inside the resulting `(lo, hi)` window -- section 9 does not
  /// spell out the second half, but domain/faden_search.dart's `prior` is
  /// only ever read as the first bisection midpoint of a search that
  /// assumes `lo < prior < hi` (see docs/ARCHITEKTUR.md section 13, this
  /// decision's entry); a reading that fails it is discarded exactly like
  /// one that fails the plain `> lo` check, not clamped.
  final int? prior;

  const SleepPriorAdjustment({required this.hi, this.prior});
}

/// Maps [wallMs] to global ms via [heartbeats] (the winning session's own
/// HEARTBEAT events, in any order): linear interpolation between the two
/// heartbeats bracketing [wallMs]. Outside the heartbeats' own range, the
/// nearest endpoint's global ms is used unchanged -- a heartbeat only
/// exists while the main player is actually playing (invariant 3: "Während
/// der Wiedergabe: Herzschlag alle 5 s"), so no heartbeat past one end
/// means playback had already stopped there, and position did not keep
/// advancing past that point. Returns null only when [heartbeats] is
/// empty (nothing to convert against at all).
int? positionAtWallClock(List<HeartbeatSample> heartbeats, int wallMs) {
  if (heartbeats.isEmpty) return null;
  final sorted = [...heartbeats]..sort((a, b) => a.wallMs.compareTo(b.wallMs));
  if (wallMs <= sorted.first.wallMs) return sorted.first.globalMs;
  if (wallMs >= sorted.last.wallMs) return sorted.last.globalMs;
  for (var i = 0; i < sorted.length - 1; i++) {
    final a = sorted[i];
    final b = sorted[i + 1];
    if (wallMs < a.wallMs || wallMs > b.wallMs) continue;
    if (b.wallMs == a.wallMs) return a.globalMs; // duplicate wallMs, avoid /0
    final frac = (wallMs - a.wallMs) / (b.wallMs - a.wallMs);
    return a.globalMs + ((b.globalMs - a.globalMs) * frac).round();
  }
  return sorted.last.globalMs; // unreachable given the two clamps above
}

/// Section 9's full `hi`/`prior` rule. [lo]/[hi] are the Resolver's own
/// `last_awake`/`stop` in global ms -- read only to validate the result,
/// never written (invariant 9: `lo` never moves from health data, enforced
/// simply by this function never taking a way to change it).
/// [sleepOnsetWallMs] is the local health reading (`T`, wall-clock ms).
/// [sessionMinWallMs]/[sessionMaxWallMs] bound "der Zeitraum der Session"
/// (the winning session's own event wall-clock range); a reading outside
/// that range is not used at all. [heartbeats] are that same session's
/// HEARTBEAT events, already converted to global ms.
SleepPriorAdjustment adjustForSleepOnset({
  required int lo,
  required int hi,
  required int sleepOnsetWallMs,
  required int sessionMinWallMs,
  required int sessionMaxWallMs,
  required List<HeartbeatSample> heartbeats,
}) {
  if (sleepOnsetWallMs < sessionMinWallMs || sleepOnsetWallMs > sessionMaxWallMs) {
    return SleepPriorAdjustment(hi: hi);
  }

  final posAtHiLookahead = positionAtWallClock(heartbeats, sleepOnsetWallMs + hiLookaheadMs);
  if (posAtHiLookahead == null) {
    return SleepPriorAdjustment(hi: hi); // no HEARTBEAT in range at all
  }
  final newHi = posAtHiLookahead < hi ? posAtHiLookahead : hi; // min(stop, pos(T + 5 Min))
  if (newHi <= lo) {
    // A reading placing "T + 5 Min" at or before last_awake is inconsistent
    // with the Resolver's own lo (health data is only ever a local hint,
    // decision E6) -- discarded rather than shrinking the window to
    // nothing or, worse, below lo.
    return SleepPriorAdjustment(hi: hi);
  }

  final posAtPriorLookbehind = positionAtWallClock(heartbeats, sleepOnsetWallMs - priorLookbehindMs);
  final int? prior =
      (posAtPriorLookbehind != null && posAtPriorLookbehind > lo && posAtPriorLookbehind < newHi)
          ? posAtPriorLookbehind
          : null;

  return SleepPriorAdjustment(hi: newHi, prior: prior);
}

/// Fastest plausible playback between two heartbeats (the app's top speed
/// is 2x), with slack for timer jitter: a larger position step between two
/// samples is a seek, not playback, and is never interpolated across.
const double _maxPlaybackRate = 3.0;
const int _rateSlackMs = 2000;

/// How far past the outermost sample a position may lie and still be
/// mapped (at 1x): the first heartbeat comes up to 5 s after PLAY.
const int _edgeToleranceMs = 10000;

/// The inverse of [positionAtWallClock] (decision E79): the wall-clock time
/// at which playback passed [globalMs], from the session's own HEARTBEAT
/// samples. Linear interpolation between the two samples around it, only
/// where playback actually ran between them (never across a seek). A
/// position heard twice (a seek back) maps to the later time, when it was
/// last heard. Just outside the samples (the first heartbeat comes 5 s
/// after PLAY) it is extrapolated at 1x for up to 10 s; otherwise, or with
/// no samples at all, null.
int? wallClockAtPosition(List<HeartbeatSample> heartbeats, int globalMs) {
  if (heartbeats.isEmpty) return null;
  final sorted = [...heartbeats]..sort((a, b) => a.wallMs.compareTo(b.wallMs));
  for (var i = sorted.length - 2; i >= 0; i--) {
    final a = sorted[i];
    final b = sorted[i + 1];
    if (globalMs < a.globalMs || globalMs > b.globalMs) continue;
    final dg = b.globalMs - a.globalMs;
    final dw = b.wallMs - a.wallMs;
    if (dg > dw * _maxPlaybackRate + _rateSlackMs) continue; // a seek, not playback
    if (dg == 0) return a.wallMs;
    return a.wallMs + ((globalMs - a.globalMs) * dw / dg).round();
  }
  HeartbeatSample? nearest;
  for (final s in sorted.reversed) {
    final d = (s.globalMs - globalMs).abs();
    if (d > _edgeToleranceMs) continue;
    if (nearest == null || d < (nearest.globalMs - globalMs).abs()) nearest = s;
  }
  if (nearest == null) return null;
  return nearest.wallMs + (globalMs - nearest.globalMs);
}
