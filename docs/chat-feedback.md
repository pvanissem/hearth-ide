# Arbeitsanzeige und Fehler im Chat

## Arbeitsanzeige

Ein kleiner segmentierter, laufender Balken mit „Agent arbeitet …“ erscheint im
Chat, solange die Session läuft. Beim Absenden wird der Status schon vor dem
ersten Text-Delta gesetzt. Freigabe-/Fragepausen, Ende, Abbruch und Fehler stoppen
die Anzeige. Bei einer unterbrochenen Verbindung wird nicht behauptet, der Agent
arbeite weiter; stattdessen erscheint der Verbindungsfehler.

Die Animation zeigt keinen erfundenen Fortschrittsprozentsatz und keine internen
Gedanken. Sie läuft mit begrenzter Aktualisierungsrate; bei der macOS-Einstellung
„Bewegung reduzieren“ bleiben die Segmente statisch. Ihre feste Größe verhindert,
dass Animationsschritte das Chat-Layout ständig ändern. Alle Scroll-Aktionen
respektieren weiterhin die Pause nach manuellem Hochscrollen.

## Fehlerpfade

- Live: `session.error` und `session.execution.failed` werden sessionbezogen
  festgehalten. Ein generisches Folge-Event überschreibt keinen konkreten
  Anbieterfehler. Session-Refresh und Tabwechsel löschen diesen Fehler nicht;
  ein neuer Lauf setzt den aktuellen Live-Fehler zurück.
- Verlauf: `assistant.error` und `idle` mit `outcome: failed` werden auch ohne
  Antworttext dargestellt. Gespeicherte Fehler bleiben somit beim erneuten Laden
  bzw. nach App-Neustart sichtbar, soweit der Server sie im geladenen Verlauf liefert.
- HTTP: Fehlgeschlagene Prompt-Requests erscheinen direkt im Chat. Der vollständige
  Fehler-Body wird benutzt, nicht nur die gekürzte `localizedDescription`.
- Verlaufslade- und Verbindungsfehler haben eigene Titel. Sie behaupten nicht,
  dass eine eventuell serverseitig laufende Ausführung sicher beendet wurde.
- Mehrere Meldungen desselben Fehlers werden innerhalb eines User-Turns
  zusammengeführt. Ein konkreter Fehler ersetzt einen generischen Platzhalter.
  Derselbe Fehler in einem späteren Turn bleibt sichtbar.
- Asynchrone Verlaufsantworten prüfen Session, Server und Ladegeneration, bevor
  sie den offenen Chat ändern; ein alter Request darf keinen anderen Chat überschreiben.

`ChatFailure` liest bekannte strukturierte Felder und eingebettete
`{"error": ...}`-Objekte in Stream-Fehlerketten. Im Fall `cyber_policy` zeigt die
Karte „Anfrage durch Sicherheitsrichtlinie blockiert“, den Fehlercode und die
Anbieter-Meldung. Die vollständige Kette ist aufklappbar und kopierbar.

Fehler sind reiner Text, kein ausführbares HTML/Markdown und keine Anweisung an
den Agenten. Es gibt weder automatische Wiederholungen noch einen Policy-Bypass.
Die App speichert dafür keine zusätzliche rohe Fehlerhistorie in Preferences;
historische Meldungen kommen vom OpenCode-Server, aktuelle Live-Fehler liegen im Speicher.

## Prüfung

`bash scripts/test-security.sh` führt auch `ChatFeedbackTests` aus:

- Originalformat eines verschachtelten SSE-Fehlers mit `cyber_policy`.
- Fehler vor jeglichem Antworttext und mit bereits vorhandener Teilantwort.
- Persistierte Assistant-/Idle-Fehler, Duplikate und getrennte User-Turns.
- Vollständige HTTP-Fehlerdetails, generische und fehlerhaft abgeschnittene Payloads.
- Live-Event-Reihenfolge, Session-Isolation, Refresh und Submit/Start/Erfolg/Stop.
- Activity-Gating bei Freigaben, Fragen, Fehlern und Verbindungsabbruch.
- Offscreen-Darstellung beider Komponenten in Hell/Dunkel mit eingefrorener Animation.

Die Tests verwenden Fixtures und HTTP-Mocks, keine echten Sicherheitsanfragen an
einen Modellanbieter. Maus-/Trackpad-Bedienung sowie ein kompletter realer Agenten-
Durchlauf bleiben zusätzlich manuell zu prüfen.
