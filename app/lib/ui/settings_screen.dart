import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/settings_store.dart' show Appearance;
import '../l10n/strings.dart';
import 'mini_player.dart';
import 'providers.dart';
import 'theme.dart';

/// docs/KONZEPT.md "Screens": "5. Einstellungen: Server, Nachtfenster,
/// Schlafdaten erlauben, Belegung der Kopfhörertasten", plus
/// "Erscheinungsbild" (decision E28). Headphone-button remapping beyond the
/// fixed +/-30s of section 9 stays out of scope (M7).
///
/// Night window, appearance and the health-data switch are saved the
/// moment they change. Server address and token keep an explicit save:
/// main.dart builds the API client from them once at start, so a change
/// only takes effect after a restart, which the saved notice says.
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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _load();
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
    final settings = ref.read(settingsStoreProvider);
    await settings.setServerUrl(_urlController.text.trim());
    await settings.setServerToken(_tokenController.text.trim());
    if (!mounted) return;
    setState(() => _saved = true);
  }

  Future<void> _setHealthDataOptIn(bool optIn) async {
    await ref.read(settingsStoreProvider).setHealthDataOptIn(optIn);
    if (!mounted) return;
    setState(() => _healthDataOptIn = optIn);
  }

  /// Opens the 24-hour time picker at [currentMin] (minutes since
  /// midnight) and returns the picked time in the same unit, or null if
  /// the picker was dismissed.
  Future<int?> _pickTime(int currentMin, String helpText) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: currentMin ~/ 60, minute: currentMin % 60),
      helpText: helpText,
      confirmText: AppStrings.timePickerConfirm,
      cancelText: AppStrings.timePickerCancel,
      hourLabelText: AppStrings.timePickerHour,
      minuteLabelText: AppStrings.timePickerMinute,
      errorInvalidText: AppStrings.timePickerInvalid,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (picked == null) return null;
    return picked.hour * 60 + picked.minute;
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
    final start = formatMinutesOfDay(window.startMin);
    final end = formatMinutesOfDay(window.endMin);
    final secondary = TextStyle(color: tokens.tinteLeise, fontSize: FadenTypeSizes.caption);

    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.settingsTitle)),
      bottomNavigationBar: const MiniPlayer(),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionTitle(AppStrings.settingsServerSection, tokens: tokens),
          TextField(
            controller: _urlController,
            decoration: InputDecoration(labelText: AppStrings.settingsServerUrl),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _tokenController,
            decoration: InputDecoration(labelText: AppStrings.settingsServerToken),
            obscureText: true,
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton(
              onPressed: _saveServer,
              style: FilledButton.styleFrom(minimumSize: const Size(0, fadenMinTapTarget)),
              child: Text(AppStrings.settingsSave),
            ),
          ),
          if (_saved)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(AppStrings.settingsSaved, style: secondary),
            ),
          const SizedBox(height: 32),
          _SectionTitle(AppStrings.settingsNightWindowTitle, tokens: tokens),
          Text(
            AppStrings.settingsNightWindowSummary(start, end),
            style: TextStyle(color: tokens.tinte, fontSize: FadenTypeSizes.body),
          ),
          const SizedBox(height: 4),
          Text(AppStrings.settingsNightWindowExplanation, style: secondary),
          const SizedBox(height: 8),
          ListTile(
            contentPadding: EdgeInsets.zero,
            minTileHeight: fadenMinTapTarget,
            title: Text(AppStrings.settingsNightWindowStartsAt(start)),
            trailing: Icon(Icons.schedule, color: tokens.tinteLeise),
            onTap: () => _editStart(window),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            minTileHeight: fadenMinTapTarget,
            title: Text(AppStrings.settingsNightWindowEndsAt(end)),
            trailing: Icon(Icons.schedule, color: tokens.tinteLeise),
            onTap: () => _editEnd(window),
          ),
          const SizedBox(height: 32),
          _SectionTitle(AppStrings.settingsAppearanceTitle, tokens: tokens),
          RadioGroup<Appearance>(
            groupValue: appearance,
            onChanged: (value) {
              if (value != null) ref.read(appearanceProvider.notifier).set(value);
            },
            child: Column(
              children: [
                for (final option in Appearance.values)
                  RadioListTile<Appearance>(
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
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _healthDataOptIn,
            onChanged: _setHealthDataOptIn,
            title: Text(AppStrings.settingsHealthDataOptIn),
            subtitle: Text(AppStrings.settingsHealthDataOptInDescription, style: secondary),
          ),
        ],
      ),
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

class _SectionTitle extends StatelessWidget {
  final String text;
  final FadenTokens tokens;

  const _SectionTitle(this.text, {required this.tokens});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text, style: TextStyle(color: tokens.tinte, fontSize: FadenTypeSizes.title)),
    );
  }
}
