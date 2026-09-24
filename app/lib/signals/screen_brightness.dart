import 'package:flutter/services.dart';

/// The display brightness, 0..1, as the phone shows it right now
/// (decision E54: it switches the night view, signals/night.dart
/// `nextNightView`). Only ever read, never set.
abstract interface class ScreenBrightnessSource {
  /// The brightness now, or null if it cannot be read.
  Future<double?> current();

  /// The brightness on every change (the platform side may also repeat an
  /// unchanged value). Errors mean "unknown".
  Stream<double> changes();
}

/// iOS: `UIScreen.main.brightness` through a small method and event
/// channel in ios/Runner/AppDelegate.swift. The system brightness is what
/// the user set in Control Center or what auto-brightness chose; Faden
/// never overrides it, so this is the device value. Other platforms have
/// no source (main.dart passes none), so the night view stays off there.
class PlatformScreenBrightness implements ScreenBrightnessSource {
  static const _method = MethodChannel('de.faden.app/brightness');
  static const _events = EventChannel('de.faden.app/brightness/changes');

  const PlatformScreenBrightness();

  @override
  Future<double?> current() async {
    try {
      final value = await _method.invokeMethod<double>('get');
      return value == null ? null : _clamp(value);
    } catch (_) {
      return null;
    }
  }

  @override
  Stream<double> changes() => _events.receiveBroadcastStream().map((v) => _clamp((v as num).toDouble()));

  static double _clamp(double v) => v.clamp(0.0, 1.0);
}
