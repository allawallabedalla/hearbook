import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'audio/handler.dart';
import 'data/api.dart';
import 'data/db.dart';
import 'data/downloads.dart';
import 'data/journal.dart';
import 'data/settings_store.dart';
import 'data/sleep_data_source.dart';
import 'data/sync.dart';
import 'domain/manifest.dart';
import 'l10n/strings.dart';
import 'ui/library_screen.dart';
import 'ui/player_screen.dart';
import 'ui/providers.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final appDir = await getApplicationDocumentsDirectory();
  final db = AppDatabase.open(File('${appDir.path}/faden.db'));
  final journal = Journal(db);
  final settings = SettingsStore(db);
  final deviceId = await settings.deviceId();

  final serverUrl = await settings.serverUrl();
  final serverToken = await settings.serverToken();
  final api = (serverUrl != null && serverUrl.isNotEmpty && serverToken != null)
      ? ApiClient.create(baseUrl: serverUrl, token: serverToken)
      : null;
  final downloads =
      api == null ? null : DownloadManager(api: api, targetDir: downloadsDirFor(appDir));
  final syncClient = api == null ? null : SyncClient(db: db, journal: journal, api: api);
  // M6 (docs/ARCHITEKTUR.md section 9): constructing/overriding this alone
  // requests no OS permission and reads no health data -- both only happen
  // inside PlayerSessionController.sleepOnsetAdjustment, and only once the
  // "Schlafdaten erlauben" setting is on and Faden-Suche actually starts.
  final sleepDataSource = HealthPluginSleepDataSource();

  final audioHandler = await AudioService.init(
    builder: () => FadenAudioHandler(journal: journal, deviceId: deviceId, syncClient: syncClient),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'de.faden.app.channel.audio',
      androidNotificationChannelName: 'Faden Wiedergabe',
      androidNotificationOngoing: true,
    ),
  );
  // just_audio would default to a music session, which ducks under navigation
  // prompts instead of pausing; its README recommends speech() for audiobooks.
  await (await AudioSession.instance).configure(const AudioSessionConfiguration.speech());

  runApp(
    ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        journalProvider.overrideWithValue(journal),
        settingsStoreProvider.overrideWithValue(settings),
        deviceIdProvider.overrideWithValue(deviceId),
        apiClientProvider.overrideWithValue(api),
        downloadManagerProvider.overrideWithValue(downloads),
        syncClientProvider.overrideWithValue(syncClient),
        sleepDataSourceProvider.overrideWithValue(sleepDataSource),
        audioHandlerProvider.overrideWithValue(audioHandler),
      ],
      child: const FadenApp(),
    ),
  );
}

class FadenApp extends StatelessWidget {
  const FadenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppStrings.appTitle,
      debugShowCheckedModeBanner: false,
      theme: buildFadenTheme(FadenTokens.day),
      darkTheme: buildFadenTheme(FadenTokens.night),
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

  Future<void> _bootstrap() async {
    final api = ref.read(apiClientProvider);
    final settings = ref.read(settingsStoreProvider);
    final lastBookId = await settings.lastOpenedBookId();

    if (api != null && lastBookId != null) {
      try {
        final detail = await api.bookDetail(lastBookId);
        final activeJson = detail['active_manifest'] as Map<String, dynamic>?;
        if (activeJson != null) {
          final manifest = Manifest.fromJson(activeJson);
          final title = detail['title'] as String? ?? '';
          final serverUrl = await settings.serverUrl() ?? '';
          final token = await settings.serverToken() ?? '';
          await ref.read(playerSessionProvider).openBook(
                bookId: lastBookId,
                bookTitle: title,
                manifest: manifest,
                downloads: ref.read(downloadManagerProvider),
                serverBaseUrl: serverUrl,
                serverToken: token,
                api: api,
              );
          if (!mounted) return;
          Navigator.of(context)
              .pushReplacement(MaterialPageRoute(builder: (_) => const PlayerScreen()));
          return;
        }
      } catch (_) {
        // Falls through to the library -- matches KONZEPT.md's offline
        // behaviour: a reachability problem never blocks the app.
      }
    }
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LibraryScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.day;
    return Scaffold(
      backgroundColor: tokens.grund,
      body: const Center(child: CircularProgressIndicator()),
    );
  }
}
