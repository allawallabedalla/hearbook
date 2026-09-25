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
   - **Faden aufnehmen, Audit (E84–E91)** (ca. 15 Min.):
     - Sleep-Timer 15 Min, einschlafen lassen (oder warten), Handy gesperrt lassen, Play an den Kopfhörern: Ton, dann Probe 1; nochmal drücken = „Kenne ich“ → es geht kurz vor dem Stopp weiter, Doppelton
     - Mit gesperrtem Handy die ganze Suche über die Kopfhörer: 1× kenne ich (Klick), 2× kenne ich nicht (tiefer Ton), 3× nochmal hören; läuft sie ohne Hänger durch (App bleibt wach)? Kommt 2×/3× bei deinen Kopfhörern an?
     - Auf dem Ergebnis 3× drücken: „Etwas früher anfangen“; Play/Pause wirkt normal
     - Faden-Screen offen lassen: sperrt sich das Display nicht mehr von selbst?
     - Gestreamtes Kapitel (nicht geladen): beginnt der Balken erst, wenn die Probe hörbar ist?
     - Nachts ohne Timer über 20 Min (tagsüber über 60 Min) nichts antippen, dann aufs Display tippen: „Eingeschlafen?“ erscheint, der Tipp löst nichts anderes aus; „Ja, Stelle suchen“ hält an und sucht; „Nein, weiterhören“ läuft weiter
     - App im Hintergrund lassen und nach über einer Stunde öffnen: die Frage kommt sofort, nachts im dunklen Look
     - Mit CarPlay: keine Frage, Play spielt einfach
     - Tagsüber ohne Timer nach Sperrbildschirm-Pause: Hauptbutton „Weiterhören“, darunter „Eingeschlafen? Stelle suchen“
     - Ergebnis-Texte: „Du warst noch wach …“, „Nichts wiedererkannt …“, „gehört gegen 23:12 Uhr“ stimmt ungefähr mit der Uhr?
     - „Nochmal prüfen“ auf dem Ergebnis; „Abbrechen“ ändert nichts und spielt nicht los
     - Einstellungen → „Deine Einschlafzeiten“: eine Zeile nach links wischen löscht sie
     - Buchende im Schlaf (E92): ein kurzes Buch über eine Stunde ohne Tippen bis zum Ende laufen lassen → nicht „gehört“, Dateien bleiben; „Nein, weiterhören“ → „gehört“
     - App nachts von iOS beenden lassen (oder wegwischen), morgens öffnen: kommt „Eingeschlafen?“ trotzdem (E93)?
     - Bibliothek in „Kacheln“ ganz nach unten scrollen: keine Striche mehr unter der Leiste (E94)
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

## Erledigt: UX-Audit „Faden aufnehmen“ und „Eingeschlafen?“

Gebaut am 25.09.2026 (E84–E91 in `docs/ARCHITEKTUR.md`), iPhone-Checks oben in Schritt 3.

1. ~~Play vom Sperrbildschirm/Kopfhörer startet die Suche statt einfach zu spielen~~ (E86; nachts und nach dem Timer, nie mit CarPlay; zweiter Druck in Probe 1 = „Kenne ich“)
2. ~~Kopfhörer-Gesten 1×/2×/3×, auf dem Ergebnis 3× = etwas früher~~ (E85; in audio_service 0.18.19 geprüft)
3. ~~Tipp nach langem Hören löscht den Verdacht nicht mehr~~ (E84: „Eingeschlafen?“ ab 60 Min, nachts ab 20 Min)
4. ~~Kopfhörer-Akku leer nachts nach 20 Min: Verdacht bleibt~~ (E84, Vektoren 09, 14, 15)
5. ~~Töne: Klick, tiefer Ton, Doppelton~~ (E85)
6. ~~Gesperrtes Handy: Display bleibt an, Stille zwischen Proben, Antwortzeit ab Probenstart~~ (E85)
7. ~~Ehrliche Ergebnis-Texte~~ (E88)
8. ~~Einfache Sprache~~ (E89)
9. ~~Langer Druck bricht nicht mehr ab; „Abbrechen“ ändert nichts~~ (E89)
10. ~~Tagsüber „Weiterhören“ mit „Eingeschlafen? Stelle suchen“ darunter~~ (E86)
11. ~~Lernen nur nachts, Einschlafzeiten wegwischen, Vorschlag nur breiter~~ (E90)
12. ~~„Nochmal prüfen“~~ (E91)
13. ~~Fenster bis 6 Min: nur Probe 1~~ (E87)

Nachträge: ~~Buchende im Schlaf gilt nicht als fertig, Dateien bleiben bis zur Bestätigung~~ (E92); ~~Hörzeit übersteht einen Neustart~~ (E93); ~~Striche unter der Leiste in „Kacheln“~~ (E94); „Nochmal prüfen“ nur, wo es etwas bringt (E95).

## Erledigt: Faden-Suche lernt mit

Besprochen am 25.09.2026, gebaut am 25.09.2026 (E77–E83 in `docs/ARCHITEKTUR.md`).

1. ~~**Einschlaf-Schätzer**~~ erledigt (E78): ab 5 Suchen liegt die zweite Probe beim Median; Probe 1 (Fehlalarm-Test) läuft weiter. Invariante 9 bleibt.
2. ~~**Einschlafzeit zurückrechnen**~~ erledigt (E79): Übersicht „Deine Einschlafzeiten“ in den Einstellungen.
3. ~~**Nachtfenster-Vorschlag**~~ erledigt (E81).
4. ~~**Verdacht auch tagsüber**~~ erledigt, anders als geplant (E80): jede unbewusste Pause (AirPods, Kopfhörertaste, Sperrbildschirm) zu jeder Tageszeit; Verbindungsabriss, Anruf und CarPlay nie, nach Verbindungsabriss 30 s zurück.
5. ~~**Probenlänge 4 / 6 / 8 s**~~ erledigt (E77), Standard 6 s.
6. ~~**Optional an Health schreiben**~~ erledigt (E82), nur iPhone, Standard aus.

Grenzen: Die letzte erkannte Stelle ist die letzte Erinnerung, nicht der messbare Einschlafmoment; die Aufwachzeit kennt Faden nicht (für Health gilt die erste Berührung danach als Ende).
