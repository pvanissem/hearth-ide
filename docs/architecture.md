# Architektur

Stand v0.3. Hearth ist eine SwiftUI-App ohne eigenen Agenten: Sie startet die
Agent-CLIs der Nutzer in einer nono-Sandbox und zeigt drumherum Inbox, Editor,
Git, Tests, Build & Deployment und CI.

## Überblick

```mermaid
flowchart TB
  subgraph UI["SwiftUI-Ansichten"]
    Inbox["InboxView"]
    Chat["ChatView → AgentRunView (Terminal)"]
    Insp["InspectorView: Directory, Git, Editor, Tests,<br/>Architecture, Build & Deployment, CI/CD, Terminal"]
  end
  subgraph Model["AppModel (Komposition)"]
    Layout["LayoutStore"]
    Editor["EditorStore"]
    WS["WorkspaceState"]
    Zoom["TextZoomStore"]
    GL["GitLabAccounts"]
    Agents["AgentHost"]
    Builds["BuildDeployStore"]
    Updates["UpdateChecker"]
  end
  subgraph Sandbox["Sandbox-Schicht"]
    Policy["SandboxPolicy<br/>(SandboxPurpose + SandboxContext)"]
    Home["AgentHome"]
    Manager["SandboxManager.prepare"]
    Runner["SandboxCommandRunner<br/>NonoCommandRunner"]
  end
  nono[["nono (Contents/Helpers)"]]
  UI --> Model
  Agents --> Manager
  Builds --> Runner
  GitRunner["SandboxGitRunner"] --> Runner
  Model --> GitRunner
  Runner --> Manager
  Manager --> Policy & Home
  Manager --> nono
  HostGit["Git (Host, nur lesen, sandbox-exec)"]
  Model --> HostGit
```

## Bausteine

| Bereich | Typen | Aufgabe |
|---|---|---|
| Zustand | `AppModel` | Komposition und Auswahl: Die gewählte Agenten-Sitzung bestimmt den Arbeitsordner (`workspaceRoot`) und damit Inspector, Editor-Tabs und Build & Deployment. Startet Agenten, leitet „Auftrag an den Agenten“ ins Terminal. |
| | `LayoutStore` | Bereiche, Splits, eigene Fenster, Maximieren; gespeichert in `UIStateStore`. |
| | `EditorStore`, `EditorGroup` | Editoren pro Preview-Bereich, Tabs, ungespeicherte Dokumente, Navigation, „Gehe zu Definition“, Tabs pro Sitzung. |
| | `WorkspaceState` | Git-Stand, Verzeichnisbaum, Revision (lädt Inspector-Tabs neu, wenn ein Agent Dateien ändert). |
| | `TextZoomStore`, `GitLabAccounts` | Schriftgröße pro Bereich; GitLab-Tokens pro bestätigtem Origin. |
| Agenten | `AgentKind` | Katalog: Programm, Login, Status-Quelle, API-Hosts. |
| | `AgentHost`, `AgentRun` | Start, Fortsetzen, Stoppen, Status aus `events.jsonl` (Claude-Hooks, Codex-`notify`), Benachrichtigungen, `runs.json`. |
| Sandbox | `SandboxPurpose` | Wofür eine Sandbox ist: `.agent(kind)`, `.build`, `.gitNetwork`, `.gitLocal`. |
| | `SandboxPolicy` | Einzige Quelle aller Rechte: aus Zweck und `SandboxContext` (Home, Arbeitsordner, Einstellungen) wird das nono-Profil. Rein, ohne Dateizugriffe, daher als Golden-Datei testbar. |
| | `AgentHome` | Eigener Konfigurationsordner je Agent mit nur-lesenden Links auf die eigene Konfiguration; Schreibsperren für Agenten ohne Ordner-Variable. |
| | `SandboxManager` | Findet nono und die CLI, prüft den Arbeitsordner, schreibt Profil und Status-Hooks, baut Befehlszeile und Umgebung. |
| | `SandboxCommandRunner`, `NonoCommandRunner` | Typisierte Schnittstelle für Befehle in der Sandbox (Start, Status, Ausgabe-Seiten, Entfernen); jeder Befehl in einer eigenen nono-Sandbox. |
| Git | `Git` | Lesende Host-Abfragen und lokale Änderungen unter `sandbox-exec` ohne Netz und ohne Helfer. |
| | `SandboxGitOperation`, `SandboxGitRunner` | Fetch/Clone in `.gitNetwork`, Fast-forward in `.gitLocal`; Repo-Helfer neutralisiert. |
| Build | `BuildDetector`, `BuildCommand`, `BuildDeployStore` | Aufgaben aus Projektdateien, sicher gequotete Befehle, Ausführung und Health-Checks über `SandboxCommandRunner`. |
| Sonstiges | `GitLabCI`, `TestReports`, `MermaidScanner`, `SymbolFinder`, `AppUpdates` | CI-Pipelines, Testberichte, Architekturdiagramme, Definitionen, Updates. |

## Datenablage

| Ort | Inhalt |
|---|---|
| `~/Library/Application Support/Hearth/settings.json` | Sandbox-Regeln der Nutzer (Domains, Ports, Ordner, Projekte, Credentials-Metadaten) |
| `…/Hearth/runs.json`, `…/Hearth/runs/<id>/` | Sitzungen; je Sitzung nono-Profil, Log, Status-Ereignisse, Hook-Skripte |
| `…/Hearth/agents/<agent>/` | Hearths Konfigurationsordner der Agenten (Login, Verlauf, Einstellungen) |
| `UserDefaults` (`ui.*`) | Layout, Editor-Tabs (auch pro Sitzung), Schriftgrößen, Update-Einstellungen |
| Schlüsselbund | `nono` / `hearth.<name>`: Credentials für den nono-Proxy; `hearth-gitlab`: GitLab-Tokens |

## Abläufe

**Agent starten:** `AppModel.startAgent` → `AgentHost.start` → `SandboxManager.prepare(.agent(kind))`
(Arbeitsordner prüfen, `AgentHome.prepare`, Profil aus `SandboxPolicy`, Hooks) → SwiftTerm startet
`nono run --profile … -- <cli>`. Hooks schreiben in `events.jsonl`, `AgentHost` liest alle 0,5 s.

**Pull:** `AppModel.pull` → `SandboxGitRunner(.fetchUpstream)` in `.gitNetwork` → bei Erfolg
`SandboxGitRunner(.fastForward)` in `.gitLocal`.

**Build-Aufgabe:** `BuildDeployStore.start` → `NonoCommandRunner(.build).start` → Ausgabe seitenweise,
Health-Check vom Mac aus über `LocalPortProbe`.

## Tests und Auslieferung

- `scripts/test.sh` (swift-testing, auch ohne Xcode). Golden-Profile in `Tests/HearthTests/Golden`,
  Live-Tests gegen echtes nono, Fakes für die Sandbox-Schnittstelle (`FakeCommandRunner`).
- `.github/workflows/ci.yml`: Build und Tests bei jedem Push/PR, App-Bundle als Artefakt,
  Release bei Versions-Tag. `scripts/release.sh` setzt Changelog und Tag.
