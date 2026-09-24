# Faden

Selbstgehosteter Hörbuch-Player für Hörbücher aus einzelnen Kapitel-MP3s.

Deine Position geht nie verloren. Und wenn du beim Hören einschläfst, findest du deinen Punkt ohne Scrubben wieder: Die App spielt ein paar kurze Hörproben, du tippst nur bei denen, die du wiedererkennst. Das heißt „Faden aufnehmen“.

## Stand

Spezifikation fertig. Umsetzung mit Claude Code entlang `docs/ROADMAP.md`.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `CLAUDE.md` | Regeln und Invarianten für Claude Code |
| `docs/KONZEPT.md` | Produkt, Abläufe, Design |
| `docs/ARCHITEKTUR.md` | Datenmodell, Algorithmen, API, Entscheidungen |
| `docs/ROADMAP.md` | Meilensteine mit Abnahmekriterien und Prompts |
| `prototype/` | Browser-Prototyp von „Faden aufnehmen“ (M0) |
| `server/` | Faden-Dienst: Python, FastAPI, SQLite, ffmpeg (M1, M2) |
| `app/` | App für iOS und Android in Flutter (M3 bis M6) |
| `spec/vectors/` | Testfälle für den Positions-Resolver (M3) |

## Voraussetzungen

| Ab | Werkzeug |
|---|---|
| M0 | Git, Claude Code, ein Browser |
| M1 | Docker, Python 3.12 mit uv, ffmpeg |
| M3 | Flutter SDK, Android Studio; für iOS zusätzlich Xcode (nur macOS) |

## Start

1. Claude Code installieren: https://code.claude.com/docs/en/setup
2. Im Repo-Ordner `claude` starten.
3. Den Prompt von M0 aus `docs/ROADMAP.md` einfügen.

## Betrieb (ab M1)

`docker compose up -d --build`. Der unter `FADEN_LIBRARY` eingebundene Wurzelordner wird nur lesend gemountet und darf bewusst weiter gefasst sein als die eigentliche Bibliothek (z. B. eine ganze NAS-Freigabe); den tatsächlichen Bibliotheksordner darunter per Klick wählen unter `http://<host>:8787/setup` (ab M1b, siehe `docs/ARCHITEKTUR.md` Abschnitte 10, 12, Entscheidung E12). Von unterwegs am besten über ein VPN zugreifen, statt den Port öffentlich freizugeben.

In `.env` ist `FADEN_TOKEN` Pflicht: mindestens 16 Zeichen, nicht der Platzhalter `change-me` (sonst startet der Server nicht), z. B. `openssl rand -hex 32`. Der Container läuft nicht als root, sondern als `FADEN_UID`/`FADEN_GID` (Standard 10001). Bleibt die Bibliothek leer, fehlen meist Leserechte auf der Freigabe: dann dort die uid/gid des NAS-Benutzers eintragen, dem die Hörbücher gehören (`id <benutzer>` per SSH), wie `USERMAP_UID` bei Paperless. Neue Hörbücher werden alle `FADEN_RESCAN_MIN` Minuten (Standard 10) automatisch eingelesen, sofort per `POST /api/v1/rescan`.

## iOS ohne Bezahl-Account

Mit einer kostenlosen Apple-ID läuft die App mit allen Funktionen (Hintergrundwiedergabe und HealthKit sind laut Apple auch ohne Bezahl-Account erlaubt), die Signatur gilt aber nur 7 Tage. `app/scripts/ios-resign.sh` erneuert sie automatisch vom Mac aus und installiert die App per WLAN neu; die Daten auf dem iPhone bleiben dabei erhalten.

Einmalig einrichten (Mac mit Xcode und Flutter):

1. Xcode → Einstellungen → Accounts: mit der Apple-ID anmelden.
2. `app/ios/Runner.xcworkspace` öffnen, Target „Runner“ → Signing & Capabilities → Team: dein „Personal Team“. Meldet Xcode, dass die Bundle-ID vergeben ist, eine eigene wählen (z. B. `de.<name>.faden`).
3. iPhone per Kabel anschließen, Entwicklermodus einschalten (iPhone: Einstellungen → Datenschutz & Sicherheit → Entwicklermodus), in Xcode unter Window → Devices and Simulators „Connect via network“ aktivieren.
4. `cp app/scripts/ios-resign.env.example app/scripts/ios-resign.env` und `FADEN_DEVICE` eintragen (Kennung aus `xcrun devicectl list devices`), ggf. `BUNDLE_ID` anpassen.
5. Einmal von Hand starten: `app/scripts/ios-resign.sh --force`. Fragt macOS nach dem Schlüsselbund-Zugriff für `codesign`, „Immer erlauben“ wählen. Auf dem iPhone beim ersten Mal unter Einstellungen → Allgemein → VPN & Geräteverwaltung dem Entwickler vertrauen.
6. Zeitplan aktivieren: `app/scripts/ios-resign-install.sh` (entfernen mit `--uninstall`).

Danach prüft der Mac täglich um 3 Uhr, oder beim nächsten Aufwachen, ob die letzte Erneuerung mindestens 3 Tage her ist, und erneuert dann. Ergebnis kommt als Mitteilung, Details in `~/Library/Logs/faden-ios-resign.log`. Den Mac also spätestens alle 6 Tage aufklappen, iPhone im selben WLAN.

Ungeprüft, weil hier kein Mac und kein iPhone verfügbar waren: ob das iPhone für die WLAN-Installation entsperrt sein muss.
