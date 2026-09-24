# Konzept: Faden

## Problem

Wer beim Hören einschläft, verliert den Punkt. Das Hörbuch läuft weiter, am Morgen folgt Scrubben und Raten. Dazu kommen Sync-Fehler, die Fortschritt zurücksetzen, und Kapitel-Dateien, die in falscher Reihenfolge landen.

## Versprechen

1. Die Position geht nie verloren: nicht bei Absturz, nicht offline, nicht mit mehreren Geräten.
2. Nach dem Einschlafen findest du deinen Punkt in höchstens 60 s, ohne aufs Display zu schauen.
3. Der Player zeigt nur, was du gerade brauchst.

## Situationen

- **Im Bett:** Sleep-Timer an, Licht aus, einschlafen. Am Morgen Kopfhörer rein, „Faden aufnehmen“.
- **Unterwegs:** Das Buch ist geladen, das Handy offline. Die Position wird später synchronisiert.
- **Zwei Geräte:** Abends Tablet, morgens Handy. Es gilt die Stelle der letzten bewussten Aktion.

## Funktionen im MVP

1. Bibliothek aus dem Hörbuch-Ordner des Servers, ganze Bücher offline laden.
2. Player ohne Scrubber im Hauptscreen, lückenlose Kapitelwechsel.
3. Nachtmodus mit Sleep-Timer und Tastensperre.
4. „Faden aufnehmen“ nach vermutetem Einschlafen.
5. Verlauf: jeder große Sprung mit einem Tipp rückgängig.

## Faden aufnehmen

Die App kennt zwei Punkte: den letzten sicheren Wach-Punkt (letzte bewusste Aktion) und den Stopp-Punkt. Liegen mehr als 3 Min dazwischen und lief die Sitzung im Nachtfenster (Standard 20 bis 6 Uhr) oder endete per Sleep-Timer, gilt „Schlaf vermutet“.

Ablauf:
1. Der Hauptbutton heißt jetzt „Faden aufnehmen“, darunter klein „Ab Stopp weiterhören“.
2. Ein leiser Ton, dann eine 4 s lange Hörprobe ab einem Satzanfang.
3. Kennst du die Stelle, tippst du einmal: Kopfhörertaste oder irgendwo auf den Screen. Tust du bis 3 s nach Ende der Probe nichts, gilt „kenne ich nicht“.
4. Das Suchfenster halbiert sich, die nächste Probe folgt. Höchstens 8 Proben.
5. Die Wiedergabe startet am letzten erkannten Satz. „Früher“ springt zur vorherigen erkannten Stelle.

Regeln:
- Die erste Probe liegt 25 s vor dem Stopp. Erkennst du sie, warst du wach und die Wiedergabe startet dort. Ein Fehlalarm kostet so nur einen Tipp.
- Unsicher heißt: nichts tun. Die Suche rutscht dann früher, nie später. Lieber 20 s doppelt hören als etwas verpassen.
- Langer Druck auf den Screen bricht ab und startet am letzten sicheren Wach-Punkt.
- Der Screen bleibt dunkel. Zu sehen sind nur der Faden, der mit jeder Antwort kürzer wird, und „Probe 3 von höchstens 8“.

## Screens

1. **Start ist der Player:** Cover, Titel, Kapitel, Restzeit, der Faden als Buchfortschritt (nicht ziehbar), großer Button. Die Bibliothek erreichst du über ein kleines Symbol.
2. **Details (nach oben wischen):** Kapitel, Zeitleiste mit Scrubber, Tempo, Sleep-Timer, Verlauf.
3. **Faden-Modus:** Vollbild, dunkel, siehe oben.
4. **Bibliothek:** Liste der Bücher mit Status: geladen, neu, Reihenfolge prüfen.
5. **Einstellungen:** Server, Nachtfenster, Schlafdaten erlauben, Belegung der Kopfhörertasten.

## Nachtmodus

- Aktiv im Nachtfenster oder bei laufendem Sleep-Timer.
- Echtes Schwarz, Cover ausgeblendet, nur Faden und Button.
- Nach 10 s ohne Berührung sind die Bildschirmtasten gesperrt; entsperren durch 1 s Halten. Kopfhörertasten funktionieren immer.
- Sleep-Timer: 15, 30, 45, 60 Min oder Kapitelende. Die letzten 30 s werden leiser. In der letzten Minute verlängert jede Kopfhörertaste den Timer um die gewählte Dauer, statt zu pausieren, und zählt als Wach-Beleg.

## Design

Leitbild ist ein einzelner Faden. Er ersetzt den Scrubber als Fortschrittsanzeige und ist das einzige markante Element; alles andere bleibt ruhig.

| Token | Tag | Nacht | Rolle |
|---|---|---|---|
| `grund` | `#EEF0F3` | `#000000` | Hintergrund |
| `tinte` | `#1C2130` | `#9A8F80` | Text |
| `tinte-leise` | `#5E6577` | `#7D7366` | Nebentext |
| `faden` | `#3346A8` | `#E0A03A` | Faden, Hauptbutton |
| `knoten` | `#1C2130` | `#F2C879` | aktuelle Position |

Tagsüber indigo gefärbtes Garn auf kühlem Weiß. Nachts warmes Bernstein ohne Blauanteil, gedimmte Schrift, echtes Schwarz für OLED. Alle Text-Kombinationen erreichen mindestens 4,5:1 Kontrast.

- **Faden:** 3 dp Linie über die volle Breite. Gehörter Teil in `faden`, Rest in `tinte-leise` mit 40 % Deckkraft, Position als 10 dp Knoten. Kapitelgrenzen sind 2 dp Lücken im Faden.
- **Hauptbutton:** mindestens 88 dp. Tagsüber gefüllt in `faden` mit Symbol in `grund`; nachts nur ein Ring in `faden`, damit wenig Licht entsteht.
- **Schrift:** eine Familie, Atkinson Hyperlegible Next (OFL, für Lesbarkeit entworfen; Fallback Atkinson Hyperlegible), im App-Bundle. Größen 28, 20, 17, 14 sp. Keine Großbuchstaben-Labels.
- **Layout:** eine Spalte. Im Player zentriert, Listen linksbündig. Alle Tippziele mindestens 56 dp.
- **Bewegung:** ein einziger bewusster Moment: Im Faden-Modus wird der Faden mit jeder Antwort kürzer (300 ms). Sonst keine Deko-Animationen; die System-Einstellung „Bewegung reduzieren“ gilt.
- **Kein Cover vorhanden:** Titel in `tinte` auf `grund`, gesetzt in der Hausschrift.

## Texte

| Stelle | Text |
|---|---|
| Hauptbutton | Weiterhören |
| Hauptbutton nach Schlafverdacht | Faden aufnehmen |
| darunter | Ab Stopp weiterhören |
| Faden-Modus | Kennst du das? Dann tippen. |
| Ergebnis | Gefunden. Weiter ab hier. |
| Leiter | Früher |
| Undo-Hinweis | Zurück zu Kapitel 7, 23:41 |
| Bibliothek | Ordner geändert: Reihenfolge prüfen |
| Offline | Keine Verbindung zum Server. Geladene Bücher spielen weiter. |

## Nicht im MVP

Transkripte, Audiobookshelf-Anbindung, mehrere Nutzer, M4B, Web-Client. Schlafdaten kommen in M6.

## Erfolgskriterien

1. **Kill-Test:** App während der Wiedergabe beenden und neu starten → Position höchstens 5 s zurück.
2. **Zwei-Geräte-Test:** Gerät A offline mit alten Herzschlägen, B hört weiter → nach dem Sync gilt B.
3. **Faden-Selbsttest:** 10 Min eines unbekannten Kapitels hören, dann Faden über das Fenster 0 bis 30 Min → Start höchstens 30 s vor der echten Stelle, nie danach, Dauer höchstens 60 s.
4. **Umbenennen:** alle MP3s umbenennen und neu taggen → keine Position ändert sich.
5. **Anhängen:** neue Kapitel-Datei am Ende → automatisch übernommen, Position unverändert.
