/// UI texts, German only (CLAUDE.md: "UI-Texte auf Deutsch, nur über die
/// l10n-Datei"). `l10n/app_de.arb` is the authoritative source -- every
/// value below is copied from it verbatim, and `test/l10n/strings_test.dart`
/// checks that word-for-word so the two can never drift silently. Widgets
/// only ever import this file, never a string literal of their own (see
/// decision E14 in docs/ARCHITEKTUR.md section 13 for why this is a plain
/// Dart map rather than Flutter's `flutter gen-l10n` pipeline).
class AppStrings {
  const AppStrings._();

  /// Keys and values exactly as in `l10n/app_de.arb` (metadata entries
  /// starting with `@` excluded). Placeholder syntax (`{name}`) is kept
  /// as-is; the typed formatter methods below substitute it.
  static const Map<String, String> values = {
    'appTitle': 'Faden',
    'mainButtonListen': 'Weiterhören',
    'mainButtonRecordThread': 'Faden aufnehmen',
    'resumeFromStop': 'Ab Stopp weiterhören',
    'fadenModePrompt': 'Kennst du das? Dann tippen.',
    'fadenResultFound': 'Gefunden. Weiter ab hier.',
    'fadenLadderEarlier': 'Früher',
    'fadenProbeCounter': 'Probe {n} von höchstens {max}',
    'undoHint': 'Zurück zu {chapter}, {time}',
    'undoAction': 'Rückgängig',
    'libraryFolderChanged': 'Ordner geändert: Reihenfolge prüfen',
    'offlineNotice': 'Keine Verbindung zum Server. Geladene Bücher spielen weiter.',
    'libraryTitle': 'Bibliothek',
    'libraryStatusDownloaded': 'geladen',
    'libraryStatusNew': 'neu',
    'libraryStatusIncomplete': 'unvollständig',
    'libraryStatusEmpty': 'keine Dateien',
    'libraryDownloadAction': 'Herunterladen',
    'libraryOpenAction': 'Öffnen',
    'libraryDownloading': 'Lädt …',
    'libraryDownloadFailed': 'Herunterladen fehlgeschlagen',
    'libraryEmpty': 'Keine Bücher gefunden.',
    'libraryRetry': 'Erneut versuchen',
    'reviewDialogTitle': 'Reihenfolge prüfen',
    'reviewDialogBody':
        'Für dieses Buch gibt es mehr als eine mögliche Reihenfolge. Wähle die richtige.',
    'reviewDialogConfirm': 'Übernehmen',
    'reviewDialogCancel': 'Abbrechen',
    'reviewDialogOption': 'Option {n}',
    'settingsTitle': 'Einstellungen',
    'settingsServerUrl': 'Server-Adresse',
    'settingsServerToken': 'Zugangs-Token',
    'settingsNightWindowStart': 'Nachtfenster Beginn',
    'settingsNightWindowEnd': 'Nachtfenster Ende',
    'settingsSave': 'Speichern',
    'settingsSaved': 'Gespeichert. Neu starten, damit es wirkt.',
    'detailsChapters': 'Kapitel',
    'detailsHistory': 'Verlauf',
    'detailsSpeed': 'Tempo',
    'detailsSleepTimer': 'Sleep-Timer',
    'sleepTimerOff': 'Aus',
    'sleepTimerChapterEnd': 'Kapitelende',
    'sleepTimerMinutes': '{n} Min',
    'chapterLabel': 'Kapitel {n}',
    'chapterOfTotal': 'Kapitel {n} von {total}',
    'remainingTime': 'noch {time}',
    'lockedHint': 'Gesperrt. Halten zum Entsperren.',
    'playAction': 'Wiedergabe starten',
    'pauseAction': 'Pause',
    'seekBackAction': '30 Sekunden zurück',
    'seekForwardAction': '30 Sekunden vor',
    'confirmManifestSuccess': 'Reihenfolge übernommen.',
  };

  static String _of(String key) {
    final v = values[key];
    if (v == null) throw ArgumentError('unknown l10n key: $key');
    return v;
  }

  static String get appTitle => _of('appTitle');
  static String get mainButtonListen => _of('mainButtonListen');
  static String get mainButtonRecordThread => _of('mainButtonRecordThread');
  static String get resumeFromStop => _of('resumeFromStop');
  static String get fadenModePrompt => _of('fadenModePrompt');
  static String get fadenResultFound => _of('fadenResultFound');
  static String get fadenLadderEarlier => _of('fadenLadderEarlier');

  static String fadenProbeCounter(int n, int max) =>
      _of('fadenProbeCounter').replaceAll('{n}', '$n').replaceAll('{max}', '$max');
  static String get undoAction => _of('undoAction');
  static String get libraryFolderChanged => _of('libraryFolderChanged');
  static String get offlineNotice => _of('offlineNotice');
  static String get libraryTitle => _of('libraryTitle');
  static String get libraryStatusDownloaded => _of('libraryStatusDownloaded');
  static String get libraryStatusNew => _of('libraryStatusNew');
  static String get libraryStatusIncomplete => _of('libraryStatusIncomplete');
  static String get libraryStatusEmpty => _of('libraryStatusEmpty');
  static String get libraryDownloadAction => _of('libraryDownloadAction');
  static String get libraryOpenAction => _of('libraryOpenAction');
  static String get libraryDownloading => _of('libraryDownloading');
  static String get libraryDownloadFailed => _of('libraryDownloadFailed');
  static String get libraryEmpty => _of('libraryEmpty');
  static String get libraryRetry => _of('libraryRetry');
  static String get reviewDialogTitle => _of('reviewDialogTitle');
  static String get reviewDialogBody => _of('reviewDialogBody');
  static String get reviewDialogConfirm => _of('reviewDialogConfirm');
  static String get reviewDialogCancel => _of('reviewDialogCancel');
  static String get settingsTitle => _of('settingsTitle');
  static String get settingsServerUrl => _of('settingsServerUrl');
  static String get settingsServerToken => _of('settingsServerToken');
  static String get settingsNightWindowStart => _of('settingsNightWindowStart');
  static String get settingsNightWindowEnd => _of('settingsNightWindowEnd');
  static String get settingsSave => _of('settingsSave');
  static String get settingsSaved => _of('settingsSaved');
  static String get detailsChapters => _of('detailsChapters');
  static String get detailsHistory => _of('detailsHistory');
  static String get detailsSpeed => _of('detailsSpeed');
  static String get detailsSleepTimer => _of('detailsSleepTimer');
  static String get sleepTimerOff => _of('sleepTimerOff');
  static String get sleepTimerChapterEnd => _of('sleepTimerChapterEnd');
  static String get lockedHint => _of('lockedHint');
  static String get playAction => _of('playAction');
  static String get pauseAction => _of('pauseAction');
  static String get seekBackAction => _of('seekBackAction');
  static String get seekForwardAction => _of('seekForwardAction');
  static String get confirmManifestSuccess => _of('confirmManifestSuccess');

  /// KONZEPT.md Texte-Tabelle: "Zurück zu Kapitel 7, 23:41". [chapter] is
  /// an already-formatted [chapterLabel] and [time] an mm:ss string.
  static String undoHint(String chapter, String time) =>
      _of('undoHint').replaceAll('{chapter}', chapter).replaceAll('{time}', time);

  static String reviewDialogOption(int n) =>
      _of('reviewDialogOption').replaceAll('{n}', '$n');

  static String sleepTimerMinutes(int n) =>
      _of('sleepTimerMinutes').replaceAll('{n}', '$n');

  static String chapterLabel(int n) => _of('chapterLabel').replaceAll('{n}', '$n');

  static String chapterOfTotal(int n, int total) =>
      _of('chapterOfTotal').replaceAll('{n}', '$n').replaceAll('{total}', '$total');

  static String remainingTime(String time) => _of('remainingTime').replaceAll('{time}', time);
}
