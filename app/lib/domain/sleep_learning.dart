/// What Faden learns from its own searches ("Faden-Suche lernt mit",
/// decisions E78, E79, E81, E82). Pure, no I/O: data/sleep_log.dart stores
/// the records locally (never an event, never synced, invariant 7 in
/// spirit -- they are sleep data too).
///
/// A [SleepOnsetRecord] is written after a Faden search found a passage the
/// listener recognised: the found position mapped back to wall-clock time
/// through the session's HEARTBEAT events (domain/sleep_onset.dart's
/// `wallClockAtPosition`). It is the last passage remembered, not a measured
/// moment of falling asleep.
library;

import 'dart:convert';
import 'dart:math' show max;

/// At most this many onsets are stored; the oldest go first.
const int maxStoredOnsets = 60;

/// Learning starts with this many onsets (E78, E81).
const int minOnsetsForLearning = 5;

/// The learned prior uses only the most recent onsets.
const int learningWindow = 30;

/// Padding around the suggested night window, and its grid (E81).
const int nightWindowPaddingMin = 30;
const int nightWindowGridMin = 15;

/// A suggestion longer than this is too scattered to be useful.
const int maxSuggestedWindowMin = 12 * 60;

/// "Im Bett" is only written for a plausible night (E82).
const int minInBedMs = 30 * 60000;
const int maxInBedMs = 16 * 3600000;

class SleepOnsetRecord {
  /// The session the listener fell asleep in; one record per session.
  final String sessionId;
  final String bookId;

  /// The recognised passage, as wall-clock time (ms since epoch).
  final int onsetWallMs;

  /// The device's UTC offset at that time, for the local date and clock.
  final int tzMin;

  /// Listening time (global ms of the book) from the last awake proof to
  /// the recognised passage.
  final int listenMs;

  /// The first awake proof after the session stopped (any book): when the
  /// listener picked the phone up again. Null when unknown.
  final int? wakeWallMs;

  /// Whether "Im Bett" was written to Health for this night (E82).
  final bool healthWritten;

  const SleepOnsetRecord({
    required this.sessionId,
    required this.bookId,
    required this.onsetWallMs,
    required this.tzMin,
    required this.listenMs,
    this.wakeWallMs,
    this.healthWritten = false,
  });

  DateTime get _local => DateTime.fromMillisecondsSinceEpoch(onsetWallMs + tzMin * 60000, isUtc: true);

  /// `YYYY-MM-DD` of the onset, local to the device then.
  String get localDate {
    final d = _local;
    return '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';
  }

  /// Minutes since local midnight of the onset.
  int get localMinuteOfDay {
    final d = _local;
    return d.hour * 60 + d.minute;
  }

  /// Weekday of the onset, local (1 = Monday ... 7 = Sunday).
  int get localWeekday => _local.weekday;

  SleepOnsetRecord copyWith({int? listenMs, int? onsetWallMs, int? wakeWallMs, bool? healthWritten}) =>
      SleepOnsetRecord(
        sessionId: sessionId,
        bookId: bookId,
        onsetWallMs: onsetWallMs ?? this.onsetWallMs,
        tzMin: tzMin,
        listenMs: listenMs ?? this.listenMs,
        wakeWallMs: wakeWallMs ?? this.wakeWallMs,
        healthWritten: healthWritten ?? this.healthWritten,
      );

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'book_id': bookId,
        'onset_wall_ms': onsetWallMs,
        'tz_min': tzMin,
        'date': localDate,
        'listen_ms': listenMs,
        if (wakeWallMs != null) 'wake_wall_ms': wakeWallMs,
        'health_written': healthWritten,
      };

  factory SleepOnsetRecord.fromJson(Map<String, dynamic> json) => SleepOnsetRecord(
        sessionId: json['session_id'] as String,
        bookId: json['book_id'] as String,
        onsetWallMs: json['onset_wall_ms'] as int,
        tzMin: json['tz_min'] as int,
        listenMs: json['listen_ms'] as int,
        wakeWallMs: json['wake_wall_ms'] as int?,
        healthWritten: json['health_written'] == true,
      );
}

String _two(int v) => v.toString().padLeft(2, '0');

/// Decodes the stored list; broken entries (or a broken value) are skipped.
List<SleepOnsetRecord> decodeOnsets(String? stored) {
  if (stored == null || stored.isEmpty) return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(stored);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];
  final out = <SleepOnsetRecord>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    try {
      out.add(SleepOnsetRecord.fromJson(Map<String, dynamic>.from(item)));
    } catch (_) {
      // Skipped: one broken entry must not cost the others.
    }
  }
  out.sort((a, b) => a.onsetWallMs.compareTo(b.onsetWallMs));
  return out;
}

String encodeOnsets(List<SleepOnsetRecord> onsets) => jsonEncode([for (final o in onsets) o.toJson()]);

/// [onsets] with [record] added or replacing the one of the same session,
/// oldest first, at most [maxStoredOnsets].
List<SleepOnsetRecord> upsertOnset(List<SleepOnsetRecord> onsets, SleepOnsetRecord record) {
  final out = [
    for (final o in onsets)
      if (o.sessionId != record.sessionId) o,
    record,
  ]..sort((a, b) => a.onsetWallMs.compareTo(b.onsetWallMs));
  return out.length > maxStoredOnsets ? out.sublist(out.length - maxStoredOnsets) : out;
}

List<SleepOnsetRecord> removeOnset(List<SleepOnsetRecord> onsets, String sessionId) => [
      for (final o in onsets)
        if (o.sessionId != sessionId) o,
    ];

/// The median listening time from the last awake proof to the onset over
/// the most recent [learningWindow] onsets, from [minOnsetsForLearning]
/// on (E78); otherwise null.
int? learnedListenMs(List<SleepOnsetRecord> onsets) {
  if (onsets.length < minOnsetsForLearning) return null;
  final byTime = [...onsets]..sort((a, b) => a.onsetWallMs.compareTo(b.onsetWallMs));
  final recent = byTime.length > learningWindow ? byTime.sublist(byTime.length - learningWindow) : byTime;
  final values = [for (final o in recent) o.listenMs]..sort();
  final mid = values.length ~/ 2;
  if (values.length.isOdd) return values[mid];
  return ((values[mid - 1] + values[mid]) / 2).round();
}

/// The first bisection point for a search over `(lo, hi)` from what Faden
/// learned (E78): `lo` plus the median listening time. Null when there is
/// too little data or the point is not strictly inside `(lo, hi)` -- it is
/// only ever a probe position, never a new `lo` (invariant 9).
int? learnedPrior({required int lo, required int hi, required List<SleepOnsetRecord> onsets}) {
  final listen = learnedListenMs(onsets);
  if (listen == null) return null;
  final prior = lo + listen;
  return (lo < prior && prior < hi) ? prior : null;
}

/// A suggested night window in minutes since local midnight (may cross
/// midnight: [startMin] > [endMin]).
class SuggestedNightWindow {
  final int startMin;
  final int endMin;

  const SuggestedNightWindow({required this.startMin, required this.endMin});
}

/// The night window suggested from the onsets' local clock times (E81): the
/// 10th to 90th percentile, padded by 30 min on both sides, start rounded
/// down and end rounded up to 15 min. Clock times are circular: the list is
/// cut at the largest gap between neighbouring times, so onsets around
/// midnight stay together. Null with fewer than [minOnsetsForLearning]
/// onsets or when the result would be longer than 12 h.
SuggestedNightWindow? suggestNightWindow(List<SleepOnsetRecord> onsets) {
  if (onsets.length < minOnsetsForLearning) return null;
  const day = 24 * 60;
  final minutes = [for (final o in onsets) o.localMinuteOfDay]..sort();

  // Cut the circle at the largest gap (the wrap-around gap included).
  var cut = 0; // index of the first value after the largest gap
  var largest = minutes.first + day - minutes.last;
  for (var i = 1; i < minutes.length; i++) {
    final gap = minutes[i] - minutes[i - 1];
    if (gap > largest) {
      largest = gap;
      cut = i;
    }
  }
  final unrolled = [
    for (var i = 0; i < minutes.length; i++)
      i < cut ? minutes[i] + day : minutes[i],
  ]..sort();

  double percentile(double q) {
    final pos = q * (unrolled.length - 1);
    final lower = pos.floor();
    final upper = pos.ceil();
    return unrolled[lower] + (unrolled[upper] - unrolled[lower]) * (pos - lower);
  }

  final start = ((percentile(0.1) - nightWindowPaddingMin) / nightWindowGridMin).floor() * nightWindowGridMin;
  final end = ((percentile(0.9) + nightWindowPaddingMin) / nightWindowGridMin).ceil() * nightWindowGridMin;
  if (end - start > maxSuggestedWindowMin) return null;
  return SuggestedNightWindow(startMin: start % day, endMin: end % day);
}

/// The night window after taking over [suggestion] (decision E90): the
/// smallest window that contains both the current one and the suggestion,
/// so taking it over only ever widens the window (a narrower suggestion
/// would stop Faden from suspecting sleep where it does now). Null when
/// the suggestion adds nothing (it lies inside the current window) or the
/// current window is the whole day.
SuggestedNightWindow? widenNightWindow({
  required int currentStartMin,
  required int currentEndMin,
  required SuggestedNightWindow suggestion,
}) {
  const day = 24 * 60;
  int len(int s, int e) => ((e - s) % day + day) % day;
  final curLen = len(currentStartMin, currentEndMin);
  if (curLen == 0) return null; // start == end: always night
  final sugLen = len(suggestion.startMin, suggestion.endMin);
  if (sugLen == 0) return null;
  // Either span starts at one window's start and runs clockwise until
  // both are covered; the shorter one wins.
  final fromCurrent = max(curLen, len(currentStartMin, suggestion.startMin) + sugLen);
  final fromSuggestion = max(sugLen, len(suggestion.startMin, currentStartMin) + curLen);
  final int start;
  final int length;
  if (fromCurrent <= fromSuggestion) {
    start = currentStartMin;
    length = fromCurrent;
  } else {
    start = suggestion.startMin;
    length = fromSuggestion;
  }
  if (length >= day) return null;
  final end = (start + length) % day;
  if (start == currentStartMin && end == currentEndMin) return null;
  return SuggestedNightWindow(startMin: start, endMin: end);
}

/// "Im Bett" for Health (E82): from the onset to the first awake proof
/// after the session stopped. None without a wake time, when shorter than
/// 30 min (not a night) or longer than 16 h (the phone lay untouched for a
/// day; the wake time says nothing about the night then).
({int start, int end})? inBedInterval(SleepOnsetRecord onset) {
  final wake = onset.wakeWallMs;
  if (wake == null) return null;
  final length = wake - onset.onsetWallMs;
  if (length < minInBedMs || length > maxInBedMs) return null;
  return (start: onset.onsetWallMs, end: wake);
}
