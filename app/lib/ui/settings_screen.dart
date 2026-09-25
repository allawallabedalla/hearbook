import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api.dart' show ConnectionCheck;
import '../data/book_downloads.dart';
import '../data/settings_store.dart' show Appearance;
import '../domain/faden_search.dart' show probeLengths;
import '../domain/sleep_learning.dart';
import '../l10n/strings.dart';
import 'controls.dart';
import 'format.dart';
import 'mini_player.dart';
import 'providers.dart';
import 'theme.dart';

/// docs/KONZEPT.md "Screens": "5. Einstellungen": server (with a
/// connection check), night window, appearance (decision E28), storage,
/// downloads (automatic on Wi-Fi, E56; chapter-wise over mobile data,
/// E66), sleep data; the Faden search's probe length (E77), the sleep
/// onsets it found with a night-window suggestion (E79, E81) and writing
/// them to Health (E82). Headphone-button remapping beyond
/// the fixed +/-30s of section 9 stays out of scope (M7).
///
/// Laid out like the iPhone's settings (decision E65): grouped sections
/// with their explanation below, choices as check-mark rows, switches in
/// the token colours. On first setup, a save that reaches the server
/// returns to the library.
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
  bool _showToken = false;
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
    final firstSetup = !ref.read(serverConfigProvider).isConfigured;
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
    if (!mounted || !firstSetup || _check != ConnectionCheck.ok) return;
    // First setup done (E65): back to the library, which loads the books
    // of the new server by itself; the confirmation goes along.
    final navigator = Navigator.of(context);
    if (!navigator.canPop()) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    navigator.pop();
    messenger?.showSnackBar(SnackBar(content: Text(AppStrings.connectionOk)));
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

  /// "Einschlafzeit in Health eintragen" (E82): only turns on once Health
  /// allows writing; otherwise says where to allow it.
  Future<void> _setHealthWrite(bool on) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    final result = await ref.read(healthWriteSettingProvider.notifier).set(on);
    if (on && !result) {
      messenger?.showSnackBar(SnackBar(content: Text(AppStrings.settingsHealthWriteDenied)));
    }
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
    final window = ref.watch(nightWindowProvider).value ?? NightWindow.defaults;
    final appearance = ref.watch(appearanceProvider);
    final cellularChapters = ref.watch(cellularChaptersSettingProvider).value ?? false;
    final cellularHint = ref.watch(cellularHintSettingProvider).value ?? true;
    final autoDownload = ref.watch(autoDownloadSettingProvider).value ?? true;
    final probeLen = ref.watch(probeLengthProvider).value;
    final healthWriter = ref.watch(sleepHealthWriterProvider);
    final canWriteHealth = healthWriter?.isSupported ?? false;
    final healthWrite = ref.watch(healthWriteSettingProvider).value ?? false;
    final ios = Theme.of(context).platform == TargetPlatform.iOS;

    // Grouped sections as in the iPhone's settings, explanations below
    // the rows (decision E65).
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.settingsTitle)),
      bottomNavigationBar: const MiniPlayer(),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          FadenGroup(
            header: AppStrings.settingsServerSection,
            rows: [
              _FieldRow(
                child: TextField(
                  controller: _urlController,
                  decoration: _fieldDecoration(
                    label: AppStrings.settingsServerUrl,
                    hint: AppStrings.settingsServerUrlHint,
                  ),
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                ),
              ),
              _FieldRow(
                child: TextField(
                  controller: _tokenController,
                  decoration: _fieldDecoration(
                    label: AppStrings.settingsServerToken,
                    suffix: IconButton(
                      tooltip: _showToken ? AppStrings.settingsTokenHide : AppStrings.settingsTokenShow,
                      icon: Icon(_showToken ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                      onPressed: () => setState(() => _showToken = !_showToken),
                    ),
                  ),
                  obscureText: !_showToken,
                  autocorrect: false,
                  enableSuggestions: false,
                ),
              ),
            ],
            footer: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 6),
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
              ],
            ),
          ),
          FadenGroup(
            header: AppStrings.settingsNightWindowTitle,
            rows: [
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
            ],
            footer: Text(AppStrings.settingsNightWindowExplanation),
          ),
          // Decision E77: the probe length, 6 s by default.
          FadenGroup(
            header: AppStrings.settingsFadenSearchTitle,
            rows: [
              for (final ms in probeLengths)
                FadenCheckRow(
                  label: AppStrings.settingsProbeLength(ms ~/ 1000),
                  selected: ms == probeLen,
                  onTap: () => ref.read(probeLengthProvider.notifier).set(ms),
                ),
            ],
            footer: Text(AppStrings.settingsProbeLengthExplanation),
          ),
          SleepOnsetsSection(window: window),
          FadenGroup(
            header: AppStrings.settingsAppearanceTitle,
            rows: [
              for (final option in Appearance.values)
                FadenCheckRow(
                  label: _appearanceLabel(option),
                  selected: option == appearance,
                  onTap: () => ref.read(appearanceProvider.notifier).set(option),
                ),
            ],
            footer: Text(AppStrings.settingsAppearanceNightNote),
          ),
          const _StorageSection(),
          // Decision E56: the open and the next "Weiterhören" book, Wi-Fi
          // only; E66: over mobile data chapter by chapter, if wanted.
          FadenGroup(
            rows: [
              SwitchListTile.adaptive(
                value: autoDownload,
                onChanged: (on) => ref.read(autoDownloadSettingProvider.notifier).set(on),
                title: Text(AppStrings.settingsAutoDownload),
              ),
              SwitchListTile.adaptive(
                value: cellularChapters,
                onChanged: (on) => ref.read(cellularChaptersSettingProvider.notifier).set(on),
                title: Text(AppStrings.settingsCellularChapters),
              ),
              if (cellularChapters)
                SwitchListTile.adaptive(
                  value: cellularHint,
                  onChanged: (show) => ref.read(cellularHintSettingProvider.notifier).set(show),
                  title: Text(AppStrings.settingsCellularHint),
                ),
            ],
            footer: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(AppStrings.settingsAutoDownloadDescription),
                const SizedBox(height: 6),
                Text(AppStrings.settingsCellularChaptersDescription),
              ],
            ),
          ),
          FadenGroup(
            rows: [
              SwitchListTile.adaptive(
                value: _healthDataOptIn,
                onChanged: _setHealthDataOptIn,
                title: Text(AppStrings.settingsHealthDataOptIn),
              ),
              // Decision E82: off by default; switching it on asks Health.
              if (canWriteHealth)
                SwitchListTile.adaptive(
                  value: healthWrite,
                  onChanged: _setHealthWrite,
                  title: Text(AppStrings.settingsHealthWrite),
                ),
            ],
            footer: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  AppStrings.settingsHealthDataOptInDescription(
                    ios ? AppStrings.healthSourceIos : AppStrings.healthSourceAndroid,
                  ),
                ),
                if (canWriteHealth) ...[
                  const SizedBox(height: 6),
                  Text(AppStrings.settingsHealthWriteDescription),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// A text field inside a grouped row: no own fill or border (the group
  /// draws the surface), the label always above, so an empty field shows
  /// its example ([hint]) from the start.
  InputDecoration _fieldDecoration({required String label, String? hint, Widget? suffix}) => InputDecoration(
        labelText: label,
        hintText: hint,
        floatingLabelBehavior: FloatingLabelBehavior.always,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: const EdgeInsets.fromLTRB(FadenGroup.inset, 10, FadenGroup.inset, 10),
        suffixIcon: suffix,
      );
}

/// A text field as a row of a [FadenGroup], at least one tap target high.
class _FieldRow extends StatelessWidget {
  final Widget child;

  const _FieldRow({required this.child});

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: fadenMinTapTarget),
        child: Center(child: child),
      );
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

    return FadenGroup(
      header: AppStrings.settingsStorageTitle,
      headerTrailing: FutureBuilder<int>(
        future: _total,
        builder: (context, snap) {
          final bytes = snap.data;
          if (bytes == null || bytes <= 0) return const SizedBox.shrink();
          return Text(AppStrings.storageTotal(formatBytes(bytes)));
        },
      ),
      rows: [
        if (stored.isEmpty)
          ListTile(
            title: Text(
              AppStrings.storageNone,
              style: TextStyle(color: tokens.leiseAufFlaeche, fontSize: FadenTypeSizes.body),
            ),
          ),
        for (final entry in stored)
          ListTile(
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
      ],
      // Decision E57: finished books leave the device by themselves.
      footer: Text(AppStrings.storageFinishedNote),
    );
  }
}

/// "Deine Einschlafzeiten" (decisions E79, E81): the last 14 onsets the
/// Faden search found, newest first, and from 5 onsets a suggested night
/// window to take over with one tap. Read from this device only.
class SleepOnsetsSection extends ConsumerStatefulWidget {
  /// The night window now, to hide a suggestion that is already set.
  final NightWindow window;

  const SleepOnsetsSection({super.key, required this.window});

  static const int shown = 14;

  @override
  ConsumerState<SleepOnsetsSection> createState() => _SleepOnsetsSectionState();
}

class _SleepOnsetsSectionState extends ConsumerState<SleepOnsetsSection> {
  /// Swiped away, gone from the list at once (the store follows).
  final Set<String> _removed = {};

  @override
  Widget build(BuildContext context) {
    final window = widget.window;
    const shown = SleepOnsetsSection.shown;
    final tokens = FadenTokens.of(context);
    final onsets = [
      for (final o in ref.watch(sleepOnsetsProvider).value ?? const <SleepOnsetRecord>[])
        if (!_removed.contains(o.sessionId)) o,
    ];
    // E90: taking the suggestion over only ever widens the window.
    final raw = suggestNightWindow(onsets);
    final suggestion = raw == null
        ? null
        : widenNightWindow(currentStartMin: window.startMin, currentEndMin: window.endMin, suggestion: raw);
    final showSuggestion = suggestion != null;
    final newest = onsets.reversed.take(shown).toList();
    final rowStyle = TextStyle(
      color: tokens.tinte,
      fontSize: FadenTypeSizes.body,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return FadenGroup(
      header: AppStrings.settingsSleepOnsetsTitle,
      rows: [
        if (showSuggestion)
          ListTile(
            minTileHeight: fadenMinTapTarget,
            title: Text(
              AppStrings.settingsNightWindowSuggestion(
                '${formatMinutesOfDay(suggestion.startMin)}–${formatMinutesOfDay(suggestion.endMin)}',
              ),
              style: TextStyle(color: tokens.faden, fontSize: FadenTypeSizes.body),
            ),
            onTap: () async {
              final notifier = ref.read(nightWindowProvider.notifier);
              await notifier.setStart(suggestion.startMin);
              await notifier.setEnd(suggestion.endMin);
            },
          ),
        if (newest.isEmpty)
          ListTile(
            title: Text(
              AppStrings.settingsSleepOnsetsEmpty,
              style: TextStyle(color: tokens.leiseAufFlaeche, fontSize: FadenTypeSizes.body),
            ),
          ),
        // E90: a wrong night can be swiped away.
        for (final onset in newest)
          Dismissible(
            key: ValueKey('sleep-onset-${onset.sessionId}'),
            direction: DismissDirection.endToStart,
            background: ColoredBox(
              color: tokens.fehler,
              child: Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(AppStrings.settingsSleepOnsetDelete, style: TextStyle(color: tokens.grund)),
                ),
              ),
            ),
            onDismissed: (_) {
              setState(() => _removed.add(onset.sessionId));
              unawaited(ref.read(sleepLogProvider).deleteOnset(onset.sessionId));
            },
            child: ListTile(
              minTileHeight: fadenMinTapTarget,
              title: Text(formatOnsetDate(onset.localDate), style: rowStyle),
              trailing: Text(formatMinutesOfDay(onset.localMinuteOfDay), style: rowStyle),
            ),
          ),
      ],
      footer: Text(AppStrings.settingsSleepOnsetsExplanation),
    );
  }
}

/// "24.09." for "2026-09-24".
String formatOnsetDate(String isoDate) {
  final parts = isoDate.split('-');
  if (parts.length != 3) return isoDate;
  return '${parts[2]}.${parts[1]}.';
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
