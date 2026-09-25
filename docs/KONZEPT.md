# Konzept: Faden

## Problem

Wer beim Hören einschläft, verliert den Punkt. Das Hörbuch läuft weiter, am Morgen folgt Scrubben und Raten. Dazu kommen Sync-Fehler, die Fortschritt zurücksetzen, und Kapitel-Dateien, die in falscher Reihenfolge landen.

## Versprechen

1. Die Position geht nie verloren: nicht bei Absturz, nicht offline, nicht mit mehreren Geräten.
2. Nach dem Einschlafen findest du deinen Punkt in höchstens 60 s, ohne aufs Display zu schauen.
3. Der Player zeigt nur, was du gerade brauchst.

## Situationen

- **Im Bett:** Sleep-Timer an, Licht aus, einschlafen. Am Morgen Kopfhörer rein, „Faden aufnehmen“.
- **Im Auto:** Beim Aussteigen reißt die Verbindung ab, die Wiedergabe hält an. Beim nächsten Play geht es 30 s früher weiter, damit du den Faden wieder hast; eine Suche gibt es dafür nie.
- **Unterwegs:** Das Buch ist geladen, das Handy offline. Die Position wird später synchronisiert.
- **Zwei Geräte:** Abends Tablet, morgens Handy. Es gilt die Stelle der letzten bewussten Aktion.

## Funktionen im MVP

1. Bibliothek aus dem Hörbuch-Ordner des Servers, ganze Bücher offline laden.
2. Player mit Faden für das ganze Buch und Scrubber für das aktuelle Kapitel, lückenlose Kapitelwechsel.
3. Nachtmodus bei gedimmtem Bildschirm, Sleep-Timer.
4. „Faden aufnehmen“ nach vermutetem Einschlafen.
5. Verlauf: jeder große Sprung mit einem Tipp rückgängig.

## Faden aufnehmen

Die App kennt zwei Punkte: den letzten sicheren Wach-Punkt (letzte bewusste Aktion) und den Stopp-Punkt. Liegen mehr als 3 Min dazwischen und lief die Sitzung im Nachtfenster (Standard 20 bis 6 Uhr), endete per Sleep-Timer oder hielten Kopfhörer, AirPods-Einschlaferkennung oder Sperrbildschirm sie an (auch tagsüber), gilt „Schlaf vermutet“. Nie, wenn die Verbindung abriss (Kopfhörer getrennt, Auto verlassen), ein Anruf kam oder CarPlay lief: Dann geht es einfach weiter, nach einem Verbindungsabriss 30 s früher.

Ablauf:
1. Der Hauptbutton heißt jetzt „Faden aufnehmen“, darunter klein „Ab Stopp weiterhören“.
2. Ein leiser Ton, dann eine 6 s lange Hörprobe ab einem Satzanfang (in den Einstellungen 4, 6 oder 8 s). Der Screen zeigt sie als Karte: „Probe 2 von höchstens 8“, wo sie liegt („Kapitel 5 · 23:14“, „4 Min. vor dem Stopp“) und als Balken, wie lange Probe und Antwortzeit noch laufen.
3. Du antwortest mit einer der zwei großen Tasten „Kenne ich“ oder „Kenne ich nicht“; eine Kopfhörertaste heißt „Kenne ich“. „Kenne ich nicht“ zählt sofort. Tust du bis 3 s nach Ende der Probe nichts, gilt „kenne ich nicht“. „Nochmal hören“ spielt die Probe noch einmal und startet die Antwortzeit neu; es bleibt eine Antwort. Ein Tipp neben die Tasten zählt nicht.
4. Das Suchfenster halbiert sich, die nächste Probe folgt. Höchstens 8 Proben. Unter der Karte stehen die schon gehörten Stellen mit „erkannt“ oder „nicht erkannt“.
5. „Gefunden. Weiter ab hier.“ mit der Stelle: Die Wiedergabe startet am letzten erkannten Satz. Darunter stehen die erkannten Stellen, nie eine spätere als das Ergebnis; ein Tipp startet dort. „Früher“ springt zur vorherigen erkannten Stelle. Jeder dieser Sprünge lässt sich rückgängig machen. „Fertig“ führt zurück zum Player.

Regeln:
- Die erste Probe liegt 25 s vor dem Stopp. Erkennst du sie, warst du wach und die Wiedergabe startet dort. Ein Fehlalarm kostet so nur einen Tipp, auch tagsüber, wenn du die AirPods nur herausgenommen hattest.
- Ab 5 Suchen weiß Faden, wie lange du nach der letzten Berührung meist noch zuhörst. Die zweite Probe liegt dann dort statt in der Mitte; das spart 2–3 Proben. Übersprungen wird dadurch nichts.
- Unsicher heißt: nichts tun oder „Kenne ich nicht“. Die Suche rutscht dann früher, nie später. Lieber 20 s doppelt hören als etwas verpassen.
- Langer Druck auf den Screen oder „Abbrechen“ bricht ab und startet am letzten sicheren Wach-Punkt. Langes Drücken auf „Kenne ich“ zählt als „Kenne ich“.
- Der Screen bleibt dunkel: echtes Schwarz, gedimmte Schrift, Tasten nur als Ring. Oben der Faden, der mit jeder Antwort kürzer wird.

## Faden-Suche lernt mit

- **Einschlafzeiten:** Nach jeder Suche rechnet Faden die zuletzt erkannte Stelle über die Herzschläge in eine Uhrzeit um (±1–2 Min.) und merkt sie sich auf dem Gerät, dazu wann du morgens zuerst getippt hast. In den Einstellungen unter „Deine Einschlafzeiten“ stehen die letzten 14.
- **Nachtfenster-Vorschlag:** Ab 5 Einschlafzeiten schlägt Faden ein persönliches Nachtfenster vor („Vorschlag: 22:30–01:00 übernehmen“); ein Tipp übernimmt es.
- **Health (nur iPhone, Standard aus):** „Einschlafzeit in Health eintragen“ schreibt nach der Suche „Im Bett“ von der Einschlafzeit bis zur ersten Berührung am Morgen in Health, nicht, wenn für die Nacht schon Schlafdaten da sind (z. B. von einer Watch).
- Nichts davon verlässt das Gerät oder wird ein Event. Grenze: Die letzte erkannte Stelle ist die letzte Erinnerung, nicht der messbare Einschlafmoment.

## Screens

Aufbau: Die Bibliothek ist die Basis der App, der Player liegt darüber. Schließt du den Player, bist du in der Bibliothek; der Mini-Player oder ein Buch aus der Liste schiebt ihn wieder hoch. Es gibt immer nur einen Player.

1. **Start ist der Player:** War ein Buch offen, startet die App im Player (über der Bibliothek), sonst in der Bibliothek. Das Cover, um das der Faden als Buchfortschritt läuft (nicht ziehbar), mit der Restzeit in Minuten direkt darunter („noch 3 Std. 45 Min.“), dann Titel (fett) und Autor, darunter der Kapitel-Scrubber, großer Button mit ±30 s links und rechts, unten „Als Nächstes: Kapitel 5 · Titel“ als Streifen, der die Details anklingen lässt (im letzten Kapitel nur ein Griff), und rechts daneben der Sleep-Timer (Mond mit „zzz“; läuft er, steht dort die Restzeit, „12 Min.“ oder „Kapitelende“). Oben rechts schaltet ein Knopf zwischen Hell und Dunkel (Mond, solange es hell ist, Sonne, solange es dunkel ist; in der Nachtansicht nicht). Oben links schließt ein Pfeil nach unten den Player, ebenso Ziehen nach unten: Der ganze Player folgt dem Finger, dahinter liegt die Bibliothek mit dem Mini-Player. Losgelassen nach mehr als einem Viertel der Höhe oder mit Schwung nach unten gleitet er weiter hinaus, sonst federt er zurück. Auf dem Kapitel-Scrubber (und dem geraden Faden, wenn kein Cover Platz hat) beginnt kein Ziehen. ±30 s und die Knöpfe der Leisten liegen auf dezenten abgerundeten Kacheln, damit man sieht, wo man tippt.
2. **Details (nach oben wischen oder Griff antippen):** Scrubber für das aktuelle Kapitel mit verstrichener und verbleibender Zeit, Tempo, Sleep-Timer (eine Zeile, die dieselbe Auswahl wie der Sleep-Timer-Knopf im Player öffnet), Verlauf, alle Kapitel mit Titel und Dauer, der Weg zurück zur Bibliothek.
3. **Faden-Modus:** Vollbild, dunkel, siehe oben.
4. **Bibliothek:** die Basis, ohne Zurück-Pfeil; oben Sortierung und Einstellungen, unten der Mini-Player, solange ein Buch offen ist. Großer Titel, der beim Scrollen in die Leiste wandert. Oben „Weiterhören“: das zuletzt gehörte Buch als große Karte (großes Cover, Titel fett, Autor, Faden und eine Kapsel „34 % · noch 8 Std.“), die übrigen als kleinere Karten; darunter „Alle Bücher“ mit Suche (sie findet alle, egal welcher Filter gilt). Direkt über „Alle Bücher“ eine Zeile kleiner Filter: „Alle · Läuft · Neu · Gehört“ und, sobald Bücher ein Genre haben, „Genre ▾“; sie gelten nur für „Alle Bücher“, nicht für „Weiterhören“, und das Gerät merkt sie sich. Bleibt nichts übrig: „Keine Bücher in diesem Filter.“ Sortierung (zuletzt gehört, Titel, Autor nach Nachname, Länge) und die Ansicht „Liste“, „Nach Autor“ (je Autor eine Kopfzeile, Bücher ohne Autor unter „Unbekannt“ am Ende) oder „Kacheln“ (zwei Spalten mit großen Covern, Titel und Autor darunter) im Menü oben; das Gerät merkt sich die Wahl. Jedes Buch ist eine eigene abgerundete Karte mit kleinem Abstand zur nächsten; das offene Buch ist hervorgehoben (leicht in `faden` gefüllt, in der Nachtansicht nur umrandet). Je Buch Cover, Autor, Fortschritt als dünner Faden und rechts eine kleine Kapsel mit Restzeit oder „neu“/„gehört“ (bei wenig Platz darunter), Download-Status (geladen, lädt mit der Restmenge „noch 240 MB“ und Abbrechen, Fehler mit „Erneut versuchen“), „Reihenfolge prüfen“. Langer Druck auf ein Buch: „Genre ändern“ (die Genres des Servers oder „Automatisch“; nur mit Verbindung zum Server) und, wenn etwas geladen ist, „Download löschen“. Download löschen auch per Wischen. Ohne Server zuerst „Server einrichten“. Offline sind nicht geladene Bücher gedimmt und als „nur online“ markiert.
5. **Einstellungen (aus der Bibliothek):** gruppiert wie auf dem iPhone, Erklärungen unter den Zeilen. Server mit „Verbindung prüfen“, Nachtfenster, Erscheinungsbild (Wie iPhone, Hell, Dunkel), Faden-Suche (Probenlänge 4, 6 oder 8 s, Standard 6 s), Deine Einschlafzeiten (mit Nachtfenster-Vorschlag), Speicher (geladene Bücher; zu Ende gehörte werden automatisch gelöscht), „Aktuelle Bücher automatisch laden“ (im WLAN das offene und das nächste Buch aus „Weiterhören“), „Über Mobilfunk kapitelweise laden“ (Standard aus; siehe unten) mit „Hinweis vor dem Laden über Mobilfunk“, Schlafdaten erlauben, Einschlafzeit in Health eintragen (nur iPhone, Standard aus), Belegung der Kopfhörertasten. Einen Sleep-Timer-Standard gibt es nicht: Der Timer startet nur über die Auswahl im Player.

## Unterwegs über Mobilfunk

Der Server ist unterwegs über ein VPN erreichbar. Ganze Bücher lädt Faden nur im WLAN. Ist „Über Mobilfunk kapitelweise laden“ an und läuft das offene Buch ohne WLAN, lädt Faden das aktuelle und das nächste Kapitel, wenn sie noch nicht auf dem Gerät sind, und dann mit der Wiedergabe immer eins weiter. Geladene Kapitel spielen ab da vom Gerät; gelöscht wird dabei nichts. In der Bibliothek zeigt die Buchzeile den Download wie jeden anderen („noch 24 MB“).

Vor dem ersten Laden über Mobilfunk seit dem App-Start fragt Faden einmal: „Über Mobilfunk laden?“ mit der Datenmenge des Buchs („1 Std. ≈ 58 MB · Kapitel 3 ≈ 24 MB“; kennt der Server keine Dateigrößen, geschätzt mit 64 kbit/s und „ca.“), dem Häkchen „Nicht wieder anzeigen“ und „Laden“ / „Nicht jetzt“. „Nicht jetzt“ gilt bis zum nächsten App-Start. Die Frage erscheint nur, wenn die App im Vordergrund ist; bis dahin wird nichts geladen.

## Nachtmodus

- Aktiv, solange die Bildschirmhelligkeit unter 30 % steht; aus erst wieder über 35 %, damit die Ansicht an der Schwelle nicht flackert. Nachtfenster und Sleep-Timer schalten die Ansicht nicht um; das Nachtfenster zählt nur für „Faden aufnehmen“.
- Echtes Schwarz, Cover stark abgedunkelt und klein, vom gedimmten Faden umrahmt (ohne Platz fürs Cover läuft der Faden gerade). Buchtitel klein und gedimmt in `tinte-leise`, darunter der Kapitel-Scrubber (das Kapitel steht nur dort, ebenso gedimmt), Hauptbutton als Squircle-Umriss und ±30 s auf fast schwarzen Kacheln. Keine leuchtenden Flächen: Auswahl und Knöpfe nur als Ring; das offene Buch in der Bibliothek nur umrandet. Details, Bibliothek und Einstellungen sind dann ebenfalls dunkel.
- Keine Tastensperre: Alle Bildschirmtasten und die Details bleiben bedienbar. Jede Berührung zählt als Wach-Beleg.
- Sleep-Timer: 15, 30, 45, 60 Min oder Kapitelende, direkt im Player über den Mond mit „zzz“ oder in den Details. Die letzten 30 s werden leiser. In der letzten Minute verlängert jede Kopfhörertaste den Timer um die gewählte Dauer, statt zu pausieren, und zählt als Wach-Beleg.

## Design

Leitbild ist ein einzelner Faden. Er zeigt den Fortschritt im ganzen Buch und ist das markanteste Element; darunter liegt ein ruhiger Scrubber für das aktuelle Kapitel.

| Token | Tag | Nacht | Rolle |
|---|---|---|---|
| `grund` | `#EEF0F3` | `#000000` | Hintergrund |
| `tinte` | `#1C2130` | `#9A8F80` | Text |
| `tinte-leise` | `#5E6577` | `#7D7366` | Nebentext |
| `faden` | `#3346A8` | `#E0A03A` | Faden, Hauptbutton |
| `knoten` | `#1C2130` | `#F2C879` | aktuelle Position |
| `fehler` | `#B3261E` | `#D9745A` | Fehler (Download, Wiedergabe) |
| `karte` | `#FFFFFF` | `#15120F` | Karten und Kacheln |

`grund` war tagsüber `#EEF0F3` (E75). Tagsüber indigo gefärbtes Garn auf warmem Off-White, weiße Karten mit weichen Schatten statt Haarlinien, große Radien (Karten 20–24 dp); Farbe vor allem für Hauptbutton, aktive Zustände und Fortschritt. Nachts warmes Bernstein ohne Blauanteil, gedimmte Schrift, echtes Schwarz für OLED. Alle Text-Kombinationen erreichen mindestens 4,5:1 Kontrast.

- **Faden:** 3 dp Linie, die im Player um das Cover läuft: oben in der Mitte beginnend im Uhrzeigersinn, mit einer kleinen Lücke oben, wo Anfang und Ende sich treffen. Gehörter Teil in `faden`, Rest in `tinte-leise` mit 40 % Deckkraft, Position als kleiner 8 dp Punkt in `faden`, kein Griff: ziehbar ist nur der Kapitel-Scrubber darunter. Kapitelgrenzen sind 3 dp Lücken im Faden (nur, wo beide Kapitel mindestens 12 dp Linie haben). Hat das Cover keinen Platz, läuft der Faden gerade über die volle Breite (2 dp Lücken). Nachts gedimmt wie das Cover.
- **Hauptbutton:** mindestens 88 dp, ein Quadrat mit fließend gerundeten Ecken wie das App-Symbol (Squircle). Tagsüber gefüllt in `faden` mit Symbol in `grund`; nachts nur der Umriss in `faden`, damit wenig Licht entsteht.
- **Kacheln:** ±30 s und die Knöpfe der Leisten auf abgerundeten Quadraten in `karte` (Radius 14–16 dp, sichtbar 44 oder 56 dp, Tippfläche immer 56 dp); tagsüber mit kleinem Schatten, nachts fast schwarz ohne Leuchten.
- **Hauptaktionen:** „Server einrichten“, „Laden“ im Mobilfunk-Dialog und „Fertig“ nach der Faden-Suche als Kapseln über die volle Breite. Erste Schritte und leere Zustände mit gemischter Schriftstärke („Willkommen bei **Faden**“).
- **Schrift:** eine Familie, Atkinson Hyperlegible Next (OFL, für Lesbarkeit entworfen; Fallback Atkinson Hyperlegible), im App-Bundle. Größen 28, 20, 17, 14 sp. Keine Großbuchstaben-Labels.
- **Layout:** eine Spalte. Im Player zentriert, Listen linksbündig. Alle Tippziele mindestens 56 dp.
- **Bewegung:** ein einziger bewusster Moment: Im Faden-Modus wird der Faden mit jeder Antwort kürzer (300 ms). Sonst keine Deko-Animationen; nur der Player gleitet beim Öffnen nach oben und beim Schließen (Pfeil, Ziehen nach unten) nach unten weg; beim Ziehen folgt er dem Finger. Die System-Einstellung „Bewegung reduzieren“ gilt für alles: Dann folgt der Player dem Finger nicht, sondern schließt beim Loslassen sofort.
- **Kein Cover vorhanden:** die Initialen des Titels in `faden` auf einer leisen Fläche, in der Hausschrift. Der Titel selbst steht direkt darunter.
- **Bedienung wie auf dem iPhone:** keine Tinten-Welle beim Tippen, Schalter und Auswahl im iOS-Stil, Uhrzeit per Drehrad. Nur Hochformat.

## Texte

| Stelle | Text |
|---|---|
| Hauptbutton | Weiterhören |
| Hauptbutton nach Schlafverdacht | Faden aufnehmen |
| darunter | Ab Stopp weiterhören |
| Faden-Modus | Kennst du diese Stelle? |
| Probenzähler | Probe 3 von höchstens 8 |
| Stelle einer Probe | Kapitel 5 · 23:14 / 4 Min. vor dem Stopp |
| Antworten | Kenne ich / Kenne ich nicht |
| Probe wiederholen | Nochmal hören |
| Faden-Suche abbrechen | Abbrechen |
| Bisherige Proben | Schon gehört: erkannt / nicht erkannt |
| Ergebnis | Gefunden. Weiter ab hier. |
| Ergebnis, Auswahl | Erkannte Stellen |
| Leiter | Früher |
| Ergebnis schließen | Fertig |
| Undo-Hinweis | Zurück zu Kapitel 7, 23:41 |
| Bibliothek | Ordner geändert: Reihenfolge prüfen |
| Offline | Keine Verbindung zum Server. Geladene Bücher spielen weiter. |
| Offline, Bücher bekannt | Offline – geladene Bücher spielen weiter |
| Restzeit | noch 3 Std. 45 Min. |
| Download läuft | noch 240 MB |
| Frage vor Mobilfunk | Über Mobilfunk laden? |
| Datenmenge | 1 Std. ≈ 58 MB · Kapitel 3 ≈ 24 MB |
| Server-Adresse, Beispiel | http://nas.local:8787 |
| Wiedergabefehler | Kann nicht abspielen |
| Nicht geladen, Server aus | Nicht geladen – der Server ist gerade nicht erreichbar. |
| Hell/Dunkel im Player | Dunkel einschalten / Hell einschalten |
| Filter der Bibliothek | Alle · Läuft · Neu · Gehört · Genre |
| Filter ohne Treffer | Keine Bücher in diesem Filter. |
| Ansicht der Bibliothek | Liste / Nach Autor / Kacheln; ohne Autor: Unbekannt |
| Player, unten | Als Nächstes: Kapitel 5 · Der Weg |
| Große „Weiterhören“-Karte | 34 % · noch 8 Std. |
| Genre eines Buchs | Genre ändern · Automatisch; offline: Nur mit Verbindung zum Server. |
| Einstellungen, Probenlänge | Faden-Suche: 4 Sekunden / 6 Sekunden / 8 Sekunden |
| Einstellungen, Einschlafzeiten | Deine Einschlafzeiten; leer: Noch keine. Nach jeder Faden-Suche steht hier, wann du ungefähr eingeschlafen bist. |
| Nachtfenster-Vorschlag | Vorschlag: 22:30–01:00 übernehmen |
| Health schreiben | Einschlafzeit in Health eintragen |

## Nicht im MVP

Transkripte, Audiobookshelf-Anbindung, mehrere Nutzer, M4B, Web-Client. Schlafdaten kommen in M6.

## Erfolgskriterien

1. **Kill-Test:** App während der Wiedergabe beenden und neu starten → Position höchstens 5 s zurück.
2. **Zwei-Geräte-Test:** Gerät A offline mit alten Herzschlägen, B hört weiter → nach dem Sync gilt B.
3. **Faden-Selbsttest:** 10 Min eines unbekannten Kapitels hören, dann Faden über das Fenster 0 bis 30 Min → Start höchstens 30 s vor der echten Stelle, nie danach, Dauer höchstens 60 s.
4. **Umbenennen:** alle MP3s umbenennen und neu taggen → keine Position ändert sich.
5. **Anhängen:** neue Kapitel-Datei am Ende → automatisch übernommen, Position unverändert.
