# Directory-Drag-and-Drop und „Zuletzt verwendet“ (30.10.2026)

## Directory

Der Verzeichnisbaum und die Suchtreffer verwenden jetzt eine native
`NSOutlineView` statt SwiftUI-Button-Zeilen. Damit übernimmt AppKit die
Unterscheidung zwischen Klick und Drag sowie die Verhandlung der Move-Operation.
Der bisherige Datenprovider allein ließ sich korrekt lesen; dieser Test hatte
die tatsächliche Maus-/Drop-Verarbeitung der Button-Zeilen nicht abgedeckt.

- Dateien und Ordner an Name oder Symbol ziehen; auf einen Zielordner ablegen.
- Zwischen Zeilen wird in den jeweiligen übergeordneten Ordner verschoben,
  nicht die alphabetische Reihenfolge geändert.
- Freie Fläche im Baum und der Workspace-Kopf sind Ziele für die Workspace-Wurzel.
- Pfeil oder Doppelklick klappt einen Ordner auf/zu.
- Ein Maus-Down öffnet noch keinen Editor: Sonst könnte beim beginnenden Drag
  ein neuer Editor-Pane angelegt und die Quellansicht neu aufgebaut werden.
- Drag-Daten sind ein eigener exportierter Data-Typ mit Prozess-Token und
  Workspace-Prüfung. Fremd-App-/Finder-Importe sind weiterhin nicht aktiviert.
- Vorhandene Ziele, `.git`, Pfade außerhalb des Workspace, eigene Unterordner
  und ungespeicherte Dokumente bleiben geschützt. Die akzeptierende AppKit-
  Callback meldet einen abgelehnten Dateivorgang nicht als erfolgreichen Move.
- Kontextmenüs, Suchtreffer, Git-Marker, Schriftzoom und „aktive Datei zeigen“
  bleiben verfügbar. Während eines Quell-Drags wird der Baum nicht neu geladen.

## Letzte Sandboxes

Die bisherige Liste verlor die Zeitstempel von Web-Sandboxes, bevorzugte bei
Duplikaten einen gegebenenfalls älteren Terminal-Eintrag, blendete bestimmte
laufende Einträge aus und schnitt anschließend nach sieben Ergebnissen ab.

Jetzt werden beide Registries **vor** der Sortierung pro Repo/Projekt vereinigt.
Der neuere Start-Zeitstempel liefert Datum und Profil; individuelle Namen bleiben
erhalten. Zusätzlich merkt sich die App Öffnen/Auswählen und Chat-Eingaben als
lokales Nutzungsdatum über Neustarts. Diese Daten ändern die CLI-Registries nicht.

Die Welcome-Liste zeigt den gesamten Verlauf in einer ScrollView. Laufende
Sandboxes werden nicht ausgeblendet und beim Öffnen wiederverwendet, ohne erneut
`devkcode web` und damit eine zusätzliche leere Session anzustoßen.

## Prüfung

`bash scripts/test-security.sh` führt zusätzlich `DirectoryAndHistoryTests` aus:

- Echte native View anlegen, AppKit-Callback-Registrierung prüfen.
- Native Pasteboard-Writer → Drop-Callback → Dateisystem-Move für Datei und
  Ordner mit Inhalt; Move zurück zur Wurzel; falschen Prozess-Token abweisen.
- Elternordner aufklappen und die aktive Datei programmatisch markieren, ohne
  dadurch einen anderen Editor zu öffnen; Data-Provider-Roundtrip prüfen.
- Web-/Terminal-Duplikate mit unterschiedlichen Daten, aktuelle Web-Sandboxes,
  lokale Nutzungsdaten und mehr als sieben Einträge prüfen.

Diese Tests ersetzen nicht das manuelle Ziehen mit Maus/Trackpad im laufenden
Fenster. Manuelle Abnahme: Datei und Ordner in einen anderen Ordner und zurück zur
Wurzel ziehen; bei ungespeicherter Datei muss die App den Move ablehnen. Danach
„aktive Datei zeigen“ und nach Neustart die Reihenfolge im Welcome prüfen.
