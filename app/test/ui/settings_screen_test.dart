// Tests ui/settings_screen.dart: the night window always shows its current
// values, is edited through a 24-hour time picker and, like the appearance
// and the health-data switch, is written to the settings store the moment
// it changes -- no save button involved.

import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/l10n/strings.dart';
import 'package:faden/ui/providers.dart';
import 'package:faden/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );

  late AppDatabase db;
  late SettingsStore store;
  late FakeAudioHandler handler;

  Future<void> pumpSettings(WidgetTester tester) async {
    await tester.runAsync(() async {
      db = AppDatabase.memory();
      store = SettingsStore(db);
      handler = FakeAudioHandler(Journal(db));
    });
    // A tall surface so every section is on screen without scrolling.
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          settingsStoreProvider.overrideWithValue(store),
          audioHandlerProvider.overrideWithValue(handler),
        ],
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await settle(tester);
  }

  Future<void> tearDownAll(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await handler.dispose();
      await db.close();
    });
  }

  testWidgets('shows the night window summary, explanation and both times', (tester) async {
    await pumpSettings(tester);
    expect(find.text(AppStrings.settingsNightWindowSummary('20:00', '06:00')), findsOneWidget);
    expect(find.text(AppStrings.settingsNightWindowExplanation), findsOneWidget);
    expect(find.text(AppStrings.settingsNightWindowStartsAt('20:00')), findsOneWidget);
    expect(find.text(AppStrings.settingsNightWindowEndsAt('06:00')), findsOneWidget);
    await tearDownAll(tester);
  });

  testWidgets('a new start time from the picker is stored at once', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text(AppStrings.settingsNightWindowStartsAt('20:00')));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.settingsNightWindowStartPicker), findsOneWidget);
    expect(find.text('PM'), findsNothing, reason: '24-hour picker, no AM/PM toggle');

    // Switch the picker to text input and type 21:30.
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.descendant(of: find.byType(Dialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), '21');
    await tester.enterText(fields.at(1), '30');
    await tester.tap(find.text(AppStrings.timePickerConfirm));
    await settle(tester);

    expect(await tester.runAsync(store.nightStartMin), 21 * 60 + 30);
    expect(await tester.runAsync(store.nightEndMin), 6 * 60);
    expect(find.text(AppStrings.settingsNightWindowSummary('21:30', '06:00')), findsOneWidget);
    expect(find.text(AppStrings.settingsNightWindowStartsAt('21:30')), findsOneWidget);
    await tearDownAll(tester);
  });

  testWidgets('a dismissed picker changes nothing', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text(AppStrings.settingsNightWindowEndsAt('06:00')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.timePickerCancel));
    await settle(tester);

    expect(await tester.runAsync(store.nightEndMin), 6 * 60);
    expect(find.text(AppStrings.settingsNightWindowEndsAt('06:00')), findsOneWidget);
    await tearDownAll(tester);
  });

  testWidgets('choosing an appearance stores it at once and applies it', (tester) async {
    await pumpSettings(tester);
    expect(await tester.runAsync(store.appearance), Appearance.system);

    await tester.tap(find.text(AppStrings.settingsAppearanceDark));
    await settle(tester);
    expect(await tester.runAsync(store.appearance), Appearance.dark);

    final container = ProviderScope.containerOf(tester.element(find.byType(SettingsScreen)));
    expect(container.read(appearanceProvider), Appearance.dark);

    await tester.tap(find.text(AppStrings.settingsAppearanceLight));
    await settle(tester);
    expect(await tester.runAsync(store.appearance), Appearance.light);
    expect(container.read(appearanceProvider), Appearance.light);
    await tearDownAll(tester);
  });

  testWidgets('the health-data switch is stored at once', (tester) async {
    await pumpSettings(tester);
    expect(await tester.runAsync(store.healthDataOptIn), isFalse);

    await tester.tap(find.text(AppStrings.settingsHealthDataOptIn));
    await settle(tester);
    expect(await tester.runAsync(store.healthDataOptIn), isTrue);
    await tearDownAll(tester);
  });

  test('formatMinutesOfDay pads hours and minutes', () {
    expect(formatMinutesOfDay(0), '00:00');
    expect(formatMinutesOfDay(6 * 60 + 5), '06:05');
    expect(formatMinutesOfDay(20 * 60), '20:00');
    expect(formatMinutesOfDay(23 * 60 + 59), '23:59');
  });
}

/// Lets the drift queries behind the settings store (real async) finish,
/// then settles the widget tree.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pumpAndSettle();
  }
}
