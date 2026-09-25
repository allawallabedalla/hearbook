import 'asleep_prompt.dart' show asleepPromptAfterMs, nightStretchSuspectMs;
import 'event.dart';
import 'manifest.dart';
import 'pause_reason.dart';
import 'position.dart';

/// Night window for section 7 rule 5 / section 9, minutes since local
/// midnight. Default 20:00-06:00 (docs/KONZEPT.md "Faden aufnehmen":
/// "Standard 20 bis 6 Uhr"), configurable in settings.
class ResolverSettings {
  final int nightStartMin;
  final int nightEndMin;

  const ResolverSettings({this.nightStartMin = 20 * 60, this.nightEndMin = 6 * 60});
}

const int sleepDistanceThresholdMs = 3 * 60000; // section 7 rule 5: >= 3 min
const int jumpThresholdMs = 2 * 60000; // section 7 rule 6 / invariant 6: > 2 min
const int historyLimit = 20; // section 7: "history", at most 20

/// Decision E84: in the night window, a lost connection (headphone battery
/// empty) after at least this long without an awake proof is suspected
/// like an unconscious pause -- except in the car.
const int nightRouteLostSuspectMs = 20 * 60000;

/// Resolver output, docs/ARCHITEKTUR.md section 7.
class BookState {
  final Position position;

  /// Global ms of [position] in the active manifest, or null when
  /// [needsConfirmation] is true because [position]'s `file_hash` is not
  /// part of the active manifest (rule 8).
  final int? globalMs;

  final Position lastAwake;

  /// Same value as [position] (see the file-level doc comment on why).
  final Position stop;

  final bool sleepSuspected;

  /// Newest first, at most [historyLimit] entries.
  final List<Position> history;

  final bool finished;
  final bool needsConfirmation;

  /// The winning session's own id (section 7 rule 2's `winningSessionId`),
  /// i.e. the session [position]/[lastAwake]/[stop] all come from. Not part
  /// of section 7's own `BookState` field list -- added in M6 (see decision
  /// E21 in docs/ARCHITEKTUR.md section 13) because section 9's
  /// health-data adjustment needs to read exactly this session's own
  /// HEARTBEAT events, and this was already computed here, just not
  /// exposed.
  final String sessionId;

  /// Whether an event of the winning session lies in the night window
  /// (rule 5's night check), for the player's offer and the learning
  /// (decision E84). False when unknown.
  final bool inNightWindow;

  /// The reason of the winning session's last PAUSE (decision E80), null
  /// without one (still playing, reached the book end, older events).
  final PauseReason? stopReason;

  const BookState({
    required this.position,
    required this.globalMs,
    required this.lastAwake,
    required this.stop,
    required this.sleepSuspected,
    required this.history,
    required this.finished,
    required this.needsConfirmation,
    required this.sessionId,
    this.inNightWindow = false,
    this.stopReason,
  });
}

bool _inNightWindow(Event e, ResolverSettings settings) {
  final localMinuteOfDay =
      ((e.wallMs + e.tzMin * 60000) ~/ 60000) % (24 * 60);
  final minute = localMinuteOfDay < 0 ? localMinuteOfDay + 24 * 60 : localMinuteOfDay;
  final start = settings.nightStartMin;
  final end = settings.nightEndMin;
  if (start == end) return true; // degenerate config: always "night"
  return start < end ? (minute >= start && minute < end) : (minute >= start || minute < end);
}

/// Decision E92: whether the winning session reached the end of the book
/// (its last FINISHED) at least [asleepPromptAfterMs] -- in the night
/// window [nightStretchSuspectMs] -- of the book after its last awake proof
/// before it (FINISHED itself excluded), and not in the car. The same rule
/// as "Eingeschlafen?" (domain/asleep_prompt.dart), measured in listening
/// distance like rule 5.
bool _endReachedAsleep(List<Event> sessionEvents, Manifest manifest, {required bool inNightWindow}) {
  final end = sessionEvents.lastIndexWhere((e) => e.type == EventType.finished);
  if (end < 0) return false;
  final finished = sessionEvents[end];
  if (finished.data['route'] == carRouteName) return false;
  Event? awakeBefore;
  for (final e in sessionEvents.take(end)) {
    if (e.isAwakeProof && e.type != EventType.finished) awakeBefore = e;
  }
  if (awakeBefore == null) return false;
  final from = manifest.globalMsFor(awakeBefore.position);
  final to = manifest.globalMsFor(finished.position);
  if (from == null || to == null) return false;
  final distance = to - from;
  return distance >= asleepPromptAfterMs || (inNightWindow && distance >= nightStretchSuspectMs);
}

/// Derives [BookState] from a book's events, its active manifest and the
/// night-window setting, per docs/ARCHITEKTUR.md section 7. Pure: the same
/// event set always yields the same state, independent of the order events
/// were received in (invariant 2 - state is a pure function of events).
///
/// Design notes for two points the rules leave implicit (see decision E11
/// in docs/ARCHITEKTUR.md section 13):
/// - `stop` is not given a rule of its own; it is computed identically to
///   `position` (both are "the position of the winning session's last
///   event") and used under a different name only because Faden-Suche
///   (section 8) and the sleep-window check (rule 5) read it as the
///   session's endpoint.
/// - Rule 6 ("springt ein Absicht-Event mehr als 2 Min von der vorherigen
///   Position weg") is scoped to the winning session's own event sequence:
///   the session's first event establishes the starting position with no
///   "previous" to jump from, so it never itself becomes a history entry.
///   A session-opening `RESUME` jumping back after Faden-Suche is not
///   double-counted here; section 8's own ladder ("Fruher") already covers
///   undoing that jump.
BookState resolve(
  List<Event> events,
  Manifest manifest, {
  ResolverSettings settings = const ResolverSettings(),
}) {
  if (events.isEmpty) {
    throw ArgumentError('resolve() requires at least one event');
  }

  // Rule 1: sort by (hlc.pt, hlc.c, device_id, event_id), drop duplicate
  // event_id (first occurrence in sorted order wins; duplicates are
  // expected to be byte-identical retransmissions per section 6).
  final sorted = [...events]..sort(compareEvents);
  final seen = <String>{};
  final deduped = <Event>[
    for (final e in sorted)
      if (seen.add(e.eventId)) e,
  ];

  // Rule 2: the last intent event (by the same order) decides the winning
  // session.
  Event? lastIntent;
  for (final e in deduped) {
    if (e.type.isIntent) lastIntent = e;
  }
  if (lastIntent == null) {
    throw ArgumentError(
      'resolve() requires at least one intent event (PLAY/SEEK/RESUME/UNDO)',
    );
  }
  final winningSessionId = lastIntent.sessionId;
  final sessionEvents = [
    for (final e in deduped)
      if (e.sessionId == winningSessionId) e,
  ]; // already sorted, filtering preserves order

  // Rule 3: position = position of the winning session's last event (of
  // any type). Events of other sessions never move it, however late they
  // arrive relative to this one.
  final position = sessionEvents.last.position;
  final stop = position; // see doc comment above

  final inNightWindow = sessionEvents.any((e) => _inNightWindow(e, settings));

  // Decision E92 (invariant 5): the end of the book reached after as long
  // without an awake proof as "Eingeschlafen?" asks for (60 min, 20 min in
  // the night window, never in the car) is no awake proof -- the listener
  // most likely slept through it. Then FINISHED neither moves last_awake
  // nor counts as finished, and sleep is suspected.
  final endAsleep = _endReachedAsleep(sessionEvents, manifest, inNightWindow: inNightWindow);

  // Rule 4: last_awake = position of the winning session's last
  // awake-proof event. lastIntent is itself always awake-proof, so this is
  // never left unset.
  var lastAwake = lastIntent.position;
  for (final e in sessionEvents) {
    if (e.isAwakeProof && !(endAsleep && e.type == EventType.finished)) lastAwake = e.position;
  }

  // Rule 8: distances are computed over the active manifest's global ms;
  // any lookup miss (file_hash not in the active manifest, e.g. an
  // unconfirmed reorder) sets needs_confirmation without altering the
  // position itself.
  var needsConfirmation = false;
  int? globalMsOf(Position p) {
    final v = manifest.globalMsFor(p);
    if (v == null) needsConfirmation = true;
    return v;
  }

  final positionGlobalMs = globalMsOf(position);
  final lastAwakeGlobalMs = globalMsOf(lastAwake);
  final stopGlobalMs = positionGlobalMs; // stop == position

  // Rule 6: history of positions superseded by an intent event jumping
  // more than jumpThresholdMs away, within the winning session only (see
  // doc comment above). Built oldest-to-newest, then capped and reversed.
  final chronological = <Position>[];
  var running = sessionEvents.first.position;
  var runningGlobalMs = globalMsOf(running);
  for (final e in sessionEvents.skip(1)) {
    if (e.type.isIntent) {
      final newGlobalMs = globalMsOf(e.position);
      if (runningGlobalMs != null && newGlobalMs != null) {
        if ((newGlobalMs - runningGlobalMs).abs() > jumpThresholdMs) {
          chronological.add(running);
        }
      }
      // else: distance undeterminable (missing file_hash); needs_confirmation
      // is already set above, this pair is simply not judged a jump.
    }
    running = e.position;
    runningGlobalMs = globalMsOf(e.position);
  }
  final cappedChronological = chronological.length > historyLimit
      ? chronological.sublist(chronological.length - historyLimit)
      : chronological;
  final history = cappedChronological.reversed.toList();

  // Rule 5: sleep_suspected.
  var sleepDistanceOk = false;
  if (lastAwakeGlobalMs != null && stopGlobalMs != null) {
    sleepDistanceOk = (stopGlobalMs - lastAwakeGlobalMs).abs() >= sleepDistanceThresholdMs;
  }
  final containsSleepHint = sessionEvents.any((e) => e.type == EventType.sleepHint);
  final stopEvent = sessionEvents.last;
  final resumeAfterStop =
      deduped.any((e) => e.type == EventType.resume && compareEvents(e, stopEvent) > 0);
  // Decision E80: a session that stopped because the connection was lost
  // (car left, headphones gone), because of an interruption (a call) or in
  // the car is never suspected -- not even in the night window.
  Event? stopPause;
  for (final e in sessionEvents) {
    if (e.type == EventType.pause) stopPause = e;
  }
  // Decision E84: in the night window a lost connection after 20 min
  // without an awake proof (the headphones' battery died while asleep)
  // still counts; the car never does.
  final routeLostAsleep = stopPause != null &&
      pauseReasonOf(stopPause) == PauseReason.routeLost &&
      stopPause.data['route'] != carRouteName &&
      inNightWindow &&
      lastAwakeGlobalMs != null &&
      stopGlobalMs != null &&
      stopGlobalMs - lastAwakeGlobalMs >= nightRouteLostSuspectMs;
  final ruledOut = stopPause != null && rulesOutSleep(stopPause) && !routeLostAsleep;
  final sleepSuspected =
      sleepDistanceOk && (inNightWindow || containsSleepHint || endAsleep) && !resumeAfterStop && !ruledOut;

  // Rule 7: finished.
  final containsFinished = sessionEvents.any((e) => e.type == EventType.finished);
  final finished = containsFinished && !sleepSuspected;

  return BookState(
    position: position,
    globalMs: positionGlobalMs,
    lastAwake: lastAwake,
    stop: stop,
    sleepSuspected: sleepSuspected,
    history: history,
    finished: finished,
    needsConfirmation: needsConfirmation,
    sessionId: winningSessionId,
    inNightWindow: inNightWindow,
    stopReason: stopPause == null ? null : pauseReasonOf(stopPause),
  );
}
