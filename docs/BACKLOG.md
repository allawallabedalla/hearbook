# Backlog

Stand: 25.09.2026 (Nachtrag). Erledigtes durchstreichen oder löschen.

## Für dich, wenn du daheim bist

1. **NAS aktualisieren** (ca. 3 Min.; bringt Dateigrößen und Genre):
   ```
   ssh naigo@192.168.178.114
   cd /volume1/docker/faden && git pull && sudo docker compose up -d --build
   ```
2. **App aufs iPhone** (ca. 5 Min.; iPhone per Kabel oder im selben WLAN):
   ```
   cd ~/Developer/hearbook && git pull && cd app/scripts && ./ios-resign.sh --force
   ```
3. **Auf dem iPhone ausprobieren** (ca. 10 Min.):
   - Player nach unten wischen: folgt er dem Finger?
   - „Faden aufnehmen“: Karten mit „Kenne ich“ / „Kenne ich nicht“, Liste, Ergebnis
   - Sleep-Timer unten rechts (Mond mit zzz), Hell/Dunkel oben rechts (Mond/Sonne)
   - Bibliothek: Filter-Chips, „Nach Autor“ im Sortiermenü, lange drücken → „Genre ändern“
   - Einstellungen → „Über Mobilfunk kapitelweise laden“ einschalten, unterwegs mit VPN testen
   - Neues Design: Faden ums Cover, Hauptknopf als abgerundetes Quadrat, Knöpfe auf Kacheln, „Als Nächstes“ unten
   - Bibliothek: große „Weiterhören“-Karte, Bücher als Karten, Ansicht „Kacheln“ im Sortiermenü
   - Gefällt dir nicht? Notieren: schwebender Mini-Player, eigenes Mobilfunk-Fenster, Wischen auf dem Cover
   - Screenshot vom Player an Claude schicken (Symbole oben rechts / unten rechts sichtbar?)
   - Faden-Suche lernt mit: Einstellungen → Probenlänge (6 s), „Deine Einschlafzeiten“ nach der ersten Suche
   - Tagsüber AirPods herausnehmen nach über 3 Min ohne Tippen: „Faden aufnehmen“ erscheint (ein Tipp auf Probe 1 reicht)
   - Im Auto (CarPlay): Pause am Lenkrad → kein „Faden aufnehmen“; aussteigen, später Play → 30 s früher
   - Kopfhörer trennen, nach 10 s Play → 30 s früher, nichts startet beim Wiederverbinden von selbst
   - „Einschlafzeit in Health eintragen“ einschalten: Health fragt nach Erlaubnis; nach der nächsten Suche in Health → Schlaf → „Im Bett“ prüfen
4. **Genres prüfen** (ca. 2 Min., frühestens 5 Min. nach Schritt 1). Token steht in `/volume1/docker/faden/.env` (`FADEN_TOKEN`):
   ```
   curl -s -H "Authorization: Bearer DEIN_TOKEN" http://192.168.178.114:8787/api/v1/books
   ```
   Ausgabe an Claude schicken.
5. **Optional, Token tauschen** (ca. 3 Min.): `openssl rand -hex 32`, Wert in `.env` bei `FADEN_TOKEN` ersetzen, `sudo docker compose up -d`, neuen Token in der App eintragen.
6. **Optional:** In der Claude-Umgebung `services.dnb.de` und `openlibrary.org` freigeben (Titelleiste → Umgebungsmenü → Edit → Network access). Dann kann Claude die Genre-Treffer selbst prüfen.

## Offen bei Claude

- Genre-Zuordnung gegen echte Antworten der Nationalbibliothek prüfen (nach Schritt 4 oder 5).
- Sortierung „Neu hinzugefügt“: Server schickt `created_at` noch nicht mit.
- Rückmeldungen aus Schritt 3 umsetzen.
- Kachelansicht: zwei kurze Striche oben links unter der Leiste prüfen (Rest vom großen Titel?).

## Erledigt: Faden-Suche lernt mit

Besprochen am 25.09.2026, gebaut am 25.09.2026 (E77–E83 in `docs/ARCHITEKTUR.md`).

1. ~~**Einschlaf-Schätzer**~~ erledigt (E78): ab 5 Suchen liegt die zweite Probe beim Median; Probe 1 (Fehlalarm-Test) läuft weiter. Invariante 9 bleibt.
2. ~~**Einschlafzeit zurückrechnen**~~ erledigt (E79): Übersicht „Deine Einschlafzeiten“ in den Einstellungen.
3. ~~**Nachtfenster-Vorschlag**~~ erledigt (E81).
4. ~~**Verdacht auch tagsüber**~~ erledigt, anders als geplant (E80): jede unbewusste Pause (AirPods, Kopfhörertaste, Sperrbildschirm) zu jeder Tageszeit; Verbindungsabriss, Anruf und CarPlay nie, nach Verbindungsabriss 30 s zurück.
5. ~~**Probenlänge 4 / 6 / 8 s**~~ erledigt (E77), Standard 6 s.
6. ~~**Optional an Health schreiben**~~ erledigt (E82), nur iPhone, Standard aus.

Grenzen: Die letzte erkannte Stelle ist die letzte Erinnerung, nicht der messbare Einschlafmoment; die Aufwachzeit kennt Faden nicht (für Health gilt die erste Berührung danach als Ende).
