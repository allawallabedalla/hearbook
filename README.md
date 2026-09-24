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

`docker compose up -d --build`. Der Hörbuch-Ordner wird nur lesend eingebunden. Von unterwegs am besten über ein VPN zugreifen, statt den Port öffentlich freizugeben.
