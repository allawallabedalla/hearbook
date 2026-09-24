# Faden – Regeln für Claude Code

Faden ist ein selbstgehosteter Hörbuch-Player für Hörbücher aus einzelnen Kapitel-MP3s.
Kernversprechen: Die Position geht nie verloren. Nach dem Einschlafen findet „Faden aufnehmen“ den letzten gehörten Punkt über kurze Hörproben statt über Scrubben.

Zu Beginn jedes Meilensteins lesen:
- `docs/KONZEPT.md` – Produkt, Abläufe, Design-Tokens, Texte
- `docs/ARCHITEKTUR.md` – Datenmodell, Algorithmen, API, Entscheidungen
- `docs/ROADMAP.md` – Meilensteine und Abnahmekriterien

## Invarianten (nicht verhandelbar)

1. Eine Position ist immer `(file_hash, offset_ms)`. Dateiname, Pfad oder Track-Index sind nie Schlüssel.
2. Fortschritt wird nie überschrieben. Es gibt nur append-only Events; der Zustand ist eine pure Funktion der Events (Resolver).
3. Jedes Event liegt in einer lokalen SQLite-Transaktion, bevor die Aktion ausgeführt oder als erledigt angezeigt wird. Während der Wiedergabe: Herzschlag alle 5 s.
4. Die Kapitel-Reihenfolge ändert sich nie still. Automatisch übernommen wird nur das Anhängen neuer Dateien am Ende; alles andere braucht eine Bestätigung.
5. Nie automatisch ins nächste Buch. „Fertig“ nur, wenn das Ende ohne Schlafverdacht erreicht wurde.
6. Jeder Sprung über 2 Min lässt sich mit einem Tipp rückgängig machen.
7. Gesundheitsdaten verlassen nie das Gerät und erzeugen keine Events.
8. Der Hörbuch-Ordner wird nur gelesen, nie verändert.
9. Die Faden-Suche überspringt nie Ungehörtes: `lo` bewegt sich nur durch eine „kenne ich“-Antwort.

Würde eine Aufgabe eine Invariante verletzen: anhalten und nachfragen.

## Struktur

- `prototype/` eine HTML-Datei, Vanilla JS, keine Abhängigkeiten
- `server/` Python 3.12, FastAPI, SQLite (stdlib `sqlite3`, WAL), ffmpeg/ffprobe, mutagen, uv, pytest, ruff
- `app/` Flutter für iOS und Android: just_audio, audio_service, drift, flutter_riverpod, dio
- `spec/vectors/` JSON-Testfälle für den Resolver: Events rein, Zustand raus

## Befehle

- Server testen: `cd server && uv sync && uv run pytest && uv run ruff check .`
- Server starten: `docker compose up -d --build`
- App prüfen: `cd app && flutter pub get && flutter analyze && flutter test`

## Arbeitsweise

- Meilensteine beginnen im Plan-Modus; umsetzen erst nach Freigabe.
- Hash-Grenzen, Manifest-Regeln, HLC, Resolver und Faden-Suche sind pure Module ohne I/O und werden test-first gebaut.
- Paket-APIs vor Nutzung in der aktuellen Doku prüfen (pub.dev, PyPI). Keine Versionen oder Signaturen raten.
- Code, Kommentare und Commit-Messages auf Englisch (Conventional Commits). UI-Texte auf Deutsch, nur über die l10n-Datei. Doku auf Deutsch.
- Kleine Commits pro Teilschritt. Neue Abhängigkeiten im Commit begründen.
- Geheimnisse nur in `.env` (gitignored); `.env.example` pflegen.
- Keine urheberrechtlich geschützten Audiodateien ins Repo. Test-Audio wird in Tests per ffmpeg erzeugt.
- Abweichungen von der Spezifikation in `docs/ARCHITEKTUR.md` Abschnitt 13 „Entscheidungen“ eintragen.

## Definition of Done

Tests grün, Lint ohne Befund, Abnahmekriterien in `docs/ROADMAP.md` erfüllt und abgehakt, keine Invariante verletzt.
