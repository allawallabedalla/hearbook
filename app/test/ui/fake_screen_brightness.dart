// Test double for signals/screen_brightness.dart: the test sets and
// emits the display brightness by hand (decision E54).

import 'dart:async';

import 'package:faden/signals/screen_brightness.dart';

class FakeScreenBrightness implements ScreenBrightnessSource {
  final StreamController<double> _changes = StreamController<double>.broadcast();
  double? now;

  FakeScreenBrightness([this.now]);

  @override
  Future<double?> current() async => now;

  @override
  Stream<double> changes() => _changes.stream;

  /// The user moved the brightness slider to [value].
  void emit(double value) {
    now = value;
    _changes.add(value);
  }

  /// The platform reported an error instead of a value.
  void fail() => _changes.addError(StateError('no brightness'));

  Future<void> close() => _changes.close();
}
