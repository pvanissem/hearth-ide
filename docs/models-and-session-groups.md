# Modellfreigaben und zuklappbare Session-Gruppen

## Modellkatalog

OpenCodes `/api/model` liefert einen Katalog für die aktuelle Location. `enabled`
allein bestätigt nicht, dass die App eine explizite Copilot-Accountfreigabe kennt.
Der initiale Snapshot kann zudem vor Abschluss der Provider-Initialisierung kommen.

Hearth IDE bildet die Schnittmenge aus:

1. Servermodell ausdrücklich `enabled: true`, Chat-Modell bzw. dokumentierter
   fehlender Chat-Default-Typ.
2. Für Copilot: accountbezogenes Modell mit `model_picker_enabled: true` und
   ausdrücklich `policy.state: "enabled"`.

Lokale Aliase werden über das tatsächliche `modelID` mit dem Accountkatalog
abgeglichen. Modellnamen sind keine Allowlist. Eine fehlende Policy bedeutet
**nicht nachgewiesen gesperrt**, aber auch **keine explizit bestätigte Freigabe**;
solche Modelle werden in dieser konservativen Auswahl nicht angeboten. Utility-
Modelle, deaktivierte und unbestätigte Modelle erscheinen nicht als neue Auswahl.

Beim Read-only-Abgleich am 30.10.2026 meldete der laufende Sandbox-Server 23
Copilot-Modelle als enabled. Davon waren 19 zugleich explizit bestätigt und für
den Picker vorgesehen. Das wurde zusätzlich mit dem produktiven Loader geprüft.
Diese Zahlen sind ein Account-/Zeitpunkt-Snapshot, keine fest codierte Auswahl.

- Modellmenü, `/model`-Vorschläge und bevorzugte Modelle verwenden denselben
  gefilterten Katalog. Ein expliziter Modellwechsel prüft ihn erneut.
- Sichtbare Chats aktualisieren nach dem initialen Laden nochmals nach zwei
  Sekunden, danach alle 60 Sekunden. Im Menü gibt es „Modellliste aktualisieren“.
- Gleichzeitige Aktualisierungen teilen sich einen laufenden Task. Die Account-
  Abfrage blockiert nicht den Aufbau der Session-Liste.
- Ist die Verfügbarkeit nicht prüfbar, erscheint ein Hinweis statt eines
  Fallbacks auf „alle Copilot-Modelle“. Andere ausdrücklich aktivierte Provider-
  Modelle bleiben verfügbar.
- Eine bestehende Session-/Default-Auswahl wird nicht ungefragt geändert. Falls
  sie nicht bestätigt ist, bleibt ihre ID mit einem Warnhinweis erkennbar, wird
  aber nicht als neue bestätigte Auswahl angeboten.

Eine Modellfreigabe garantiert weder verbleibendes Kontingent noch die Annahme
jeder einzelnen Anfrage; Content-/Cyber-Policies werden weiterhin vom Anbieter
durchgesetzt und als Fehler im Chat dargestellt.

### Authentifizierung und Grenzen

Die App fragt den bestehenden **lokalen** OpenCode-Server read-only nach seinem
aktiven Copilot-OAuth-Zugang (`/api/credential`). Die aktuelle API bietet dafür
eine Credential-Liste; die App wählt ausschließlich einen eindeutigen aktiven
Eintrag der Integration `github-copilot`. Tokens bleiben im Arbeitsspeicher;
es gibt keine neue Token-Datei, Preferences-Kopie oder Ausgabe der Credential-
Antwort in Fehlermeldungen/Logs.

Die anschließende Anfrage ist ausschließlich `GET /models` auf HTTPS-Port 443
eines dieser festen GitHub-Copilot-Hosts:

- `api.githubcopilot.com`
- `api.individual.githubcopilot.com`
- `api.business.githubcopilot.com`
- `api.enterprise.githubcopilot.com`

Die Auswahl kommt aus der geprüften Credential-Metadaten-Origin, **niemals aus
Repository-Remotes oder `model.settings.baseURL`**. Andere Hosts, Ports, Pfade,
URL-Zugangsdaten, Query/Fragment, malformed Metadaten und mehrdeutige Accounts
werden abgelehnt. Redirects, Cookie-Speicherung und Credential-Storage sind aus.
HTTP-Fehlerbodies von GitHub werden nicht als Debug-Dump angezeigt.

GitHub-Enterprise-/Sonderendpunkte außerhalb dieser Public-Origins werden nicht
automatisch authentifiziert. Sie brauchen eine gesondert abgesicherte Integration.
Bei fehlender oder nicht nutzbarer Credential-API wird kein anderer Auth-Store
durchsucht und kein Token geraten. Diese zusätzliche Account-Prüfung wäre künftig
entbehrlich, wenn die Server-API selbst explizite Account-Policy-Fakten liefert.

Referenz der verwendeten Account-Katalogfelder und API-Version:
[OpenCode v2.2.0 Copilot-Katalog](https://github.com/anomalyco/opencode/blob/v2.2.0/packages/core/src/github-copilot/models.ts)
und [Provider-Integration](https://github.com/anomalyco/opencode/blob/v2.2.0/packages/core/src/plugin/provider/github-copilot.ts).
Es handelt sich um eine interne Copilot-API; Schemaänderungen führen zu einem
sichtbaren Fehler bzw. einer konservativen Auswahl, nicht zu einer Freigabe aller Modelle.

## Session-Liste

- Jede Sandbox-Gruppe hat einen nativen Auf-/Zu-Pfeil. Der Zustand wird pro
  Repo/Projekt über Wiederverbindungen und App-Neustarts gespeichert.
- Die Session selbst und der offene Chat laufen beim Zuklappen unverändert weiter.
- Sessions stehen nur noch einmal unter ihrer Sandbox, sortiert nach Status
  und Aktualität. „Braucht Aufmerksamkeit“ ist eine ebenfalls zuklappbare
  Zusammenfassung mit einem Filter auf diese Gruppen, keine zweite Kopie der Zeilen.
- Anzahl und Rückfrage-/Fehlerhinweis bleiben am geschlossenen Gruppenkopf sichtbar.
- „Alle … anzeigen“ erweitert die Vorschau unabhängig vom Zuklappen der Gruppe.
  Die ausgewählte Session bleibt auch außerhalb der ersten fünf sichtbar.
- „Neue Session“ am Gruppenkopf klappt die zugehörige Gruppe auf.

## Prüfung

`ModelsAndSessionListTests` in `bash scripts/test-security.sh` prüfen Filter,
Alias-IDs, aktive Accounts, Auth-Origins, Fehler-/Widerrufsverhalten, konkurrierende
Refreshes, Slash-Vorschläge, Codable-Persistenz der Gruppen und die ausgewählte
Session in der Vorschau. Die automatischen Tests verwenden ausschließlich
Dummy-Credentials und HTTP-Mocks. Zusätzlich erfolgte der oben genannte einmalige
Read-only-Live-Abgleich ohne Prompt, Modellgenerierung oder Credential-Ausgabe.

Interaktive Abnahme: Gruppenkopf schließen/öffnen, Chat dabei offen lassen,
Neustart prüfen, Aufmerksamkeitsfilter testen und Modellmenü aktualisieren.
