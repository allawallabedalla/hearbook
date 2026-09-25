/// Why playback paused (decision E80), recorded in the PAUSE event's
/// `data` (`{"reason": "route_lost"}`, plus `"route": "car"` while CarPlay
/// is the output). Pure, no I/O.
///
/// | reason         | when                                               | SLEEP_HINT |
/// |----------------|----------------------------------------------------|------------|
/// | `conscious`    | the on-screen button, a book switch                | no         |
/// | `unconscious`  | media button or system (AirPods sleep detection,   | yes, at any|
/// |                | lock screen, headphone squeeze)                    | time of day|
/// | `route_lost`   | the output went away: headphones unplugged,        | no         |
/// |                | Bluetooth/CarPlay disconnected ("becoming noisy")  |            |
/// | `interruption` | a call, Siri, an alarm                             | no         |
/// | `timer`        | the sleep timer ran out                            | yes        |
/// | `error`        | a playback error stopped it (E39)                  | no         |
///
/// In the car (CarPlay) no pause writes SLEEP_HINT, and the Resolver never
/// suspects sleep for a session that ended with a lost connection, an
/// interruption or in the car ([rulesOutSleep]).
library;

import 'event.dart';

enum PauseReason {
  conscious('conscious'),
  unconscious('unconscious'),
  routeLost('route_lost'),
  interruption('interruption'),
  timer('timer'),
  error('error');

  final String wireName;

  const PauseReason(this.wireName);

  /// Null for a missing or unknown value (events written before E80).
  static PauseReason? fromWire(Object? wireName) {
    for (final r in values) {
      if (r.wireName == wireName) return r;
    }
    return null;
  }
}

/// The value of `data.route` while CarPlay is the audio output.
const String carRouteName = 'car';

/// The reason a pause from [source] has when nothing more specific is
/// known: the on-screen button is conscious; a media button or the system
/// (from here indistinguishable, section 9) is unconscious; the sleep
/// timer is its own reason.
PauseReason defaultPauseReason(EventSource source) => switch (source) {
      EventSource.ui || EventSource.faden => PauseReason.conscious,
      EventSource.mediaButton || EventSource.system => PauseReason.unconscious,
      EventSource.timer => PauseReason.timer,
    };

/// Whether a pause for [reason] also writes `SLEEP_HINT` (section 9). An
/// unconscious pause does at any time of day (it used to only in the night
/// window), the sleep timer always; nothing in the car ([carRoute]) except
/// the timer, whose hint the Resolver ignores there anyway ([rulesOutSleep]).
bool writesSleepHint(PauseReason reason, {required bool carRoute}) => switch (reason) {
      PauseReason.timer => true,
      PauseReason.unconscious => !carRoute,
      _ => false,
    };

/// The PAUSE event's `data` for [reason].
Map<String, dynamic> pauseData(PauseReason reason, {required bool carRoute}) => {
      'reason': reason.wireName,
      if (carRoute) 'route': carRouteName,
    };

/// The recorded reason of a PAUSE event, null for any other event and for
/// PAUSE events without one.
PauseReason? pauseReasonOf(Event e) {
  if (e.type != EventType.pause) return null;
  return PauseReason.fromWire(e.data['reason']);
}

/// Section 7 rule 5: a session that stopped with this PAUSE is never
/// suspected of sleep -- the connection was lost (the car was left, the
/// headphones went into the case), a call came in, or it played in the car.
bool rulesOutSleep(Event e) {
  if (e.type != EventType.pause) return false;
  final reason = pauseReasonOf(e);
  return reason == PauseReason.routeLost ||
      reason == PauseReason.interruption ||
      e.data['route'] == carRouteName;
}
