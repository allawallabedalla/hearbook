// Tests ui/settings_screen.dart: the night window always shows its current
// values (once each), is edited through a 24-hour Cupertino time wheel and,
// like the appearance, the sleep-timer default and the health-data switch,
// is written to the settings store the moment it changes -- no save button
// involved. "Verbindung prüfen" shows one distinct message per outcome.

import 'package:faden/data/api.dart' show ConnectionCheck;
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/l10n/strings.dart';
import 'package:faden/ui/providers.dart';
import 'package:faden/ui/settings_screen.dart';
import 'package:flutter/cupertino.dart';
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

  Future<void> pumpSettings(WidgetTester tester, {ConnectionCheck check = ConnectionCheck.ok}) async {
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
          connectionCheckerProvider.overrideWithValue((url, token) async => check),
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

  /// The trailing time of the night-window row labelled [label].
  Finder timeOf(String label, String time) => find.descendant(
        of: find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        matching: find.text(time),
      );

  testWidgets('shows the explanation and each night-window time once', (tester) async {
    await pumpSettings(tester);
    expect(find.text(AppStrings.settingsNightWindowExplanation), findsOneWidget);
    expect(timeOf(AppStrings.settingsNightWindowStart, '20:00'), findsOneWidget);
    expect(timeOf(AppStrings.settingsNightWindowEnd, '06:00'), findsOneWidget);
    expect(find.text('20:00'), findsOneWidget, reason: 'no summary repeating the times');
    expect(find.text('06:00'), findsOneWidget);
    await tearDownAll(tester);
  });

  testWidgets('a new start time from the wheel is stored at once', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text(AppStrings.settingsNightWindowStart));
    await tester.pumpAndSettle();
    expect(find.text(AppStrings.settingsNightWindowStartPicker), findsOneWidget);
    final picker = tester.widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker));
    expect(picker.use24hFormat, isTrue, reason: '24-hour wheel, no AM/PM');
    expect(picker.mode, CupertinoDatePickerMode.time);
    expect(picker.initialDateTime.hour, 20);

    picker.onDateTimeChanged(DateTime(2000, 1, 1, 21, 30));
    await tester.tap(find.text(AppStrings.timePickerConfirm));
    await settle(tester);

    expect(await tester.runAsync(store.nightStartMin), 21 * 60 + 30);
    expect(await tester.runAsync(store.nightEndMin), 6 * 60);
    expect(timeOf(AppStrings.settingsNightWindowStart, '21:30'), findsOneWidget);
    await tearDownAll(tester);
  });

  testWidgets('a cancelled wheel changes nothing', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text(AppStrings.settingsNightWindowEnd));
    await tester.pumpAndSettle();
    tester.widget<CupertinoDatePicker>(find.byType(CupertinoDatePicker)).onDateTimeChanged(DateTime(2000, 1, 1, 7));
    await tester.tap(find.text(AppStrings.timePickerCancel));
    await settle(tester);

    expect(await tester.runAsync(store.nightEndMin), 6 * 60);
    expect(timeOf(AppStrings.settingsNightWindowEnd, '06:00'), findsOneWidget);
    await tearDownAll(tester);
  });

  for (final (check, message) in [
    (ConnectionCheck.ok, AppStrings.connectionOk),
    (ConnectionCheck.unauthorized, AppStrings.connectionUnauthorized),
    (ConnectionCheck.unreachable, AppStrings.connectionUnreachable),
    (ConnectionCheck.invalidUrl, AppStrings.connectionInvalidUrl),
  ]) {
    testWidgets('"Verbindung prüfen" reports ${check.name}', (tester) async {
      await pumpSettings(tester, check: check);
      await tester.tap(find.text(AppStrings.settingsCheckConnection));
      await settle(tester);
      expect(find.text(message), findsOneWidget);
      // Nothing was saved by a check.
      expect(await tester.runAsync(store.serverUrl), isNull);
      await tearDownAll(tester);
    });
  }

  test('the four connection messages are distinct', () {
    final texts = ConnectionCheck.values.map(ConnectionCheckMessage.text).toSet();
    expect(texts, hasLength(ConnectionCheck.values.length));
  });

  testWidgets('saving stores the normalized address and checks it, no restart text', (tester) async {
    await pumpSettings(tester, check: ConnectionCheck.unauthorized);
    await tester.enterText(find.widgetWithText(TextField, AppStrings.settingsServerUrl), 'nas.local:8787/');
    await tester.enterText(find.widgetWithText(TextField, AppStrings.settingsServerToken), 'secret-token-123');
    await tester.tap(find.text(AppStrings.settingsSave));
    await settle(tester);
    expect(await tester.runAsync(store.serverUrl), 'http://nas.local:8787');
    expect(find.text('${AppStrings.settingsSaved} ${AppStrings.connectionUnauthorized}'), findsOneWidget);
    expect(find.textContaining('starten'), findsNothing);
    await tearDownAll(tester);
  });

  testWidgets('the sleep-timer default is stored at once', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text(AppStrings.sleepTimerMinutes(45)));
    await settle(tester);
    expect(await tester.runAsync(store.sleepTimerDefaultMin), 45);
    await tester.tap(find.text(AppStrings.sleepTimerChapterEnd));
    await settle(tester);
    expect(await tester.runAsync(store.sleepTimerDefaultMin), 0);
    await tearDownAll(tester);
  });

  testWidgets('names the health source of the platform', (tester) async {
    await pumpSettings(tester);
    expect(
      find.text(AppStrings.settingsHealthDataOptInDescription(AppStrings.healthSourceAndroid)),
      findsOneWidget,
    );
    expect(find.textContaining('Health/'), findsNothing);
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

  testWidgets('"Aktuelle Bücher automatisch laden" is on by default and stored at once (E56)', (tester) async {
    await pumpSettings(tester);
    final tile = find.widgetWithText(SwitchListTile, AppStrings.settingsAutoDownload);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    expect(find.text(AppStrings.storageFinishedNote), findsOneWidget);

    await tester.tap(find.text(AppStrings.settingsAutoDownload));
    await settle(tester);
    expect(await tester.runAsync(store.autoDownload), isFalse);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
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
