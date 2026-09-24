import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/strings.dart';
import 'providers.dart';
import 'theme.dart';

/// docs/KONZEPT.md "Screens": "5. Einstellungen: Server, Nachtfenster,
/// Schlafdaten erlauben, Belegung der Kopfhörertasten." M4 scope: server
/// connection and night window only -- health-data consent (M6) and
/// headphone-button remapping (beyond the fixed +/-30s of section 9) are
/// out of scope here.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  int _nightStart = 20 * 60;
  int _nightEnd = 6 * 60;
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
    final start = await settings.nightStartMin();
    final end = await settings.nightEndMin();
    if (!mounted) return;
    setState(() {
      _urlController.text = url ?? '';
      _tokenController.text = token ?? '';
      _nightStart = start;
      _nightEnd = end;
    });
  }

  Future<void> _save() async {
    final settings = ref.read(settingsStoreProvider);
    await settings.setServerUrl(_urlController.text.trim());
    await settings.setServerToken(_tokenController.text.trim());
    await settings.setNightStartMin(_nightStart);
    await settings.setNightEndMin(_nightEnd);
    if (!mounted) return;
    setState(() => _saved = true);
  }

  String _hhmm(int minutesSinceMidnight) {
    final h = (minutesSinceMidnight ~/ 60) % 24;
    final m = minutesSinceMidnight % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = FadenTokens.day;
    return Scaffold(
      appBar: AppBar(title: Text(AppStrings.settingsTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
          const SizedBox(height: 24),
          Text(AppStrings.settingsNightWindowStart, style: TextStyle(color: tokens.tinteLeise)),
          Slider(
            value: _nightStart.toDouble(),
            min: 0,
            max: 24 * 60 - 1,
            divisions: 24 * 4,
            label: _hhmm(_nightStart),
            onChanged: (v) => setState(() => _nightStart = v.round()),
          ),
          Text(AppStrings.settingsNightWindowEnd, style: TextStyle(color: tokens.tinteLeise)),
          Slider(
            value: _nightEnd.toDouble(),
            min: 0,
            max: 24 * 60 - 1,
            divisions: 24 * 4,
            label: _hhmm(_nightEnd),
            onChanged: (v) => setState(() => _nightEnd = v.round()),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _save,
            child: Text(AppStrings.settingsSave),
          ),
          if (_saved)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(AppStrings.settingsSaved, style: TextStyle(color: tokens.tinteLeise)),
            ),
        ],
      ),
    );
  }
}
