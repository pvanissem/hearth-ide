# Hearth IDE

Native macOS-App (SwiftUI) für KI-Coding-Agenten, die in einer Sandbox laufen.
Hearth bündelt alle laufenden Agenten in einer Inbox und bietet einen nativen
Chat sowie einen Inspector mit Directory, Git, Editor, Preview, Tests,
Architecture (Mermaid), Build & Deployment und CI-Pipelines.

> **Status: Umbau.** Hearth ist aus einem internen Projekt hervorgegangen und
> nutzt im Moment noch die `devkcode`-CLI mit OpenCode als Agenten-Backend.
> Ziel ist eine eigenständige App mit eingebauter [nono](https://nono.sh)-Sandbox,
> in der du dich mit beliebigen Agent-CLIs anmeldest (Claude Code, Codex,
> GitHub Copilot, OpenCode, …). Details: [PLAN.md](PLAN.md).

## Voraussetzungen

- macOS 14+ auf Apple Silicon
- vorübergehend: die `devkcode`-CLI (Pfad abweichend per `HEARTH_DEVKCODE_BIN`)

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

Das App-Icon wird per Skript gezeichnet:
`scripts/make-icon-source.swift && scripts/make-icon.swift`.

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
