/// Whether device-local wall time [nowWallMs] (with UTC offset [tzMin]
/// minutes, matching the event field `tz_min`) falls in the night window
/// `[nightStartMin, nightEndMin)` (minutes since local midnight).
/// Mirrors domain/resolver.dart's private `_inNightWindow`, but as a
/// public, present-tense check: the Resolver asks "was this past event in
/// the window", this asks "is it the window right now" -- for the
/// handler's SLEEP_HINT on a media/system pause (docs/ARCHITEKTUR.md
/// section 9). It no longer switches the dark night view (decision E54);
/// that follows the display brightness, see [nextNightView].
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

/// The night view switches on below this display brightness (0..1)...
const double nightViewOnBelow = 0.30;

/// ...and off again only above this one, so a brightness hovering around
/// 30 % does not make the screen flicker between day and night.
const double nightViewOffAbove = 0.35;

/// docs/KONZEPT.md "Nachtmodus" (decision E54): the dark night view is on
/// while the display brightness is below 30 %, with hysteresis: it turns
/// on below [nightViewOnBelow], off above [nightViewOffAbove], and in
/// between keeps [current]. No brightness (unsupported platform, tests,
/// a failed read) means off.
bool nextNightView({required bool current, required double? brightness}) {
  if (brightness == null || brightness.isNaN) return false;
  if (brightness < nightViewOnBelow) return true;
  if (brightness > nightViewOffAbove) return false;
  return current;
}
