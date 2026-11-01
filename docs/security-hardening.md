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

Netzwerkaktionen laufen nie über den Host-Git-Pfad, sondern über `SandboxGitRunner`
auf Hearths nono-Sandbox (`NonoCommandRunner`, Protokoll `SandboxCommandRunner`):

- Feste Befehle, vollständig shell-quoted, kein Agenten-Prompt. Hooks, Fsmonitor,
  `ext::`- und `file::`-Transport sowie automatische Submodule sind deaktiviert.
- **Zwei Rechte-Stufen** (`SandboxPurpose`):
  - `gitNetwork` für Fetch und Clone: liest `~/.ssh`, schreibt `known_hosts`, nutzt
    den Schlüsselbund (HTTPS-Logins) und darf Port 22 sowie die Hosts der Remotes
    erreichen. `core.sshCommand` und Credential-Helper kommen nur aus der globalen
    `~/.gitconfig`. Zusätzlich werden **alle Filter und Credential-Helper aus der
    Repo-Konfiguration geleert**, auch URL-gebundene wie
    `credential.https://host.helper` (`Git.networkSandboxOverrides`).
  - `gitLocal` für das Zusammenführen nach einem Fetch (`merge --ff-only @{u}`):
    kein `~/.ssh`, kein Schlüsselbund, kein Port 22. Filter (z. B. LFS) laufen nur
    hier, also mit den Rechten eines Agenten.
- **Pull = Fetch (gitNetwork) + Fast-forward (gitLocal).** So kann ein vom Agenten
  in `.git/config` eingetragener Filter beim Pull nicht neben den SSH-Schlüsseln
  laufen (Befund S1 im Review).
- Clone reserviert atomar einen neuen leeren Zielordner unterhalb von HOME und
  klont **innerhalb** der Sandbox. Vorhandene Ordner werden nicht übernommen oder
  überschrieben. HTTPS-Passwörter in URLs und ungeschütztes HTTP werden abgelehnt.
- App-Tokens aus der CI/CD-Ansicht werden weder in die Sandbox noch in URLs übernommen.
- Ausgabe wird seitenweise gelesen, Exitstatus geprüft, der Vorgang nach Abschluss
  oder Abbruch entfernt. Zeitlimit: zehn Minuten. **Kein Host-Fallback.**

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

## Tests

```bash
scripts/test.sh        # swift test, auch nur mit den Command Line Tools
```

Die Tests laufen in GitHub Actions bei jedem Push (siehe `.github/workflows/ci.yml`).

- `SandboxPolicyTests`: die nono-Profile aller Sandbox-Arten als Golden-Dateien
  (`Tests/HearthTests/Golden`); jede Rechteänderung erscheint im Review als Diff.
  Dazu Invarianten: kein Schreibzugriff auf Agent-/Shell-Konfiguration oder
  Zugangsdaten, `~/.ssh` und Port 22 nur für `gitNetwork`, `.git/hooks` überall
  schreibgeschützt, Schlüsselbund nur wo nötig, geschützte Ordner.
- `LiveSandboxTests`: echte Befehle über nono (Projekt schreibbar, `.git/hooks` nicht,
  `~/.ssh`/Schlüsselbund nur in `gitNetwork`). Läuft, sobald `scripts/fetch-nono.sh`
  nono geholt hat.
- `SandboxGitTests`: feste Befehle, Aufteilung von Pull, Neutralisierung von
  Repo-Helfern, echtes Wegwerf-Repo mit bösartigem Filter (läuft beim Fetch nicht).
- `AgentHomeTests`: eigene Konfigurationsordner, nur-lesende Links, einmalige Kopie.
- `SecurityRegressionTests`: GitLab-Origin-Bindung, Terminal-Zwischenablage,
  Host-Git ohne Helfer, Directory-Moves, Mermaid in echtem WebKit.
- `BuildDeployTests`, `DirectoryTests`, `ContextSwitchTests`, `EditorWorkspaceTests`,
  `AppUpdateTests`: Build-Erkennung und -Runner, natives Drag & Drop, Editor-Wechsel,
  Tabs pro Sitzung, Updates.

**Zusätzliche manuelle Abnahme:** Drag & Drop, mehrere Editor-Gruppen,
Freigabe-/Widerrufsbedienung sowie verschiedene Mermaid-Diagrammtypen.
