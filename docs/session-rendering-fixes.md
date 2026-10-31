# Rendering bei Session-, Agenten- und Dateiwechseln

## Gefundene Fehlerpfade

1. Jeder Verlaufs-Reload löschte den globalen `streamingText`, auch wenn während
   der HTTP-Anfrage bereits neue Deltas eingetroffen waren. OpenCode V2 schreibt
   vollständigen Text mit `session.text.ended` in den dauerhaften Verlauf; eine
   vorherige Momentaufnahme konnte die laufende Antwort daher verschwinden lassen.
2. Der Chat verwendete Scroll-/native View-Zustände beim Sessionwechsel weiter.
   Wiederholtes Auswählen derselben Session leerte zudem unnötig die Ansicht.
3. Diff-/Hunk-Abfragen über detached Git-Prozesse konnten nach Datei-/Workspace-
   Wechseln noch in den falschen View-Zustand schreiben. Eine SwiftUI-Task-
   Cancellation allein beendete diese Prozesse nicht.
4. Der native Editor wurde bei Dateien mit gleichem Inhalt und gleicher Sprache
   wiederverwendet; Auswahl, Scrollposition, Undo und verzögerte Sprungaktionen
   hatten keine zuverlässige Dokumentgrenze.
5. Read-only-Markdown meldete neue Text-/Breitenmaße nicht ausdrücklich an SwiftUI.
   Dadurch konnten zwischengespeicherte Höhen und TextKit-Containerbreiten veralten.
6. Editor-Fokus hing an einer äußeren SwiftUI-Tap-Geste statt am nativen Textfeld.
   Zusätzlich wurde ein ausgelagerter Editor bei der Ermittlung des aktiven
   Editors nicht berücksichtigt.
7. Dateiveränderungen durch nicht ausgewählte Sessions/Unteragenten derselben
   Arbeitskopie wurden für die sichtbaren Inspector-/Editor-Ansichten ignoriert.

## Abgrenzung der Zustände

- Chat-Kontext: `(serverID, sessionID)`, dazu eine View-Generation bei einem
  tatsächlichen Auswahl-/Verbindungswechsel. Ein Agentenwechsel innerhalb
  derselben Session ist kein neuer Chat und verwirft dessen Verlauf nicht.
- Asynchrone Leser: `LatestRequest` vergibt Tickets pro Generation. Nur der
  neueste Request der weiterhin aktuellen Auswahl darf Daten/Fehler veröffentlichen.
  Das gilt auch bei A → B → A. Antworten einer ausgetauschten ServerConnection
  werden zusätzlich über deren Objektidentität abgewiesen.
- Nach einer Wiederverbindung wird der Verlauf neu gelesen. Bei einer Lücke im
  Delta-Strom werden keine vermeintlich vollständigen Texte aus alten und neuen
  Fragmenten zusammengeklebt.
- Eingabeentwürfe liegen im Speicher pro Session. Verspätete native Feld-Callbacks
  prüfen die View-Generation. Senden, Stop sowie Agenten-/Modellwechsel erfassen
  die ursprüngliche Zielsession vor ihrer asynchronen Ausführung.
- Eine verzögert angelegte neue Session übernimmt nicht mehr nachträglich den
  Fokus, wenn der Nutzer inzwischen bewusst in einen anderen Chat gewechselt hat.
  Fragen/Freigaben werden anhand ihrer ausstehenden Anfrage der Sandbox zugeordnet,
  nicht anhand des zufällig gerade ausgewählten Chats.

## Live-Antworten

`ChatRenderStore` ordnet Text anhand der dokumentierten V2-Felder
`assistantMessageID` und Text-`ordinal` dem richtigen Assistant-Block zu. Ein
Reload ersetzt diese Deltas nicht. `text.ended` liefert den kanonischen vollständigen
Text; sobald der Verlauf ihn bestätigt, wird das Overlay entfernt. So entsteht
weder eine zweite anonyme Streaming-Bubble noch derselbe Text doppelt.

Auch nicht ausgewählte bekannte Sessions können ihren laufenden Stream behalten.
Zuletzt besuchte Chats haben einen begrenzten In-Memory-Verlaufscache (acht
Kontexte, höchstens 16 beendete Fragmente pro Kontext). Die Serverhistorie bleibt
maßgeblich; unbestätigte Benutzereingaben werden nicht durch Cache-Eviction gelöscht.
Optimistische Prompts bekommen eine Message-ID, die auch an die API übergeben wird.
Damit lassen sie sich ohne Textvergleich mit dem Server-Verlauf abgleichen.

Wird die App erst mitten in einem Textfragment verbunden, ist dessen Anfang nicht
immer rekonstruierbar: Dann erscheint „Live-Antwort wird synchronisiert …“, bis
kanonischer Text verfügbar ist, statt einen abgeschnittenen Markdown-Suffix als
vollständige Antwort zu rendern. Fehler/terminale Nachrichten beenden diesen
Synchronisationszustand ebenfalls. Es gibt keine zusätzliche persistierte
Chat-/Draft-Kopie in Preferences.

## Editor und Workspace

Datei-/Workspace-bezogene View-Zustände haben eine eigene Identität. Der native
Editor wird beim Dokumentwechsel neu angelegt, nicht bei jedem Agentenstatus-
Update. Jede native Editor-Ansicht hat einen eigenen UndoManager. Alte Highlight-
und Zeilensprung-Callbacks werden invalidiert und auf gültige Textbereiche geprüft.
Der Fokus wird direkt aus `NSTextView.becomeFirstResponder` gemeldet.

Die eigentlichen Dokumentpuffer bleiben im AppModel: **Ungespeicherte Änderungen
gehen beim Umschalten nicht verloren.** Eine persistente Undo-/Scroll-Historie pro
Datei über das Abbauen einer Ansicht hinweg ist damit nicht eingeführt.

Geöffnete Tabs bleiben wie bisher erhalten, auch wenn sie aus einer anderen
Arbeitskopie stammen. In diesem Fall zeigt die App einen Hinweis und deaktiviert
Git-Review für diese Datei im fremden Workspace. Es werden keine relativen Pfade
mehr durch bloßes Abschneiden einer unpassenden Root-Länge gebildet. Hintergrund-
Änderungen in der ausgewählten Arbeitskopie oder an sichtbaren Dateien lösen
eine Aktualisierung aus; veraltete Git-Ergebnisse dürfen nicht zurückschreiben.

`MarkdownTextView` misst Text gegen vorgeschlagene und tatsächliche Breite,
invalidiert bei Änderungen die intrinsische Höhe und zeichnet innerhalb seiner
Grenzen neu. Dabei bleibt die zusammenhängende native Textauswahl erhalten.

## Prüfung

`bash scripts/test-security.sh` führt auch `ContextSwitchTests` aus:

- Stale Requests bei A → B → A und nach dem Entfernen eines Views abweisen.
- Reload während eines Streams, Wechsel zu einer anderen Session/Server-ID,
  Text-Ordinal, kanonisches Textende und optimistische Message-ID-Abgleiche.
- Reconnect ohne vollständigen Präfix und danach Erfolg bzw. Fehler.
- Echte AppKit-Editoren mit **identischem Text** zwischen zwei Dokumenten
  wechseln; Scrollreset, Fokus, funktionierendes isoliertes Undo und erhaltene
  ungespeicherte Puffer prüfen.
- Echte native Markdown-Ansicht bei geänderter Breite und langem/kurzem Inhalt
  wiederverwenden; Breitenabgleich und tatsächliche Höhenänderung prüfen.

Diese Tests verwenden Fixtures, keine neuen LLM-Prompts. Der komplette manuelle
Mehrfenster-Ablauf bleibt zusätzlich abzunehmen: Während einer Antwort schnell
A/B/A wählen, Agenten wechseln, parallel in mehreren Editoren arbeiten, Dateien
unterschiedlicher Länge öffnen und ungespeicherte Änderungen kontrollieren.

Referenz für die V2-Stream-Felder und dauerhafte Textprojektion:
[Publisher](https://github.com/anomalyco/opencode/blob/v2.2.0/packages/core/src/session/runner/publish-llm-event.ts),
[Message-Updater](https://github.com/anomalyco/opencode/blob/v2.2.0/packages/core/src/session/message-updater.ts).
