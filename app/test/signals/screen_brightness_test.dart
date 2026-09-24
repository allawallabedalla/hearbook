// Tests signals/screen_brightness.dart's channel source (decision E54):
// it reads the device brightness from ios/Runner/AppDelegate.swift's
// channels, clamps it to 0..1 and treats a failure as "unknown".

import 'package:faden/signals/screen_brightness.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('de.faden.app/brightness');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(method, null));

  test('current() reads the brightness through the "get" call', () async {
    messenger.setMockMethodCallHandler(method, (call) async => call.method == 'get' ? 0.25 : null);
    expect(await const PlatformScreenBrightness().current(), 0.25);
  });

  test('current() clamps to 0..1', () async {
    messenger.setMockMethodCallHandler(method, (call) async => 1.2);
    expect(await const PlatformScreenBrightness().current(), 1.0);
  });

  test('current() is null when the platform fails or has no channel', () async {
    messenger.setMockMethodCallHandler(method, (call) async => throw PlatformException(code: 'x'));
    expect(await const PlatformScreenBrightness().current(), isNull);
    messenger.setMockMethodCallHandler(method, null);
    expect(await const PlatformScreenBrightness().current(), isNull);
  });
}
