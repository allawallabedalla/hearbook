// Tests ui/settings_screen.dart: the night window always shows its current
// values (once each), is edited through a 24-hour Cupertino time wheel and,
// like the appearance, the download switches and the health-data switch,
// is written to the settings store the moment it changes -- no save button
// involved. "Verbindung prüfen" shows one distinct message per outcome.

import 'package:faden/data/api.dart' show ConnectionCheck;
import 'package:faden/data/db.dart';
import 'package:faden/data/journal.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/data/sleep_health_writer.dart';
import 'package:faden/domain/sleep_learning.dart';
import 'package:faden/l10n/strings.dart';
import 'package:faden/ui/providers.dart';
import 'package:faden/ui/controls.dart';
import 'package:faden/ui/settings_screen.dart';
import 'package:faden/ui/theme.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_audio_handler.dart';

class _FakeHealthWriter implements SleepHealthWriter {
  bool allow = true;
  int requests = 0;

  @override
  bool get isSupported => true;

  @override
  Future<bool> requestPermission() async {
    requests++;
    return allow;
  }

  @override
  Future<bool> canWrite() async => allow;

  @override
  Future<bool> hasSleepOverlapping({required int startWallMs, required int endWallMs}) async => false;

  @override
  Future<bool> writeInBed({required int startWallMs, required int endWallMs}) async => true;
}

/// Five onsets around midnight (UTC, tz 0): 23:00 ... 00:30.
List<SleepOnsetRecord> _onsets() {
  const day = 1790208000000; // 2026-09-24 00:00 UTC
  return [
    for (final (i, minutes) in [(0, 23 * 60), (1, 23 * 60 + 30), (2, 23 * 60 + 45), (4, 24 * 60 + 10), (5, 24 * 60 + 30)])
      SleepOnsetRecord(
        sessionId: 's$i',
        bookId: 'b',
        onsetWallMs: day + i * 86400000 + minutes * 60000,
        tzMin: 0,
        listenMs: 600000,
      ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('com.ryanheise.audio_session'),
    (call) async => null,
  );

  late AppDatabase db;
  late SettingsStore store;
  late FakeAudioHandler handler;

  Future<void> pumpSettings(
    WidgetTester tester, {
    ConnectionCheck check = ConnectionCheck.ok,
    bool overLibrary = false,
    ServerConfig server = ServerConfig.empty,
    Future<void> Function(SettingsStore store)? seed,
    SleepHealthWriter? healthWriter,
    Size? size,
    double textScale = 1.0,
    FadenTokens? tokens,
  }) async {
    await tester.runAsync(() async {
      db = AppDatabase.memory();
      store = SettingsStore(db);
      await seed?.call(store);
      handler = FakeAudioHandler(Journal(db));
    });
    // A tall surface so every section is on screen without scrolling.
    tester.view.physicalSize = size == null ? const Size(1080, 7000) : size * 3;
    tester.view.devicePixelRatio = size == null ? 2 : 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          settingsStoreProvider.overrideWithValue(store),
          audioHandlerProvider.overrideWithValue(handler),
          connectionCheckerProvider.overrideWithValue((url, token) async => check),
          initialServerConfigProvider.overrideWithValue(server),
          if (healthWriter != null) sleepHealthWriterProvider.overrideWithValue(healthWriter),
        ],
        child: MaterialApp(
          theme: tokens == null ? null : fadenThemeFor(tokens),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: overLibrary
              ? Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
                      child: const Text('Bibliothek darunter'),
                    ),
                  ),
                )
              : const SettingsScreen(),
        ),
      ),
    );
    if (overLibrary) {
      await tester.tap(find.text('Bibliothek darunter'));
      await tester.pumpAndSettle();
    }
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

  testWidgets('"Über Mobilfunk kapitelweise laden" is off by default, explained and stored at once (E66)',
      (tester) async {
    await pumpSettings(tester);
    final tile = find.widgetWithText(SwitchListTile, AppStrings.settingsCellularChapters);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
    expect(find.text(AppStrings.settingsCellularChaptersDescription), findsOneWidget);
    expect(find.text(AppStrings.settingsCellularHint), findsNothing, reason: 'only with the setting on');
    // In the section of the auto-download switch, explained below it.
    expect(tester.getTopLeft(tile).dy,
        greaterThan(tester.getTopLeft(find.widgetWithText(SwitchListTile, AppStrings.settingsAutoDownload)).dy));
    expect(tester.getTopLeft(find.text(AppStrings.settingsCellularChaptersDescription)).dy,
        greaterThan(tester.getBottomLeft(tile).dy));

    await tester.tap(find.text(AppStrings.settingsCellularChapters));
    await settle(tester);
    expect(await tester.runAsync(store.cellularChapters), isTrue);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
    final hint = find.widgetWithText(SwitchListTile, AppStrings.settingsCellularHint);
    expect(tester.widget<SwitchListTile>(hint).value, isTrue, reason: 'asks by default');
    await tearDownAll(tester);
  });

  testWidgets('the hint row turns "Nicht wieder anzeigen" back off (E66)', (tester) async {
    await pumpSettings(tester, seed: (store) async {
      await store.setCellularChapters(true);
      await store.setCellularHintOff(true);
    });
    final hint = find.widgetWithText(SwitchListTile, AppStrings.settingsCellularHint);
    expect(tester.widget<SwitchListTile>(hint).value, isFalse);
    await tester.tap(find.text(AppStrings.settingsCellularHint));
    await settle(tester);
    expect(await tester.runAsync(store.cellularHintOff), isFalse);
    expect(tester.widget<SwitchListTile>(hint).value, isTrue);
    await tearDownAll(tester);
  });

  testWidgets('grouped sections: explanations below their rows, check marks instead of radios (E65)', (tester) async {
    await pumpSettings(tester);
    expect(find.byType(FadenGroup), findsWidgets);
    expect(tester.getTopLeft(find.text(AppStrings.settingsNightWindowExplanation)).dy,
        greaterThan(tester.getBottomLeft(find.text(AppStrings.settingsNightWindowEnd)).dy));
    expect(tester.getTopLeft(find.text(AppStrings.settingsAppearanceNightNote)).dy,
        greaterThan(tester.getBottomLeft(find.text(AppStrings.settingsAppearanceDark)).dy));
    expect(find.byType(Radio<Appearance>), findsNothing);
    expect(find.byType(RadioListTile<Appearance>), findsNothing);
    Finder check(String label) =>
        find.descendant(of: find.widgetWithText(ListTile, label), matching: find.byIcon(Icons.check));
    expect(check(AppStrings.settingsAppearanceSystem), findsOneWidget, reason: 'the stored choice');
    expect(check(AppStrings.settingsAppearanceDark), findsNothing);
    // E67: the sleep-timer default had no effect any more and is gone.
    expect(find.text(AppStrings.sleepTimerMinutes(30)), findsNothing);
    expect(find.text(AppStrings.sleepTimerChapterEnd), findsNothing);
    await tester.tap(find.text(AppStrings.settingsAppearanceDark));
    await settle(tester);
    expect(check(AppStrings.settingsAppearanceDark), findsOneWidget);
    expect(check(AppStrings.settingsAppearanceSystem), findsNothing);
    await tearDownAll(tester);
  });

  testWidgets('the server fields show an example address and a token eye (E65)', (tester) async {
    await pumpSettings(tester);
    expect(find.text(AppStrings.settingsServerUrlHint), findsOneWidget);
    TextField token() => tester.widget<TextField>(find.widgetWithText(TextField, AppStrings.settingsServerToken));
    expect(token().obscureText, isTrue);
    await tester.tap(find.byTooltip(AppStrings.settingsTokenShow));
    await tester.pump();
    expect(token().obscureText, isFalse);
    await tester.tap(find.byTooltip(AppStrings.settingsTokenHide));
    await tester.pump();
    expect(token().obscureText, isTrue);
    await tearDownAll(tester);
  });

  testWidgets('first setup: after "Verbindung steht." it goes back to the library (E65)', (tester) async {
    await pumpSettings(tester, overLibrary: true);
    await tester.enterText(find.widgetWithText(TextField, AppStrings.settingsServerUrl), 'nas.local:8000');
    await tester.enterText(find.widgetWithText(TextField, AppStrings.settingsServerToken), 'secret-token-123');
    await tester.tap(find.text(AppStrings.settingsSave));
    await settle(tester);
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.text('Bibliothek darunter'), findsOneWidget);
    expect(find.text(AppStrings.connectionOk), findsOneWidget, reason: 'the confirmation goes along');
    await tearDownAll(tester);
  });

  testWidgets('changing a working server stays in the settings', (tester) async {
    await pumpSettings(
      tester,
      overLibrary: true,
      server: const ServerConfig(url: 'http://nas.local:8000', token: 'secret-token-123'),
    );
    await tester.tap(find.text(AppStrings.settingsSave));
    await settle(tester);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('${AppStrings.settingsSaved} ${AppStrings.connectionOk}'), findsOneWidget);
    await tearDownAll(tester);
  });

  test('on the iPhone, switches are in the thread colour, not system green (E65)', () {
    for (final tokens in [FadenTokens.day, FadenTokens.night]) {
      final theme = buildFadenTheme(tokens).copyWith(platform: TargetPlatform.iOS);
      final adapted = theme.getAdaptation<SwitchThemeData>()!.adapt(theme, theme.switchTheme);
      expect(adapted.trackColor!.resolve({WidgetState.selected}), tokens.faden);
      expect(adapted.trackColor!.resolve({}), tokens.tinteLeiseFaden);
      final thumb = adapted.thumbColor!.resolve({WidgetState.selected})!;
      expect(thumb, tokens.isDark ? tokens.tinte : Colors.white, reason: 'no white thumb in the dark');
    }
    final android = buildFadenTheme(FadenTokens.day).copyWith(platform: TargetPlatform.android);
    expect(android.getAdaptation<SwitchThemeData>()!.adapt(android, android.switchTheme), android.switchTheme);
  });

  test('formatMinutesOfDay pads hours and minutes', () {
    expect(formatMinutesOfDay(0), '00:00');
    expect(formatMinutesOfDay(6 * 60 + 5), '06:05');
    expect(formatMinutesOfDay(20 * 60), '20:00');
    expect(formatMinutesOfDay(23 * 60 + 59), '23:59');
  });

  group('Faden-Suche lernt mit', () {
    testWidgets('probe length: 4, 6 and 8 s as check rows, 6 s by default, stored at once (E77)', (tester) async {
      await pumpSettings(tester);
      expect(find.text(AppStrings.settingsFadenSearchTitle), findsOneWidget);
      expect(find.text(AppStrings.settingsProbeLengthExplanation), findsOneWidget);
      FadenCheckRow row(int s) => tester.widget<FadenCheckRow>(
          find.widgetWithText(FadenCheckRow, AppStrings.settingsProbeLength(s)));
      expect([row(4).selected, row(6).selected, row(8).selected], [false, true, false]);

      await tester.tap(find.text(AppStrings.settingsProbeLength(8)));
      await settle(tester);
      expect(await tester.runAsync(store.probeLenMs), 8000);
      expect([row(4).selected, row(6).selected, row(8).selected], [false, false, true]);
      await tearDownAll(tester);
    });

    testWidgets('no onsets yet: the empty text, no suggestion (E79)', (tester) async {
      await pumpSettings(tester);
      expect(find.text(AppStrings.settingsSleepOnsetsTitle), findsOneWidget);
      expect(find.text(AppStrings.settingsSleepOnsetsEmpty), findsOneWidget);
      expect(find.textContaining('Vorschlag'), findsNothing);
      await tearDownAll(tester);
    });

    testWidgets('lists the onsets newest first and takes the suggested night window over in one tap (E81)',
        (tester) async {
      await pumpSettings(tester, seed: (store) => store.setSleepOnsetsJson(encodeOnsets(_onsets())));
      expect(find.text(AppStrings.settingsSleepOnsetsEmpty), findsNothing);
      expect(find.text('30.09.'), findsOneWidget);
      expect(find.text('24.09.'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('30.09.')).dy,
        lessThan(tester.getTopLeft(find.text('24.09.')).dy),
        reason: 'newest first',
      );
      expect(find.text('00:30'), findsOneWidget);
      final suggestion = find.text(AppStrings.settingsNightWindowSuggestion('22:30–01:00'));
      expect(suggestion, findsOneWidget);

      await tester.tap(suggestion);
      await settle(tester);
      expect(await tester.runAsync(store.nightStartMin), 22 * 60 + 30);
      expect(await tester.runAsync(store.nightEndMin), 60);
      expect(suggestion, findsNothing, reason: 'already set');
      await tearDownAll(tester);
    });

    for (final size in const [Size(375, 6000), Size(430, 6000)]) {
      for (final scale in const [1.0, 1.35]) {
        for (final (name, tokens) in [('light', FadenTokens.day), ('dark', FadenTokens.night)]) {
          testWidgets('new sections lay out without overflow: ${size.width.toInt()} pt, $scale, $name',
              (tester) async {
            await pumpSettings(
              tester,
              seed: (store) => store.setSleepOnsetsJson(encodeOnsets(_onsets())),
              healthWriter: _FakeHealthWriter(),
              size: size,
              textScale: scale,
              tokens: tokens,
            );
            expect(tester.takeException(), isNull);
            expect(find.text(AppStrings.settingsProbeLength(6)), findsOneWidget);
            expect(find.text(AppStrings.settingsNightWindowSuggestion('22:30–01:00')), findsOneWidget);
            expect(find.text(AppStrings.settingsHealthWrite), findsOneWidget, reason: 'everything built');
            await tearDownAll(tester);
          });
        }
      }
    }

    testWidgets('the Health write switch is hidden where Faden cannot write', (tester) async {
      await pumpSettings(tester);
      expect(find.text(AppStrings.settingsHealthWrite), findsNothing);
      await tearDownAll(tester);
    });

    testWidgets('"Einschlafzeit in Health eintragen": off by default, asks Health when switched on (E82)',
        (tester) async {
      final writer = _FakeHealthWriter();
      await pumpSettings(tester, healthWriter: writer);
      final tile = find.widgetWithText(SwitchListTile, AppStrings.settingsHealthWrite);
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      expect(find.text(AppStrings.settingsHealthWriteDescription), findsOneWidget);
      expect(writer.requests, 0, reason: 'nothing asked before the switch');

      await tester.tap(tile);
      await settle(tester);
      expect(writer.requests, 1);
      expect(await tester.runAsync(store.healthWriteOptIn), isTrue);
      expect(tester.widget<SwitchListTile>(tile).value, isTrue);
      await tearDownAll(tester);
    });

    testWidgets('stays off and says so when Health does not allow writing', (tester) async {
      final writer = _FakeHealthWriter()..allow = false;
      await pumpSettings(tester, healthWriter: writer);
      final tile = find.widgetWithText(SwitchListTile, AppStrings.settingsHealthWrite);
      await tester.tap(tile);
      await settle(tester);
      expect(await tester.runAsync(store.healthWriteOptIn), isFalse);
      expect(tester.widget<SwitchListTile>(tile).value, isFalse);
      expect(find.text(AppStrings.settingsHealthWriteDenied), findsOneWidget);
      await tearDownAll(tester);
    });
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
