import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'audio/handler.dart';
import 'data/db.dart';
import 'data/journal.dart';
import 'data/settings_store.dart';
import 'data/sleep_data_source.dart';
import 'data/storage.dart';
import 'l10n/strings.dart';
import 'signals/night.dart';
import 'signals/screen_brightness.dart';
import 'ui/library_screen.dart';
import 'ui/player_screen.dart';
import 'ui/providers.dart';
import 'ui/routes.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Portrait only (decision E50); Info.plist says the same for iOS.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // The journal stays where it always was: nothing may move or rewrite it.
  final documentsDir = await getApplicationDocumentsDirectory();
  final supportDir = await getApplicationSupportDirectory();
  final db = AppDatabase.open(File('${documentsDir.path}/faden.db'));
  final journal = Journal(db);
  final settings = SettingsStore(db);
  final deviceId = await settings.deviceId();
  // Read before the first frame so it already has the chosen look (E28).
  final appearance = await settings.appearance();
  final serverConfig = ServerConfig(url: await settings.serverUrl(), token: await settings.serverToken());
  // The night view follows the display brightness (E54), read through a
  // small channel in ios/Runner/AppDelegate.swift; no source elsewhere, so
  // it stays off. Read before the first frame so a dark screen starts black
  // (E47).
  final brightnessSource = Platform.isIOS ? const PlatformScreenBrightness() : null;
  final nightAtStart = nextNightView(current: false, brightness: await brightnessSource?.current());

  // Decision E35: downloads live in Application Support, excluded from the
  // iCloud backup; files from the old Documents location move over once,
  // keeping their names (and so their verified state).
  final audioDir = audioDirIn(supportDir);
  try {
    await migrateDownloads(from: legacyAudioDirIn(documentsDir), to: audioDir);
    await audioDir.create(recursive: true);
    await excludeFromBackup(audioDir);
  } catch (_) {
    // Storage housekeeping must never keep the app from starting.
  }

  // M6 (docs/ARCHITEKTUR.md section 9): constructing/overriding this alone
  // requests no OS permission and reads no health data -- both only happen
  // inside PlayerSessionController.sleepOnsetAdjustment, and only once the
  // "Schlafdaten erlauben" setting is on and Faden-Suche actually starts.
  final sleepDataSource = HealthPluginSleepDataSource();

  // The sync client is attached by syncWiringProvider once the providers
  // exist, and replaced whenever the server settings change (E37).
  final audioHandler = await AudioService.init(
    builder: () => FadenAudioHandler(journal: journal, deviceId: deviceId),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'de.faden.app.channel.audio',
      androidNotificationChannelName: 'Faden Wiedergabe',
      androidNotificationOngoing: true,
      // Matches the handler's +/-30 s; iOS labels the lock-screen skip buttons with it.
      fastForwardInterval: Duration(seconds: 30),
      rewindInterval: Duration(seconds: 30),
    ),
  );
  // just_audio would default to a music session, which ducks under navigation
  // prompts instead of pausing; its README recommends speech() for audiobooks.
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.speech());
  // E36: calls and headphone unplugs pause (and resume) through the journal.
  audioHandler.attachAudioSessionEvents(
    interruptions: session.interruptionEventStream,
    becomingNoisy: session.becomingNoisyEventStream,
  );

  runApp(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        journalProvider.overrideWithValue(journal),
        settingsStoreProvider.overrideWithValue(settings),
        deviceIdProvider.overrideWithValue(deviceId),
        appSupportDirProvider.overrideWithValue(supportDir),
        initialServerConfigProvider.overrideWithValue(serverConfig),
        sleepDataSourceProvider.overrideWithValue(sleepDataSource),
        audioHandlerProvider.overrideWithValue(audioHandler),
        initialAppearanceProvider.overrideWithValue(appearance),
        screenBrightnessSourceProvider.overrideWithValue(brightnessSource),
        initialNightModeProvider.overrideWithValue(nightAtStart),
      ],
      child: const FadenApp(),
    ),
  );
}

/// The app-wide theme follows the "Erscheinungsbild" setting and the
/// phone's light/dark setting (decision E28, [resolveFadenTokens]), and the
/// night view (display brightness below 30 %, E54, [nightModeProvider]),
/// so library, settings, sheets and dialogs are dark at night too (E46).
/// Hiding the cover stays in the player (ui/player_screen.dart).
///
/// Also the home of the app-level sync triggers of docs/ARCHITEKTUR.md
/// section 6 that are not tied to playback (E31): app start (via opening
/// the last book), app back in the foreground, and a network change.
class FadenApp extends ConsumerStatefulWidget {
  const FadenApp({super.key});

  @override
  ConsumerState<FadenApp> createState() => _FadenAppState();
}

class _FadenAppState extends ConsumerState<FadenApp> {
  AppLifecycleListener? _lifecycle;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  List<ConnectivityResult>? _lastConnectivity;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () {
      _syncNow();
      _autoDownload();
    });
    try {
      final connectivity = Connectivity();
      unawaited(connectivity
          .checkConnectivity()
          .then((r) => _lastConnectivity ??= r)
          .catchError((Object _) => const <ConnectivityResult>[]));
      _connectivitySub = connectivity.onConnectivityChanged.listen(_onConnectivity, onError: (Object _) {});
    } catch (_) {
      // No connectivity plugin (tests): the other triggers still run.
    }
  }

  void _onConnectivity(List<ConnectivityResult> results) {
    final previous = _lastConnectivity;
    _lastConnectivity = results;
    // The first report (or checkConnectivity) is the baseline; only a change is a trigger.
    if (previous == null || _sameResults(previous, results)) return;
    // E56: to Wi-Fi starts auto-downloads, anything else stops them.
    ref.read(autoDownloaderProvider)?.onNetworkChanged(results);
    if (results.every((r) => r == ConnectivityResult.none)) return;
    _syncNow();
  }

  /// Decision E56: keep the open and the next "Weiterhören" book on the
  /// device (Wi-Fi only, in the background).
  void _autoDownload() {
    final downloader = ref.read(autoDownloaderProvider);
    if (downloader != null) unawaited(downloader.trigger());
  }

  static bool _sameResults(List<ConnectivityResult> a, List<ConnectivityResult> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  /// Results reach the open book (take-over, E31) and the library's
  /// progress through the handler's `remoteEventsPulled`.
  void _syncNow() => unawaited(ref.read(audioHandlerProvider).syncNow());

  @override
  void dispose() {
    _lifecycle?.dispose();
    unawaited(_connectivitySub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(syncWiringProvider);
    ref.watch(offlineWiringProvider);
    final tokens = resolveFadenTokens(
      appearance: ref.watch(appearanceProvider),
      platformBrightness: MediaQuery.platformBrightnessOf(context),
      nightMode: ref.watch(nightModeProvider),
    );
    return MaterialApp(
      title: AppStrings.appTitle,
      debugShowCheckedModeBanner: false,
      // German for Material's and Cupertino's own texts (back button,
      // text selection menu, picker semantics).
      locale: const Locale('de'),
      supportedLocales: const [Locale('de')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: fadenThemeFor(tokens),
      // KONZEPT.md "Bewegung": no decorative animation, so a change of
      // look switches at once instead of cross-fading.
      themeAnimationDuration: Duration.zero,
      home: const _StartupScreen(),
    );
  }
}

/// docs/ARCHITEKTUR.md section 11: "App-Start: Resolver ausführen, Player
/// an der Position pausiert vorbereiten." If a book was open before
/// (settings_store.dart's `lastOpenedBookId`), reopen it directly in the
/// player; otherwise land on the library so the user can pick one.
class _StartupScreen extends ConsumerStatefulWidget {
  const _StartupScreen();

  @override
  ConsumerState<_StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends ConsumerState<_StartupScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  /// Decision E30: the last book opens from the cached detail and the
  /// local journal, so a downloaded book is ready to play without the
  /// server; the detail is refreshed in the background.
  Future<void> _bootstrap() async {
    final settings = ref.read(settingsStoreProvider);
    final lastBookId = await settings.lastOpenedBookId();
    // E57: finished books leave the device before anything is loaded into
    // the player (a loaded book keeps its files). Local work only, fast.
    await ref.read(finishedCleanupProvider)?.cleanAll();

    if (lastBookId != null) {
      try {
        final result = await ref.read(bookOpenerProvider).open(lastBookId);
        if (result != OpenBookResult.unavailable) {
          if (!mounted) return;
          Navigator.of(context).pushReplacement(PlayerScreen.route(instant: true));
          return;
        }
      } catch (_) {
        // Falls through to the library -- matches KONZEPT.md's offline
        // behaviour: a reachability problem never blocks the app.
      }
    }
    if (!mounted) return;
    // E56 at app start (opening the last book above triggers it itself).
    final downloader = ref.read(autoDownloaderProvider);
    if (downloader != null) unawaited(downloader.trigger());
    Navigator.of(context)
        .pushReplacement(UnderPlayerRoute<void>(instant: true, builder: (_) => const LibraryScreen()));
  }

  /// An empty screen in the background colour, no spinner (E47): opening
  /// the last book takes a moment at most, and a spinner flashing by reads
  /// as a glitch.
  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: FadenTokens.of(context).grund);
}
