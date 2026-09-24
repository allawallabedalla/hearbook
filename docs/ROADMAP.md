# Roadmap

Jeder Meilenstein ist eine Claude-Code-Sitzung: Prompt einfügen, Plan prüfen, freigeben. Zwischen zwei Meilensteinen `/clear` eingeben, damit der Kontext frisch ist.

Zeiten = Claude-Code-Laufzeit plus dein Review, ohne Tests auf echten Geräten. Summe M0–M6: ≈ 780 Min.

## M0 – Prototyp „Faden aufnehmen“ (≈ 30 Min + 15 Min Selbsttest)

Ziel: die Kernidee an einem echten Hörbuch prüfen, bevor etwas anderes gebaut wird.

- [ ] `prototype/faden.html`: eine Datei, läuft ohne Server im Browser (Desktop und Android-Chrome)
- [ ] MP3 per Dateiauswahl laden; Satzanfänge per Web Audio erkennen (Stille ≥ 350 ms, Analyse mit niedriger Abtastrate, speicherschonend); scheitert die Erkennung, ohne Einrasten weiter
- [ ] Fenster von/bis eingeben (mm:ss); Faden-Suche exakt nach `docs/ARCHITEKTUR.md` Abschnitt 8
- [ ] „Kenne ich“ per Leertaste, Tipp irgendwo oder Mediataste (Media Session API); keine Antwort = „kenne ich nicht“
- [ ] Nachtfarben und Faden-Darstellung aus `docs/KONZEPT.md`; Ergebnis, „Früher“ und „Weiterhören ab hier“
- [ ] Protokoll (Probe, Position, Antwort, Gesamtdauer) zum Kopieren

```text
/plan Setze Meilenstein M0 aus docs/ROADMAP.md um. Spezifikation: docs/KONZEPT.md (Faden aufnehmen, Design, Texte) und docs/ARCHITEKTUR.md Abschnitt 8. Am Ende die Abnahme-Punkte in docs/ROADMAP.md abhaken und committen.
```

Selbsttest: 10 Min eines Kapitels hören, das du nicht kennst. Dann Fenster 00:00 bis 30:00 und Faden starten. Bestanden, wenn der Start höchstens 30 s vor 10:00 liegt, nie danach, und alles höchstens 60 s dauert. Echter Test: eine Nacht mit Sleep-Timer.

## M1 – Server: Import, Manifest, Dateien (≈ 120 Min)

- [ ] `server/` mit uv, FastAPI, pytest, ruff; `.env.example`
- [ ] Audio-Hash nach Abschnitt 3.4 mit allen dort genannten Pflicht-Tests
- [ ] Buch-Erkennung, Reihenfolge und Rescan-Regeln nach 3.1–3.3; ein Test pro Tabellenfall
- [ ] Dauer (3.5), Metadaten und Cover (3.6), Pausen-Index (4); alles per Hash gecacht
- [ ] API aus Abschnitt 10 ohne Events; Token-Auth; HTTP-Range für Dateien getestet
- [ ] `Dockerfile` und `docker-compose.yml` (Ordner nur lesend); nach `docker compose up -d --build` antwortet `/api/v1/health`
- [ ] Test-Audio wird in Tests per ffmpeg erzeugt (Sinus mit Stille-Lücken, verschiedene Tags)

```text
/plan Setze Meilenstein M1 aus docs/ROADMAP.md um. Spezifikation: docs/ARCHITEKTUR.md Abschnitte 2, 3, 4, 10 und 12. Hash, Sortierung und Rescan-Regeln test-first. Am Ende Abnahme-Punkte abhaken und committen.
```

## M2 – Server: Events und Sync (≈ 60 Min)

- [ ] `POST` und `GET /api/v1/events` nach Abschnitt 6: idempotent, Cursor, Paging
- [ ] Schema-Validierung; `skew_flag` bei `hlc.pt` > Serverzeit + 10 Min, geloggt
- [ ] Tests: Duplikate, Reihenfolge, Paging über 1.000 Events; 100.000 Events als `slow`-Test
- [ ] `server/scripts/backup.sh` nach Abschnitt 12

```text
/plan Setze Meilenstein M2 aus docs/ROADMAP.md um. Spezifikation: docs/ARCHITEKTUR.md Abschnitte 5, 6 und 12. Am Ende Abnahme-Punkte abhaken und committen.
```

## M3 – App-Kern ohne Oberfläche (≈ 150 Min)

- [ ] Flutter-Projekt `app/` für iOS und Android
- [ ] `domain/`: Position, Manifest-Mapping (global ↔ Hash und Offset), HLC, Events, Resolver, Faden-Suche; pur, ohne Flutter-Imports
- [ ] `spec/vectors/`: die 8 Fälle aus Abschnitt 7 als JSON; die Resolver-Tests laden alle Dateien
- [ ] Faden-Suche: die 5 Eigenschafts-Tests aus Abschnitt 8 mit simuliertem Hörer, mindestens 10.000 Zufallsfälle
- [ ] Audio-Hash in Dart mit denselben Testfällen wie der Server
- [ ] `data/`: drift-Journal (Event vor Aktion, in einer Transaktion), Sync-Client nach Abschnitt 6, API-Client

```text
/plan Setze Meilenstein M3 aus docs/ROADMAP.md um. Spezifikation: docs/ARCHITEKTUR.md Abschnitte 5 bis 8 und 11. domain/ strikt test-first. Am Ende Abnahme-Punkte abhaken und committen.
```

## M4 – App: Player und Oberfläche (≈ 180 Min)

- [ ] Theme aus den Design-Tokens (Tag und Nacht), Schrift gebündelt, l10n-Datei mit den Texten aus dem Konzept
- [ ] Bibliothek, Download mit Hash-Prüfung, Status „Reihenfolge prüfen“ mit Auswahl-Dialog
- [ ] Player nach Abschnitt 11: Playlist, lückenlos, Hintergrund, Sperrbildschirm, ±30 s, Mediatasten
- [ ] Start = Player mit Faden; Details-Sheet mit Kapiteln, Scrubber, Tempo, Sleep-Timer, Verlauf
- [ ] Nachtmodus mit Tastensperre; Sleep-Timer mit Ausblenden und Verlängern
- [ ] Undo-Hinweis nach jedem Sprung über 2 Min
- [ ] Auf einem echten Gerät: Kill-Test und Zwei-Geräte-Test aus dem Konzept bestanden, Ergebnis im Commit notiert

```text
/plan Setze Meilenstein M4 aus docs/ROADMAP.md um. Spezifikation: docs/KONZEPT.md (Screens, Nachtmodus, Design, Texte) und docs/ARCHITEKTUR.md Abschnitte 9 und 11. Am Ende Abnahme-Punkte abhaken und committen.
```

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
