// Tests data/settings_store.dart's M6 addition, the health-data opt-in
// (docs/ARCHITEKTUR.md section 9 / KONZEPT.md "Schlafdaten erlauben").
// Safety-relevant: the whole M6 feature is gated behind this being true,
// so an unset key must read back as false, not as some other default.

import 'package:faden/data/db.dart';
import 'package:faden/data/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late SettingsStore settings;

  setUp(() {
    db = AppDatabase.memory();
    settings = SettingsStore(db);
  });

  tearDown(() => db.close());

  test('health data opt-in defaults to false (off) when never set', () async {
    expect(await settings.healthDataOptIn(), isFalse);
  });

  test('health data opt-in round-trips true and false', () async {
    await settings.setHealthDataOptIn(true);
    expect(await settings.healthDataOptIn(), isTrue);

    await settings.setHealthDataOptIn(false);
    expect(await settings.healthDataOptIn(), isFalse);
  });
}
