// Tests ui/providers.dart's nightModeProvider (decision E54): the night
// view follows the display brightness with hysteresis (on below 30 %, off
// above 35 %); no source or an error means off.

import 'package:faden/ui/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_screen_brightness.dart';

void main() {
  late FakeScreenBrightness brightness;

  setUp(() => brightness = FakeScreenBrightness());
  tearDown(() => brightness.close());

  ProviderContainer container({bool initial = false, bool withSource = true}) {
    final c = ProviderContainer(overrides: [
      if (withSource) screenBrightnessSourceProvider.overrideWithValue(brightness),
      initialNightModeProvider.overrideWithValue(initial),
    ]);
    addTearDown(c.dispose);
    // Keep the provider alive between reads, as the app root does.
    c.listen(nightModeProvider, (_, _) {});
    return c;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('switches on below 30 % and off only above 35 %', () async {
    final c = container();
    expect(c.read(nightModeProvider), isFalse);
    brightness.emit(0.5);
    await settle();
    expect(c.read(nightModeProvider), isFalse);
    brightness.emit(0.29);
    await settle();
    expect(c.read(nightModeProvider), isTrue);
    brightness.emit(0.34);
    await settle();
    expect(c.read(nightModeProvider), isTrue, reason: 'hysteresis band keeps it on');
    brightness.emit(0.36);
    await settle();
    expect(c.read(nightModeProvider), isFalse);
    brightness.emit(0.32);
    await settle();
    expect(c.read(nightModeProvider), isFalse, reason: 'hysteresis band keeps it off');
  });

  test('starts from the brightness main.dart read before the first frame', () async {
    final c = container(initial: true);
    expect(c.read(nightModeProvider), isTrue);
    brightness.emit(0.8);
    await settle();
    expect(c.read(nightModeProvider), isFalse);
  });

  test('an error from the platform turns it off', () async {
    final c = container(initial: true);
    brightness.fail();
    await settle();
    expect(c.read(nightModeProvider), isFalse);
  });

  test('no brightness source (Android, tests) keeps it off', () {
    final c = container(initial: true, withSource: false);
    expect(c.read(nightModeProvider), isFalse);
  });
}
