# Hearth IDE

Native macOS-App (SwiftUI) für KI-Coding-Agenten, die in einer Sandbox laufen.
Hearth bündelt alle laufenden Agenten in einer Inbox und bietet einen nativen
Chat sowie einen Inspector mit Directory, Git, Editor, Preview, Tests,
Architecture (Mermaid), Build & Deployment und CI-Pipelines.

## Agenten in der Sandbox

Über **＋ Agent starten** wählst du einen Ordner und einen Agenten:
Claude Code, Codex, GitHub Copilot CLI, OpenCode, Gemini CLI oder eine
Sandbox-Shell. Hearth startet ihn in einer mitgelieferten
[nono](https://nono.sh)-Sandbox (Seatbelt):

- Schreiben nur im gewählten Ordner und im Konfigurationsordner des Agenten
- gesperrt: SSH-Schlüssel, Shell-Konfiguration, Browserdaten, übriges Home
- Netzwerk nur zu LLM-APIs, Paket-Registries, GitHub/GitLab, Doku und den
  API-Hosts des Agenten
- Claude Code, Codex und Copilot dürfen an den Schlüsselbund (ihr Login liegt dort)

Jeder Agent nutzt seinen eigenen Login (Claude-Abo, ChatGPT, GitHub …).
„Anmelden …“ im Startdialog startet den Login-Befehl des Agenten in der Sandbox.

Der Chat-Bereich zeigt den Agenten als Terminal. Die Inbox kennt den Status:
Claude Code meldet ihn über Hooks (läuft, wartet auf Freigabe, fertig), Codex
über `notify`, andere Agenten über Eingabe und Terminal-Klingel. Sitzungen
bleiben beim Wechsel aktiv; beendete Claude-/Codex-/OpenCode-Sitzungen lassen
sich fortsetzen. Profil, Protokoll und Status-Ereignisse jeder Sitzung liegen
unter `~/Library/Application Support/Hearth/runs/<id>/`.

> **Status:** Die bisherige Anbindung über die `devkcode`-CLI (OpenCode-Server,
> nativer Chat) ist noch enthalten und erscheint nur, wenn `devkcode` installiert
> ist. Nächster Schritt ist der native Chat über ACP. Details: [PLAN.md](PLAN.md).

## Voraussetzungen

- macOS 14+ auf Apple Silicon
- mindestens eine Agent-CLI im PATH deiner Login-Shell

## Installation

```bash
curl -fsSL https://github.com/pvanissem/hearth/releases/latest/download/install.sh | bash
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
scripts/test-security.sh        # Regressionstests, auch ohne Xcode
```

Ohne Xcode (nur Command Line Tools) gilt:
- `@State` wird als explizite `State(...)`-Property geschrieben, da das
  SwiftUI-Makro-Plugin nur mit Xcode ausgeliefert wird.
- `swift test` benötigt Xcode (Swift-Testing-Makros); `scripts/test-security.sh`
  führt dieselben Tests ohne Xcode aus.

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
scripts/release.sh v0.1.0
```

Baut das Bundle, erzeugt Zip, Prüfsumme, `latest-version.txt` und ein
kumulatives `CHANGELOG.md`, setzt und pusht den Tag und legt das GitHub-Release
mit allen Dateien an. App-Updater und `install.sh` lesen von
`releases/latest/download/…`.

## Weitere Dokumentation

- [Sicherheit](docs/security-hardening.md): GitLab-Freigaben, Terminal-/Mermaid-Schutz, Git-Policy, Regressionstests
- [Build & Deployment](docs/build-and-deployment.md)
- [App-Updates](docs/app-updates.md)

## Lizenz

[MIT](LICENSE)
