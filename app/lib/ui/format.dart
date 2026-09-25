import '../l10n/strings.dart';

/// Pure display formatters shared by the player, the mini player, the
/// details sheet, the library and the settings. No widgets, so they are
/// unit-tested directly (test/ui/format_test.dart).

/// Remaining listening time at minute level (decision E44): "3 Std. 45 Min.",
/// "2 Std.", "12 Min.". Rounds up, so the last seconds of a book still read
/// "1 Min." instead of "0 Min.". With [coarse] (library rows), an hour or
/// more shows whole hours only: "5 Std.".
String formatRemaining(int ms, {bool coarse = false}) {
  if (ms <= 0) return AppStrings.durationMinutes(0);
  const minuteMs = 60 * 1000;
  const hourMs = 60 * minuteMs;
  if (coarse && ms >= hourMs) {
    return AppStrings.durationHours((ms / hourMs).round());
  }
  final minutes = (ms + minuteMs - 1) ~/ minuteMs;
  if (minutes < 60) return AppStrings.durationMinutes(minutes);
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return m == 0 ? AppStrings.durationHours(h) : AppStrings.durationHoursMinutes(h, m);
}

/// "12:34" or "3:04:05" for a play time in milliseconds (scrubber labels,
/// chapter durations, the sleep-timer countdown).
String formatClock(int ms) {
  final totalSeconds = (ms < 0 ? 0 : ms) ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(hours > 0 ? 2 : 1, '0');
  final ss = seconds.toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$mm:$ss' : '$mm:$ss';
}

/// German speed label: "1×", "1,25×", "0,75×", "1,5×".
String formatSpeed(double speed) {
  var text = speed.toStringAsFixed(2);
  text = text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  return AppStrings.speedLabel(text.replaceAll('.', ','));
}

/// Storage size in decimal units, as iOS shows them: "340 MB", "1,2 GB".
String formatBytes(int bytes) {
  const mb = 1000 * 1000;
  const gb = 1000 * mb;
  if (bytes < gb) {
    final value = bytes <= 0 ? 0 : (bytes / mb).round().clamp(1, 999);
    return AppStrings.sizeMegabytes('$value');
  }
  final value = bytes / gb;
  final text = value >= 100 ? value.round().toString() : value.toStringAsFixed(1).replaceAll('.', ',');
  return AppStrings.sizeGigabytes(text);
}

/// What a running download still has to fetch, for "noch 240 MB" (decision
/// E62). Decimal units like [formatBytes], but coarser, since it is an
/// estimate that changes while it runs, and rounded up so a rest never
/// reads "0 MB": whole MB below 100 MB, steps of 10 MB up to 1 GB, then
/// GB with one decimal (German comma) below 10 GB and whole GB above.
String formatRemainingBytes(int bytes) {
  const mb = 1000 * 1000;
  const gb = 1000 * mb;
  if (bytes <= 0) return AppStrings.sizeMegabytes('0');
  var megabytes = (bytes + mb - 1) ~/ mb;
  if (megabytes >= 100) megabytes = (megabytes + 9) ~/ 10 * 10;
  if (megabytes < 1000) return AppStrings.sizeMegabytes('$megabytes');
  if (bytes < 10 * gb) {
    final tenths = (bytes + gb ~/ 10 - 1) ~/ (gb ~/ 10);
    if (tenths < 100) return AppStrings.sizeGigabytes('${tenths ~/ 10},${tenths % 10}');
  }
  return AppStrings.sizeGigabytes('${(bytes + gb - 1) ~/ gb}');
}

/// Up to two initials for the no-cover monogram: "Der Zauberberg" -> "DZ",
/// "Momo" -> "M". Empty for a title without letters or digits.
String initialsFor(String title) {
  final words = title
      .split(RegExp(r'\s+'))
      .map((w) => w.replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), ''))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '';
  final first = words.first.characters1;
  if (words.length == 1) return first.toUpperCase();
  return (first + words[1].characters1).toUpperCase();
}

extension on String {
  /// The first user-visible character (a surrogate pair stays whole).
  String get characters1 => String.fromCharCode(runes.first);
}

/// How long before the stop point a Faden probe lies (decision E64):
/// "25 Sek." (rounded) under a minute, else as [formatRemaining] ("4 Min.",
/// "1 Std. 5 Min.").
String formatBeforeStop(int ms) {
  if (ms < 60 * 1000) return AppStrings.durationSeconds(((ms < 0 ? 0 : ms) + 500) ~/ 1000);
  return formatRemaining(ms);
}

/// The estimate in the question before loading over mobile data (decision
/// E66): "1 Std. ≈ 58 MB · Kapitel 3 ≈ 24 MB", rounded up like
/// [formatRemainingBytes]. [approximate] (no file sizes from the server,
/// estimated at 64 kbit/s) says "ca." instead of "≈".
String formatCellularEstimate({
  required int bytesPerHour,
  required int chapterNumber,
  required int chapterBytes,
  bool approximate = false,
}) =>
    '${AppStrings.cellularPerHour(formatRemainingBytes(bytesPerHour), approximate: approximate)}'
    ' · '
    '${AppStrings.cellularChapterSize(AppStrings.chapterLabel(chapterNumber), formatRemainingBytes(chapterBytes), approximate: approximate)}';

/// The local clock time "23:12" of wall time [wallMs] on a device with UTC
/// offset [tzMin] (the event's `tz_min`), for "gehört gegen 23:12 Uhr"
/// (decision E89).
String formatClockOfDay(int wallMs, int tzMin) {
  final local = DateTime.fromMillisecondsSinceEpoch(wallMs + tzMin * 60000, isUtc: true);
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}
