# Hearth IDE – Änderungen

## Unveröffentlicht

- Die App ist jetzt standardmäßig auf Englisch. Deutsch lässt sich unter Settings › General › Language wählen (Neustart per Knopf).
- Landingpage auf Englisch mit deutscher Fassung unter /de/, README auf Englisch.

## 0.3.1 · 2026-11-01

- CI/CD: GitHub Actions funktioniert auch für umbenannte oder verschobene Repositories, deren lokaler Remote noch den alten Namen trägt (vorher „GitHub-Fehler 301“).

## 0.3.0 · 2026-11-01

- CI/CD zeigt jetzt auch GitHub Actions (github.com und GitHub Enterprise): Workflow-Läufe des aktuellen Branchs oder aller Branches, Jobs als Diagramm oder Liste, Job-Logs, fehlgeschlagene Jobs wiederholen, Läufe abbrechen und Workflows mit `workflow_dispatch` für den aktuellen Branch starten. Zugang per Fine-grained Token, getrennt für Lesen („Actions: Read-only“) und Schreiben, gebunden an den bestätigten Server – Job-Logs werden von GitHubs signierter Adresse ohne Token geladen.

## 0.2.1 · 2026-11-01

- Sicherheit: Ein Pull im Git-Bereich lädt nur noch in der Sandbox mit Zugriff auf deine SSH-Schlüssel herunter; das Zusammenführen läuft in einer Sandbox ohne Schlüssel. Filter und Zugangs-Helfer aus der Repository-Konfiguration werden dort ignoriert. Vorher konnte ein Agent über die Konfiguration seines Projekts beim nächsten Pull an die Schlüssel kommen.
- Sicherheit: Claude Code, Codex und OpenCode bekommen in Hearth einen eigenen Konfigurationsordner. Deine Anweisungen, Skills, Agents und Commands werden nur lesend eingebunden, deine Einstellungen einmal kopiert. Ein Agent kann damit keine Hooks oder MCP-Server mehr in deine echte Konfiguration schreiben, die außerhalb von Hearth laufen würden. **Bitte melde dich in Hearth einmal neu an** (Einstellungen › Agenten › Anmelden). Ältere Claude-Sitzungen starten neu statt fortzusetzen.
- Sicherheit: Bei Gemini CLI und Copilot CLI sind die Dateien, die Befehle starten, schreibgeschützt. `.git/hooks` im Projekt ist für alle Sandboxes gesperrt. Als Arbeitsordner lassen sich keine Ordner mit Hearth-, macOS- oder Agent-Einstellungen mehr wählen.
- Der Terminal-Bereich kennzeichnet, dass seine Shell ohne Sandbox läuft.
- „Im Chat erwähnen“ und die Agent-Aufträge aus Tests und Architektur tippen jetzt direkt in den Terminal-Chat des ausgewählten Agenten.
- Entfernt: die alte Anbindung über devkcode und OpenCode-Server (nativer Chat, Sandbox-Profile, Copilot-Verbrauch). Ein nativer Chat kommt über ACP zurück.
- Intern: Sandbox-Regeln als eigene Typen mit Golden-Tests, typisierte Schnittstelle für Sandbox-Befehle, aufgeteiltes App-Modell, Tests mit swift-testing und eine Build-Pipeline in GitHub Actions, die Releases baut und veröffentlicht.

## 0.2.0 · 2026-10-31

- Editor: Jede Sitzung behält ihre eigenen Tabs. Beim Wechsel zu einem anderen Agenten zeigt der Editor nur dessen Dateien, beim Zurückwechseln sind die alten Tabs samt Position wieder da – auch nach einem Neustart.
- Verzeichnis, Git und Editor aktualisieren sich, sobald ein Agent Dateien ändert.
- Updates und Installer laden vom umbenannten Repository pvanissem/hearth-ide.

## 0.1.0 · 2026-10-31

- Settings: show ports without thousands separator
- Git pane: allow the repository's remote hosts
- Native settings for the new sandbox
- Git pane: fetch/pull/clone in Hearth's nono sandbox, SSH included
- New app icon
- Agents: offer resume only when the agent has a conversation to continue
- Build & Deployment: run tasks in Hearth's nono sandbox without devkcode
- Run agents in Hearth's own nono sandbox with a terminal chat
- Hearth IDE: initial import from devkdesk without internal infrastructure
