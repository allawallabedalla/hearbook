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
    'resumeFromStop': 'Weiter, wo es anhielt',
    'fadenModePrompt': 'Kennst du diese Stelle?',
    'fadenResultFound': 'Gefunden. Weiter ab hier.',
    'fadenLadderEarlier': 'Etwas früher anfangen',
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
    'libraryDownloading': 'Lädt …',
    'libraryDownloadFailed': 'Herunterladen fehlgeschlagen',
    'libraryEmpty': 'Noch keine Bücher.',
    'libraryRetry': 'Erneut versuchen',
    'reviewDialogTitle': 'Reihenfolge prüfen',
    'reviewDialogBody': 'Die Dateien dieses Buchs lassen sich verschieden ordnen. Wähle die Reihenfolge, die stimmt.',
    'reviewDialogConfirm': 'Übernehmen',
    'reviewDialogCancel': 'Abbrechen',
    'reviewDialogOption': 'Reihenfolge {n}',
    'settingsTitle': 'Einstellungen',
    'settingsServerUrl': 'Server-Adresse',
    'settingsServerToken': 'Zugangs-Token',
    'settingsSave': 'Speichern',
    'settingsSaved': 'Gespeichert.',
    'settingsHealthDataOptIn': 'Schlafdaten erlauben',
    'settingsHealthDataOptInDescription': 'Liest lokal den Schlafbeginn aus {source}, um die Faden-Suche zu verkürzen. Verlässt nie dieses Gerät.',
    'detailsChapters': 'Kapitel',
    'detailsHistory': 'Verlauf',
    'detailsSpeed': 'Tempo',
    'detailsSleepTimer': 'Sleep-Timer',
    'sleepTimerOff': 'Aus',
    'sleepTimerChapterEnd': 'Kapitelende',
    'sleepTimerMinutes': '{n} Min.',
    'chapterLabel': 'Kapitel {n}',
    'chapterOfTotal': 'Kapitel {n} von {total}',
    'remainingTime': 'noch {time}',
    'playAction': 'Wiedergabe starten',
    'pauseAction': 'Pause',
    'seekBackAction': '30 Sekunden zurück',
    'seekForwardAction': '30 Sekunden vor',
    'confirmManifestSuccess': 'Reihenfolge übernommen.',
    'settingsServerSection': 'Server',
    'settingsNightWindowTitle': 'Nachtfenster',
    'settingsNightWindowExplanation': 'In dieser Zeit rechnet Faden damit, dass du einschläfst: Läuft das Hörbuch länger als 3 Minuten, ohne dass du etwas tippst oder drückst, bietet Faden danach „Faden aufnehmen“ an, nach 20 Minuten auch, wenn die Kopfhörer die Verbindung verloren haben. Tagsüber nur, wenn Kopfhörer oder Sperrbildschirm die Wiedergabe angehalten haben – nie im Auto.',
    'settingsNightWindowStartPicker': 'Nacht beginnt um',
    'settingsNightWindowEndPicker': 'Nacht endet um',
    'timePickerConfirm': 'Übernehmen',
    'timePickerCancel': 'Abbrechen',
    'settingsAppearanceTitle': 'Erscheinungsbild',
    'settingsAppearanceSystem': 'Wie iPhone',
    'settingsAppearanceLight': 'Hell',
    'settingsAppearanceDark': 'Dunkel',
    'settingsAppearanceNightNote': 'Steht die Bildschirmhelligkeit unter 30 %, ist Faden immer dunkel und der Player zeigt kein Cover.',
    'miniPlayerOpen': 'Player öffnen',
    'remotePositionAdopted': 'Position vom anderen Gerät übernommen',
    'connectionOk': 'Verbindung steht.',
    'connectionUnauthorized': 'Falscher Token. Der Server lehnt ihn ab.',
    'connectionUnreachable': 'Server nicht erreichbar. Adresse und Netz prüfen.',
    'connectionInvalidUrl': 'Ungültige Adresse.',
    'playbackError': 'Kann nicht abspielen',
    'downloadCancel': 'Download abbrechen',
    'downloadDelete': 'Download löschen',
    'healthSourceIos': 'Health',
    'healthSourceAndroid': 'Health Connect',
    'settingsNightWindowStart': 'Beginn',
    'settingsNightWindowEnd': 'Ende',
    'settingsCheckConnection': 'Verbindung prüfen',
    'settingsChecking': 'Prüfe …',
    'settingsStorageTitle': 'Speicher',
    'storageTotal': 'Geladen: {size}',
    'storageNone': 'Noch keine Bücher geladen.',
    'deleteConfirmTitle': 'Download löschen?',
    'deleteConfirmBody': '„{title}“ wird vom Gerät gelöscht. Du kannst es jederzeit wieder laden. Dein Fortschritt bleibt.',
    'deleteAction': 'Löschen',
    'cancelAction': 'Abbrechen',
    'durationHoursMinutes': '{h} Std. {m} Min.',
    'durationHours': '{h} Std.',
    'durationMinutes': '{m} Min.',
    'libraryProgressFinished': 'gehört',
    'libraryContinueSection': 'Weiterhören',
    'libraryAllBooks': 'Alle Bücher',
    'librarySearchHint': 'Titel oder Autor suchen',
    'librarySortTooltip': 'Sortieren',
    'librarySortRecent': 'Zuletzt gehört',
    'librarySortTitle': 'Titel',
    'librarySortAuthor': 'Autor',
    'libraryNoMatches': 'Nichts gefunden.',
    'libraryEmptyHint': 'Lege auf dem Server je Buch einen Ordner mit MP3-Dateien an. Zum Aktualisieren nach unten ziehen.',
    'offlineBanner': 'Offline – geladene Bücher spielen weiter',
    'setupTitle': 'Willkommen bei Faden',
    'setupBody': 'Verbinde die App mit deinem Hörbuch-Server. Danach erscheinen hier deine Bücher.',
    'setupAction': 'Server einrichten',
    'libraryIncompleteExplain': 'Auf dem Server fehlen noch Dateien dieses Buchs.',
    'libraryEmptyExplain': 'In diesem Ordner liegen keine Hördateien.',
    'libraryOpenFailed': 'Dieses Buch lässt sich erst mit Verbindung zum Server öffnen.',
    'libraryPartial': 'teilweise geladen',
    'downloadDeleteWithSize': 'Download löschen · {size}',
    'sizeMegabytes': '{n} MB',
    'sizeGigabytes': '{n} GB',
    'reviewDialogChoose': 'Diese nehmen',
    'reviewTrack': 'Track {n}',
    'reviewUntitled': 'ohne Titel',
    'reviewMoreFiles': 'und {n} weitere',
    'playbackLoading': 'Lädt …',
    'detailsOpen': 'Details öffnen',
    'threadLabel': 'Fortschritt im Buch',
    'threadValue': '{n} % gehört',
    'detailsAllChapters': 'Alle {n} Kapitel',
    'scrubberLabel': 'Position im Kapitel',
    'sleepTimerStart': 'Starten · {duration}',
    'sleepTimerRunning': 'noch {time}',
    'sleepTimerUntilChapterEnd': 'bis Kapitelende · {time}',
    'speedLabel': '{n}×',
    'scrubberRemaining': '−{time}',
    'offlineNotDownloaded': 'Nicht geladen – der Server ist gerade nicht erreichbar.',
    'libraryOnlineOnly': '{status} · nur online',
    'settingsAutoDownload': 'Aktuelle Bücher automatisch laden',
    'settingsAutoDownloadDescription': 'Lädt im WLAN das offene Buch und das nächste aus „Weiterhören“, solange der Server erreichbar ist. Nie über Mobilfunk.',
    'storageFinishedNote': 'Zu Ende gehörte Bücher werden automatisch vom Gerät gelöscht. Der Fortschritt bleibt.',
    'downloadRemaining': 'noch {size}',
    'playerClose': 'Zur Bibliothek',
    'fadenKnown': 'Kenne ich',
    'fadenUnknown': 'Kenne ich nicht',
    'fadenReplay': 'Nochmal hören',
    'fadenAbort': 'Abbrechen',
    'fadenAbortHint': 'Zurück zum Player, ohne etwas zu ändern',
    'fadenStarting': 'Gleich kommt die erste Hörprobe.',
    'fadenPassage': '{chapter} · {time}',
    'fadenBeforeStop': '{time} bevor es anhielt',
    'durationSeconds': '{n} Sek.',
    'fadenAnswerWindow': 'Zeit zum Antworten',
    'fadenHeardTitle': 'Bisher gefragt',
    'fadenHeardKnown': 'kannte ich',
    'fadenHeardUnknown': 'kannte ich nicht',
    'fadenAlternativesTitle': 'Oder hier weiterhören',
    'fadenPlaying': 'läuft',
    'fadenDone': 'Fertig',
    'reviewOffline': 'Reihenfolge prüfen geht nur mit Verbindung zum Server.',
    'reviewNothingToChoose': 'Keine andere Reihenfolge zur Auswahl. Zum Aktualisieren nach unten ziehen.',
    'reviewLoadFailed': 'Die Reihenfolgen ließen sich nicht laden. Bitte erneut versuchen.',
    'confirmManifestFailed': 'Die Reihenfolge ließ sich nicht übernehmen. Bitte erneut versuchen.',
    'libraryOpening': 'Öffnet …',
    'settingsServerUrlHint': 'http://nas.local:8787',
    'settingsTokenShow': 'Token zeigen',
    'settingsTokenHide': 'Token verbergen',
    'settingsCellularChapters': 'Über Mobilfunk kapitelweise laden',
    'settingsCellularHint': 'Hinweis vor dem Laden über Mobilfunk',
    'settingsCellularChaptersDescription': 'Ohne WLAN lädt Faden beim Hören nur das aktuelle und das nächste Kapitel, dann immer eins weiter. Ganze Bücher nur im WLAN.',
    'cellularPromptTitle': 'Über Mobilfunk laden?',
    'cellularPromptBody': 'Faden lädt beim Hören das aktuelle und das nächste Kapitel.',
    'cellularPerHour': '1 Std. ≈ {size}',
    'cellularPerHourApprox': '1 Std. ca. {size}',
    'cellularChapterSize': '{chapter} ≈ {size}',
    'cellularChapterSizeApprox': '{chapter} ca. {size}',
    'cellularPromptDontShowAgain': 'Nicht wieder anzeigen',
    'cellularPromptLoad': 'Laden',
    'cellularPromptNotNow': 'Nicht jetzt',
    'playerAppearanceDark': 'Dunkel einschalten',
    'playerAppearanceLight': 'Hell einschalten',
    'libraryFilterAll': 'Alle',
    'libraryFilterStarted': 'Läuft',
    'libraryFilterUnstarted': 'Neu',
    'libraryFilterFinished': 'Gehört',
    'libraryFilterGenre': 'Genre',
    'libraryFilterAllGenres': 'Alle Genres',
    'libraryFilterEmpty': 'Keine Bücher in diesem Filter.',
    'librarySortLength': 'Länge',
    'libraryGroupList': 'Liste',
    'libraryGroupAuthor': 'Nach Autor',
    'libraryUnknownAuthor': 'Unbekannt',
    'genreChange': 'Genre ändern',
    'genreAutomatic': 'Automatisch',
    'genreNone': 'Kein Genre',
    'genreOffline': 'Nur mit Verbindung zum Server.',
    'genreChangeFailed': 'Das Genre ließ sich nicht ändern. Bitte erneut versuchen.',
    'libraryGroupGrid': 'Kacheln',
    'libraryPercent': '{n} %',
    'playerNextUp': 'Als Nächstes:',
    'playerNextChapter': '{chapter} · {title}',
    'settingsFadenSearchTitle': 'Faden-Suche',
    'settingsProbeLength': '{n} Sekunden',
    'settingsProbeLengthExplanation': 'So lange spielt jede Hörprobe. Kürzere Proben sind schneller vorbei, längere erkennst du leichter wieder.',
    'settingsSleepOnsetsTitle': 'Deine Einschlafzeiten',
    'settingsSleepOnsetsEmpty': 'Noch keine. Nach jeder Faden-Suche in der Nacht steht hier, wann du ungefähr eingeschlafen bist.',
    'settingsSleepOnsetsExplanation': 'Die letzte Stelle, die du bei der Faden-Suche wiedererkannt hast, als Uhrzeit, nur aus Nächten oder nach dem Sleep-Timer. Ab 5 Nächten fragt Faden zuerst dort, wo du nach dem letzten Tippen meist eingeschlafen bist. Zum Löschen nach links wischen. Bleibt auf diesem Gerät.',
    'settingsNightWindowSuggestion': 'Vorschlag: {time} übernehmen',
    'settingsHealthWrite': 'Einschlafzeit in Health eintragen',
    'settingsHealthWriteDescription': 'Trägt nach der Faden-Suche „Im Bett“ von der errechneten Einschlafzeit bis zu deiner ersten Berührung am Morgen in Health ein, nur wenn für die Nacht noch keine Schlafdaten da sind. Bleibt auf dem iPhone.',
    'settingsHealthWriteDenied': 'Health erlaubt Faden das Eintragen nicht. Du kannst es in der Health-App unter Datenzugriff freigeben.',
    'fadenQuestionsLeft': 'Noch höchstens {n} Fragen',
    'fadenQuestionsLeftOne': 'Noch höchstens 1 Frage',
    'fadenQuestionsLast': 'Letzte Frage',
    'fadenHeardAt': 'gehört gegen {time} Uhr',
    'fadenResultStillAwake': 'Du warst noch wach. Weiter kurz bevor es anhielt.',
    'fadenResultNothing': 'Nichts wiedererkannt. Weiter ab deiner letzten Berührung.',
    'fadenResultLastTouch': 'Weiter ab deiner letzten Berührung.',
    'fadenRecheck': 'Nochmal prüfen',
    'mainButtonAsleepSearch': 'Eingeschlafen? Stelle suchen',
    'undoHintFaden': 'Rückgängig: wieder, wo es anhielt',
    'undoActionBack': 'Zurück',
    'asleepPromptTitle': 'Eingeschlafen?',
    'asleepPromptPlayingHour': 'Du hörst seit über einer Stunde, ohne etwas anzutippen.',
    'asleepPromptStoppedHour': 'Es lief über eine Stunde, ohne dass du etwas angetippt hast.',
    'asleepPromptPlayingMinutes': 'Du hörst seit {n} Min., ohne etwas anzutippen.',
    'asleepPromptStoppedMinutes': 'Es lief {n} Min., ohne dass du etwas angetippt hast.',
    'asleepPromptYes': 'Ja, Stelle suchen',
    'asleepPromptNo': 'Nein, weiterhören',
    'settingsSleepOnsetDelete': 'Löschen',
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
  static String get undoAction => _of('undoAction');
  static String get libraryFolderChanged => _of('libraryFolderChanged');
  static String get offlineNotice => _of('offlineNotice');
  static String get libraryTitle => _of('libraryTitle');
  static String get playerClose => _of('playerClose');
  static String get libraryStatusDownloaded => _of('libraryStatusDownloaded');
  static String get libraryStatusNew => _of('libraryStatusNew');
  static String get libraryStatusIncomplete => _of('libraryStatusIncomplete');
  static String get libraryStatusEmpty => _of('libraryStatusEmpty');
  static String get libraryDownloadAction => _of('libraryDownloadAction');
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
  static String get settingsSave => _of('settingsSave');
  static String get settingsSaved => _of('settingsSaved');
  static String get settingsHealthDataOptIn => _of('settingsHealthDataOptIn');
  static String get detailsChapters => _of('detailsChapters');
  static String get detailsHistory => _of('detailsHistory');
  static String get detailsSpeed => _of('detailsSpeed');
  static String get detailsSleepTimer => _of('detailsSleepTimer');
  static String get sleepTimerOff => _of('sleepTimerOff');
  static String get sleepTimerChapterEnd => _of('sleepTimerChapterEnd');
  static String get playAction => _of('playAction');
  static String get pauseAction => _of('pauseAction');
  static String get seekBackAction => _of('seekBackAction');
  static String get seekForwardAction => _of('seekForwardAction');
  static String get confirmManifestSuccess => _of('confirmManifestSuccess');
  static String get settingsServerSection => _of('settingsServerSection');
  static String get settingsNightWindowTitle => _of('settingsNightWindowTitle');
  static String get settingsNightWindowExplanation => _of('settingsNightWindowExplanation');
  static String get settingsNightWindowStartPicker => _of('settingsNightWindowStartPicker');
  static String get settingsNightWindowEndPicker => _of('settingsNightWindowEndPicker');
  static String get timePickerConfirm => _of('timePickerConfirm');
  static String get timePickerCancel => _of('timePickerCancel');
  static String get settingsAppearanceTitle => _of('settingsAppearanceTitle');
  static String get settingsAppearanceSystem => _of('settingsAppearanceSystem');
  static String get settingsAppearanceLight => _of('settingsAppearanceLight');
  static String get settingsAppearanceDark => _of('settingsAppearanceDark');
  static String get settingsAppearanceNightNote => _of('settingsAppearanceNightNote');
  static String get miniPlayerOpen => _of('miniPlayerOpen');
  static String get remotePositionAdopted => _of('remotePositionAdopted');
  static String get connectionOk => _of('connectionOk');
  static String get connectionUnauthorized => _of('connectionUnauthorized');
  static String get connectionUnreachable => _of('connectionUnreachable');
  static String get connectionInvalidUrl => _of('connectionInvalidUrl');
  static String get playbackError => _of('playbackError');
  static String get downloadCancel => _of('downloadCancel');
  static String get downloadDelete => _of('downloadDelete');
  static String get healthSourceIos => _of('healthSourceIos');
  static String get healthSourceAndroid => _of('healthSourceAndroid');
  static String get settingsNightWindowStart => _of('settingsNightWindowStart');
  static String get settingsNightWindowEnd => _of('settingsNightWindowEnd');
  static String get settingsCheckConnection => _of('settingsCheckConnection');
  static String get settingsChecking => _of('settingsChecking');
  static String get settingsStorageTitle => _of('settingsStorageTitle');
  static String get storageNone => _of('storageNone');
  static String get deleteConfirmTitle => _of('deleteConfirmTitle');
  static String get deleteAction => _of('deleteAction');
  static String get cancelAction => _of('cancelAction');
  static String get libraryProgressFinished => _of('libraryProgressFinished');
  static String get libraryContinueSection => _of('libraryContinueSection');
  static String get libraryAllBooks => _of('libraryAllBooks');
  static String get librarySearchHint => _of('librarySearchHint');
  static String get librarySortTooltip => _of('librarySortTooltip');
  static String get librarySortRecent => _of('librarySortRecent');
  static String get librarySortTitle => _of('librarySortTitle');
  static String get librarySortAuthor => _of('librarySortAuthor');
  static String get libraryNoMatches => _of('libraryNoMatches');
  static String get libraryEmptyHint => _of('libraryEmptyHint');
  static String get offlineBanner => _of('offlineBanner');
  static String get offlineNotDownloaded => _of('offlineNotDownloaded');
  static String get settingsAutoDownload => _of('settingsAutoDownload');
  static String get settingsAutoDownloadDescription => _of('settingsAutoDownloadDescription');
  static String get storageFinishedNote => _of('storageFinishedNote');
  static String get setupTitle => _of('setupTitle');
  static String get setupBody => _of('setupBody');
  static String get setupAction => _of('setupAction');
  static String get libraryIncompleteExplain => _of('libraryIncompleteExplain');
  static String get libraryEmptyExplain => _of('libraryEmptyExplain');
  static String get libraryOpenFailed => _of('libraryOpenFailed');
  static String get libraryPartial => _of('libraryPartial');
  static String get reviewDialogChoose => _of('reviewDialogChoose');
  static String get reviewUntitled => _of('reviewUntitled');
  static String get playbackLoading => _of('playbackLoading');
  static String get detailsOpen => _of('detailsOpen');
  static String get threadLabel => _of('threadLabel');
  static String get scrubberLabel => _of('scrubberLabel');
  static String get fadenKnown => _of('fadenKnown');
  static String get fadenUnknown => _of('fadenUnknown');
  static String get fadenReplay => _of('fadenReplay');
  static String get fadenAbort => _of('fadenAbort');
  static String get fadenAbortHint => _of('fadenAbortHint');
  static String get fadenStarting => _of('fadenStarting');
  static String get fadenAnswerWindow => _of('fadenAnswerWindow');
  static String get fadenHeardTitle => _of('fadenHeardTitle');
  static String get fadenHeardKnown => _of('fadenHeardKnown');
  static String get fadenHeardUnknown => _of('fadenHeardUnknown');
  static String get fadenAlternativesTitle => _of('fadenAlternativesTitle');
  static String get fadenPlaying => _of('fadenPlaying');
  static String get fadenDone => _of('fadenDone');
  static String get reviewOffline => _of('reviewOffline');
  static String get reviewNothingToChoose => _of('reviewNothingToChoose');
  static String get reviewLoadFailed => _of('reviewLoadFailed');
  static String get confirmManifestFailed => _of('confirmManifestFailed');
  static String get libraryOpening => _of('libraryOpening');
  static String get settingsServerUrlHint => _of('settingsServerUrlHint');
  static String get settingsTokenShow => _of('settingsTokenShow');
  static String get settingsTokenHide => _of('settingsTokenHide');

  /// "Noch höchstens 6 Fragen" (E89) for [n] questions left after this one;
  /// "Noch höchstens 1 Frage", and "Letzte Frage" when none is left.
  static String fadenQuestionsLeft(int n) {
    if (n <= 0) return _of('fadenQuestionsLast');
    if (n == 1) return _of('fadenQuestionsLeftOne');
    return _of('fadenQuestionsLeft').replaceAll('{n}', '$n');
  }

  /// "gehört gegen 23:12 Uhr" (E89); [time] is a local HH:MM clock time.
  static String fadenHeardAt(String time) => _of('fadenHeardAt').replaceAll('{time}', time);

  /// The body of "Eingeschlafen?" (E84) with the whole minutes listened.
  static String asleepPromptPlayingMinutes(int n) => _of('asleepPromptPlayingMinutes').replaceAll('{n}', '$n');
  static String asleepPromptStoppedMinutes(int n) => _of('asleepPromptStoppedMinutes').replaceAll('{n}', '$n');

  /// KONZEPT.md Texte-Tabelle: "Zurück zu Kapitel 7, 23:41". [chapter] is
  /// an already-formatted [chapterLabel] and [time] an mm:ss string.
  static String undoHint(String chapter, String time) =>
      _of('undoHint').replaceAll('{chapter}', chapter).replaceAll('{time}', time);

  static String reviewDialogOption(int n) => _of('reviewDialogOption').replaceAll('{n}', '$n');

  static String settingsHealthDataOptInDescription(String source) =>
      _of('settingsHealthDataOptInDescription').replaceAll('{source}', source);

  static String sleepTimerMinutes(int n) => _of('sleepTimerMinutes').replaceAll('{n}', '$n');

  static String chapterLabel(int n) => _of('chapterLabel').replaceAll('{n}', '$n');

  static String chapterOfTotal(int n, int total) =>
      _of('chapterOfTotal').replaceAll('{n}', '$n').replaceAll('{total}', '$total');

  static String remainingTime(String time) => _of('remainingTime').replaceAll('{time}', time);

  static String storageTotal(String size) => _of('storageTotal').replaceAll('{size}', size);

  static String deleteConfirmBody(String title) =>
      _of('deleteConfirmBody').replaceAll('{title}', title);

  static String durationHoursMinutes(int h, int m) =>
      _of('durationHoursMinutes').replaceAll('{h}', '$h').replaceAll('{m}', '$m');

  static String durationHours(int h) => _of('durationHours').replaceAll('{h}', '$h');

  static String durationMinutes(int m) => _of('durationMinutes').replaceAll('{m}', '$m');

  /// A running download's rest, "noch 240 MB" (E62).
  static String downloadRemaining(String size) => _of('downloadRemaining').replaceAll('{size}', size);

  static String downloadDeleteWithSize(String size) =>
      _of('downloadDeleteWithSize').replaceAll('{size}', size);

  static String sizeMegabytes(String n) => _of('sizeMegabytes').replaceAll('{n}', n);

  static String sizeGigabytes(String n) => _of('sizeGigabytes').replaceAll('{n}', n);

  static String reviewTrack(int n) => _of('reviewTrack').replaceAll('{n}', '$n');

  static String reviewMoreFiles(int n) => _of('reviewMoreFiles').replaceAll('{n}', '$n');

  static String threadValue(int n) => _of('threadValue').replaceAll('{n}', '$n');

  static String detailsAllChapters(int n) => _of('detailsAllChapters').replaceAll('{n}', '$n');

  static String sleepTimerStart(String duration) =>
      _of('sleepTimerStart').replaceAll('{duration}', duration);

  static String sleepTimerRunning(String time) =>
      _of('sleepTimerRunning').replaceAll('{time}', time);

  static String sleepTimerUntilChapterEnd(String time) =>
      _of('sleepTimerUntilChapterEnd').replaceAll('{time}', time);

  static String speedLabel(String n) => _of('speedLabel').replaceAll('{n}', n);

  static String scrubberRemaining(String time) =>
      _of('scrubberRemaining').replaceAll('{time}', time);

  /// Where a Faden probe lies (E64): "Kapitel 5 · 23:14".
  static String fadenPassage(String chapter, String time) =>
      _of('fadenPassage').replaceAll('{chapter}', chapter).replaceAll('{time}', time);

  /// A probe's distance to the stop point (E64): "4 Min. vor dem Stopp".
  static String fadenBeforeStop(String time) => _of('fadenBeforeStop').replaceAll('{time}', time);

  static String durationSeconds(int n) => _of('durationSeconds').replaceAll('{n}', '$n');

  /// A library status line plus "nur online" (E58).
  static String libraryOnlineOnly(String status) => _of('libraryOnlineOnly').replaceAll('{status}', status);

  static String get settingsCellularChapters => _of('settingsCellularChapters');
  static String get settingsCellularHint => _of('settingsCellularHint');
  static String get settingsCellularChaptersDescription => _of('settingsCellularChaptersDescription');
  static String get cellularPromptTitle => _of('cellularPromptTitle');
  static String get cellularPromptBody => _of('cellularPromptBody');
  static String get cellularPromptDontShowAgain => _of('cellularPromptDontShowAgain');
  static String get cellularPromptLoad => _of('cellularPromptLoad');
  static String get cellularPromptNotNow => _of('cellularPromptNotNow');

  /// Mobile-data estimate per hour (E66): "1 Std. ≈ 58 MB", or with
  /// "ca." when estimated from the assumed bit rate.
  static String cellularPerHour(String size, {bool approximate = false}) =>
      _of(approximate ? 'cellularPerHourApprox' : 'cellularPerHour').replaceAll('{size}', size);

  /// "Kapitel 3 ≈ 24 MB" (E66), or with "ca.".
  static String cellularChapterSize(String chapter, String size, {bool approximate = false}) =>
      _of(approximate ? 'cellularChapterSizeApprox' : 'cellularChapterSize')
          .replaceAll('{chapter}', chapter)
          .replaceAll('{size}', size);

  // Library filters and grouping, genre (E70); player appearance (E69).
  static String get playerAppearanceDark => _of('playerAppearanceDark');
  static String get playerAppearanceLight => _of('playerAppearanceLight');
  static String get libraryFilterAll => _of('libraryFilterAll');
  static String get libraryFilterStarted => _of('libraryFilterStarted');
  static String get libraryFilterUnstarted => _of('libraryFilterUnstarted');
  static String get libraryFilterFinished => _of('libraryFilterFinished');
  static String get libraryFilterGenre => _of('libraryFilterGenre');
  static String get libraryFilterAllGenres => _of('libraryFilterAllGenres');
  static String get libraryFilterEmpty => _of('libraryFilterEmpty');
  static String get librarySortLength => _of('librarySortLength');
  static String get libraryGroupList => _of('libraryGroupList');
  static String get libraryGroupAuthor => _of('libraryGroupAuthor');
  static String get libraryUnknownAuthor => _of('libraryUnknownAuthor');
  static String get genreChange => _of('genreChange');
  static String get genreAutomatic => _of('genreAutomatic');
  static String get genreNone => _of('genreNone');
  static String get genreOffline => _of('genreOffline');
  static String get genreChangeFailed => _of('genreChangeFailed');
  static String get libraryGroupGrid => _of('libraryGroupGrid');
  static String get playerNextUp => _of('playerNextUp');

  /// "34 %" in the large "Weiterhören" card's capsule (E73).
  static String libraryPercent(int n) => _of('libraryPercent').replaceAll('{n}', '$n');

  /// "Kapitel 5 · Der Weg" in the player's "Als Nächstes" peek (E74).
  static String playerNextChapter(String chapter, String title) =>
      _of('playerNextChapter').replaceAll('{chapter}', chapter).replaceAll('{title}', title);

  // Faden-Suche lernt mit (E77-E82).
  static String get settingsFadenSearchTitle => _of('settingsFadenSearchTitle');
  static String get settingsProbeLengthExplanation => _of('settingsProbeLengthExplanation');
  static String get settingsSleepOnsetsTitle => _of('settingsSleepOnsetsTitle');
  static String get settingsSleepOnsetsEmpty => _of('settingsSleepOnsetsEmpty');
  static String get settingsSleepOnsetsExplanation => _of('settingsSleepOnsetsExplanation');
  static String get settingsHealthWrite => _of('settingsHealthWrite');
  static String get settingsHealthWriteDescription => _of('settingsHealthWriteDescription');
  static String get settingsHealthWriteDenied => _of('settingsHealthWriteDenied');

  /// "6 Sekunden", one probe-length choice (E77).
  static String settingsProbeLength(int seconds) => _of('settingsProbeLength').replaceAll('{n}', '$seconds');

  /// "Vorschlag: 22:30–01:00 übernehmen" (E81); [range] is already formatted.
  static String settingsNightWindowSuggestion(String range) =>
      _of('settingsNightWindowSuggestion').replaceAll('{time}', range);

  // Faden aufnehmen, audit and "Eingeschlafen?" (E84-E91).
  static String get fadenResultStillAwake => _of('fadenResultStillAwake');
  static String get fadenResultNothing => _of('fadenResultNothing');
  static String get fadenResultLastTouch => _of('fadenResultLastTouch');
  static String get fadenRecheck => _of('fadenRecheck');
  static String get mainButtonAsleepSearch => _of('mainButtonAsleepSearch');
  static String get undoHintFaden => _of('undoHintFaden');
  static String get undoActionBack => _of('undoActionBack');
  static String get asleepPromptTitle => _of('asleepPromptTitle');
  static String get asleepPromptPlayingHour => _of('asleepPromptPlayingHour');
  static String get asleepPromptStoppedHour => _of('asleepPromptStoppedHour');
  static String get asleepPromptYes => _of('asleepPromptYes');
  static String get asleepPromptNo => _of('asleepPromptNo');
  static String get settingsSleepOnsetDelete => _of('settingsSleepOnsetDelete');
}
