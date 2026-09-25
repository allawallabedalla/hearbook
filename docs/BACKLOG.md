# Backlog

Stand: 25.09.2026. Erledigtes durchstreichen oder löschen.

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
4. **Genres prüfen** (ca. 2 Min., frühestens 5 Min. nach Schritt 1). Token steht in `/volume1/docker/faden/.env` (`FADEN_TOKEN`):
   ```
   curl -s -H "Authorization: Bearer DEIN_TOKEN" http://192.168.178.114:8787/api/v1/books
   ```
   Ausgabe an Claude schicken.
5. **Optional:** In der Claude-Umgebung `services.dnb.de` und `openlibrary.org` freigeben (Titelleiste → Umgebungsmenü → Edit → Network access). Dann kann Claude die Genre-Treffer selbst prüfen.

## Offen bei Claude

- Genre-Zuordnung gegen echte Antworten der Nationalbibliothek prüfen (nach Schritt 4 oder 5).
- Sortierung „Neu hinzugefügt“: Server schickt `created_at` noch nicht mit.
- Rückmeldungen aus Schritt 3 umsetzen.
