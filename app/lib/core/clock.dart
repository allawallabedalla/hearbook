/// Wall-clock abstraction so code that needs "now" can be driven by a fixed
/// or scripted clock in tests instead of the real `DateTime.now()`.
abstract class Clock {
  /// Current time in milliseconds since the Unix epoch.
  int nowMs();

  /// UTC offset of the device's local timezone, in minutes (matches the
  /// event field `tz_min`, docs/ARCHITEKTUR.md section 5).
  int tzOffsetMin();
}

class SystemClock implements Clock {
  const SystemClock();

  @override
  int nowMs() => DateTime.now().millisecondsSinceEpoch;

  @override
  int tzOffsetMin() => DateTime.now().timeZoneOffset.inMinutes;
}
