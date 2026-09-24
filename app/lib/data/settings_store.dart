import '../core/ids.dart';
import 'db.dart';

/// Keys used in [KeyValueSettings]. Kept as string constants (not an enum)
/// because the table itself is a plain key/value store -- new keys never
/// need a migration.
class SettingsKeys {
  const SettingsKeys._();

  static const deviceId = 'device_id';
  static const serverUrl = 'server_url';
  static const serverToken = 'server_token';
  static const nightStartMin = 'night_start_min';
  static const nightEndMin = 'night_end_min';
  static const sleepTimerDefaultMin = 'sleep_timer_default_min';
  static const lastOpenedBookId = 'last_opened_book_id';
  static const healthDataOptIn = 'health_data_opt_in';
}

/// Typed wrapper around [KeyValueSettings]: server connection, device id
/// and the small settings docs/KONZEPT.md's "Einstellungen" screen exposes
/// (server, night window, health-data opt-in). Headphone-button mapping
/// beyond the fixed +/-30s of section 9 is out of scope (M7).
class SettingsStore {
  final AppDatabase db;

  SettingsStore(this.db);

  Future<String?> _get(String key) async {
    final row = await (db.select(db.keyValueSettings)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> _set(String key, String value) async {
    await db.into(db.keyValueSettings).insertOnConflictUpdate(
          KeyValueSettingsCompanion.insert(key: key, value: value),
        );
  }

  /// This device's id (a plain UUIDv4, minted once and then reused --
  /// docs/ARCHITEKTUR.md section 5's `device_id`).
  Future<String> deviceId() async {
    final existing = await _get(SettingsKeys.deviceId);
    if (existing != null) return existing;
    final fresh = Ids.uuid();
    await _set(SettingsKeys.deviceId, fresh);
    return fresh;
  }

  Future<String?> serverUrl() => _get(SettingsKeys.serverUrl);
  Future<void> setServerUrl(String url) => _set(SettingsKeys.serverUrl, url);

  Future<String?> serverToken() => _get(SettingsKeys.serverToken);
  Future<void> setServerToken(String token) => _set(SettingsKeys.serverToken, token);

  /// Night window in minutes since local midnight (docs/KONZEPT.md "Faden
  /// aufnehmen": default 20:00-06:00). Falls back to the Resolver's own
  /// default when unset.
  Future<int> nightStartMin() async {
    final v = await _get(SettingsKeys.nightStartMin);
    return v == null ? 20 * 60 : int.parse(v);
  }

  Future<void> setNightStartMin(int minutes) =>
      _set(SettingsKeys.nightStartMin, minutes.toString());

  Future<int> nightEndMin() async {
    final v = await _get(SettingsKeys.nightEndMin);
    return v == null ? 6 * 60 : int.parse(v);
  }

  Future<void> setNightEndMin(int minutes) =>
      _set(SettingsKeys.nightEndMin, minutes.toString());

  /// Default sleep-timer duration in minutes (docs/KONZEPT.md
  /// "Nachtmodus": 15/30/45/60 or chapter-end; 0 encodes chapter-end).
  Future<int> sleepTimerDefaultMin() async {
    final v = await _get(SettingsKeys.sleepTimerDefaultMin);
    return v == null ? 30 : int.parse(v);
  }

  Future<void> setSleepTimerDefaultMin(int minutes) =>
      _set(SettingsKeys.sleepTimerDefaultMin, minutes.toString());

  /// The book last opened in the player (docs/ARCHITEKTUR.md section 11:
  /// "Start ist der Player" -- main.dart uses this to reopen it straight
  /// away on the next app start instead of landing on the library).
  Future<String?> lastOpenedBookId() => _get(SettingsKeys.lastOpenedBookId);

  Future<void> setLastOpenedBookId(String bookId) =>
      _set(SettingsKeys.lastOpenedBookId, bookId);

  /// docs/KONZEPT.md "Screens": "Schlafdaten erlauben" -- M6's opt-in for
  /// reading local sleep data (docs/ARCHITEKTUR.md section 9, decision E6).
  /// Off by default: an unset key must behave exactly like an explicit
  /// "no", since the whole feature is additive and gated behind this
  /// setting (ui/providers.dart's `PlayerSessionController.sleepOnsetAdjustment`
  /// treats `optedIn: false` the same as no [SleepDataSource] at all).
  Future<bool> healthDataOptIn() async {
    final v = await _get(SettingsKeys.healthDataOptIn);
    return v == 'true';
  }

  Future<void> setHealthDataOptIn(bool optIn) =>
      _set(SettingsKeys.healthDataOptIn, optIn.toString());
}
