// Tests the settings-backed providers in ui/providers.dart: the night
// window loads what is stored and every change is written to the store
// before the state changes; the appearance starts from the value main.dart
// read before the first frame and persists every change.

import 'package:faden/data/db.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/ui/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late SettingsStore store;

  setUp(() {
    db = AppDatabase.memory();
    store = SettingsStore(db);
  });

  tearDown(() => db.close());

  ProviderContainer container({Appearance initial = Appearance.system}) {
    final c = ProviderContainer(overrides: [
      settingsStoreProvider.overrideWithValue(store),
      initialAppearanceProvider.overrideWithValue(initial),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('night window loads the stored values', () async {
    await store.setNightStartMin(21 * 60);
    await store.setNightEndMin(7 * 60);
    final c = container();
    expect(await c.read(nightWindowProvider.future), const NightWindow(startMin: 21 * 60, endMin: 7 * 60));
  });

  test('night window setters persist and update the state', () async {
    final c = container();
    expect(await c.read(nightWindowProvider.future), NightWindow.defaults);

    await c.read(nightWindowProvider.notifier).setStart(22 * 60);
    await c.read(nightWindowProvider.notifier).setEnd(5 * 60 + 30);

    expect(await store.nightStartMin(), 22 * 60);
    expect(await store.nightEndMin(), 5 * 60 + 30);
    expect(c.read(nightWindowProvider).value, const NightWindow(startMin: 22 * 60, endMin: 5 * 60 + 30));
  });

  test('appearance starts from the preloaded value and persists changes', () async {
    final c = container(initial: Appearance.dark);
    expect(c.read(appearanceProvider), Appearance.dark);

    await c.read(appearanceProvider.notifier).set(Appearance.light);
    expect(c.read(appearanceProvider), Appearance.light);
    expect(await store.appearance(), Appearance.light);
  });
}
