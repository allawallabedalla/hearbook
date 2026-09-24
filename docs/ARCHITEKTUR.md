# Architektur: Faden

## 1. Überblick

```mermaid
flowchart LR
  subgraph Server["Server (Docker)"]
    L[("Hörbuch-Ordner, nur lesen")] --> S[Scanner]
    S --> M[Manifeste und Hashes]
    S --> P[Pausen-Index]
    E[("Event-Speicher, SQLite")]
    A[REST-API]
    M --> A
    P --> A
    E <--> A
  end
  subgraph App["App (Flutter)"]
    J[("Journal, SQLite")]
    R[Resolver]
    F[Faden-Suche]
    PL[Player]
    W[Wach-Signale]
    PL --> J
    W --> J
    J --> R --> F --> PL
  end
  A <-->|"Sync und Download"| J
```

Grundsatz: Der Server speichert Dateien, Manifeste und Events und entscheidet nichts. Die Position berechnet ausschließlich der Client (Resolver). So funktioniert die App offline vollständig, und die Logik existiert nur einmal.

## 2. Datenmodell (Server, SQLite im WAL-Modus)

| Tabelle | Felder |
|---|---|
| `files` | `file_hash` PK, `path`, `size`, `mtime_ns`, `duration_ms`, `disc`, `track`, `title` |
| `books` | `book_id` PK (UUID), `path`, `title`, `author`, `created_at` |
| `manifests` | `manifest_id` PK, `book_id`, `version`, `status` (`active`, `pending`, `needs_review`, `superseded`), `created_at` |
| `manifest_files` | `manifest_id`, `idx`, `file_hash`, PK (`manifest_id`, `idx`) |
| `pauses` | `file_hash` PK, `offsets_ms` (JSON), `params` (JSON) |
| `events` | `seq` PK autoincrement, `event_id` UNIQUE, `book_id`, `device_id`, `body` (JSON), `received_at`, `skew_flag` |
| `settings` | `key` PK, `value` |

`manifest_id` = SHA-256 über die geordneten `file_hash`-Werte, getrennt durch Zeilenumbrüche.

`settings.library_path`: relativer Unterpfad unter `FADEN_LIBRARY` (Wurzel-Mount), der die tatsächliche Bibliothek markiert. Leer/fehlend = die Wurzel selbst. Siehe Abschnitt 10 (Setup-Endpunkte) und Abschnitt 12 (Mount-Semantik).

## 3. Import und Manifest

### 3.1 Buch-Erkennung

- Ein Ordner mit MP3-Dateien ist ein Buch.
- Enthält ein Ordner nur Unterordner, deren Name auf `CD`, `Disc`, `Disk`, `Teil` oder `Part` plus Zahl passt (Groß/klein egal, Leerzeichen optional), ist er ein Buch; die Zahl ist die Disc-Nummer.
- `book_id` ist eine UUID, vergeben beim ersten Import. Verschwindet ein Pfad und taucht dieselbe Menge Datei-Hashes unter neuem Pfad auf, behält das Buch seine `book_id` (Umbenennung).

### 3.2 Reihenfolge

1. Schlüssel A: (Disc, Track) aus ID3 (`TPOS`, `TRCK`). Nur gültig, wenn jede Datei einen Track hat und alle (Disc, Track)-Paare eindeutig sind. Fehlt Disc: Disc aus dem Unterordner, sonst 1.
2. Schlüssel B: (Disc aus dem Unterordner, natürliche Sortierung des Dateinamens: Zahlen numerisch, Groß/klein egal, Unicode NFC).
3. A gültig und A = B → Reihenfolge A, Status `active`.
4. A gültig und A ≠ B → beide Reihenfolgen werden als Manifeste mit Status `needs_review` angelegt; die App lässt wählen, die Wahl wird `active`, die andere `superseded`.
5. A ungültig → Reihenfolge B, Status `active`.

Zusätzlich `needs_review` bei doppelten Hashes im Buch, Dauer 0 oder unlesbarer Datei.

### 3.3 Änderungen beim Rescan

| Fall | Ergebnis |
|---|---|
| Neue Liste = aktive Liste | nichts |
| Aktive Liste ist Präfix der neuen (nur angehängt) | neues Manifest sofort `active`, altes `superseded` |
| Alles andere | neues Manifest `pending`, altes bleibt `active` bis zur Bestätigung |
| Dateien fehlen auf der Platte | Buch „unvollständig“, Manifest und Positionen bleiben |

### 3.4 Audio-Hash (Tags werden ignoriert)

```text
audio_hash(datei):
  start = 0
  solange bytes[start : start+3] == "ID3":
    größe    = syncsafe_u32(bytes[start+6 : start+10])
    fußzeile = 10 wenn (bytes[start+5] & 0x10) sonst 0
    start   += 10 + größe + fußzeile

  ende = dateigröße
  wiederhole, solange sich ende ändert (höchstens 4 Durchläufe):
    wenn bytes[ende-128 : ende-125] == "TAG":
      ende -= 128
    sonst wenn bytes[ende-32 : ende-24] == "APETAGEX":
      größe = u32_le(bytes[ende-20 : ende-16])
      flags = u32_le(bytes[ende-12 : ende-8])
      ende -= größe + (32 wenn flags & 0x80000000 sonst 0)

  return hex(sha256(bytes[start : ende]))
```

- Streamend lesen (Blöcke à 1 MiB), nie die ganze Datei in den Speicher.
- Cache: (`path`, `size`, `mtime_ns`) → Hash; neu hashen nur bei Änderung.
- Dieselbe Berechnung gibt es in Dart (die App prüft Downloads). Beide Implementierungen nutzen dieselben Testfälle.
- Pflicht-Tests: gleiche Audiodaten mit anderen Tags oder anderem Namen → gleicher Hash; anderes Audio → anderer Hash; ID3v2 mit Fußzeile; APEv2 mit und ohne Header; ID3v1 und APEv2 kombiniert.

### 3.5 Dauer

Summe der Paketdauern per ffprobe, in ms gerundet. Nie aus der Bitrate geschätzt (VBR). Cache per Hash.

### 3.6 Metadaten

- Titel und Autor: ID3 `TALB` und `TPE1` der ersten Datei, sonst Ordnername nach Muster „Autor - Titel“, sonst Ordnername.
- Cover: `cover.jpg`, `cover.jpeg`, `cover.png`, `folder.jpg`, sonst eingebettetes Bild der ersten Datei, sonst keins (die App setzt ein Titel-Cover).

## 4. Pausen-Index

- `ffmpeg -i <datei> -af silencedetect=noise=-35dB:d=0.35 -f null -`; jedes `silence_end` ist ein Satzanfang.
- Pro Datei als sortierte Liste `offsets_ms` gespeichert, 0 für den Dateianfang immer enthalten.
- Parameter per Umgebungsvariable; sie werden in `params` mitgespeichert, bei Änderung wird neu berechnet.

## 5. Events

```json
{
  "event_id": "UUIDv7",
  "device_id": "UUID",
  "session_id": "UUID",
  "book_id": "UUID",
  "manifest_id": "hex",
  "type": "PLAY",
  "file_hash": "hex",
  "offset_ms": 0,
  "hlc": { "pt": 0, "c": 0 },
  "wall_ms": 0,
  "tz_min": 120,
  "source": "ui",
  "data": {}
}
```

`source`: `ui`, `media_button`, `timer`, `system`, `faden`. `tz_min`: UTC-Offset des Geräts in Minuten, nötig für das Nachtfenster.

| Typ | Wann | Absicht | Wach-Beleg |
|---|---|---|---|
| `PLAY` | Wiedergabe startet | ja | ja |
| `SEEK` | ±30 s, Kapitel, Scrubber, Verlauf | ja | ja |
| `RESUME` | Ergebnis der Faden-Suche oder „Ab Stopp weiterhören“ | ja | ja |
| `UNDO` | Rückgängig, „Früher“ | ja | ja |
| `HEARTBEAT` | alle 5 s während der Wiedergabe | nein | nein |
| `PAUSE` | Wiedergabe stoppt | nein | nur bei `source=ui` |
| `AWAKE` | Berührung, Lautstärke, Timer verlängert (höchstens 1 pro 10 s) | nein | ja |
| `SLEEP_HINT` | Sleep-Timer abgelaufen; Pause über Mediataste oder System im Nachtfenster | nein | nein |
| `PROBE` | Hörprobe der Faden-Suche, `data.known` | nein | nein |
| `FINISHED` | Buchende ohne Schlafverdacht erreicht | nein | ja |

Sessions: Jedes Absicht-Event außerhalb einer laufenden Wiedergabe beginnt eine neue `session_id`. Alle folgenden Events bis zur nächsten Pause tragen sie.

Hybrid Logical Clock:

```text
lokales Event:  pt = max(letzt.pt, jetzt)
                c  = (pt == letzt.pt) ? letzt.c + 1 : 0
empfangenes r:  pt = max(letzt.pt, r.pt, jetzt)
                c  = (pt == letzt.pt == r.pt) ? max(letzt.c, r.c) + 1
                   : (pt == letzt.pt)         ? letzt.c + 1
                   : (pt == r.pt)             ? r.c + 1
                   : 0
Ordnung:        (pt, c, device_id, event_id)
```

## 6. Sync

- Push zuerst: `POST /api/v1/events` mit bis zu 500 Events. Der Server prüft jedes Event einzeln und speichert die gültigen per `INSERT OR IGNORE` auf `event_id`. Antwort: `{"accepted", "duplicates", "rejected": [{"index", "event_id", "error"}], "max_seq"}` (`max_seq` ist `null`, wenn nichts gespeichert wurde). 422 nur, wenn der Request selbst kaputt ist (kein Array, mehr als 500 Events). Abgelehnte Events gelten beim Client als erledigt und bleiben lokal im Journal (E23).
- Dann Pull: `GET /api/v1/events?since=<seq>&limit=500`, bis `has_more = false`. Cursor lokal speichern. Jedes gezogene Event läuft vor dem Speichern durch die HLC-Empfangsregel (Abschnitt 5), damit spätere lokale Events danach einsortiert werden.
- Auslöser: App-Start, App im Vordergrund, Pause, Netzwechsel, alle 60 s während der Wiedergabe.
- Events mit `hlc.pt` > Serverzeit + 10 Min bekommen `skew_flag` und werden geloggt. Bekannte Grenze: Ein Gerät mit stark vorgehender Uhr kann fälschlich gewinnen.
- Events werden im MVP nie gelöscht.

## 7. Resolver (pur, Dart)

Eingabe: alle Events eines Buchs, die Manifeste, Einstellungen (Nachtfenster). Ausgabe:

```text
BookState {
  position: Pos(file_hash, offset_ms)
  global_ms: int
  last_awake: Pos
  stop: Pos
  sleep_suspected: bool
  history: List<Pos>          // neueste zuerst, höchstens 20
  finished: bool
  needs_confirmation: bool
}
```

Regeln:
1. Nach HLC sortieren, doppelte `event_id` ignorieren.
2. Das letzte Absicht-Event (`PLAY`, `SEEK`, `RESUME`, `UNDO`) bestimmt die gewinnende Session.
3. `position` = Position des letzten Events der gewinnenden Session. Events anderer Sessions bewegen die Position nie, auch wenn sie später eintreffen.
4. `last_awake` = Position des letzten Wach-Belegs der gewinnenden Session.
5. `sleep_suspected` = Abstand(`last_awake`, `stop`) ≥ 3 Min UND (ein Event der Session liegt in Gerätezeit im Nachtfenster ODER die Session enthält `SLEEP_HINT`) UND nach dem Stopp folgte kein `RESUME`.
6. `history`: Springt ein Absicht-Event mehr als 2 Min von der vorherigen Position weg, kommt die vorherige Position in `history`.
7. `finished` = `FINISHED` in der gewinnenden Session und `sleep_suspected` ist falsch.
8. Abstände über globale ms des aktiven Manifests. Fehlt ein `file_hash` im aktiven Manifest: `needs_confirmation = true`, die Position bleibt unangetastet.

Testfälle in `spec/vectors/`, je eine JSON-Datei mit `settings`, `manifest`, `events`, `expect`:
1. Ein Gerät, Herzschläge, Pause → Position der Pause.
2. Doppelte Events → gleicher Zustand wie ohne Duplikate.
3. A spielt, B startet später, A schickt danach noch Herzschläge → Position von B.
4. A war offline mit älterer Session und synct nach B → B bleibt.
5. Nachtfenster, 20 Min ohne Wach-Beleg, Timer-Ende → `sleep_suspected`, `last_awake` korrekt.
6. Kapitelsprung über 2 Min, dann `UNDO` → alte Position, `history` korrekt.
7. Manifest nur angehängt → Position unverändert.
8. Buchende mit Schlafverdacht → `finished = false`.

## 8. Faden-Suche (pur, Dart; im Prototyp JavaScript)

```text
Parameter
  target        = 30_000   ms Zielgenauigkeit
  max_probes    = 8        inklusive Probe 1
  probe_len     = 4_000    ms
  answer_window = 3_000    ms nach Ende der Probe (Antworten während der Probe zählen)
  first_offset  = 25_000   ms vor dem Stopp
  preroll       = 2_000    ms

suche(lo, hi, pausen, frage, prior = null) -> (start, leiter)
  // lo = last_awake, hi = stop, beides globale ms
  wenn hi - lo <= target:
    return (max(lo - preroll, 0), [lo])

  leiter = [lo]
  proben = 0

  wenn prior == null:                          // Probe 1: Fehlalarm-Test
    p = snap(hi - first_offset, lo, hi, tol = 2_000)
    proben += 1
    wenn frage(p): return (p, [lo, p])
    hi = p

  solange hi - lo > target und proben < max_probes:
    x = (proben == 0 und prior != null) ? prior : lo + (hi - lo) / 2
    p = snap(x, lo, hi, tol = max(2_000, 0.03 * (hi - lo)))
    proben += 1
    wenn frage(p): lo = p; leiter.append(p)
    sonst:         hi = p

  start = (lo == leiter[0]) ? max(lo - preroll, 0) : lo
  return (start, leiter)

snap(x, lo, hi, tol):
  k = { s in pausen | lo + probe_len < s < hi - probe_len und |s - x| <= tol }
  wenn k leer: return x
  return das s aus k mit kleinstem |s - x|
```

Eigenschafts-Tests mit simuliertem Hörer („kennt p genau dann, wenn p ≤ S“, S zufällig in [lo, hi]):
1. `start ≤ S` immer. Es wird nie Ungehörtes übersprungen.
2. Fenster ≤ 30 Min → `S - start ≤ target + preroll`.
3. Nie mehr als `max_probes` Proben.
4. Hörer antwortet nie → `start = max(lo - preroll, 0)`.
5. „Früher“ springt in `leiter` genau einen Schritt zurück.

Weitere Regeln: Eine Probe endet spätestens am Dateiende. Proben laufen über einen eigenen Player, der Hauptplayer ist pausiert. Jede Probe wird als `PROBE`-Event geschrieben, das Ergebnis als `RESUME`-Event.

## 9. Wach-Signale und Schlafverdacht (App)

- `AWAKE` entsteht bei Berührung des Player-Screens, Lautstärkeänderung (falls die Plattform sie meldet) und Timer-Verlängerung.
- `SLEEP_HINT` entsteht beim Ablauf des Sleep-Timers und bei einer Pause über Mediataste oder System im Nachtfenster. Die AirPods-Einschlaferkennung (ab iOS 26) kommt als normale Pause an und ist von einem bewussten Tastendruck nicht zu unterscheiden, daher nur Hinweis.
- Gesundheitsdaten (M6) erzeugen keine Events. Beim Start der Faden-Suche liest die App lokal den Schlafbeginn T im Zeitraum der Session und rechnet T über die `HEARTBEAT`-Events (Wanduhr → Position) in globale ms um. Dann gilt: `hi = min(stop, pos(T + 5 Min))`, `prior = pos(T - 10 Min)` falls > `lo`. `lo` wird nie aus Gesundheitsdaten gesetzt (Invariante 9).
- Mediatasten: normal Play/Pause, Weiter = +30 s, Zurück = −30 s. In der letzten Minute des Sleep-Timers verlängert jede Taste. Im Faden-Modus zählt jede Taste als „kenne ich“.

## 10. API

Alle Endpunkte außer `/api/v1/health` verlangen `Authorization: Bearer <FADEN_TOKEN>`.

| Methode | Pfad | Zweck |
|---|---|---|
| GET | `/api/v1/health` | Status |
| GET | `/api/v1/books` | Bücher: id, Titel, Autor, Dauer, Status |
| GET | `/api/v1/books/{book_id}` | aktives Manifest mit Dateien, dazu `pending` oder `needs_review`-Kandidaten |
| GET | `/api/v1/books/{book_id}/cover` | Cover oder 404 |
| GET | `/api/v1/books/{book_id}/pauses` | Pausen-Index je `file_hash` |
| POST | `/api/v1/books/{book_id}/manifests/{manifest_id}/confirm` | Kandidat bestätigen → `active` |
| GET | `/api/v1/files/{file_hash}` | Audiodatei mit HTTP-Range |
| POST | `/api/v1/events` | Events hochladen, idempotent |
| GET | `/api/v1/events?since={seq}&limit={n}` | Events abholen |
| POST | `/api/v1/rescan` | Ordner neu einlesen |
| GET | `/api/v1/setup/browse?path={rel}` | Unterordner von `path` unter `FADEN_LIBRARY` auflisten (nur Verzeichnisnamen, keine Dateien) |
| GET | `/api/v1/setup/library` | aktuell gewählter `settings.library_path` |
| POST | `/api/v1/setup/library` | `{"path": "<rel>"}` setzen, danach sofortiger Rescan |

Setup-Endpunkte verlangen ebenfalls `Authorization: Bearer <FADEN_TOKEN>`. `path` ist relativ zu `FADEN_LIBRARY` und wird serverseitig aufgelöst und geprüft, dass das Ergebnis innerhalb von `FADEN_LIBRARY` bleibt (kein `..`, keine Symlinks nach außerhalb) — Invariante 8 gilt weiter, es wird nur gelesen. Eine winzige statische Seite `server/static/setup.html` (Vanilla JS, kein Framework, Stil wie `prototype/faden.html`) nutzt diese drei Endpunkte: Token einmalig eingeben (nur im Browser-Tab gehalten), Ordner anklicken, bestätigen.

## 11. App

```text
app/lib/
  core/     hlc.dart, ids.dart, clock.dart
  domain/   position.dart, manifest.dart, event.dart, resolver.dart,
            faden_search.dart, audio_hash_bounds.dart, auto_rewind.dart   (pur, keine Flutter-Imports)
  data/     db.dart (drift), journal.dart, sync.dart, api.dart, downloads.dart, hash_file.dart,
            library.dart (Cache Bücher/Details/Pausen-Index), book_downloads.dart, storage.dart,
            offline_books.dart (automatisch laden und aufräumen)
  audio/    handler.dart (audio_service), player.dart (just_audio), probe_player.dart,
            playback_status.dart
  signals/  awake.dart, night.dart, screen_brightness.dart, health.dart
  ui/       theme.dart, player_screen.dart, details_sheet.dart, faden_screen.dart,
            library_screen.dart, settings_screen.dart, mini_player.dart,
            routes.dart, playback_announcer.dart, cover.dart, controls.dart, format.dart
  l10n/     app_de.arb
app/test/   domain/, data/   (Resolver-Tests laden ../spec/vectors/*.json)
```

Player-Regeln:
- Playlist = alle Dateien des aktiven Manifests; lokale Datei, sonst Stream-URL mit Token-Header.
- Lückenlose Übergänge, Hintergrundwiedergabe, Steuerung auf dem Sperrbildschirm.
- App-Start: Resolver ausführen, Player an der Position pausiert vorbereiten. Die Bibliothek ist die Wurzel-Route, der Player liegt darüber (E60).
- Buchende: stoppen; `FINISHED` nur ohne Schlafverdacht. Nie ins nächste Buch.
- Ein Download gilt erst als fertig, wenn der Audio-Hash der Datei stimmt.
- Der Server kann nachts aus sein: Pausen-Index aus dem Gerätecache (E55), offenes und nächstes Buch vorher im WLAN geladen (E56), zu Ende gehörte Bücher räumen ihre Audiodateien selbst weg (E57), nicht geladene Bücher sagen offline klar, warum sie nicht spielen (E58).

## 12. Betrieb

```yaml
services:
  faden:
    build: ./server
    ports: ["8787:8787"]
    env_file: .env
    volumes:
      - /pfad/zu/hoerbuechern:/library:ro
      - faden-data:/data
    restart: unless-stopped
volumes:
  faden-data:
```

| Variable | Standard | Zweck |
|---|---|---|
| `FADEN_TOKEN` | Pflicht | Bearer-Token, mindestens 16 Zeichen, nicht `change-me` (sonst startet der Server nicht) |
| `FADEN_UID` / `FADEN_GID` | `10001` | Benutzer, unter dem der Container läuft (`docker-compose.yml`, nur dort gelesen); muss die Hörbuch-Freigabe lesen dürfen |
| `FADEN_LIBRARY` | `/library` | Gemounteter Wurzelordner, nur lesen. Kann bewusst weiter gefasst sein als die eigentliche Bibliothek (z. B. eine ganze NAS-Freigabe); der tatsächliche Bibliotheksordner darunter wird per `settings.library_path` gewählt (Standard: die Wurzel selbst), entweder über die Setup-Seite (Abschnitt 10) oder direkt in der DB |
| `FADEN_DATA` | `/data` | SQLite und Caches |
| `FADEN_PORT` | `8787` | Port |
| `FADEN_RESCAN_MIN` | `10` | Rescan-Intervall in Minuten, erster Lauf kurz nach dem Start; `0` schaltet ihn ab. Immer nur ein Scan zugleich, ein manueller Rescan währenddessen bekommt 409 |
| `FADEN_SILENCE_DB` | `-35` | Schwelle für `silencedetect` |
| `FADEN_SILENCE_S` | `0.35` | Mindestdauer für `silencedetect` |

- Backup täglich: `sqlite3 /data/faden.db ".backup /data/backup/faden-<datum>.db"` (Skript `server/scripts/backup.sh`). Zusätzlich hält jedes Gerät alle Events, die es synchronisiert hat.
- Zugriff von unterwegs über ein VPN (z. B. WireGuard oder Tailscale), den Port nicht öffentlich freigeben.

## 13. Entscheidungen

| Nr. | Entscheidung | Grund |
|---|---|---|
| E1 | App in Flutter statt nativ | Eine Codebasis für iOS und Android; just_audio und audio_service decken Hintergrund und Mediatasten ab. Risiko: Tasten-Details je Plattform, daher Gerätetests in M4 und M5. |
| E2 | Server liest den Ordner direkt, Audiobookshelf höchstens optional (M7) | Weniger Abhängigkeiten, keine fremde Fortschrittslogik im Kern. |
| E3 | Resolver nur im Client | Server bleibt einfacher Speicher, keine doppelte Logik, offline vollständig. |
| E4 | Pausen-Index statt Transkript im MVP | ffmpeg reicht für Satzanfänge; Whisper später optional. |
| E5 | Hash über reine Audiodaten | Umbenennen und Taggen ändern nichts; neu encodierte Dateien gelten als neue Dateien und brauchen eine Bestätigung. |
| E6 | Gesundheitsdaten nur als lokaler Hinweis | Datenschutz; `lo` bleibt durch Antworten belegt, dadurch nie Ungehörtes übersprungen. |
| E7 | Beim Rescan erzwingt eine mehrdeutige Reihenfolge (Schlüssel A ≠ B) oder ein needs_review-Auslöser (doppelter Hash, Dauer 0, unlesbare Datei) immer `needs_review`, selbst wenn die neue Liste die aktive Liste nur verlängert | 3.3 nennt nur "nur angehängt" als Bedingung für sofortiges Aktivieren; das deckt aber nicht den Fall, dass die neue Reihenfolge selbst unsicher ist. Invariante 4 verbietet stille Reihenfolgeänderungen, daher gewinnt die Unsicherheit aus 3.2 immer gegen das automatische Aktivieren aus 3.3. |
| E8 | Buch-Erkennung (3.1): ein Ordner mit MP3-Dateien ist sofort ein Buch (andere Unterordner werden ignoriert); ein Ordner mit gemischten (teils passenden, teils nicht passenden) Unterordnern ist kein Buch, seine Unterordner werden aber weiter nach verschachtelten Büchern durchsucht | 3.1 spezifiziert nur die zwei positiven Fälle (MP3 direkt, oder ausschließlich CD/Disc/Disk/Teil/Part-Unterordner). Der Umgang mit gemischten Strukturen (z. B. `Autor/Buch1/*.mp3` neben `Autor/Notizen/`) war nicht festgelegt; die Rekursion sorgt dafür, dass verschachtelte Bücher trotzdem gefunden werden, ohne die zwei klaren Fälle zu verändern. |
| E9 | Dockerfile kopiert statische ffmpeg/ffprobe-Binaries aus dem Image `mwader/static-ffmpeg` statt sie per `apt-get` zu installieren | In der Entwicklungs-Sandbox war das Debian-Paketarchiv über das Sandbox-Netzwerk nicht erreichbar (403), Docker Hub-Images dagegen schon. Statische Binaries vermeiden außerdem zusätzliche Laufzeit-Abhängigkeiten im Image. |
| E12 | Setup-Weboberfläche ergänzt (nicht im ursprünglichen KONZEPT/ARCHITEKTUR): `FADEN_LIBRARY` wird weiter gefasst gemountet als die eigentliche Bibliothek; `settings.library_path` (neue Tabelle, Abschnitt 2) wählt den tatsächlichen Unterordner; drei neue Endpunkte `GET /api/v1/setup/browse`, `GET`/`POST /api/v1/setup/library` (Abschnitt 10); statische Seite `server/static/setup.html` zum Klicken statt manuellem `.env`-Editieren | Nutzer-Anforderung während der Umsetzung: Bibliotheksordner soll über eine Weboberfläche wählbar sein, nicht nur per Handbearbeitung von `docker-compose.yml`/`.env`. Docker-Volumes sind zur Container-Startzeit fix — eine Weboberfläche kann nicht selbst einen neuen Host-Pfad mounten. Lösung wie bei vergleichbarer Selfhosted-Software (Audiobookshelf, Jellyfin): einmalig einen ausreichend weiten Wurzelordner mounten, die eigentliche Bibliothek darunter per UI auswählen. Bleibt mit Invariante 8 vereinbar (nur lesend, Pfad-Traversal serverseitig auf die Wurzel begrenzt). Mehrere Bibliotheken bleiben out of scope (siehe „Nicht im MVP" in `docs/KONZEPT.md`), es gibt weiterhin nur einen gewählten Pfad. |
| E10 | Dockerfile installiert die `sqlite3`-CLI zusätzlich per `apt-get`; `server/scripts/backup.sh` läuft damit per `docker compose exec faden ...` im Container | Abschnitt 12 nennt nur das Skript und den Befehl, nicht wie es an die Daten kommt. `/data` ist in `docker-compose.yml` ein benanntes Docker-Volume, kein Host-Bind-Mount, der Host kennt den Dateipfad also nicht ohne Weiteres; das Skript braucht die `sqlite3`-CLI deshalb im Container selbst. Anders als bei E9 (statische Binaries wegen nicht erreichbarem Docker Hub für das ffmpeg-Basisimage) ist `sqlite3` ein gewöhnliches, kleines Debian-Paket, das in einer normalen Netzwerkumgebung per `apt-get` installierbar ist; ein vollständiger `docker compose up -d --build` ließ sich in dieser Sandbox nicht verifizieren, da sowohl `deb.debian.org` als auch der Docker-Daemon hier nicht erreichbar waren (dieselbe Einschränkung wie bei E9). |
| E11 | `domain/audio_hash_bounds.dart` hasht nur; `sqlite3_flutter_libs` wird nicht verwendet (siehe unten). Im Resolver (`domain/resolver.dart`): `stop` wird identisch zu `position` berechnet (Position des letzten Events der gewinnenden Session); die Sprung-Erkennung für `history` (Regel 6) läuft nur innerhalb der Events der gewinnenden Session, nicht sitzungsübergreifend; `needs_confirmation` wird gesetzt, sobald irgendeine für eine Distanzberechnung benötigte `file_hash` (Position, `last_awake` oder ein Sprungvergleich in der Historie) nicht im aktiven Manifest steht | (1) Abschnitt 11 listet `data/hash_file.dart` getrennt von `domain/audio_hash_bounds.dart`; „bounds" deutet auf Grenzerkennung (ID3/APE), nicht zwingend auf den vollständigen Hash. Da Abschnitt 11 aber verlangt, dass die App den Hash eines Downloads prüft, lebt der volle SHA-256-Hash (`audioHashBytes`/`audioHashStreaming`) trotzdem in `domain/audio_hash_bounds.dart`, weil er pur ist (kein `dart:io`, nur `crypto`/`convert`); `data/hash_file.dart` bleibt der dünne `dart:io`-Adapter, der Dateien blockweise liest und die reine Funktion aufruft. `sqlite3_flutter_libs` ist laut eigenem `pub.dev`-Eintrag „not used anymore, update to version 3.x of package:sqlite3 instead" (EOL), daher wird direkt `sqlite3` (>=3.x) verwendet. (2) Abschnitt 7 definiert `stop` nicht separat, benutzt es aber genau wie `position` als Endpunkt der Sitzung (siehe auch `docs/KONZEPT.md`: „Stopp-Punkt"); ohne eigene Regel ist Gleichheit mit `position` die einzige eindeutige Lesart. (3) Eine sitzungsübergreifende Sprung-Erkennung wäre nicht wohldefiniert (mehrere Geräte, keine globale Reihenfolge vor Sitzungsbeginn); Invariante 6 ist mit dem Ladder aus Abschnitt 8 (Eigenschaft 5, "Früher") für den Sprung zurück nach einer Faden-Suche bereits abgedeckt. (4) Regel 8 nennt nur die Positions-`file_hash` explizit, verlangt aber allgemein `needs_confirmation` bei jeder fehlenden `file_hash`, die für eine Abstandsberechnung nötig ist; das schließt `last_awake` und die Sprungvergleiche in der Historie ein, sonst würde der Resolver bei einer unbestätigten Manifest-Änderung falsche Abstände stillschweigend berechnen. |
| E13 | M4 grenzt bewusst gegen Abschnitt 9 ab: der Sleep-Timer (`signals/sleep_timer.dart`) pausiert bei Ablauf nur mit einem normalen `PAUSE`-Event (`source: timer`, dadurch laut `domain/event.dart` kein Wach-Beleg) und verlängert sich in der letzten Minute rein lokal (Timer-Reset, keine Auswirkung auf Events) — kein `SLEEP_HINT`- oder `AWAKE`-Event. Beides bleibt M5 vorbehalten. Zusätzlich: `settings_store.dart` bekommt einen neuen Schlüssel `last_opened_book_id`, den `main.dart` beim Start liest, um Abschnitt 11 ("App-Start: Resolver ausführen, Player an der Position pausiert vorbereiten") ohne Umweg über die Bibliothek zu erfüllen — welches Buch das ist, legt Abschnitt 11 sonst nicht fest. Außerdem: ein Tipp auf einen „Verlauf"-Eintrag in `ui/details_sheet.dart` erzeugt wie der Undo-Hinweis-Banner ein `UNDO`-Event, nicht `SEEK` — Abschnitt 5 nennt `UNDO` für „Rückgängig, 'Früher'", das Verlauf-Feature dient laut KONZEPT.md („jeder große Sprung mit einem Tipp rückgängig") demselben Zweck. | M4-Auftrag (siehe `docs/ROADMAP.md`): `sleep_suspected`, `AWAKE`, `SLEEP_HINT` und die Faden-Suche-UI sind explizit M5-Scope; ein Sleep-Timer ohne jedes Event wäre aber nicht testbar und würde Invariante 3 verletzen, daher der schmale Mittelweg über den bereits vorhandenen `PAUSE`-Typ. `last_opened_book_id` ist reine Client-Bequemlichkeit (kein Server-Zustand, keine Invariante berührt). Die `UNDO`-Wahl für Verlauf-Taps hält beide Rückgängig-Wege (Banner und Liste) im selben, für Resolver-Regel 5 (`resumeAfterStop`) bereits korrekt behandelten Eventtyp. |
| E14 | `l10n/app_de.arb` bleibt die dokumentierte Textquelle, wird aber nicht über Flutters `flutter gen-l10n`/`intl`-Pipeline eingebunden. Stattdessen spiegelt `l10n/strings.dart` jeden Eintrag als Dart-`Map<String,String>` samt typisierter Getter/Format-Methoden; `test/l10n/strings_test.dart` vergleicht beide Dateien Wort für Wort und schlägt fehl, sobald sie auseinanderlaufen. UI-Code importiert ausschließlich `strings.dart`. | `flutter gen-l10n` bräuchte zusätzlich `flutter_localizations` (SDK-Paket, unproblematisch) und ein zur SDK-Version passendes `intl` (bislang keine direkte Abhängigkeit) sowie einen Codegen-Schritt vor `flutter analyze`/`flutter test`, dessen Ausgabe für eine einzige, feste Sprache (nur Deutsch, keine Sprachumschaltung im MVP) keinen Mehrwert bringt. Die Dart-Map plus Abgleichs-Test erfüllt dieselbe Anforderung aus CLAUDE.md („UI-Texte auf Deutsch, nur über die l10n-Datei") ohne dieses Risiko in der Sandbox und ohne einen zusätzlichen Build-Schritt, der bei jedem `flutter test` unbemerkt veralten könnte. |
| E15 | Die Schriftfamilie „Atkinson Hyperlegible Next" (KONZEPT.md, OFL) wurde tatsächlich beschafft und im Bundle ausgeliefert (`app/assets/fonts/AtkinsonHyperlegibleNext-{Regular,Bold}.ttf`, Lizenztext in `app/assets/fonts/OFL.txt`) — keine Fallback-Substitution nötig. Bezugsweg: `fonts.googleapis.com`/`fonts.gstatic.com` (Google Fonts spiegelt die offiziellen, von Google Fonts/dem Braille Institute gepflegten OFL-Dateien) über den in dieser Sandbox vorkonfigurierten HTTPS-Proxy; direkte Downloads von `fonts.google.com/download` waren blockiert (403), die `css2`-API und `fonts.gstatic.com` dagegen erreichbar. | KONZEPT.md verlangt die Schrift „im App-Bundle" und nennt „Atkinson Hyperlegible" nur als Fallback, falls die exakte Familie „in diesem Sandbox nicht beschaffbar" ist (Auftragstext M4). Sie war es. Festgehalten wird trotzdem, weil der Bezugsweg (Google Fonts CDN statt z. B. eines vendorierten npm-/pub-Pakets) eine bewusste, dokumentationswürdige Wahl ist und weil ein künftiger Build in einer anderen Umgebung denselben Weg (oder die dort mitgelieferten Dateien) reproduzieren können muss. |
| E16 | M5 (`audio/handler.dart`): die von der Plattform direkt aufgerufenen Überschreibungen `pause()`/`play()` (Kopfhörertaste, Sperrbildschirm-/Benachrichtigungssteuerung, eine System-Unterbrechung durch Audio-Fokus-Verlust — von hier aus nicht unterscheidbar, Abschnitt 9 selbst nennt genau diese Ambiguität für die AirPods-Einschlaferkennung) schreiben einheitlich `source: system`; der Hauptbutton ruft stattdessen weiterhin explizit `pauseFrom`/das neue `playFrom(source: ui)` auf. `PROBE`, `RESUME` (`resumeFromFaden`/`resumeFromStop`) und die AWAKE/SLEEP_HINT-Methoden bekommen `Position`/Datei-Index vom Aufrufer (`ui/faden_screen.dart`, das das aktive `Manifest` ohnehin hält) statt intern `_manifest` nachzuschlagen — dadurch funktionieren sie unabhängig davon, ob `openBook()` je gelaufen ist. | Abschnitt 9 legt keine Aufrufform fest, nur Event-Semantik; die Entkopplung von `_manifest` hält alle Regeln (`isAwakeProof`, die Nachtfenster-Bedingung für SLEEP_HINT, Invariante 9) unverändert und war zugleich Voraussetzung dafür, `audio/handler.dart` (in M4 ganz ohne eigene Testdatei) in M5 erstmals direkt zu testen (`app/test/audio/handler_test.dart`), ohne eine echte audio_service/just_audio-Plattform zu benötigen — die nur über `openBook()` erreichbar wäre (siehe E17). |
| E17 | In dieser Sandbox hängt `just_audio`s `AudioPlayer.play()` unbegrenzt, wenn es auf einem Player ohne per `setAudioSources` gesetzte Playlist aufgerufen wird (der Plattform-Aktivierungsschritt wird bei leerer Playlist übersprungen, obwohl bedingungslos auf einen Completer gewartet wird, den nur dieser Schritt erfüllt) — ein reines Sandbox-/Testumgebungs-Artefakt (in echter Nutzung ist vor jedem M5-Aufruf immer schon `openBook()`s nicht-leere Playlist geladen), kein Produktfehler. `app/test/audio/handler_test.dart` umgeht das, indem ein solcher Aufruf gestartet, aber nicht abgewartet wird, und stattdessen direkt das Journal geprüft wird (Invariante 3 garantiert: das Event steht, bevor die — hier dauerhaft hängende — Spieler-Aktion überhaupt läuft), statt auf Testabdeckung für `resumeFromFaden`/`resumeFromStop`/`playFrom` zu verzichten. | Empirisch beim Schreiben der ersten `audio/handler.dart`-Unit-Tests in M5 entdeckt. Nicht upstream gegen just_audio gemeldet, da aus echter App-Nutzung heraus nicht erreichbar. |
| E18 | Der Hörprobe-Ton der Faden-Suche (KONZEPT.md: „Ein leiser Ton, dann eine 4 s lange Hörprobe") ist eine lokal erzeugte, 220 ms lange Sinuston-WAV-Datei (`app/assets/sounds/ton.wav`, per Python-Stdlib `wave`/`math` erzeugt, kein Fremd-Asset, keine Lizenzfrage) und spielt vor *jeder* Probe, nicht nur der ersten — KONZEPT.md nennt den Ton nur einmal als Teil der Ablaufbeschreibung, ohne festzulegen, ob er sich wiederholt; da jede Probe an einer neuen, sonst orientierungslosen Stelle im Buch beginnt, ist die Wiederholung vor jeder Probe die treuere Lesart seines Zwecks. | `prototype/faden.html` (M0) implementiert gar keinen Ton (die Probe spielt direkt), es gab also kein Referenzverhalten zum exakten Abgleich. |
| E19 | Das Ergebnis der Faden-Suche („Ergebnis: Gefunden. Weiter ab hier." / „Leiter: Früher", KONZEPT.md Texte-Tabelle) erscheint als kurzer zweiter Zustand von `ui/faden_screen.dart` selbst (weiterhin Vollbild, weiterhin dunkel) statt als eigener Screen: Die Wiedergabe startet sofort am Fund (ein neues `RESUME`/`source=faden`), der Screen zeigt danach den Bestätigungstext plus einen „Früher"-Button (nur solange die Leiter weiter zurückreicht), jeder andere Tipp kehrt zum Player zurück. Jeder „Früher"-Tipp schreibt auf dieselbe Weise ein weiteres `RESUME`/`source=faden` auf den vorherigen Leiter-Eintrag. | KONZEPT.md „Screens" nennt nur „3. Faden-Modus" als einen Screen, keinen separaten Ergebnis-Screen, und Versprechen 2 („den Punkt in höchstens 60 s finden, ohne aufs Display zu schauen") spricht für sofortiges Weiterhören statt einer zusätzlichen Bestätigung. Die separate „Ergebnis"-Karte in `prototype/faden.html` ist eine M0-eigene Selbsttest-/Protokoll-Kopier-Hilfe, kein Teil der von der App nachzubildenden Interaktion. |
| E20 | `audio/handler.dart` bekommt zwei kleine injizierte Callback-Hooks, `onLastMinuteExtend` und `isInNightWindow`, verdrahtet aus `ui/player_screen.dart`, statt einer direkten Abhängigkeit auf `signals/sleep_timer.dart`s `SleepTimerController` oder die Nachtfenster-Einstellung. Der „Lautstärkeänderung"-Auslöser für AWAKE (Abschnitt 9) wird nicht verdrahtet: KONZEPT.md macht ihn selbst bedingt („falls die Plattform sie meldet"), und es gibt kein bereits deklariertes Cross-Platform-Paket für Hardware-Lautstärketasten-Änderungen in dieser App (CLAUDE.md: Paket-APIs vor Nutzung prüfen, keine ungeprüften neuen Abhängigkeiten); Berührung und Timer-Verlängerung decken die anderen beiden Auslöser ab. | Hält `audio/handler.dart` frei von einer harten Abhängigkeit auf den UI-eigenen Sleep-Timer/die Einstellungen, analog zum bestehenden Muster für `syncClient` (ebenfalls ein optionaler, injizierter Kollaborateur). Der Lautstärke-Auslöser bleibt eine dokumentierte Lücke statt einer ungeprüften Paket-Ergänzung. |

| E21 | M6 (`data/sleep_data_source.dart`, `domain/sleep_onset.dart`, `domain/resolver.dart`, `ui/providers.dart`): Für HealthKit/Health Connect wird das Paket `health` (pub.dev, verifizierter Publisher `carp.dk`, Version 13.3.2, aktiv gepflegt, 680 Likes/160 Pub Points) verwendet, aber nie direkt aus `domain/`/`ui/` -- eine eigene `SleepDataSource`-Schnittstelle (`isSupported`, `requestPermission()`, `sleepOnsetWallMs(...)`) kapselt es; `HealthPluginSleepDataSource` ist die echte, `health`-gestützte Implementierung, Tests verwenden ausschließlich eine eigene Fake-Implementierung (nie eine echte `Health()`-Instanz, die einen Plattform-Kanal ohne Gerät anspräche). `BookState` (Abschnitt 7) bekommt ein zusätzliches Feld `sessionId` (die bereits intern berechnete `winningSessionId`) -- Abschnitt 7 listet dieses Feld nicht, aber Abschnitt 9 braucht genau diese Session-Zuordnung, um "die HEARTBEAT-Events der Session" von denen einer verlierenden/älteren Session zu unterscheiden; alle 8 Resolver-Testvektoren prüfen weiterhin nur die dort dokumentierten Felder und bleiben unverändert grün. Die Wanduhr-zu-Position-Umrechnung (Abschnitt 9: "HEARTBEAT-Events (Wanduhr -> Position)") ist nicht weiter spezifiziert; implementiert als lineare Interpolation zwischen den beiden `T` umgebenden HEARTBEAT-Punkten (Wanduhr- und Global-ms-Werte beider Punkte, nicht nur die Zeitdifferenz -- das bleibt korrekt auch wenn zwischen zwei Herzschlägen gesucht/gesprungen wurde), außerhalb des Herzschlag-Bereichs geklemmt auf den jeweils äußersten Punkt (kein Herzschlag heißt: während der Wiedergabe pausiert, invariant 3). `T` selbst zählt nur, wenn es im durch die Events der Session gebildeten Wanduhr-Zeitraum liegt ("im Zeitraum der Session"), sonst keine Anpassung. Zwei Gültigkeits-Regeln über den wörtlichen Text aus Abschnitt 9 hinaus, beide notwendig, damit `fadenSuche`s eigene Annahme `lo < prior < hi` nie verletzt wird: (1) `hi = min(stop, pos(T + 5 Min))` wird verworfen (auf `stop` zurückgesetzt), wenn das Ergebnis `<= lo` wäre; (2) `prior` wird zusätzlich zur Text-Bedingung "> lo" auch verworfen, wenn es nicht `< hi` (das schon angepasste) ist. Android: `minSdk` von Flutters Default 24 auf 26 angehoben (vom `health`-Beispielprojekt für Health Connect vorausgesetzt), `MainActivity` von `FlutterActivity` auf `FlutterFragmentActivity` umgestellt (das Paket braucht `registerForActivityResult` für die Berechtigungsabfrage), `AndroidManifest.xml` um den Health-Connect-`<queries>`-Block und `android.permission.health.READ_SLEEP` ergänzt (nur Lesen, kein `WRITE_SLEEP` -- diese App schreibt nie Gesundheitsdaten). iOS: `Info.plist` um `NSHealthShareUsageDescription`/`NSHealthUpdateUsageDescription` ergänzt, eine neue `ios/Runner/Runner.entitlements` mit der HealthKit-Capability angelegt und über `CODE_SIGN_ENTITLEMENTS` von Hand in `project.pbxproj` verdrahtet (Äquivalent zu Xcodes "Capability hinzufügen"-Knopf) -- ohne Xcode/Gerät in dieser Sandbox nicht mit einem echten Build verifizierbar. Der komplette Opt-in→Berechtigung→Lesen-Ablauf ist entsprechend nur bis zur Grenze testbar, die ohne Gerät/Berechtigungsdialog erreichbar ist: `SleepDataSource` ist eine Schnittstelle genau deshalb, `test/ui/player_session_sleep_test.dart` deckt jeden Gate (Opt-in aus, keine Datenquelle, nicht unterstützte Plattform, Berechtigung verweigert, keine Ablesung im Zeitraum) sowie explizit CLAUDE.md Invariante 7 (der Journal-Inhalt ist vor und nach jedem `sleepOnsetAdjustment`-Aufruf exakt identisch) mit einer Fake-Implementierung ab; der echte Berechtigungsdialog/`health`-Plattformcode selbst ist in dieser Sandbox nicht ausführbar. | Sicherstellen, dass Invariante 7 (Gesundheitsdaten verlassen nie das Gerät, erzeugen keine Events) und Invariante 9 (`lo` bewegt sich nie durch Gesundheitsdaten) beide strukturell erzwungen sind, nicht nur durch Code-Review: Die reine `domain/sleep_onset.dart` hat schlicht keinen Weg, irgendetwas zu persistieren, und `SleepDataSource` macht den einzigen I/O-Schritt (die eigentliche Ablesung) isoliert test- und ersetzbar, obwohl in dieser Sandbox kein iOS/Android-Gerät für einen echten HealthKit-/Health-Connect-Dialog zur Verfügung steht (CLAUDE.md: Paket-APIs vor Nutzung in der aktuellen Doku prüfen -- hier zusätzlich direkt im gepullten Paket-Quellcode nachgesehen, nicht nur in Trainingsdaten geraten). |
| E22 | Nach „Faden aufnehmen" und „Ab Stopp weiterhören" zeigt der Player den Rückgängig-Hinweis zur Position vor dem Sprung, sobald der Faden-Screen geschlossen ist (`audio/handler.dart` `_resumeTo`, `ui/player_screen.dart`) | Audit: E11 nahm an, die Leiter („Früher") decke Invariante 6 für die Faden-Suche ab. Das gilt aber nur, solange der Faden-Screen offen ist. Das `RESUME` eröffnet nach dem Einschlafen eine neue Session, und Regel 6 erfasst Sprünge nur innerhalb der gewinnenden Session, also stand der Sprung nie im Verlauf. Resolver und `spec/vectors` bleiben unverändert. |
| E23 | `POST /api/v1/events` prüft jedes Event einzeln, speichert die gültigen und meldet die übrigen in `rejected` (Abschnitt 6); `data` ist auf 4 KB begrenzt. Der Client markiert abgelehnte Events als erledigt, löscht sie aber nicht | Audit: Bisher lehnte der Server bei einem einzigen ungültigen Event den ganzen Batch mit 422 ab, der Client schickte denselben Batch endlos erneut und synchronisierte nie wieder, ohne dass es jemand bemerkte. |
| E24 | Der Container läuft nicht als root, sondern als `FADEN_UID`/`FADEN_GID` (Standard 10001); `/data` ist im Image für jeden beschreibbar. Der Server startet nicht mit dem Platzhalter-Token oder einem Token unter 16 Zeichen. SQLite `busy_timeout` 30 s, Commit pro Buch beim Scan, Scans serialisiert, Cover über 10 MB werden ignoriert | Audit: Ein unverändert kopiertes `.env.example` ergab einen Server mit öffentlich bekanntem Token. Während eines minutenlangen Scans scheiterten Event-Pushes mit „database is locked". Die frei wählbare uid ist nötig, weil NAS-Freigaben oft nur für bestimmte Benutzer lesbar sind. Ein Volume, das ein älteres, als root laufendes Image angelegt hat, braucht einmal `chown`. |
| E25 | `just_audio`s `play()` wird nicht abgewartet (`audio/handler.dart` `_startPlayback`, `audio/probe_player.dart`) | Laut Paket-Doku kehrt `play()` erst zurück, wenn die Wiedergabe pausiert oder endet. Bisher starteten Herzschlag und periodischer Sync deshalb erst nach der Wiedergabe (verletzte Invariante 3), und der Faden-Screen kam nicht zum Ergebnis. Das Event wird weiterhin vor dem Start der Wiedergabe committet. |
| E26 | Die Hörprobe endet spätestens am Dateiende laut Manifest (`durationMs`), nicht laut `just_audio`-Dauer | Audit: `_player.duration` kann direkt nach `setAudioSources` noch `null` sein, vor allem bei gestreamten Dateien. Dann lief die Probe ins nächste Kapitel (verletzte Abschnitt 8). |
| E27 | iOS `Info.plist`: `UIBackgroundModes` = `audio`, `NSAppTransportSecurity` → `NSAllowsArbitraryLoads` = true, `NSLocalNetworkUsageDescription` | Beim ersten Gerätetest fehlten alle drei. Ohne `audio` endet die Wiedergabe beim Sperren (Pflicht laut README von `audio_service`). `just_audio` braucht laut README `NSAllowsArbitraryLoads` für `http://`-Adressen und für Header wie den Bearer-Token. Der Server läuft per HTTP im LAN oder VPN (Abschnitt 12), unter Umständen auf einer Nicht-RFC1918-Adresse wie bei Tailscale (100.64/10), die `NSAllowsLocalNetworking` nicht abdeckt. Für eine selbst installierte App ohne App Store vertretbar. Android (`AndroidManifest.xml`) fehlt die `audio_service`-Einrichtung noch ebenso. |
| E28 | Einstellung „Erscheinungsbild“ mit „Wie iPhone“ (Standard, folgt der Hell/Dunkel-Einstellung des Telefons), „Hell“ und „Dunkel“, gespeichert in `settings_store.dart` (Schlüssel `appearance`). „Hell“ nutzt die Tag-Tokens, „Dunkel“ die Nacht-Tokens (Bernstein auf Schwarz), aber ohne das Nachtmodus-Verhalten: Cover bleibt sichtbar, Hauptbutton gefüllt, keine Tastensperre. Der Nachtmodus (Nachtfenster oder laufender Sleep-Timer) hat weiter Vorrang und bringt Aussehen und Verhalten mit, egal was eingestellt ist. Die Auflösung (Einstellung + Helligkeit des Telefons + Nachtmodus → Token-Satz) ist die pure Funktion `resolveFadenTokens` in `ui/theme.dart`. Der Nachtmodus gilt wie bisher nur im Player; Bibliothek und Einstellungen folgen allein dem Erscheinungsbild. Die 10-s-Tastensperre greift jetzt ausdrücklich nur im Nachtmodus (vorher lief der Sperr-Timer auch tagsüber und sperrte die Tasten nach 10 s). Nachtfenster, Erscheinungsbild und „Schlafdaten erlauben“ werden sofort beim Ändern gespeichert; Server-Adresse und Token behalten „Speichern“, weil `main.dart` den API-Client nur beim Start baut. Das Nachtfenster wird über zwei Zeilen mit 24-Stunden-Uhrzeitauswahl statt über Schieberegler eingestellt, Speicherung weiter in Minuten seit Mitternacht. KONZEPT.md „Screens“ nennt „Erscheinungsbild“ jetzt unter Einstellungen. | Wunsch nach dem ersten Gerätetest: Die App soll sich wie andere iPhone-Apps an Hell/Dunkel halten oder fest einstellbar sein. KONZEPT.md bindet den Nachtmodus an den Schlaf-Anwendungsfall, nicht an das Systemdesign; deshalb bleibt beides getrennt, und „Dunkel“ leiht nur die Farben. Neue Farben wären nötig gewesen, um die 4,5:1-Kontrastregel neu zu prüfen; die Nacht-Tokens erfüllen sie schon. |
| E29 | Mini-Player (`ui/mini_player.dart`) unten in Bibliothek und Einstellungen, solange ein Buch offen ist (nicht im Player, nicht im Faden-Modus): kleines Cover, Titel, Restzeit, dünne Fortschrittslinie in Faden-Farben (nicht ziehbar), ein Play/Pause-Knopf (56 dp) über `playFrom`/`pauseFrom` mit `source: ui`. Ein Tipp auf die Leiste führt zurück zum Player. Bei `sleep_suspected` spielt der Knopf nicht ab, sondern öffnet den Player, damit „Faden aufnehmen“ angeboten wird. Navigation: Der Player ist die eine Wurzel-Route (`PlayerScreen.route()`); das Bibliothek-Symbol legt die Bibliothek darüber, statt den Player zu ersetzen, und Buchauswahl wie Mini-Player kehren über `showPlayerScreen` zu genau diesem Player zurück. Startet die App ohne offenes Buch in der Bibliothek, ersetzt die erste Buchauswahl den ganzen Stapel durch den Player. | Wunsch nach dem ersten Gerätetest (wie Tidal/Spotify); steht nicht in der Screen-Liste von KONZEPT.md. Vorher ersetzte das Bibliothek-Symbol den Player, und jede Buchauswahl legte einen neuen Player obendrauf; dabei wurde der Player samt Sleep-Timer verworfen und der Stapel wuchs. Ein stilles Weiterspielen ab dem Stopp-Punkt aus dem Mini-Player würde die Faden-Suche umgehen, deshalb öffnet er in diesem Fall den Player. |
| E30 | Offline-Cache für Bibliothek und Bücher: Jede erfolgreiche Antwort von `GET /api/v1/books` und `GET /api/v1/books/{id}` wird als JSON-Datei unter Application Support (`library/`) abgelegt (`data/library.dart`, `LibraryCache`/`LibraryRepository`). App-Start und Bibliothek lesen zuerst den Cache und fragen den Server im Hintergrund (`BookOpener` in `ui/providers.dart`). Ändert sich dabei das aktive Manifest eines geöffneten, pausierten Buchs, wird es mit dem neuen Manifest neu vorbereitet. Die Bibliothek meldet die Liste, sobald sie da ist, und holt Details danach mit höchstens 4 gleichzeitigen Anfragen. Covers kommen offline aus der schon für den Sperrbildschirm gespeicherten Kopie. Kein Drift-Schema dafür. | KONZEPT „Unterwegs“: Ohne Server öffnete bisher gar nichts, auch kein geladenes Buch, weil Start und Bibliothek `bookDetail` brauchten. Der Cache ist reiner Server-Spiegel; Fortschritt kommt weiterhin nur aus dem Journal (Invariante 2). JSON-Dateien statt Tabelle, damit keine Migration das Journal berührt. |
| E31 | Sync-Auslöser vollständig (Abschnitt 6): App im Vordergrund (`AppLifecycleListener`) und Netzwechsel (`connectivity_plus`, nur als Auslöser) in `main.dart`; Start, Pause und 60-s-Takt wie bisher über `FadenAudioHandler.syncNow` (ein laufender Sync wird geteilt). Beim Öffnen eines Buchs wird zuerst synchronisiert (höchstens 2 s warten), dann aufgelöst. Bringt ein Pull neue Events eines anderen Geräts für das offene Buch (`SyncSummary.pulledBookIds`, eigene zurückkommende Events zählen nicht) und läuft nichts, löst `PlayerSessionController` neu auf und setzt den vorbereiteten Player auf die neue Position (`adoptRemotePosition`, ohne eigenes Event, nur wenn sie um mindestens 1,5 s abweicht). Bei einem Sprung über 2 Min erscheint der Rückgängig-Hinweis „Position vom anderen Gerät übernommen“; „Rückgängig“ schreibt wie immer ein `UNDO`. | KONZEPT „Zwei Geräte“ und Invariante 6. Die Übernahme braucht kein eigenes Event: Die entscheidenden Events des anderen Geräts liegen schon im Journal, der Player folgt nur dem Resolver. Das `UNDO` gewinnt dann als neueste Absicht. Während der Wiedergabe wird nie übernommen. |
| E32 | Automatisches Zurückspulen beim Fortsetzen: Pause ab 10 s → 3 s, ab 5 Min → 10 s, ab 1 h → 30 s, nie vor den Buchanfang, auch über Kapitelgrenzen (pure Funktion `domain/auto_rewind.dart`). Gilt für Play per Button, Mediataste und Ende einer Unterbrechung; die Pausenzeit überlebt einen App-Neustart (neuestes Event des Buchs). Nicht nach einem ausdrücklichen Sprung im Pausenzustand (±30 s, Kapitel, Scrubber, Verlauf, Übernahme per Rückgängig) und nie für Faden-Suche oder „Ab Stopp weiterhören“. Die zurückgespulte Stelle ist die Position des `PLAY`-Events selbst. | Produktentscheidung (wie Apple Books). Alle Werte liegen unter 2 Min, daher kein eigener Sprung und kein Rückgängig-Hinweis; das Event enthält die tatsächliche Startstelle (Invariante 3). |
| E33 | Fortschritt je Buch für die Bibliothek („Weiterhören“, „zuletzt gehört“) aus einer einzigen SQL-Abfrage (`Journal.progressRows`, Fensterfunktionen), die Regeln 1–3 des Resolvers nachbildet: gewinnende Session über das letzte Absicht-Event nach `(pt, c, device_id, event_id)`, Position = deren letztes Event; dazu die jüngste Wanduhrzeit des Buchs. Ein Test vergleicht sie mit dem Resolver auf Zufallsdaten. Dafür Schema v3: nur ein zusätzlicher Index `event_rows_book_hlc (book_id, hlc_pt, hlc_c)`, additive Migration, kein Event wird verändert. Das Manifest behält den Dateititel des Servers (`ManifestFile.title`); die UI zeigt ihn, sonst „Kapitel N“. | Kein Resolver-Lauf pro Zeile. Der Index beschleunigt auch `eventsForBook`, das bisher das ganze Journal las (ein Herzschlag alle 5 s). |
| E34 | Downloads: Der Audio-Hash wird genau einmal geprüft, wenn eine Datei fertig ist; danach liegt daneben `<file_hash>.ok` mit der geprüften Größe, und „geladen“ heißt Datei vorhanden und Größe gleich Marker. Dateien ohne Marker (vor dieser Änderung geladen) werden einmal nachgeprüft und markiert. `BookDownloads` (`data/book_downloads.dart`) bietet je Buch Fortschritt (Bytes und nach Dauer gewichteter Anteil), Abbrechen, Wiederholen, Löschen, Speicherbedarf je Buch und gesamt sowie einen Fehlerzustand, der bis zum nächsten Versuch sichtbar bleibt. | Bisher wurde bei jedem Öffnen und jeder Bibliotheks-Aktualisierung jede Datei komplett per SHA-256 gelesen, und Fehler verschwanden spurlos. Abschnitt 11 („erst fertig, wenn der Hash stimmt“) gilt unverändert. |
| E35 | Heruntergeladene Hörbücher liegen in Application Support (`audio/`) statt in Documents und tragen auf iOS das Attribut „vom Backup ausschließen“ (kleiner Method-Channel `de.faden.app/storage` in `ios/Runner/AppDelegate.swift`, `URLResourceValues.isExcludedFromBackup`, auf dem Ordner). Beim Start werden vorhandene Dateien aus `Documents/audio` verschoben (Name und Marker bleiben, `.part`-Reste entfallen). Die Datenbank `faden.db` bleibt in Documents. | Gigabytes an jederzeit neu ladbarem Audio gehören nicht ins iCloud-Backup. Das Journal bleibt bewusst am alten Ort und im Backup, damit kein gespeichertes Event angefasst wird. |
| E36 | Unterbrechungen: `just_audio` läuft mit `handleInterruptions: false`. Anrufe und andere Unterbrechungen sowie „Kopfhörer getrennt“ kommen über `audio_session` (`interruptionEventStream`, `becomingNoisyEventStream`) in `FadenAudioHandler.attachAudioSessionEvents` und laufen über `pauseFrom`/`playFrom` mit `source: system`, also als `PAUSE`/`PLAY` im Journal (samt `SLEEP_HINT`-Regel im Nachtfenster). Nur eine Unterbrechung vom Typ `pause` setzt nach ihrem Ende fort (mit E32), `unknown` nicht; Ducking übernimmt das System. | Bisher pausierte und startete `just_audio` selbst, ohne Event: Die Position nach einem Anruf fehlte im Journal (Invariante 3). |
| E37 | Netz: API-Aufrufe mit 4 s Verbindungs- und 15 s Empfangs-Timeout; Downloads nur mit 60 s Stillstands-Timeout (dio misst den Empfang pro Datenpaket, nicht gesamt). Server-Adressen werden normalisiert (`http://` ergänzt, `/` am Ende entfernt, sonst ungültig). `ApiClient.checkConnection()` liefert `ok`, `unauthorized` (401/403), `unreachable` (Timeout, keine Verbindung, kein Faden-Server) oder `invalidUrl` (Health, dann ein authentifizierter Aufruf). Server-Einstellungen sind ein Riverpod-Zustand (`serverConfigProvider`); Speichern baut API-Client, Downloads, Sync und Bibliothek sofort neu, ohne Neustart. | Ein langsamer oder nicht erreichbarer NAS hielt den Startbildschirm bis zu 75 s fest, und eine geänderte Adresse wirkte erst nach einem Neustart. |
| E38 | Wiedergabetempo pro Buch, lokal in den Einstellungen (`book_speed:<book_id>`), beim Öffnen angewendet; weiterhin kein Event und nicht synchronisiert. | Abschnitt 5 kennt kein Tempo-Event, und Tempo ist keine Position. Ein Buch mit schneller Sprecherin soll nicht das Tempo des nächsten bestimmen. |
| E39 | `FadenAudioHandler.statusStream` liefert `PlaybackStatus` (spielt, puffert, letzter Wiedergabefehler). Fehler aus `just_audio` werden abgefangen; stoppt die Wiedergabe dadurch, wird das als `PAUSE` (`source: system`, ohne `SLEEP_HINT`) geschrieben. Das nächste Play lädt die Playlist an der Position neu. | Der Wiedergabe-Stream hatte keinen Fehler-Handler, und der Button zeigte „Pause“, während nichts lief. |
| E40 | `eventsWritten` trägt das geschriebene Event. `PlayerSessionController` löst bei `HEARTBEAT` nicht neu auf (die Position liest die UI live aus `positionStream`), nur bei allen anderen Events des offenen Buchs. | Bisher lief der Resolver über alle Events des Buchs alle 5 s. |
| E41 | Wechselt man das Buch, während eines spielt, wird das alte zuerst pausiert und als `PAUSE` (`source: ui`) für das alte Buch geschrieben. Ein Tipp auf das schon offene Buch lässt die Wiedergabe unberührt. | Bisher begann das neue Buch ohne `PLAY`, und die Session des alten Buchs endete nie. |
| E42 | Sleep-Timer: Der Countdown läuft nur während der Wiedergabe. „Kapitelende“ pausiert, wenn die Wiedergabe tatsächlich ins nächste Kapitel läuft (Playlist-Index +1 ohne eigenen Sprung, `chapterAdvanced`), nicht zu einer beim Start errechneten Uhrzeit; Anzeige und Ausblenden folgen der Restzeit des Kapitels beim aktuellen Tempo. Eine Verlängerung in der letzten Minute lässt bei „Kapitelende“ einen Kapitelwechsel passieren. Die zuletzt gewählte Dauer wird als Standard gespeichert (`sleepTimerDefaultProvider`, 0 = Kapitelende). In der letzten Minute verlängern nur Kopfhörer- und Medientasten, Bildschirmtasten wirken normal. | Die alte Uhrzeit-Rechnung stimmte bei Tempo ≠ 1 und nach Sprüngen nicht, ein pausiertes Buch verbrauchte den Timer, und KONZEPT nennt für die Verlängerung ausdrücklich die Kopfhörertaste. |
| E43 | Der Scrubber auf dem Sperrbildschirm bleibt ziehbar: `seek(Duration)` innerhalb des aktuellen Kapitels schreibt ein `SEEK` (`source: system`) mit demselben Rückgängig-Hinweis wie jeder andere Sprung; im Faden-Modus wird er ignoriert. | `MediaAction.seek` war angekündigt, aber `seek()` nicht implementiert, Ziehen bewirkte nichts. |
| E44 | Player-Layout (`ui/player_screen.dart`): Cover = min(Breite − 48, 38 % der Höhe) und schrumpft auf den Restplatz (unter 72 dp entfällt es), Titel höchstens 2 Zeilen, Autor darunter, Bedienelemente und „Ab Stopp weiterhören“ (echter TextButton, 56 dp) immer sichtbar, Schriftskalierung im Player auf 1,6 begrenzt. Ohne Cover Initialen in `faden` statt des Titels. Restzeit minutengenau und aufgerundet („noch 3 Std. 45 Min.“, `ui/format.dart`). Nur Faden und die zwei Positions-Texte hören auf `positionStream`; die Texte bauen nur bei geändertem Text neu. Cover werden in Anzeigegröße dekodiert (`cacheWidth`). Tempo und Sleep-Timer als Segmente gleicher Breite statt ChoiceChips, Tempo als „1,25×“. Haptik bei „kenne ich“, beim Entsperren und bei der Timer-Verlängerung | Audit: Überlauf bis 546 px (SE, Schrift 1,35), Cover wiederholte den Titel, Cover/Titel/Buttons liefen 5-mal pro Sekunde neu, sekündlich tickende Restzeit war unruhig, Chips sprangen in der Breite. |
| E45 | Theme vollständig aus den Tokens (`ui/theme.dart`): alle ColorScheme-Rollen (u. a. `outline`, `outlineVariant`, `onSurfaceVariant`, `secondaryContainer`, `inverseSurface` nachts dunkel `#1E1A15`), neues Token `fehler` (Tag `#B3261E`, Nacht `#D9745A`, je ≥ 4,5:1), alle TextTheme-Stufen auf 28/20/17/14, `NoSplash`, adaptive Schalter und Radios, Uhrzeit per Cupertino-Drehrad. Material/Cupertino-Standardtexte deutsch über `flutter_localizations` (Teil des Flutter-SDK) | Audit: Material-Vorgaben schlugen durch (Dialogtitel 24 sp, beige SnackBar nachts, lila Flächen, Tinten-Welle, englisches „Back“). Entscheidung des Nutzers: Bedienung wie auf dem iPhone. |
| E46 | Nachtmodus reicht über den Player hinaus: Der Player veröffentlicht nach jedem Build `PlayerChrome` (Theme, Nacht, Sperre) an offene Blätter und `nightModeProvider` an die App-Wurzel. Details-Sheet und Kapitelliste folgen dem live; bei aktiver Sperre lässt sich das Sheet weder öffnen (Wischen, Griff) noch bedienen (Overlay, 1 s Halten entsperrt). Jede Berührung im Sheet zählt wie eine am Player (Sperr-Timer, AWAKE) | Audit: Das Sheet bekam den Kontext über dem Player-Theme und war nachts hell; Scrubber und Kapitel waren trotz Sperre bedienbar. Bibliothek und Einstellungen sind nachts im Bett dunkel genauso nötig. |
| E47 | Start: `LaunchScreen.storyboard` mit `systemBackgroundColor` statt Weiß; der Flutter-Startscreen ist eine leere Fläche in `grund` ohne Spinner; main.dart liest das Nachtfenster vor dem ersten Frame (`initialNightModeProvider`), damit der erste Frame nachts schon schwarz ist | Weißer Blitz vor dem schwarzen Nacht-Player. |
| E48 | Bibliothek (`ui/library_screen.dart`): „Weiterhören“ (bis zu 3 zuletzt gehörte, nicht zu Ende gehörte Bücher, E33), Suche über Titel und Autor (Groß/klein und Umlaute gefaltet), Sortierung zuletzt gehört/Titel/Autor (nur für die Laufzeit gemerkt), Cover-Vorschau zuerst aus der gespeicherten Kopie (`libraryCoverProvider`, autoDispose), Fortschritt als dünner Faden mit „noch 5 Std.“ bzw. „neu“/„gehört“, Download als ruhiges Symbol, Ring mit Abbrechen, Fehler mit „Erneut versuchen“, Löschen mit Größe per Wischen (mit Rückfrage) oder langem Druck. „unvollständig“/„keine Dateien“ sind grau und erklären sich beim Tippen. „Reihenfolge prüfen“ zeigt je Kandidat die Dateien ab kurz vor der ersten Abweichung mit Titel und Track; dafür trägt `ManifestFile` `disc`/`track` (nur Anzeige, nie Schlüssel). Erststart ohne Server: „Server einrichten“ statt eines wirkungslosen „Erneut versuchen“; offline mit bekannten Büchern ein schmaler Hinweis | Entscheidung des Nutzers (Weiterhören, Cover, Fortschritt, Suche) und Audit (Rohtexte wie „Option 1 · 12 · needs_review“, 38-%-Knopf für „geladen“). |
| E49 | Bewegung zwischen Player und Bibliothek (`ui/routes.dart`): Der Player bleibt Wurzel-Route (E29). Die Bibliothek kommt als `UnderPlayerRoute`: der Player gleitet nach unten weg, die Bibliothek erscheint im frei werdenden Streifen; zurück (Mini-Player, Zurück) gleitet der Player wieder hoch. Wischen nach unten auf dem Player öffnet die Bibliothek (nicht bei Sperre). Bei „Bewegung reduzieren“ wechseln alle Übergänge sofort, auch der Faden im Faden-Modus | Entscheidung des Nutzers; der Player samt Sleep-Timer darf dafür nicht abgebaut werden. |
| E50 | Nur Hochformat: `Info.plist` (iPhone nur Portrait, iPad Portrait mit `UIRequiresFullScreen`), Android-Manifest und `SystemChrome` in main.dart. `CFBundleLocalizations` = `de` für deutsche Systemmenüs. Die plist bleibt ohne XML-Kommentare | Entscheidung des Nutzers. |
| E51 | Einstellungen: „Verbindung prüfen“ testet Adresse und Token wie eingegeben, ohne zu speichern (`connectionCheckerProvider` → `ApiClient.checkServer`), mit je eigener Meldung für ok, falscher Token, nicht erreichbar, ungültige Adresse; „Speichern“ prüft danach selbst. Nachtfenster: Erklärung plus zwei Zeilen „Beginn“/„Ende“ mit der Uhrzeit rechts (die Zusammenfassung entfällt). Neu: Sleep-Timer-Standard und Speicher (gesamt, je Buch mit Löschen). Schlafdaten nennen „Health“ auf dem iPhone, „Health Connect“ unter Android | Audit: dreifache Uhrzeit, kein Prüfen der Verbindung, „Health/Health Connect“. |
| E52 | Details-Sheet und Wiedergabestatus: Scrubber nur für das aktuelle Kapitel mit verstrichener/verbleibender Zeit und großer Anzeige beim Ziehen, Sprung über `seekToGlobalMs` (journaled, Rückgängig-Hinweis über 2 Min); Verlauf vor den Kapiteln; alle Kapitel in einem eigenen Blatt mit Titel und Dauer, das beim aktuellen Kapitel öffnet; Sleep-Timer merkt die gewählte Dauer (`SleepTimerState.chosen`), zeigt den Countdown und startet mit dem gespeicherten Standard. Puffern zeigt einen Spinner im Hauptbutton und im Mini-Player; ein Wiedergabefehler erscheint einmal als „Kann nicht abspielen“ mit „Erneut versuchen“ (`playFrom(ui)`) | Audit: Auswahl fiel nach 2 Min weg, lange Kapitelliste vor dem Verlauf, `statusStream` (E39) war ungenutzt. |
| E53 | Der ungehörte Teil des Fadens ist nachts 60 % statt 40 % `tinte-leise`, als deckende Farbe gezeichnet; Kapitellücken erscheinen nur, wenn die Kapitel auf beiden Seiten mindestens 12 dp breit sind (`visibleChapterGaps` in `ui/thread_progress.dart`) | Auf dem iPhone war der Faden nachts auf Schwarz kaum zu sehen, und bei vielen kurzen Kapiteln zerfiel er in einzelne Punkte. |
| E54 | Die Nachtansicht folgt der Bildschirmhelligkeit statt Nachtfenster und Sleep-Timer: an unter 30 %, aus erst über 35 % (Hysterese, pure Funktion `nextNightView` in `signals/night.dart`); ohne Helligkeitswert (Android, Tests, Fehler) aus. Quelle ist ein kleiner Method- und Event-Channel in `ios/Runner/AppDelegate.swift` (`de.faden.app/brightness`), der `UIScreen.main.brightness` nur liest: beim Abonnieren, bei `brightnessDidChangeNotification`, beim Zurückkehren in den Vordergrund und alle 5 s, solange die App aktiv ist. `nightModeProvider` (`ui/providers.dart`) rechnet die Ansicht selbst aus der Quelle aus, statt sie vom Player zu übernehmen; `main.dart` liest die Helligkeit vor dem ersten Frame. Die Tastensperre entfällt ganz: kein `ScreenLockController`, kein „Gesperrt …“, kein Halten zum Entsperren, kein Overlay im Details-Sheet, Wischen und Griff öffnen es immer. Nachts zeigt der Player Titel (17 sp, höchstens 2 Zeilen) und aktuelles Kapitel (14 sp, 1 Zeile) in `tinte-leise` über dem Faden, weiter ohne Cover. Unverändert: Das Nachtfenster speist Schlafverdacht (Abschnitt 7 Regel 5) und `SLEEP_HINT` (Abschnitt 9, `isInNightWindow`); Berührungen erzeugen `AWAKE`; Kopfhörertasten verlängern den Sleep-Timer in der letzten Minute; „Dunkel“ und „Wie iPhone“ (E28) gelten, solange die Nachtansicht aus ist. Ersetzt: in E28 den Auslöser „Nachtfenster oder laufender Sleep-Timer“ und „keine Tastensperre“ als Unterschied zu „Dunkel“; in E44 die Haptik beim Entsperren; in E46 `PlayerChrome.locked`, das Sperr-Overlay und dass der Player `nightModeProvider` setzt; in E47 das Nachtfenster als Grundlage des ersten Frames; in E49 „nicht bei Sperre“. | Gerätetest auf dem iPhone: Die Sperre störte mehr, als sie half, und das Nachtfenster traf nicht, wann es wirklich dunkel ist; wer den Bildschirm herunterdimmt, will die dunkle Ansicht. Titel und Kapitel gedimmt helfen beim Einschlafen, ohne Licht zu machen. Das Paket `screen_brightness` (2.1.11) wurde geprüft und verworfen: Unter iOS liefert sein `system` einen zwischengespeicherten Wert, der Änderungs-Stream hört nur, solange die App inaktiv ist, und mit dem voreingestellten Auto-Reset setzt es die Helligkeit beim Verlassen der App selbst, statt sie nur zu lesen. |
| E55 | Der Pausen-Index wird bei jedem Abruf je Buch als JSON-Datei neben dem Bibliotheks-Cache abgelegt (`library/pauses-<book_id>.json`), zusammen mit der ID des Manifests, mit dem das Buch geöffnet war (`LibraryRepository.fetchPauseIndex`/`cachedPauseIndex`). Beim Öffnen gilt sofort die gespeicherte Kopie, aber nur bei gleicher Manifest-ID; danach fragt `PlayerSessionController` den Server im Hintergrund und ersetzt sie. Das Öffnen wartet nicht mehr auf den Abruf. | Der NAS ist nachts (20–7 Uhr) aus, genau wenn im Bett gehört wird: Ohne Server rastete die Faden-Suche bisher nie auf Satzanfänge ein. Offsets eines anderen Manifests könnten an falschen Stellen einrasten, daher kein Cache über einen Manifest-Wechsel. |
| E56 | „Aktuelle Bücher automatisch laden“ (Einstellung, Standard an, `settings_store.dart` `auto_download`): `AutoDownloader` (`data/offline_books.dart`) lädt das offene Buch und das nächste Buch aus „Weiterhören“ (nicht zu Ende gehört, nicht `finished`), wenn sie nicht vollständig geladen sind — nur bei WLAN oder Ethernet ohne gleichzeitig gemeldeten Mobilfunk (`connectivity_plus`) und nur, wenn `/health` antwortet. Auslöser: Buch öffnen, App-Start, App im Vordergrund, Netzwechsel ins WLAN; ein Wechsel weg vom WLAN bricht nur die automatisch gestarteten Downloads ab. Immer im Hintergrund; ein Auslöser während eines Durchlaufs fordert genau einen weiteren an, `BookDownloads` lädt kein Buch doppelt. | Entscheidung des Nutzers: Der NAS ist nachts aus. Mobilfunk nie, damit kein Datenvolumen verbraucht wird. Ohne erreichbaren Server wird gar nicht erst versucht, sonst stünde nachts „Herunterladen fehlgeschlagen“ in der Bibliothek. |
| E57 | Zu Ende gehörte Bücher löschen ihre heruntergeladenen Audiodateien (`FinishedCleanup` in `data/offline_books.dart`): nur wenn der Resolver `finished` meldet (Ende ohne Schlafverdacht, Nachtfenster aus den Einstellungen) und die Position im aktiven Manifest liegt. Events, Positionen, Bibliotheks- und Pausen-Cache bleiben. Beim Start vor dem Öffnen des letzten Buchs für alle Bücher mit `FINISHED`-Event (`Journal.bookIdsWithEvent`), beim Öffnen eines anderen Buchs für das vorher geladene und nach einem Sync für Bücher mit neuen Events anderer Geräte. Ein Buch, das noch im Player geladen ist, behält seine Dateien bis dahin. | Entscheidung des Nutzers (Speicher). Invariante 5: Mit Schlafverdacht ist ein Buch nicht fertig, also bleibt es geladen. Die Playlist des geladenen Buchs zeigt auf die Dateien; gelöscht würde ein erneutes Hören des letzten Kapitels scheitern. Die Dateien sind jederzeit wieder ladbar. |
| E58 | Offline und nicht geladen: `PlaybackFailure.notDownloaded` sagt, dass das fehlgeschlagene Kapitel vom Server gestreamt werden sollte (`streamsFromServer` in `audio/player.dart`). Antwortet der Server dann nicht (`serverReachableProvider`), zeigt der Player statt „Kann nicht abspielen“ „Nicht geladen – der Server ist gerade nicht erreichbar.“, auch für einen Fehler, der schon vor dem Player-Screen auftrat (App-Start). In der Bibliothek sind offline alle nicht vollständig geladenen Bücher gedimmt und tragen „· nur online“ in der Statuszeile. | Nachts war ein nicht geladenes Buch bisher nur ein allgemeiner Wiedergabefehler ohne Grund, und die Bibliothek zeigte nicht, was offline spielt. |
| E59 | Der Player selbst bekommt den Kapitel-Scrubber aus dem Details-Sheet (unter dem Faden), und die Nachtansicht zeigt das Cover stark abgedunkelt (45 % Deckkraft), schrumpfend bis ausgeblendet bei wenig Platz; die doppelte Kapitelzeile unter dem Titel entfällt, auf kurzen Bildschirmen werden die Abstände halbiert | Wunsch des Nutzers nach dem ersten Abend: Im Player fehlten Cover und Vorspulen. Der Scrubber springt wie im Details-Sheet über `seekToGlobalMs` (SEEK-Event, Rückgängig-Hinweis ab 2 Min), Invariante 6 bleibt gewahrt. Ersetzt den Teil von KONZEPT „Player ohne Scrubber im Hauptscreen“ und von E54 „ohne Cover“. |
| E60 | Navigation umgedreht: Die Bibliothek ist die Wurzel-Route (`LibraryScreen.route()`, `BaseRoute` ohne Übergang, kein Zurück-Pfeil; Sortierung und Einstellungen im App-Bar), der Player eine Route darüber (`PlayerRoute`). App-Start (`main.dart`): mit zuletzt offenem Buch Stapel [Bibliothek, Player], der Player ohne Übergang, sonst nur die Bibliothek. Schließen per Pfeil nach unten oben links (`AppStrings.playerClose`), Wischen nach unten oder „Bibliothek“ im Details-Sheet (`closePlayer`: `pop`; liegt nichts darunter, ersetzt die Bibliothek den Player). Mini-Player und Buchauswahl rufen `showPlayerScreen`: holt einen vorhandenen Player nach vorn (`PlayerRoute.activeIn`), sonst Push über den aktuellen Screen — nie zwei Player. Der Player gleitet beim Öffnen hoch und beim Schließen nach unten; bei „Bewegung reduzieren“ sind beide Dauern 0 (aus `platformDispatcher.accessibilityFeatures`, da die Dauer beim Einsetzen der Route feststeht); kein seitliches Zurückwischen (`popGestureEnabled` aus). Weil der Player jetzt abgebaut wird, leben seine app-weiten Aufgaben außerhalb: Sleep-Timer als `sleepTimerProvider` (samt `onLastMinuteExtend` und `chapterAdvanced`), der SLEEP_HINT-Haken als `nightWindowHookProvider` (beide von `FadenApp` beobachtet), Undo-Hinweise und Wiedergabefehler im `PlaybackAnnouncer` über dem Navigator (`MaterialApp.builder`); das Zurückhalten von Undo-Hinweisen während der Faden-Suche läuft über `fadenScreenOpenProvider`. Ersetzt in E29 „Der Player ist die eine Wurzel-Route“ und das Ersetzen des Stapels bei der ersten Buchauswahl, in E49 `UnderPlayerRoute` und das Wegschieben des Players für die Bibliothek. | Wunsch des Nutzers: Vom Player geht es zurück in die Bibliothek, nicht umgekehrt. „Start ist der Player“ bleibt, weil der Player beim Start sofort über der Bibliothek liegt. Ohne das Herauslösen hätte das Schließen des Players den laufenden Sleep-Timer beendet, und Fehler aus dem Mini-Player wären in der Bibliothek stumm geblieben. |
| E61 | Sleep-Timer direkt im Player (Tag und Nacht): Mond-Knopf (`SleepTimerButton`, mind. 56 dp, VoiceOver „Sleep-Timer“ mit der Restzeit als Wert) rechts im unteren Streifen neben dem Details-Griff. Ein Tipp öffnet ein kleines Sheet im Look des Players (`showSleepTimerSheet`): 15, 30, 45, 60 Min., Kapitelende, Aus; die Wahl startet oder stoppt den Timer, wird wie im Details-Sheet als Standard gemerkt und schließt das Sheet. Läuft ein Timer, zeigt der Knopf die aufgerundeten Minuten („12 Min.“) oder „Kapitelende“; lange Texte schrumpfen, statt den Griff zu überdecken. Player und Details-Sheet teilen denselben `SleepTimerController` aus `sleepTimerProvider`, es gibt keine zweite Timer-Logik. | Wunsch des Nutzers: den Timer abends ohne Umweg über die Details stellen. Unten rechts statt im App-Bar, weil der Nacht-Player keinen App-Bar hat und eine eigene Zeile oben auf dem iPhone SE bei 135 % Schrift und Schlafverdacht nicht mehr passte; der Streifen neben dem Griff kostet keine Höhe und ist nachts mit dem Daumen gut erreichbar. |
| E62 | Laufende Downloads zeigen in der Bibliothek die Restmenge („noch 240 MB“) statt der empfangenen Menge oder eines Fortschrittsrings; der Abbrechen-Knopf ist nur noch ein Stopp-Symbol, Fehler behalten „Erneut versuchen“. Das Manifest kennt keine Dateigrößen, daher schätzt `estimateRemainingBytes` (`data/book_downloads.dart`, pur) die Restmenge aus den bekannten Größen (fertige Dateien plus die laufende, sobald ihre Größe gemeldet ist) über die noch fehlende Dauer; der Rest der laufenden Datei ist dann exakt. Ohne Grundlage (noch keine Größe bekannt) steht „Lädt …“. Anzeige über `formatRemainingBytes` (`ui/format.dart`): aufgerundet, ganze MB unter 100 MB, 10-MB-Schritte bis 1 GB, darüber GB mit einer Nachkommastelle (deutsches Komma) bzw. ganze GB ab 10 GB. | Wunsch des Nutzers: Wichtig ist, wie viel noch fehlt (reicht das WLAN noch?), nicht wie viel schon da ist. Grob gerundet, weil es eine Schätzung ist und sonst bei jedem Fortschritt springt. |

Neue Entscheidungen unten anhängen: Nummer, Entscheidung, Grund.
