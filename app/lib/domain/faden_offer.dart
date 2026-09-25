/// How the player offers the Faden search (decision E86). Pure, no I/O.
///
/// At night and after the sleep timer, falling asleep is the likely cause
/// of a stop: "Faden aufnehmen" is the main button, and a play from the
/// lock screen or the headphones starts the search too. By day without a
/// timer (AirPods taken out, the lock screen) it is more likely a pause:
/// the main button stays "Weiterhören", with "Eingeschlafen? Stelle
/// suchen" underneath.
library;

import 'asleep_prompt.dart';
import 'pause_reason.dart';
import 'resolver.dart';

enum FadenOffer {
  /// No sleep suspected: the ordinary player.
  none,

  /// "Faden aufnehmen" as the main button, "Weiter, wo es anhielt" below.
  primary,

  /// "Weiterhören" as the main button, "Eingeschlafen? Stelle suchen" below.
  secondary,
}

/// Whether a session in the night window, or one the sleep timer ended,
/// counts as a night (the offer, and what the search learns from).
bool _night({required bool inNightWindow, required PauseReason? stopReason}) =>
    inNightWindow || stopReason == PauseReason.timer;

FadenOffer fadenOfferFor(BookState state) {
  if (!state.sleepSuspected) return FadenOffer.none;
  return _night(inNightWindow: state.inNightWindow, stopReason: state.stopReason)
      ? FadenOffer.primary
      : FadenOffer.secondary;
}

/// Whether a play from the lock screen, Control Center or the headphones
/// starts the Faden search instead of playing (the audit's finding 1):
/// where the search is the main button, or where "Eingeschlafen?" would
/// ask; never with CarPlay as the output.
bool searchesOnRemotePlay({required FadenOffer offer, required AsleepAsk asleepAsk, required bool carRoute}) {
  if (carRoute) return false;
  return offer == FadenOffer.primary || asleepAsk != AsleepAsk.no;
}

/// Whether a search's result is remembered as a sleep onset (E79) and may
/// go to Health (E82): only for a night -- a session in the night window
/// or one the sleep timer ended. A pause by day says little about when
/// the listener falls asleep.
bool learnsFromSession({required bool inNightWindow, required PauseReason? stopReason}) =>
    _night(inNightWindow: inNightWindow, stopReason: stopReason);
