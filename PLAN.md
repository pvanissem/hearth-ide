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
- [ ] **1b SandboxManager** – nono ins Bundle, Profile/Projekte/Netzwerk/
      Credentials aus devkcode nach Swift portieren (nur macOS/Seatbelt),
      `DevkCLI`/`DevkConfig`/`WebSessionRegistry` ablösen.
- [ ] **2 Terminal-Chat** – generischer Terminal-Modus, Claude Code mit Hooks,
      Inbox-Status und Session-Liste.
- [ ] **3 ACP-Chat** – Agent-Schnittstelle in der App, ACP-Client auf den
      bestehenden Chat-Views (Permissions, Modelle, Modi, Slash-Commands);
      OpenCode-HTTP-Weg danach entfernen.
- [ ] **4 Feinschliff** – Pipelines für GitHub Actions und GitLab (freie URL),
      Signierung/Notarisierung, Agent-spezifische Verbrauchsanzeigen.

## Risiken

- ACP-Adapter unterscheiden sich (Session-Liste/Fortsetzen, Rückfragen,
  Slash-Commands); die UI muss Fähigkeiten pro Agent abfragen.
- Abo-Bedingungen der Anbieter ändern sich; Claude über ACP läuft nicht über
  die normalen Abo-Limits.
- Guards (Git-Remote, MR, WebFetch) waren OpenCode-Plugins und müssen als
  nono-Regeln bzw. agentenspezifische Hooks neu entstehen.
