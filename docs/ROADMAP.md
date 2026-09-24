# Roadmap

Jeder Meilenstein ist eine Claude-Code-Sitzung: Prompt einfügen, Plan prüfen, freigeben. Zwischen zwei Meilensteinen `/clear` eingeben, damit der Kontext frisch ist.

Zeiten = Claude-Code-Laufzeit plus dein Review, ohne Tests auf echten Geräten. Summe M0–M6: ≈ 780 Min.

## M0 – Prototyp „Faden aufnehmen“ (≈ 30 Min + 15 Min Selbsttest)

Ziel: die Kernidee an einem echten Hörbuch prüfen, bevor etwas anderes gebaut wird.

- [x] `prototype/faden.html`: eine Datei, läuft ohne Server im Browser (Desktop und Android-Chrome)
- [x] MP3 per Dateiauswahl laden; Satzanfänge per Web Audio erkennen (Stille ≥ 350 ms, Analyse mit niedriger Abtastrate, speicherschonend); scheitert die Erkennung, ohne Einrasten weiter
- [x] Fenster von/bis eingeben (mm:ss); Faden-Suche exakt nach `docs/ARCHITEKTUR.md` Abschnitt 8
- [x] „Kenne ich“ per Leertaste, Tipp irgendwo oder Mediataste (Media Session API); keine Antwort = „kenne ich nicht“
- [x] Nachtfarben und Faden-Darstellung aus `docs/KONZEPT.md`; Ergebnis, „Früher“ und „Weiterhören ab hier“
- [x] Protokoll (Probe, Position, Antwort, Gesamtdauer) zum Kopieren

```text
/plan Setze Meilenstein M0 aus docs/ROADMAP.md um. Spezifikation: docs/KONZEPT.md (Faden aufnehmen, Design, Texte) und docs/ARCHITEKTUR.md Abschnitt 8. Am Ende die Abnahme-Punkte in docs/ROADMAP.md abhaken und committen.
```

Selbsttest: 10 Min eines Kapitels hören, das du nicht kennst. Dann Fenster 00:00 bis 30:00 und Faden starten. Bestanden, wenn der Start höchstens 30 s vor 10:00 liegt, nie danach, und alles höchstens 60 s dauert. Echter Test: eine Nacht mit Sleep-Timer.

Hinweis: Faden-Suche gegen 20.000 simulierte Hörer (alle 5 Eigenschaften aus Abschnitt 8 grün) und der UI-Ablauf per Headless-Chromium mit synthetischem Testton verifiziert. Der Selbsttest mit einem echten Hörbuch und der Nacht-Test brauchen ein echtes Gerät und deine Ohren — das kann hier niemand für dich abnehmen.

## M1 – Server: Import, Manifest, Dateien (≈ 120 Min)

- [x] `server/` mit uv, FastAPI, pytest, ruff; `.env.example`
- [x] Audio-Hash nach Abschnitt 3.4 mit allen dort genannten Pflicht-Tests
- [x] Buch-Erkennung, Reihenfolge und Rescan-Regeln nach 3.1–3.3; ein Test pro Tabellenfall
- [x] Dauer (3.5), Metadaten und Cover (3.6), Pausen-Index (4); alles per Hash gecacht
- [x] API aus Abschnitt 10 ohne Events; Token-Auth; HTTP-Range für Dateien getestet
- [x] `Dockerfile` und `docker-compose.yml` (Ordner nur lesend); nach `docker compose up -d --build` antwortet `/api/v1/health`
- [x] Test-Audio wird in Tests per ffmpeg erzeugt (Sinus mit Stille-Lücken, verschiedene Tags)

```text
/plan Setze Meilenstein M1 aus docs/ROADMAP.md um. Spezifikation: docs/ARCHITEKTUR.md Abschnitte 2, 3, 4, 10 und 12. Hash, Sortierung und Rescan-Regeln test-first. Am Ende Abnahme-Punkte abhaken und committen.
```

## M1b – Setup-Weboberfläche (≈ 45 Min, nachträglich ergänzt)

Ziel: Bibliotheksordner auf dem NAS per Klick wählen statt `docker-compose.yml`/`.env` von Hand zu editieren. Nicht im ursprünglichen KONZEPT/ARCHITEKTUR, siehe `docs/ARCHITEKTUR.md` Abschnitt 13 Entscheidung E12.

- [x] `settings`-Tabelle (Abschnitt 2); `FADEN_LIBRARY` wird als weiter gefasster, nur lesender Wurzel-Mount dokumentiert
- [x] `GET /api/v1/setup/browse?path=`, `GET`/`POST /api/v1/setup/library` (Abschnitt 10); Pfad-Traversal serverseitig auf die Wurzel begrenzt (kein `..`, kein Verlassen von `FADEN_LIBRARY`); Bearer-Auth wie alle anderen Endpunkte
- [x] Scanner/Rescan nutzt `FADEN_LIBRARY` + `settings.library_path` als effektiven Bibliothekspfad statt `FADEN_LIBRARY` allein
- [x] `server/static/setup.html`: eine Datei, Vanilla JS, Stil wie `prototype/faden.html`; Token einmalig eingeben, Ordner anklicken, bestätigen; danach sofortiger Rescan
- [x] Tests: Pfad-Traversal-Schutz, Auswahl wird persistiert und vom Scanner verwendet, 401 ohne Token
- [x] `docker-compose.yml`/README-Hinweis aktualisiert: `FADEN_LIBRARY` kann jetzt bewusst weiter gemountet werden als die eigentliche Bibliothek

```text
/plan Setze Meilenstein M1b aus docs/ROADMAP.md um. Spezifikation: docs/ARCHITEKTUR.md Abschnitte 2, 10, 12 und 13 (E12). Baut auf dem bestehenden server/ aus M1/M2 auf. Am Ende Abnahme-Punkte abhaken und committen.
```

## M2 – Server: Events und Sync (≈ 60 Min)

- [x] `POST` und `GET /api/v1/events` nach Abschnitt 6: idempotent, Cursor, Paging
- [x] Schema-Validierung; `skew_flag` bei `hlc.pt` > Serverzeit + 10 Min, geloggt
- [x] Tests: Duplikate, Reihenfolge, Paging über 1.000 Events; 100.000 Events als `slow`-Test
- [x] `server/scripts/backup.sh` nach Abschnitt 12

```text
/plan Setze Meilenstein M2 aus docs/ROADMAP.md um. Spezifikation: docs/ARCHITEKTUR.md Abschnitte 5, 6 und 12. Am Ende Abnahme-Punkte abhaken und committen.
```

## M3 – App-Kern ohne Oberfläche (≈ 150 Min)

- [x] Flutter-Projekt `app/` für iOS und Android
- [x] `domain/`: Position, Manifest-Mapping (global ↔ Hash und Offset), HLC, Events, Resolver, Faden-Suche; pur, ohne Flutter-Imports
- [x] `spec/vectors/`: die 8 Fälle aus Abschnitt 7 als JSON; die Resolver-Tests laden alle Dateien
- [x] Faden-Suche: die 5 Eigenschafts-Tests aus Abschnitt 8 mit simuliertem Hörer, mindestens 10.000 Zufallsfälle
- [x] Audio-Hash in Dart mit denselben Testfällen wie der Server
- [x] `data/`: drift-Journal (Event vor Aktion, in einer Transaktion), Sync-Client nach Abschnitt 6, API-Client

```text
/plan Setze Meilenstein M3 aus docs/ROADMAP.md um. Spezifikation: docs/ARCHITEKTUR.md Abschnitte 5 bis 8 und 11. domain/ strikt test-first. Am Ende Abnahme-Punkte abhaken und committen.
```

## M4 – App: Player und Oberfläche (≈ 180 Min)

- [x] Theme aus den Design-Tokens (Tag und Nacht), Schrift gebündelt, l10n-Datei mit den Texten aus dem Konzept
- [x] Bibliothek, Download mit Hash-Prüfung, Status „Reihenfolge prüfen“ mit Auswahl-Dialog
- [x] Player nach Abschnitt 11: Playlist, lückenlos, Hintergrund, Sperrbildschirm, ±30 s, Mediatasten
- [x] Start = Player mit Faden; Details-Sheet mit Kapiteln, Scrubber, Tempo, Sleep-Timer, Verlauf
- [x] Nachtmodus mit Tastensperre; Sleep-Timer mit Ausblenden und Verlängern
- [x] Undo-Hinweis nach jedem Sprung über 2 Min
- [ ] Auf einem echten Gerät: Kill-Test und Zwei-Geräte-Test aus dem Konzept bestanden, Ergebnis im Commit notiert

```text
/plan Setze Meilenstein M4 aus docs/ROADMAP.md um. Spezifikation: docs/KONZEPT.md (Screens, Nachtmodus, Design, Texte) und docs/ARCHITEKTUR.md Abschnitte 9 und 11. Am Ende Abnahme-Punkte abhaken und committen.
```

Hinweis: `flutter analyze` und `flutter test` sind grün (Design-Tokens/Kontrast, l10n-Abgleich, Faden-Layout, Undo-Hinweis-Text, Nachtmodus-Sperre und Sleep-Timer-Countdown je mit eigenen Tests, letzte zwei mit `fake_async` statt echter Wartezeit). Hintergrundwiedergabe, Sperrbildschirm-Steuerung und echte Kopfhörertasten (audio_service/just_audio) sind gegen die aktuelle Paket-API gebaut, in dieser Sandbox aber ohne Gerät/Emulator nicht startbar und daher nicht selbst beobachtet — das deckt sich mit dem letzten, bewusst offen gelassenen Punkt oben.

## M5 – App: Faden-Modus (≈ 150 Min)

- [ ] Wach-Belege und `SLEEP_HINT` nach Abschnitt 9
- [ ] Hauptbutton „Faden aufnehmen“ bei Schlafverdacht, darunter „Ab Stopp weiterhören“
- [ ] Faden-Screen: Ton, Probe, Antwortfenster, kürzer werdender Faden, Probenzähler; Abbruch per langem Druck
- [ ] Im Faden-Modus zählt jede Mediataste als „kenne ich“ (iOS und Android mit echten Kopfhörern geprüft)
- [ ] `PROBE`- und `RESUME`-Events; „Früher“ nutzt die Leiter
- [ ] Selbsttest aus M0 in der App wiederholt, Ergebnis im Commit notiert

```text
/plan Setze Meilenstein M5 aus docs/ROADMAP.md um. Spezifikation: docs/KONZEPT.md (Faden aufnehmen) und docs/ARCHITEKTUR.md Abschnitte 8 und 9. Am Ende Abnahme-Punkte abhaken und committen.
```

## M6 – Schlafdaten (≈ 90 Min)

- [ ] Opt-in in den Einstellungen; Lesen aus HealthKit (iOS) und Health Connect (Android)
- [ ] Schlafbeginn nach Abschnitt 9: `hi` kürzen, `prior` setzen, `lo` nie aus Gesundheitsdaten
- [ ] Keine Gesundheitsdaten in Events, Logs oder Sync; ohne Berechtigung verhält sich alles wie vorher

```text
/plan Setze Meilenstein M6 aus docs/ROADMAP.md um. Spezifikation: docs/ARCHITEKTUR.md Abschnitte 8, 9 und 13 (E6). Am Ende Abnahme-Punkte abhaken und committen.
```

## M7 – Optional

- Transkripte mit faster-whisper: genauere Satzanfänge, Text-Ansicht, Suche
- Audiobookshelf-Import für Metadaten und Cover
- Mehrere Nutzer, M4B
