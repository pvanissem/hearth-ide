# Hearth IDE – Plan

Native macOS-App (SwiftUI, macOS 14+, nur Apple Silicon) als Oberfläche für
KI-Coding-Agenten. Jeder Agent läuft in einer nono-Sandbox, die die App selbst
mitbringt. Welche Agent-CLI dahinter steckt, entscheidet der Nutzer.

## Zielbild

```
Hearth IDE.app
├─ UI: Inbox · Chat · Inspector · Editor · Pipelines
├─ AgentHost
│   ├─ ACP-Chat (nativ)  → Codex, GitHub Copilot, OpenCode, Gemini, …
│   └─ Terminal-Chat     → Claude Code (und optional jeder andere Agent)
├─ SandboxManager        → Profile, Projekte, Netzwerk, Credentials
└─ Contents/Helpers/nono → mitgeliefert, jeder Agent läuft darin
```

- **ACP** (Agent Client Protocol, JSON-RPC über stdio): ein Protokoll für alle
  Agenten. Kein offener Port, der Agent ist Kindprozess von nono.
- **Claude Code** läuft als Terminal (SwiftTerm) in der Chat-Fläche. Die
  Claude-Abo-Limits gelten nur für die offizielle CLI, nicht für ACP/Agent SDK.
  Inbox-Status über Claude-Code-Hooks (`UserPromptSubmit` → RUNNING,
  `Notification` → NEEDS INPUT, `Stop` → DONE), Sessions aus
  `~/.claude/projects`, Fortsetzen mit `claude --resume`.
- **Login** übernimmt jede CLI selbst; die App startet ihn nur.
- Pro Agent ein nono-Profil mit dessen API-Hosts und Konfigurationsordner.

## Schritte

- [x] **1a Neues Repo** – aus devkdesk ohne Historie, DEVK-Infrastruktur
      entfernt, Name/Bundle-ID/Icon, Updates und Releases über GitHub.
- [x] **1b Sandbox** – nono v0.80.0 im Bundle (`Contents/Helpers`), Profil pro
      Sitzung (`SandboxManager`), Agenten-Katalog (`AgentKind`): Claude Code,
      Codex, Copilot CLI, OpenCode (privater Server auf einem freigegebenen Port),
      Gemini CLI, Sandbox-Shell.
- [x] **2 Terminal-Chat** – `AgentHost`/`AgentRunView`: Terminal in der
      Chat-Fläche, bleibt beim Wechsel aktiv; Inbox-Status über Claude-Hooks,
      Codex-`notify` oder Terminal-Heuristik; Fortsetzen, Benachrichtigungen.
- [x] **2b Einstellungen** – nativ statt devkcode-CLI: Domains, Ports, Ordner,
      Projekte, Credentials (nono-Proxy oder env), Git über SSH; Build &
      Deployment und Git laufen in Hearths nono-Sandbox.
- [x] **2c Härtung & Architektur (v0.2.1)** – Befunde aus dem
      [Review](docs/review-security-architecture.md): Pull geteilt (S1), eigene
      Konfigurationsordner pro Agent (S2), geschützte Ordner (S6); devkcode-/
      OpenCode-Server-Pfad entfernt, `AppModel` in Stores geteilt, Sandbox-Regeln
      als `SandboxPolicy`, typisiertes `SandboxCommandRunner`-Protokoll,
      swift-testing-Suite mit Golden-Profilen und Live-nono-Tests, CI-Pipeline.
- [ ] **2d Rest** – Login ohne Schlüsselbund-Freigabe (nono `credential_providers`,
      Platzhalter-Tokens), Terminal-Bereich standardmäßig in der Sandbox (S5),
      Warnung vor ausführbaren Dateien (S4).
- [ ] **3 ACP-Chat** – Agent-Schnittstelle in der App, ACP-Client mit eigenen
      Chat-Views (Permissions, Modelle, Modi, Slash-Commands) als zweite
      Darstellung neben dem Terminal.
- [x] **CI/CD für GitHub Actions** neben GitLab (gemeinsames `CIClient`-Protokoll).
- [ ] **4 Feinschliff** – GitLab-Pipelines für frei wählbare URL,
      Signierung/Notarisierung, Agent-spezifische Verbrauchsanzeigen.

## Risiken

- ACP-Adapter unterscheiden sich (Session-Liste/Fortsetzen, Rückfragen,
  Slash-Commands); die UI muss Fähigkeiten pro Agent abfragen.
- Abo-Bedingungen der Anbieter ändern sich; Claude über ACP läuft nicht über
  die normalen Abo-Limits.
- Guards (Git-Remote, MR, WebFetch) waren OpenCode-Plugins und müssen als
  nono-Regeln bzw. agentenspezifische Hooks neu entstehen.
- Gemini CLI und Copilot CLI haben keine verlässliche Variable für einen eigenen
  Konfigurationsordner; dort schützt nur eine Schreibsperre einzelner Dateien.
