import 'package:flutter/services.dart';

/// Keeps the display from locking itself (decision E85): while the Faden
/// screen is open, the phone must not lock between two probes -- a locked
/// phone would hide the answer buttons and, without audio, let iOS
/// suspend the app. Only the auto-lock is held back; the brightness stays
/// what the user set.
abstract interface class ScreenAwake {
  Future<void> keepOn(bool on);
}

/// iOS: `UIApplication.shared.isIdleTimerDisabled`; Android: the window's
/// `FLAG_KEEP_SCREEN_ON`. Both through the small channel
/// `de.faden.app/screen` in ios/Runner/AppDelegate.swift and
/// android/.../MainActivity.kt, like the brightness channel (E54); no
/// package needed for one flag.
class PlatformScreenAwake implements ScreenAwake {
  static const _channel = MethodChannel('de.faden.app/screen');

  const PlatformScreenAwake();

  @override
  Future<void> keepOn(bool on) async {
    try {
      await _channel.invokeMethod<void>('keepOn', {'on': on});
    } catch (_) {
      // Best effort: a phone that locks only costs a tap to wake it.
    }
  }
}
