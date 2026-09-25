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

Die App kennt zwei Punkte: deine letzte Berührung (letzte bewusste Aktion, der letzte sichere Wach-Punkt) und die Stelle, an der es anhielt. Liegen mehr als 3 Min dazwischen und lief die Sitzung im Nachtfenster (Standard 20 bis 6 Uhr), endete per Sleep-Timer oder hielten Kopfhörer, AirPods-Einschlaferkennung oder Sperrbildschirm sie an (auch tagsüber), gilt „Schlaf vermutet“. Nie, wenn ein Anruf kam oder CarPlay lief, und nicht, wenn die Verbindung abriss (Kopfhörer getrennt, Auto verlassen): Dann geht es einfach weiter, nach einem Verbindungsabriss 30 s früher. Ausnahme: Reißt nachts nach mindestens 20 Min ohne Berührung die Kopfhörer-Verbindung ab (Akku leer), gilt doch „Schlaf vermutet“.

Ablauf:
1. Nachts oder nach dem Sleep-Timer heißt der Hauptbutton „Faden aufnehmen“, darunter klein „Weiter, wo es anhielt“. Tagsüber ohne Sleep-Timer bleibt „Weiterhören“ der Hauptbutton, darunter „Eingeschlafen? Stelle suchen“. Nachts startet auch Play auf dem Sperrbildschirm oder an den Kopfhörern die Suche (nie mit CarPlay); ein zweiter Druck während der ersten Probe heißt „Kenne ich“ und es geht kurz vor dem Stopp weiter.
2. Ein leiser Ton, dann eine 6 s lange Hörprobe ab einem Satzanfang (in den Einstellungen 4, 6 oder 8 s). Der Screen zeigt sie als Karte: „Noch höchstens 6 Fragen“, wann du sie gehört hast („gehört gegen 23:12 Uhr“, ohne Uhrzeit „Kapitel 5 · 23:14“), „4 Min. bevor es anhielt“ und als Balken, wie lange Probe und Antwortzeit noch laufen. Die Zeit läuft erst, wenn die Probe wirklich spielt.
3. Du antwortest mit einer der zwei großen Tasten „Kenne ich“ oder „Kenne ich nicht“ oder mit den Kopfhörern: 1× drücken „Kenne ich“, 2× „Kenne ich nicht“, 3× „Nochmal hören“. Ein Klick bestätigt „Kenne ich“, ein leiser tiefer Ton „Kenne ich nicht“. „Kenne ich nicht“ zählt sofort. Tust du bis 3 s nach Ende der Probe nichts, gilt „kenne ich nicht“. „Nochmal hören“ spielt die Probe noch einmal und startet die Antwortzeit neu; es bleibt eine Antwort. Ein Tipp neben die Tasten zählt nicht.
4. Das Suchfenster halbiert sich, die nächste Probe folgt. Höchstens 8 Proben. Unter der Karte steht „Bisher gefragt“ mit „kannte ich“ oder „kannte ich nicht“.
5. Ein Doppelton, dann das Ergebnis: „Gefunden. Weiter ab hier.“ mit der Stelle (bei erkannter erster Probe „Du warst noch wach. Weiter kurz bevor es anhielt.“, ohne erkannte Stelle „Nichts wiedererkannt. Weiter ab deiner letzten Berührung.“). Die Wiedergabe startet am letzten erkannten Satz. In langen Nächten, wenn die Proben nicht bis auf 30 s herankommen, fragt „Nochmal prüfen“ die früheste Stelle, die du nicht kanntest, noch einmal; kennst du sie jetzt, geht es dort weiter. Unter „Oder hier weiterhören“ stehen die erkannten Stellen, nie eine spätere als das Ergebnis; ein Tipp startet dort. „Etwas früher anfangen“ (auch 3× an den Kopfhörern) springt zur vorherigen erkannten Stelle. Jeder dieser Sprünge lässt sich rückgängig machen. „Fertig“ führt zurück zum Player.

Regeln:
- Die erste Probe liegt 25 s vor dem Stopp. Erkennst du sie, warst du wach und die Wiedergabe startet dort. Ein Fehlalarm kostet so nur einen Tipp.
- Liegen höchstens 6 Min zwischen deiner letzten Berührung und dem Stopp, kommt nur diese erste Probe; kennst du sie nicht, geht es ab deiner letzten Berührung weiter.
- Ab 5 Nächten weiß Faden, wie lange du nach der letzten Berührung meist noch zuhörst. Die zweite Probe liegt dann dort statt in der Mitte; das spart 2–3 Proben. Übersprungen wird dadurch nichts.
- Unsicher heißt: nichts tun oder „Kenne ich nicht“. Die Suche rutscht dann früher, nie später. Lieber 20 s doppelt hören als etwas verpassen.
- „Abbrechen“ führt zurück zum Player; Stelle und Wiedergabe bleiben, wie sie waren. Langes Drücken auf „Kenne ich“ zählt als „Kenne ich“.
- Der Screen bleibt dunkel: echtes Schwarz, gedimmte Schrift, Tasten nur als Ring. Oben der Faden, der mit jeder Antwort kürzer wird. Solange er offen ist, sperrt sich das Display nicht; bei gesperrtem Handy läuft die Suche über die Kopfhörer weiter.

## Eingeschlafen?

Läuft das Buch weiter (oder hielt es von selbst an: Kapitel- oder Buchende, Sleep-Timer, Kopfhörer, System) und hast du über eine Stunde nichts angetippt, im Nachtfenster schon nach 20 Minuten, fragt Faden, sobald du zurückkommst (App wieder vorn oder erste Berührung): „Eingeschlafen?“ mit „Du hörst seit über einer Stunde, ohne etwas anzutippen.“ Die Berührung selbst tut sonst nichts, sie zählt noch nicht als Wach-Beleg.
- „Ja, Stelle suchen“ hält an und startet die Faden-Suche von deiner letzten Berührung bis zur aktuellen Stelle.
- „Nein, weiterhören“ zählt als Wach-Beleg; es läuft weiter oder startet dort, wo es anhielt.
- Wegtippen heißt „Nein“, solange es noch läuft; sonst bleibt alles, wie es ist. Nie im Auto (CarPlay), einmal je Strecke, nachts im dunklen Look. Die Hörzeit übersteht auch einen Neustart der App.
- Buchende im Schlaf: Endet das Buch nach so langer Strecke ohne Berührung, gilt es nicht als „gehört“ und seine Dateien bleiben auf dem Gerät, bis du das Ende bestätigst („Nein, weiterhören“ oder das Ende noch einmal abspielen).

## Faden-Suche lernt mit

- **Einschlafzeiten:** Nach jeder Suche in der Nacht (im Nachtfenster oder nach dem Sleep-Timer) rechnet Faden die zuletzt erkannte Stelle über die Herzschläge in eine Uhrzeit um (±1–2 Min.) und merkt sie sich auf dem Gerät, dazu wann du morgens zuerst getippt hast. Tagsüber lernt Faden nichts. In den Einstellungen unter „Deine Einschlafzeiten“ stehen die letzten 14; eine falsche wischst du nach links weg.
- **Nachtfenster-Vorschlag:** Ab 5 Einschlafzeiten schlägt Faden ein persönliches Nachtfenster vor („Vorschlag: 22:30–01:00 übernehmen“); ein Tipp übernimmt es. Der Vorschlag macht das Fenster nur breiter, nie schmaler.
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
- Keine Tastensperre: Alle Bildschirmtasten und die Details bleiben bedienbar. Jede Berührung zählt als Wach-Beleg, außer nach langer Strecke ohne Berührung: Dann fragt Faden zuerst „Eingeschlafen?“.
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
| darunter | Weiter, wo es anhielt |
| Tagsüber unter „Weiterhören“ | Eingeschlafen? Stelle suchen |
| Faden-Modus | Kennst du diese Stelle? |
| Probenzähler | Noch höchstens 6 Fragen / Noch höchstens 1 Frage / Letzte Frage |
| Stelle einer Probe | gehört gegen 23:12 Uhr (ohne Uhrzeit: Kapitel 5 · 23:14) / 4 Min. bevor es anhielt |
| Antworten | Kenne ich / Kenne ich nicht |
| Probe wiederholen | Nochmal hören |
| Faden-Suche abbrechen | Abbrechen |
| Bisherige Proben | Bisher gefragt: kannte ich / kannte ich nicht |
| Ergebnis | Gefunden. Weiter ab hier. |
| Ergebnis, erste Probe erkannt | Du warst noch wach. Weiter kurz bevor es anhielt. |
| Ergebnis, nichts erkannt | Nichts wiedererkannt. Weiter ab deiner letzten Berührung. |
| Ergebnis, zurück bis zur Berührung | Weiter ab deiner letzten Berührung. |
| Ergebnis, Auswahl | Oder hier weiterhören |
| Ergebnis, nicht erkannte Stelle | Nochmal prüfen |
| Leiter | Etwas früher anfangen |
| Ergebnis schließen | Fertig |
| Undo-Hinweis | Zurück zu Kapitel 7, 23:41 |
| Undo-Hinweis nach der Faden-Suche | Rückgängig: wieder, wo es anhielt · Zurück |
| Frage nach langer Strecke | Eingeschlafen? |
| Text der Frage | Du hörst seit über einer Stunde, ohne etwas anzutippen. / Es lief über eine Stunde, ohne dass du etwas angetippt hast. / nachts: Du hörst seit 25 Min., ohne etwas anzutippen. |
| Antworten der Frage | Ja, Stelle suchen / Nein, weiterhören |
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
| Einstellungen, Einschlafzeiten | Deine Einschlafzeiten; leer: Noch keine. Nach jeder Faden-Suche in der Nacht steht hier, wann du ungefähr eingeschlafen bist. Erklärung: Ab 5 Nächten fragt Faden zuerst dort, wo du nach dem letzten Tippen meist eingeschlafen bist. |
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
