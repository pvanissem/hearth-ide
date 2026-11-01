# Hearth IDE

Native macOS-App (SwiftUI) für KI-Coding-Agenten, die in einer Sandbox laufen.
Hearth bündelt alle laufenden Agenten in einer Inbox, zeigt jeden Agenten als
Terminal im Chat-Bereich und bietet einen Inspector mit Directory, Git, Editor,
Tests, Architecture (Mermaid), Build & Deployment und CI/CD (GitLab-Pipelines
und GitHub Actions).

## Agenten in der Sandbox

Über **＋ Agent starten** wählst du einen Ordner und einen Agenten:
Claude Code, Codex, GitHub Copilot CLI, OpenCode, Gemini CLI oder eine
Sandbox-Shell. Hearth startet ihn in einer mitgelieferten
[nono](https://nono.sh)-Sandbox (Seatbelt):

- Schreiben nur im gewählten Ordner und in Hearths eigenem Konfigurationsordner
  des Agenten (`~/Library/Application Support/Hearth/agents/<agent>`). Deine
  `CLAUDE.md`, Skills, Agents und Commands werden nur lesend eingebunden, deine
  Einstellungen einmalig kopiert. So kann ein Agent nichts in deine echte
  `~/.claude` & Co. schreiben, was außerhalb von Hearth ausgeführt würde.
- `.git/hooks` im Projekt ist schreibgeschützt
- gesperrt: SSH-Schlüssel, Shell-Konfiguration, Browserdaten, übriges Home
- Netzwerk nur zu LLM-APIs, Paket-Registries, GitHub/GitLab, Doku und den
  API-Hosts des Agenten
- Claude Code, Codex und Copilot dürfen an den Schlüsselbund (ihr Login liegt dort)

Jeder Agent nutzt seinen eigenen Login (Claude-Abo, ChatGPT, GitHub …).
„Anmelden …“ (Einstellungen › Agenten) startet den Login-Befehl des Agenten in der
Sandbox. Weil Claude Code, Codex und OpenCode in Hearth einen eigenen
Konfigurationsordner haben, meldest du dich dort einmal separat an.

Der Chat-Bereich zeigt den Agenten als Terminal. Die Inbox kennt den Status:
Claude Code meldet ihn über Hooks (läuft, wartet auf Freigabe, fertig), Codex
über `notify`, andere Agenten über Eingabe und Terminal-Klingel. Sitzungen
bleiben beim Wechsel aktiv; beendete Claude-/Codex-/OpenCode-Sitzungen lassen
sich fortsetzen. Profil, Protokoll und Status-Ereignisse jeder Sitzung liegen
unter `~/Library/Application Support/Hearth/runs/<id>/`.

**Einstellungen** (⌘,): Agenten (installiert?, Anmelden, Schlüsselbund),
Sandbox (zusätzliche Domains, Ports, Ordner, SSH für den Git-Bereich, Profil-Vorschau),
Projekte (weitere Ordner für Sitzungen in einem Projektordner) und Credentials
(API-Keys/Tokens im Schlüsselbund – per nono-Proxy, sodass die Sandbox nur einen
Platzhalter sieht, oder als Umgebungsvariable). Gespeichert unter
`~/Library/Application Support/Hearth/settings.json`, nie im Repository; gilt für
Agenten, Build & Deployment und Git.

> **Status:** Nächster Schritt ist ein nativer Chat über ACP (Agent Client
> Protocol). Details: [PLAN.md](PLAN.md), Aufbau: [Architektur](docs/architecture.md).

## Voraussetzungen

- macOS 14+ auf Apple Silicon
- mindestens eine Agent-CLI im PATH deiner Login-Shell

## Installation

```bash
curl -fsSL https://github.com/pvanissem/hearth-ide/releases/latest/download/install.sh | bash
```

Lädt die aktuelle Version aus den GitHub Releases, prüft die SHA-256-Prüfsumme,
installiert `Hearth IDE.app` nach `/Applications` (ohne Schreibrecht nach
`~/Applications`) und startet die App. Zum Aktualisieren erneut ausführen oder
in der App unter Einstellungen → Updates.

Die App ist ad-hoc signiert und nicht von Apple notarisiert.

## Build & Start

```bash
swift run                       # Entwicklung
scripts/bundle.sh               # erzeugt "build/Hearth IDE.app"
open "build/Hearth IDE.app"
scripts/test.sh                 # alle Tests (swift test), auch ohne Xcode
```

Ohne Xcode (nur Command Line Tools) gilt:
- `@State` wird als explizite `State(...)`-Property geschrieben, da das
  SwiftUI-Makro-Plugin nur mit Xcode ausgeliefert wird.
- `scripts/test.sh` ruft `swift test` mit dem Testing-Framework der Command Line
  Tools auf; mit Xcode genügt `swift test`.
- Die Live-Sandbox-Tests brauchen nono in `Vendor/` (`scripts/fetch-nono.sh`).

Jeder Push und jeder Pull Request läuft durch GitHub Actions
(`.github/workflows/ci.yml`): Build, alle Tests inklusive echter nono-Sandbox,
App-Bundle als Download-Artefakt. Ein Versions-Tag veröffentlicht das Release.

`scripts/bundle.sh` lädt nono (gepinnte Version, SHA-256 geprüft) über
`scripts/fetch-nono.sh` nach `Vendor/` und legt es nach `Contents/Helpers/nono`.
`swift run` findet es dort ebenfalls; abweichend per `HEARTH_NONO_BIN`.

Entwicklerhilfen (Umgebungsvariablen beim Start):

| Variable | Wirkung |
|---|---|
| `HEARTH_AUTOSTART_AGENT=claude` + `HEARTH_AUTOSTART_DIR=<ordner>` | startet direkt einen Agenten |
| `HEARTH_AUTOSTART_PROMPT=<text>` | bestätigt die Ordner-Abfrage und tippt den Prompt ein |
| `HEARTH_SHOW_START_SHEET=1` | öffnet den Startdialog |
| `HEARTH_WINDOW_SNAPSHOT=<datei.png>` | schreibt alle 3 s ein Bild des Fensters (ohne Bildschirmaufnahme-Recht) |

```bash
open -n --env HEARTH_AUTOSTART_AGENT=shell --env HEARTH_AUTOSTART_DIR=$HOME/IdeaProjects/demo "build/Hearth IDE.app"
```

App-Icon: Motiv in `Resources/AppIcon-source.png` (randlos, 1024 × 1024);
`scripts/make-icon.swift` schneidet es auf die macOS-Form zu und erzeugt `AppIcon.icns`.

## Release erstellen

Auf einem Apple-Silicon-Mac, auf aktuellem `main`, mit eingeloggter GitHub CLI:

```bash
scripts/release.sh v0.3.0
```

Prüft den Stand, führt die Tests aus, macht aus dem Abschnitt „Unveröffentlicht“
in [`CHANGELOG.md`](CHANGELOG.md) den Eintrag der neuen Version (Commit auf
`main`) und pusht ihn mit dem Tag. GitHub Actions baut daraufhin das Bundle,
testet erneut und legt das GitHub-Release mit Zip, Prüfsumme,
`latest-version.txt`, `CHANGELOG.md` und `install.sh` an. Neue Änderungen kommen unter einen frischen
Abschnitt `## Unveröffentlicht`; fehlt er, stammen die Notizen aus den Commits. App-Updater und `install.sh` lesen von
`releases/latest/download/…`.

## Weitere Dokumentation

- [Sicherheit](docs/security-hardening.md): GitLab-Freigaben, Terminal-/Mermaid-Schutz, Git-Policy, Regressionstests
- [Build & Deployment](docs/build-and-deployment.md)
- [App-Updates](docs/app-updates.md)
- [Architektur](docs/architecture.md)
- [Security- und Architektur-Review](docs/review-security-architecture.md)

## Lizenz

[MIT](LICENSE)
