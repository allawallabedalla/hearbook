// Tests ui/cellular_prompt.dart (decision E66): the question before loading
// over mobile data -- its texts and answers, day and night -- and the host
// that shows it only in the foreground, once per session.

import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:faden/data/book_downloads.dart';
import 'package:faden/data/cellular_downloads.dart';
import 'package:faden/data/db.dart';
import 'package:faden/data/downloads.dart';
import 'package:faden/data/settings_store.dart';
import 'package:faden/domain/manifest.dart';
import 'package:faden/l10n/strings.dart';
import 'package:faden/ui/cellular_prompt.dart';
import 'package:faden/ui/providers.dart';
import 'package:faden/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _estimate = CellularEstimate(bytesPerHour: 57600000, chapterNumber: 3, chapterBytes: 24000000, approximate: false);

void main() {
  group('CellularPromptDialog', () {
    /// Opens the dialog; the answer lands in [answers] once it closes.
    Future<void> open(
      WidgetTester tester, {
      FadenTokens tokens = FadenTokens.day,
      CellularEstimate estimate = _estimate,
      List<CellularAnswer?>? answers,
    }) async {
      await tester.pumpWidget(MaterialApp(
        theme: fadenThemeFor(tokens),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              final answer = await showCellularPromptDialog(context, estimate);
              answers?.add(answer);
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('title, what it loads, the real estimate, the checkbox and both buttons', (tester) async {
      await open(tester);
      expect(find.text(AppStrings.cellularPromptTitle), findsOneWidget);
      expect(find.text(AppStrings.cellularPromptBody), findsOneWidget);
      expect(find.text('1 Std. ≈ 58 MB · Kapitel 3 ≈ 24 MB'), findsOneWidget);
      expect(find.text(AppStrings.cellularPromptDontShowAgain), findsOneWidget);
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isFalse);
      expect(find.text(AppStrings.cellularPromptLoad), findsOneWidget);
      expect(find.text(AppStrings.cellularPromptNotNow), findsOneWidget);
      // "Laden" is a full-width capsule, "Nicht jetzt" a quiet text below (E76).
      final load = find.widgetWithText(FilledButton, AppStrings.cellularPromptLoad);
      expect(load, findsOneWidget);
      final notNow = find.widgetWithText(TextButton, AppStrings.cellularPromptNotNow);
      expect(tester.getSize(load).width, closeTo(tester.getSize(notNow).width, 0.5));
      expect(tester.getTopLeft(notNow).dy, greaterThan(tester.getBottomLeft(load).dy));
    });

    testWidgets('"Laden" with "Nicht wieder anzeigen" ticked', (tester) async {
      final answers = <CellularAnswer?>[];
      await open(tester, answers: answers);
      await tester.tap(find.text(AppStrings.cellularPromptDontShowAgain));
      await tester.pump();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      await tester.tap(find.text(AppStrings.cellularPromptLoad));
      await tester.pumpAndSettle();
      expect(answers, [(load: true, dontShowAgain: true)]);
      expect(find.text(AppStrings.cellularPromptTitle), findsNothing);
    });

    testWidgets('"Nicht jetzt" never stores "Nicht wieder anzeigen"', (tester) async {
      final answers = <CellularAnswer?>[];
      await open(tester, answers: answers);
      await tester.tap(find.text(AppStrings.cellularPromptDontShowAgain));
      await tester.tap(find.text(AppStrings.cellularPromptNotNow));
      await tester.pumpAndSettle();
      expect(answers, [(load: false, dontShowAgain: false)]);
    });

    testWidgets('at night: the night look, the checkbox only a ring', (tester) async {
      await open(tester, tokens: FadenTokens.night);
      final context = tester.element(find.text(AppStrings.cellularPromptTitle));
      expect(FadenTokens.of(context), FadenTokens.night);
      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(checkbox.activeColor, Colors.transparent);
      expect(checkbox.checkColor, FadenTokens.night.faden);
    });

    testWidgets('"ca." without file sizes', (tester) async {
      await open(
        tester,
        estimate: const CellularEstimate(bytesPerHour: 28800000, chapterNumber: 1, chapterBytes: 14400000, approximate: true),
      );
      expect(find.text('1 Std. ca. 29 MB · Kapitel 1 ca. 15 MB'), findsOneWidget);
    });
  });

  group('CellularPromptHost', () {
    late Directory dir;
    late AppDatabase db;
    late SettingsStore store;
    late ChapterDownloader downloader;
    final navigatorKey = GlobalKey<NavigatorState>();

    Future<void> pumpHost(WidgetTester tester) async {
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('faden-prompt');
        db = AppDatabase.memory();
        store = SettingsStore(db);
        downloader = ChapterDownloader(
          enabled: () async => true,
          connectivity: () async => [ConnectivityResult.mobile],
          serverReachable: () async => false,
          consent: CellularConsent(hintOff: store.cellularHintOff, setHintOff: store.setCellularHintOff),
          downloads: BookDownloads(manager: DownloadManager(api: null, targetDir: dir)),
          playback: () => const ChapterPlayback(
            bookId: 'book',
            manifest: Manifest(manifestId: 'm', files: [
              ManifestFile(idx: 0, fileHash: 'h0', durationMs: 60000, sizeBytes: 960000),
              ManifestFile(idx: 1, fileHash: 'h1', durationMs: 60000, sizeBytes: 960000),
            ]),
            currentIndex: 0,
            playing: true,
          ),
        );
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          appDatabaseProvider.overrideWithValue(db),
          settingsStoreProvider.overrideWithValue(store),
          chapterDownloaderProvider.overrideWithValue(downloader),
        ],
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: fadenThemeFor(FadenTokens.day),
          builder: (context, child) => CellularPromptHost(navigatorKey: navigatorKey, child: child!),
          home: const Scaffold(body: Text('Bibliothek')),
        ),
      ));
    }

    Future<void> cleanUp(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
    }

    Future<void> pass(WidgetTester tester) async {
      await tester.runAsync(downloader.trigger);
      await tester.pumpAndSettle();
    }

    testWidgets('in the foreground: asks once; "Nicht jetzt" holds for the session', (tester) async {
      await pumpHost(tester);
      await pass(tester);
      expect(find.text(AppStrings.cellularPromptTitle), findsOneWidget);
      expect(find.text('1 Std. ≈ 58 MB · Kapitel 1 ≈ 1 MB'), findsOneWidget);
      await tester.tap(find.text(AppStrings.cellularPromptNotNow));
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.cellularPromptTitle), findsNothing);
      await pass(tester);
      expect(find.text(AppStrings.cellularPromptTitle), findsNothing, reason: 'not again this session');
      expect(await tester.runAsync(store.cellularHintOff), isFalse);
      await cleanUp(tester);
    });

    testWidgets('"Laden" with "Nicht wieder anzeigen" is stored', (tester) async {
      await pumpHost(tester);
      await pass(tester);
      await tester.tap(find.text(AppStrings.cellularPromptDontShowAgain));
      await tester.tap(find.text(AppStrings.cellularPromptLoad));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      expect(await tester.runAsync(store.cellularHintOff), isTrue);
      await pass(tester);
      expect(find.text(AppStrings.cellularPromptTitle), findsNothing);
      await cleanUp(tester);
    });

    testWidgets('in the background: no dialog until the app is back in front', (tester) async {
      await pumpHost(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await pass(tester);
      expect(downloader.prompt.value, isNotNull, reason: 'waiting for an answer');
      expect(find.text(AppStrings.cellularPromptTitle), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.text(AppStrings.cellularPromptTitle), findsOneWidget);
      await tester.tap(find.text(AppStrings.cellularPromptNotNow));
      await tester.pumpAndSettle();
      await cleanUp(tester);
    });
  });
}
