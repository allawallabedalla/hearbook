import 'dart:io';

import 'package:health/health.dart';

/// Writes the computed sleep onset to Apple Health as "Im Bett" (HealthKit
/// sleep analysis `inBed`, decision E82) -- opt-in, off by default. The one
/// seam between the `health` plugin's write side and the rest of the app;
/// tests use a fake (never a real [Health] instance).
///
/// CLAUDE.md invariant 7: what goes to Health stays on the device (HealthKit
/// is local), and nothing here writes an event or syncs anything. The
/// onset itself is computed from the listener's own answers in the Faden
/// search, not from health data.
abstract class SleepHealthWriter {
  /// Whether this platform can write "Im Bett" at all. Only iOS: Health
  /// Connect on Android has no "in bed" type in the `health` package.
  bool get isSupported;

  /// Asks for permission to write sleep (and to read it, for the overlap
  /// check). Called only when the setting is switched on. Returns whether
  /// writing is allowed now.
  Future<bool> requestPermission();

  /// Whether writing is allowed right now (HealthKit tells this for
  /// writing, unlike for reading).
  Future<bool> canWrite();

  /// Whether Health already has any sleep sample overlapping
  /// `[startWallMs, endWallMs]` -- from a watch, a sleep app, the iPhone's
  /// own bedtime, or Faden itself. Then nothing is written.
  Future<bool> hasSleepOverlapping({required int startWallMs, required int endWallMs});

  /// Writes one "Im Bett" sample. Returns whether it was saved.
  Future<bool> writeInBed({required int startWallMs, required int endWallMs});
}

/// [SleepHealthWriter] on the `health` package (13.3.2; checked in its
/// source: `writeHealthData` with `HealthDataType.SLEEP_IN_BED` saves an
/// `HKCategorySample` with `HKCategoryValueSleepAnalysis.inBed` on iOS;
/// `hasPermissions` with `HealthDataAccess.WRITE` reports HealthKit's
/// sharing status; the value of sleep types is set by the plugin).
class HealthPluginSleepWriter implements SleepHealthWriter {
  final Health _health;
  bool _configured = false;

  HealthPluginSleepWriter({Health? health}) : _health = health ?? Health();

  /// Every HealthKit sleep value, so the overlap check sees a watch's
  /// sleep stages as well as another app's "in bed".
  static const List<HealthDataType> _readTypes = [
    HealthDataType.SLEEP_IN_BED,
    HealthDataType.SLEEP_ASLEEP,
    HealthDataType.SLEEP_AWAKE,
    HealthDataType.SLEEP_LIGHT,
    HealthDataType.SLEEP_DEEP,
    HealthDataType.SLEEP_REM,
  ];

  @override
  bool get isSupported => Platform.isIOS;

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  @override
  Future<bool> requestPermission() async {
    if (!isSupported) return false;
    await _ensureConfigured();
    if (await canWrite()) return true;
    await _health.requestAuthorization(
      _readTypes,
      permissions: [
        HealthDataAccess.READ_WRITE, // SLEEP_IN_BED
        for (var i = 1; i < _readTypes.length; i++) HealthDataAccess.READ,
      ],
    );
    return canWrite();
  }

  @override
  Future<bool> canWrite() async {
    if (!isSupported) return false;
    await _ensureConfigured();
    return await _health.hasPermissions(
          const [HealthDataType.SLEEP_IN_BED],
          permissions: const [HealthDataAccess.WRITE],
        ) ??
        false;
  }

  @override
  Future<bool> hasSleepOverlapping({required int startWallMs, required int endWallMs}) async {
    await _ensureConfigured();
    // A sample that began up to a day earlier can still reach into the night.
    final points = await _health.getHealthDataFromTypes(
      types: _readTypes,
      startTime: DateTime.fromMillisecondsSinceEpoch(startWallMs - 24 * 3600000),
      endTime: DateTime.fromMillisecondsSinceEpoch(endWallMs),
    );
    return points.any((p) =>
        p.dateFrom.millisecondsSinceEpoch < endWallMs && p.dateTo.millisecondsSinceEpoch > startWallMs);
  }

  @override
  Future<bool> writeInBed({required int startWallMs, required int endWallMs}) async {
    await _ensureConfigured();
    return _health.writeHealthData(
      value: 0, // ignored: the plugin sets the sleep value itself
      type: HealthDataType.SLEEP_IN_BED,
      startTime: DateTime.fromMillisecondsSinceEpoch(startWallMs),
      endTime: DateTime.fromMillisecondsSinceEpoch(endWallMs),
      recordingMethod: RecordingMethod.automatic,
    );
  }
}
