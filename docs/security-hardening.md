# Security-Hardening und Dateiverwaltung (30.10.2026)

## 1. GitLab: Freigabe und Tokens pro HTTPS-Origin

- Ein `origin`-Remote beschreibt lediglich ein Projekt, niemals eine Serverfreigabe.
- Der Nutzer bestätigt den vollständigen HTTPS-Origin einschließlich eines
  eventuell abweichenden Ports ausdrücklich, bevor ein Token gespeichert wird.
- Einträge liegen unter `hearth-gitlab`, getrennt nach Origin und
  Lese-/Schreibzugriff. Unbekannte Origins lösen keine automatische
  Schlüsselbund-Abfrage aus.
- Für automatisches Lesen ist ein eigener Token mit `read_api` vorgesehen.
  Schreibaktionen verwenden nur einen separat eingerichteten `api`-Token.
  Die App kann die tatsächlich erteilten GitLab-Scopes nicht lokal beweisen;
  sie beschränkt aber die Verwendung des jeweiligen Eintrags auf den gewählten Zweck.
- Der REST-Client prüft die Origin-Bindung vor jedem Request und sperrt POST
  mit einer Leseberechtigung. Alle HTTP-Redirects werden abgelehnt.
- Die Session ist ephemeral, ohne Cookie-/Credential-Speicher oder URL-Cache.
- Über das Schlüssel-Symbol in CI/CD lassen sich Zugänge ergänzen und die
  Serverfreigabe widerrufen.

**Einrichtung:** In CI/CD den angezeigten Server prüfen und einen Lesetoken
einrichten; für Retry/Cancel/Run/Play bei Bedarf separat Schreibzugriff freigeben.

## 2. Terminal: Prozessgesteuerte Zwischenablage gesperrt

`TerminalSecurity` sitzt direkt als `TerminalViewDelegate` vor SwiftTerm.
PTY-Eingaben, Größenänderungen und Status werden an die lokale Prozess-View
weitergereicht, Clipboard-Callbacks dagegen nicht:

- OSC 52 Lesen: `nil` / verweigert.
- OSC 52 Schreiben: keine Aktion.
- Kitty/OSC 5522: keine Capabilities, leere MIME-Liste und ausdrücklich
  `denied` statt eines Werts, der auf die Systemzwischenablage zurückfällt.

Manuelles Kopieren/Einfügen durch den Nutzer ist davon zu unterscheiden und bleibt
eine normale Terminal-Aktion. Das Terminal ist dadurch **nicht automatisch eine
Sandbox**; seine normale Workspace-Shell läuft weiterhin auf dem Host.

## 3. Mermaid: feste Seite, Datenbrücke und Offline-Renderer

- Diagrammtext wird weder in HTML noch in ausführbaren JavaScript-Quelltext
  interpoliert. Er gelangt ausschließlich über `callAsyncJavaScript`-Argumente
  in die Renderfunktion.
- Ein privater URL-Scheme-Handler liefert genau zwei Ressourcen: die feste
  HTML-Seite und die gebündelte `mermaid.min.js`. Andere Pfade werden abgelehnt.
  Es gibt keine Dateiverzeichnis-Freigabe an WebKit und keine temporäre HTML-Datei.
- CSP: standardmäßig keine Ressourcen, nur nonce-autorisierte Scripts;
  kein Connect, keine Frames/Objekte/Formulare, keine entfernten Bilder oder Fonts.
  Inline-CSS bleibt für Mermaid-SVGs erlaubt.
- Zusätzlich blockiert eine WebKit-Content-Rule-Liste HTTP(S), WS(S) und FTP.
  Scheitert die Einrichtung, wird die Seite nicht geladen.
- Navigation ist ausschließlich auf die Renderer-Seite erlaubt. Diagrammlinks,
  neue Fenster und Navigation zu Host-Dateien/anderen Seiten sind gesperrt.
- Nichtpersistenter WebKit-Datenspeicher und Mermaid `securityLevel: strict`.

## 4. Git: keine Repository-Helfer auf dem Host

Für lokale Host-Abfragen gilt zentral in `Git.swift`:

- Fsmonitor, Hooks, Pager, externe Diffs, globale Attributes und optionale Locks
  sind deaktiviert. Diff/Show/Log erhalten `--no-textconv` und `--no-ext-diff`.
- Geerbte `GIT_*`-Variablen werden entfernt; System-/Global-Konfiguration wird
  nicht verwendet. Repository-/Worktree-Konfiguration samt Includes wird nach
  Filtern untersucht; deren Einstellungen werden für lesende Aufrufe neutralisiert.
- Lokale Schreibaktionen haben eine enge Befehls-Allowlist und deaktivierte Hooks.
  Bei konfigurierten Filtern werden sie abgelehnt, statt z. B. LFS-/Encryption-
  Dateien durch stilles Umgehen eines Filters zu beschädigen.
- Zusätzlich startet jeder Host-Git-Prozess unter einem macOS-Seatbelt-Profil:
  keine Netzwerkverbindungen und keine Ausführung von Shells/Helfern, nur Apples
  Git-Binaries. Das schützt auch gegen Konfigurationsänderungen zwischen Vorprüfung
  und Aufruf. Es gibt keinen ungeschützten Fallback.

### Fetch, Pull und Clone: eigener Sandbox-Ausführungspfad

Die Buttons sind nutzbar. Nur der **Host-Dispatcher** lehnt Netzwerkbefehle weiter
ab. Die Oberfläche verwendet dafür `SandboxGitRunner`:

- Direkte Befehle über OpenCodes `/api/shell`, kein Agenten-Prompt/LLM und keine
  zusätzliche Chat-Session. Argumente werden vollständig shell-quoted; Fetch,
  Fast-forward-only Pull und Clone sind fest vorgegeben. Hooks, Fsmonitor,
  `ext::`-Transport und automatische Submodule sind deaktiviert.
- Wiederverwendung des laufenden, zur Arbeitskopie gehörenden devkcode-Servers.
  Falls erforderlich startet die App ihn über die bestehende CLI, nicht durch
  Nachbauen von nono-Profilen. Ein bestehender Server mit abweichendem explizit
  gewähltem Profil wird nicht still neu gestartet.
- Clone reserviert atomar einen neuen leeren Zielordner unterhalb von HOME,
  startet dort die Sandbox und klont **innerhalb** dieser Sandbox. Vorhandene
  Ordner werden nicht übernommen/überschrieben. Noch leere, von dieser App-Instanz
  reservierte Ziele können nach einem Fehler erneut versucht werden. Teilweise
  gefüllte Ziele bleiben zur Diagnose erhalten und werden nicht automatisch gelöscht.
- Netzwerkzugriffe und Git-Zugänge werden vom gewählten devkcode-Profil kontrolliert.
  Die geerbte GitLab-Proxy-/Credential-Konfiguration bleibt erhalten. App-PATs
  aus der CI/CD-Ansicht werden weder in die Shell noch in Clone-URLs übernommen.
  Für GitLab ggf. vorher `devkcode gitlab login` ausführen; andere Hosts benötigen
  die passenden Sandbox-Freigaben/Zugänge. HTTPS-Passwörter in URLs und ungeschütztes
  HTTP werden für Clone nicht akzeptiert.
- Nur registrierte lokale Loopback-Endpunkte werden angesprochen; Redirects sind
  gesperrt. Ausgabe wird seitenweise gelesen, Exitstatus geprüft und die retained
  Shell nach Abschluss/Abbruch entfernt. Eigenes Zeitlimit: zehn Minuten.
- Git-Helfer/Filter können für Netzwerkaktionen **innerhalb der devkcode-Sandbox**
  laufen, nie über den Host-Git-Pfad. Hook-Policy bleibt ausdrücklich gesperrt.
- Bei fehlender Anmeldung, gesperrtem Netzwerk oder nicht verfügbarer Shell-API
  erscheint ein Fehler. **Kein ungeschützter Host-Fallback.** Der normale eingebettete
  Host-Shell-Modus ist nicht Teil dieses Ausführungspfads.

Die lokale Git-Policy ist keine vollständige Dateisystem-Isolation und kein
Schutz gegen unbekannte Schwachstellen im Git-Binary selbst. `sandbox-exec` ist
eine macOS-spezifische, veraltete Schnittstelle; die geprüften Standardpfade sind
`/usr/bin/git`, Command Line Tools und `/Applications/Xcode.app`. Abweichende
Installationen oder ein Wegfall von Seatbelt-Unterstützung können sicher
fehlschlagen und benötigen eine Anpassung statt eines offenen Fallbacks.

## Directory und Editor

- Dateien/Ordner lassen sich innerhalb desselben Workspace per Drag & Drop auf
  einen Ordner oder den Workspace-Kopf verschieben. Finder-/Fremd-App-Drags
  werden nicht importiert; der Payload ist an die laufende App-Instanz gebunden.
- Bestehende Ziele werden nicht überschrieben; Workspace-Wurzel, `.git`, Pfade
  außerhalb des Workspace, Symlink-Auswege und Verschieben in eigene Unterordner
  werden abgewiesen. Ungespeicherte Dokumente blockieren die Aktion.
- Offene Editor-Tabs folgen erfolgreich verschobenen Pfaden.
- Der Zielscheiben-Button zeigt die fokussierte Editor-Datei im Directory:
  Suche zurücksetzen, Elternordner aufklappen, zur Datei scrollen und sie markieren.
  Der Button ist im Directory-Kopf und im Editor-Dateikopf vorhanden.
- „Preview“ heißt sichtbar „Editor“. Der persistierte Raw-Value `Preview` und
  bestehende Fenster-/Pane-IDs bleiben kompatibel.

## Regressionstests

```bash
bash scripts/test-security.sh
swift build
```

`Tests/HearthTests/SecurityRegressionTests.swift` enthält die Tests. Der Runner
kompiliert produktive Implementierungen in einem isolierten SwiftPM-Harness,
damit die Tests auch ohne die hier fehlenden Swift-Testing-Makros laufen können.
Temporäre Harness-Builds liegen unter `$TMPDIR/opencode/security-regression.*`.

Abgedeckt:

1. Dummy-HTTP-Request über `URLProtocol`, Token-/Origin-Bindung, Porttrennung,
   Lese-/Schreibtrennung und Redirect-Policy – ohne echten Netzwerkrequest/Token.
2. Terminal-Clipboard-Callbacks und OSC-52-Parserpfad, ohne Zugriff auf den
   Inhalt der echten Zwischenablage.
3. Isoliertes Git-Testrepo mit harmlosen Fsmonitor-/Textconv-/Filter-/Hook-
   Markerprogrammen: Status, Diff, Commit-Anzeige, Inline-Diff und Branchwechsel.
4. Directory-Move, Kollisionen, Unterordner-/Wurzelschutz und Symlink-Auswege.
5. Echtes WebKit: normales Mermaid-Diagramm, `</script>`-Payload,
   durch CSP blockierter Verbindungsversuch und nichtpersistenter Datenspeicher.
6. `SandboxGitTests.swift`: Fetch/Pull/Clone über einen HTTP-Mock, vollständig
   gequotete Kommandos, explizite Location/cwd, mehrere Ausgabeseiten und finale
   Ausgabe, kein Session-/Prompt-Endpunkt, Cleanup bei Timeout, Ablehnung externer
   Shell-Server und kein Host-Fallback bei einer fehlenden API. Diese Tests führen
   keinen echten GitLab-Netzwerkabruf durch.
7. `DirectoryAndHistoryTests.swift`: native AppKit-Pasteboard-/Drop-Callbacks mit
   echten Datei-/Ordner-Moves und Reveal sowie Zusammenführung und Sortierung
   beider Sandbox-Registries. Details: [Directory und Verlauf](directory-history-fixes.md).
8. `ChatFeedbackTests.swift`: verschachtelte Anbieterfehler, persistierte Fehler
   ohne Antworttext, Duplikate, Live-Zustand und Activity-Anzeige sowie Hell-/Dunkel-
   Darstellungen. Details: [Chat-Feedback](chat-feedback.md).
9. `ModelsAndSessionListTests.swift`: explizite Copilot-Freigaben, Credential-Origin-
   Grenzen, Refresh-/Fehler-/Widerrufsverhalten, Slash-Liste und persistente
   Gruppenzustände. Details: [Modelle und Session-Gruppen](models-and-session-groups.md).
10. `ContextSwitchTests.swift`: Wechsel A/B/A, scoped Stream-Overlays, native Editor-
    Identität/Fokus/Undo und Markdown-Größenänderungen. Details:
    [Session-Rendering](session-rendering-fixes.md).

**Zusätzliche manuelle Abnahme:** Drag & Drop, Scrollen zur aktiven Datei in
einem langen Baum, mehrere Editor-Gruppen, Freigabe-/Widerrufsbedienung sowie
verschiedene Mermaid-Diagrammtypen. Automatische Harness-Tests ersetzen diese
interaktive Prüfung nicht.
