import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart' show ConnectionCheck;
import '../data/book_downloads.dart';
import '../data/settings_store.dart' show Appearance;
import '../l10n/strings.dart';
import '../signals/sleep_timer.dart' show sleepTimerPresetMinutes;
import 'controls.dart';
import 'format.dart';
import 'mini_player.dart';
import 'providers.dart';
import 'theme.dart';

/// docs/KONZEPT.md "Screens": "5. Einstellungen": server (with a
/// connection check), night window, sleep-timer default, appearance
/// (decision E28), storage, sleep data. Headphone-button remapping beyond
/// the fixed +/-30s of section 9 stays out of scope (M7).
///
/// Everything but the server is saved the moment it changes. Server
/// address and token keep an explicit save, which takes effect at once --
/// API client, downloads, sync and library are rebuilt, no restart
/// (decision E37).
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _healthDataOptIn = false;
  bool _loaded = false;
  bool _saved = false;
  bool _checking = false;
  ConnectionCheck? _check;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    final settings = ref.read(settingsStoreProvider);
    final url = await settings.serverUrl();
    final token = await settings.serverToken();
    final healthDataOptIn = await settings.healthDataOptIn();
    if (!mounted) return;
    setState(() {
      _urlController.text = url ?? '';
      _tokenController.text = token ?? '';
      _healthDataOptIn = healthDataOptIn;
    });
  }

  Future<void> _saveServer() async {
    FocusScope.of(context).unfocus();
    // Applies at once: API client, downloads and sync are rebuilt (E37).
    final saved = await ref
        .read(serverConfigProvider.notifier)
        .save(url: _urlController.text, token: _tokenController.text);
    if (!mounted) return;
    setState(() {
      _urlController.text = saved.url ?? '';
      _saved = true;
    });
    await _checkConnection();
  }

  /// "Verbindung prüfen": the address and token as typed (E37).
  Future<void> _checkConnection() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _checking = true;
      _check = null;
    });
    final result = await ref.read(connectionCheckerProvider)(_urlController.text, _tokenController.text);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _check = result;
    });
  }

  Future<void> _setHealthDataOptIn(bool optIn) async {
    await ref.read(settingsStoreProvider).setHealthDataOptIn(optIn);
    if (!mounted) return;
    setState(() => _healthDataOptIn = optIn);
  }

  /// A Cupertino time wheel in a sheet (decision E44), 24-hour. Returns the
  /// picked time in minutes since midnight, or null if cancelled.
  Future<int?> _pickTime(int currentMin, String title) async {
    var selected = currentMin;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      builder: (context) {
        final tokens = FadenTokens.of(context);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(AppStrings.timePickerCancel),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: tokens.tinte, fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(AppStrings.timePickerConfirm),
                  ),
                ],
              ),
              SizedBox(
                height: 216,
                child: CupertinoTheme(
                  data: CupertinoThemeData(
                    brightness: tokens.isDark ? Brightness.dark : Brightness.light,
                    primaryColor: tokens.faden,
                    textTheme: CupertinoTextThemeData(
                      dateTimePickerTextStyle: TextStyle(
                        color: tokens.tinte,
                        fontSize: FadenTypeSizes.title,
                        fontFamily: fadenFontFamily,
                      ),
                    ),
                  ),
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.time,
                    use24hFormat: true,
                    initialDateTime: DateTime(2000, 1, 1, currentMin ~/ 60, currentMin % 60),
                    onDateTimeChanged: (time) => selected = time.hour * 60 + time.minute,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
    return ok == true ? selected : null;
  }

  Future<void> _editStart(NightWindow window) async {
    final minutes = await _pickTime(window.startMin, AppStrings.settingsNightWindowStartPicker);
    if (minutes == null) return;
    await ref.read(nightWindowProvider.notifier).setStart(minutes);
  }

  Future<void> _editEnd(NightWindow window) async {
    final minutes = await _pickTime(window.endMin, AppStrings.settingsNightWindowEndPicker);
    if (minutes == null) return;
    await ref.read(nightWindowProvider.notifier).setEnd(minutes);
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    final window = ref.watch(nightWindowProvider).value ?? NightWindow.defaults;
    final appearance = ref.watch(appearanceProvider);
    final sleepDefault = ref.watch(sleepTimerDefaultProvider).value ?? 30;
    final autoDownload = ref.watch(autoDownloadSettingProvider).value ?? true;
    final secondary = TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.caption);
    final ios = Theme.of(context).platform == TargetPlatform.iOS;

    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.settingsTitle)),
      bottomNavigationBar: const MiniPlayer(),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          SectionTitle(AppStrings.settingsServerSection),
          TextField(
            controller: _urlController,
            decoration: InputDecoration(labelText: AppStrings.settingsServerUrl),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenController,
            decoration: InputDecoration(labelText: AppStrings.settingsServerToken),
            obscureText: true,
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton(onPressed: _checking ? null : _saveServer, child: Text(AppStrings.settingsSave)),
              OutlinedButton(
                onPressed: _checking ? null : _checkConnection,
                child: Text(_checking ? AppStrings.settingsChecking : AppStrings.settingsCheckConnection),
              ),
            ],
          ),
          if (_saved || _check != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ConnectionCheckMessage(check: _check, saved: _saved),
            ),
          const SizedBox(height: 32),
          SectionTitle(AppStrings.settingsNightWindowTitle),
          Text(AppStrings.settingsNightWindowExplanation, style: secondary),
          const SizedBox(height: 8),
          _TimeRow(
            label: AppStrings.settingsNightWindowStart,
            value: formatMinutesOfDay(window.startMin),
            onTap: () => _editStart(window),
          ),
          _TimeRow(
            label: AppStrings.settingsNightWindowEnd,
            value: formatMinutesOfDay(window.endMin),
            onTap: () => _editEnd(window),
          ),
          const SizedBox(height: 32),
          SectionTitle(AppStrings.detailsSleepTimer),
          Text(AppStrings.settingsSleepTimerExplanation, style: secondary),
          const SizedBox(height: 12),
          FadenSegmented<int>(
            values: sleepTimerPresetMinutes,
            selected: sleepDefault,
            label: AppStrings.sleepTimerMinutes,
            onChanged: (m) => ref.read(sleepTimerDefaultProvider.notifier).set(m),
          ),
          const SizedBox(height: 8),
          FadenSegmented<int>(
            values: const [0],
            selected: sleepDefault <= 0 ? 0 : null,
            label: (_) => AppStrings.sleepTimerChapterEnd,
            onChanged: (_) => ref.read(sleepTimerDefaultProvider.notifier).set(0),
          ),
          const SizedBox(height: 32),
          SectionTitle(AppStrings.settingsAppearanceTitle),
          RadioGroup<Appearance>(
            groupValue: appearance,
            onChanged: (value) {
              if (value != null) ref.read(appearanceProvider.notifier).set(value);
            },
            child: Column(
              children: [
                for (final option in Appearance.values)
                  RadioListTile<Appearance>.adaptive(
                    contentPadding: EdgeInsets.zero,
                    minTileHeight: fadenMinTapTarget,
                    value: option,
                    title: Text(_appearanceLabel(option)),
                  ),
              ],
            ),
          ),
          Text(AppStrings.settingsAppearanceNightNote, style: secondary),
          const SizedBox(height: 32),
          const _StorageSection(),
          const SizedBox(height: 8),
          // Decision E56: the open and the next "Weiterhören" book, Wi-Fi only.
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: autoDownload,
            onChanged: (on) => ref.read(autoDownloadSettingProvider.notifier).set(on),
            title: Text(AppStrings.settingsAutoDownload),
            subtitle: Text(AppStrings.settingsAutoDownloadDescription, style: secondary),
          ),
          const SizedBox(height: 32),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _healthDataOptIn,
            onChanged: _setHealthDataOptIn,
            title: Text(AppStrings.settingsHealthDataOptIn),
            subtitle: Text(
              AppStrings.settingsHealthDataOptInDescription(
                ios ? AppStrings.healthSourceIos : AppStrings.healthSourceAndroid,
              ),
              style: secondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// The result of "Speichern"/"Verbindung prüfen", one distinct message per
/// outcome (E37).
class ConnectionCheckMessage extends StatelessWidget {
  final ConnectionCheck? check;
  final bool saved;

  const ConnectionCheckMessage({super.key, required this.check, this.saved = false});

  static String text(ConnectionCheck check) => switch (check) {
        ConnectionCheck.ok => AppStrings.connectionOk,
        ConnectionCheck.unauthorized => AppStrings.connectionUnauthorized,
        ConnectionCheck.unreachable => AppStrings.connectionUnreachable,
        ConnectionCheck.invalidUrl => AppStrings.connectionInvalidUrl,
      };

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    final c = check;
    final ok = c == ConnectionCheck.ok;
    final color = c == null ? tokens.tinteLeise : (ok ? tokens.faden : tokens.fehler);
    final parts = [if (saved) AppStrings.settingsSaved, if (c != null) text(c)];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (c != null) ...[
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline, size: 20, color: color),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(parts.join(' '), style: TextStyle(color: color, fontSize: FadenTypeSizes.caption)),
        ),
      ],
    );
  }
}

class _TimeRow extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _TimeRow({required this.label, required this.value, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minTileHeight: fadenMinTapTarget,
      title: Text(label),
      trailing: Text(
        value,
        style: TextStyle(color: tokens.faden, fontSize: FadenTypeSizes.body, fontFeatures: const [FontFeature.tabularFigures()]),
      ),
      onTap: onTap,
    );
  }
}

/// "Speicher": all downloaded audio, and per book with delete.
class _StorageSection extends ConsumerStatefulWidget {
  const _StorageSection();

  @override
  ConsumerState<_StorageSection> createState() => _StorageSectionState();
}

class _StorageSectionState extends ConsumerState<_StorageSection> {
  Future<int>? _total;
  int? _countedBytes;

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.of(context);
    final downloads = ref.watch(bookDownloadsProvider);
    final library = ref.watch(libraryControllerProvider);
    final titles = {for (final b in library.books) b.bookId: b.title};
    final stored = [
      for (final e in (downloads?.states ?? const <String, BookDownloadState>{}).entries)
        if (e.value.bytesOnDisk > 0) e,
    ]..sort((a, b) => b.value.bytesOnDisk.compareTo(a.value.bytesOnDisk));
    // Recount the disk only when a book's stored bytes changed (a finished
    // file, a delete), not on every progress tick.
    final known = stored.fold<int>(0, (sum, e) => sum + e.value.bytesOnDisk);
    if (known != _countedBytes) {
      _countedBytes = known;
      _total = downloads?.totalBytesOnDisk();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          AppStrings.settingsStorageTitle,
          trailing: FutureBuilder<int>(
            future: _total,
            builder: (context, snap) {
              final bytes = snap.data;
              if (bytes == null || bytes <= 0) return const SizedBox.shrink();
              return Text(
                AppStrings.storageTotal(formatBytes(bytes)),
                style: TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.caption),
              );
            },
          ),
        ),
        if (stored.isEmpty)
          Text(AppStrings.storageNone, style: TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.caption)),
        for (final entry in stored)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(titles[entry.key] ?? entry.key, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(formatBytes(entry.value.bytesOnDisk)),
            trailing: IconButton(
              tooltip: AppStrings.downloadDelete,
              icon: Icon(Icons.delete_outline, color: tokens.fehler),
              onPressed: () async {
                final title = titles[entry.key] ?? '';
                if (await confirmDeleteDownload(context, title)) {
                  await library.deleteDownload(entry.key);
                }
              },
            ),
          ),
        // Decision E57: finished books leave the device by themselves.
        const SizedBox(height: 4),
        Text(AppStrings.storageFinishedNote, style: TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.caption)),
      ],
    );
  }
}

String _appearanceLabel(Appearance appearance) => switch (appearance) {
      Appearance.system => AppStrings.settingsAppearanceSystem,
      Appearance.light => AppStrings.settingsAppearanceLight,
      Appearance.dark => AppStrings.settingsAppearanceDark,
    };

/// "20:00" for 1200 minutes since midnight.
String formatMinutesOfDay(int minutesSinceMidnight) {
  final h = (minutesSinceMidnight ~/ 60) % 24;
  final m = minutesSinceMidnight % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}
