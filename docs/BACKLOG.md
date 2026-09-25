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

## Geplant: Faden-Suche lernt mit

Besprochen am 25.09.2026, noch nicht gebaut (ca. 50 Min., Health-Schreiben +20 Min.).

1. **Einschlaf-Schätzer:** Aus früheren Suchen lernt die App, wie viele Minuten nach der letzten Aktion du typischerweise einschläfst. Ab ca. 5 Suchen liegt die erste Probe dort. Spart 2–3 Proben, ändert nichts an der Sicherheit (Invariante 9).
2. **Einschlafzeit zurückrechnen:** Gefundene Stelle → Uhrzeit über die Herzschlag-Events (±1–2 Min.). Übersicht „Deine Einschlafzeiten“ in den Einstellungen.
3. **Nachtfenster-Vorschlag:** Aus den Einschlafzeiten ein persönliches Fenster vorschlagen (z. B. 22:30–01:00) statt fest 20–06 Uhr.
4. **Verdacht auch tagsüber:** Pausieren die AirPods zu einer Uhrzeit, zu der du laut Daten oft einschläfst, bietet die App die Suche auch am Tag an.
5. **Probenlänge 4 / 6 / 8 s** in den Einstellungen; ob 4 s zum Wiedererkennen reichen, ist ungetestet.
6. **Optional an Health schreiben:** „Im Bett“ von der errechneten Einschlafzeit bis zum ersten Tippen am Morgen. Nicht, wenn für die Nacht schon Watch-Daten da sind. Daten bleiben auf dem iPhone (Invariante 7); Schreiben mit dem Paket `health` vor dem Bau in dessen Doku prüfen.

Grenzen: Die letzte erkannte Stelle ist die letzte Erinnerung, nicht der messbare Einschlafmoment; die Aufwachzeit kennt Faden nicht.
