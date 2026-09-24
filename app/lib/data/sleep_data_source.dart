import 'dart:io';

import 'package:health/health.dart';

/// Local-only sleep-onset reading (docs/ARCHITEKTUR.md section 9, decision
/// E6): HealthKit on iOS, Health Connect on Android. This interface is the
/// single seam between the `health` plugin and the rest of the app so M6
/// is testable without a device -- [HealthPluginSleepDataSource] is the
/// real, platform-backed implementation; tests use their own fake
/// implementation instead (never a real [Health] instance, which would
/// hit a platform channel this sandbox/CI has no device for).
///
/// CLAUDE.md invariant 7 ("Gesundheitsdaten verlassen nie das Gerät und
/// erzeugen keine Events") is not this interface's job to enforce -- it
/// is a property of what callers do with [sleepOnsetWallMs]'s return
/// value. The one real call site, `ui/providers.dart`'s
/// `PlayerSessionController.sleepOnsetAdjustment`, only ever feeds it into
/// `domain/sleep_onset.dart`'s pure `adjustForSleepOnset` in memory and
/// returns the numeric result -- never to `data/journal.dart`, never
/// logged, never synced.
abstract class SleepDataSource {
  /// Whether this platform can supply sleep data at all (iOS/Android
  /// only). Checked before ever touching the plugin/OS.
  bool get isSupported;

  /// Requests the OS-level permission (HealthKit's share sheet / Health
  /// Connect's permission screen) if not already granted or denied, and
  /// reports whether reading is allowed right now. Safe to call every time
  /// Faden-Suche starts -- the underlying plugin/OS no-ops once the user
  /// has already answered.
  Future<bool> requestPermission();

  /// The earliest recorded sleep-onset wall-clock instant (ms since Unix
  /// epoch, section 9's `T`) starting within `[fromWallMs, toWallMs]`, or
  /// null if none is recorded. Only meaningful after [requestPermission]
  /// returned true; callers must not call this otherwise.
  Future<int?> sleepOnsetWallMs({required int fromWallMs, required int toWallMs});
}

/// [SleepDataSource] backed by the `health` package (pubspec.yaml: verified
/// publisher, actively maintained -- see the pubspec.yaml comment for the
/// exact version/rationale). Reads only `HealthDataType.SLEEP_ASLEEP`
/// ("Schlafbeginn", section 9); this app never writes any health data
/// (invariant 7 doesn't strictly forbid it, but a write is not part of
/// this feature and would be one more thing to keep off any sync path).
class HealthPluginSleepDataSource implements SleepDataSource {
  final Health _health;
  bool _configured = false;

  HealthPluginSleepDataSource({Health? health}) : _health = health ?? Health();

  static const List<HealthDataType> _types = [HealthDataType.SLEEP_ASLEEP];
  static const List<HealthDataAccess> _permissions = [HealthDataAccess.READ];

  @override
  bool get isSupported => Platform.isIOS || Platform.isAndroid;

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  @override
  Future<bool> requestPermission() async {
    if (!isSupported) return false;
    await _ensureConfigured();
    final has = await _health.hasPermissions(_types, permissions: _permissions) ?? false;
    if (has) return true;
    return _health.requestAuthorization(_types, permissions: _permissions);
  }

  @override
  Future<int?> sleepOnsetWallMs({required int fromWallMs, required int toWallMs}) async {
    if (!isSupported) return null;
    await _ensureConfigured();
    final points = await _health.getHealthDataFromTypes(
      types: _types,
      startTime: DateTime.fromMillisecondsSinceEpoch(fromWallMs),
      endTime: DateTime.fromMillisecondsSinceEpoch(toWallMs),
    );
    if (points.isEmpty) return null;
    // "Schlafbeginn" = the earliest asleep sample's start in the window.
    var earliest = points.first.dateFrom;
    for (final p in points.skip(1)) {
      if (p.dateFrom.isBefore(earliest)) earliest = p.dateFrom;
    }
    return earliest.millisecondsSinceEpoch;
  }
}
