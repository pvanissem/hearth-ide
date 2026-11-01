# Build & Deployment

Neuer Bereich im Pane-System (Tab „Build & Deployment“, Symbol Hammer). Er erkennt
Build-Werkzeuge und Services des ausgewählten Workspace und führt sie
**ausschließlich in Hearths nono-Sandbox** aus (`NonoCommandRunner`, Zweck `.build`:
Projektordner schreibbar, keine SSH-Schlüssel, kein Schlüsselbund). Es gibt keinen
Host-Fallback und keinen LLM-Prompt.

## Erkennung (nur Dateien lesen, nichts ausführen)

| Datei | Aufgaben | Services |
|---|---|---|
| `pom.xml` (+ `mvnw`) | clean install, verify, test, package, package ohne Tests, compile, clean, dependency:tree; Maven-Profile (`-P`) wählbar | `spring-boot:run` je Spring-Boot-Modul; Port aus `application.properties/yml` (sonst 8080), Health über `/actuator/health`, falls Actuator vorhanden |
| `build.gradle(.kts)` (+ `gradlew`) | build, test, clean | `bootRun` bei Spring Boot |
| `package.json` | Install (`npm ci`/pnpm/yarn je Lockfile), alle Scripts | `start`, `dev`, `serve`, `preview`, `watch` …; Port aus Script bzw. Vite/Next/Angular-Standard |
| `go.mod` | build, test, vet | `go run .` und jedes `cmd/*` mit `package main`; Port aus `":8080"`-Literal |
| `Makefile` | alle einfachen Targets | `run`, `serve`, `start`, `dev`, `up` |
| `.hearth/tasks.json` | eigene Befehle (`name`, `command`, optional `cwd`, `service`, `port`, `health`) | ja |

Gescannt werden Root und direkte Unterordner (ohne `node_modules`, `target`,
`build`, versteckte Ordner, Symlinks), Maven-Module über `<modules>`. Ungültige
Namen, Pfade außerhalb des Workspace und übergroße Dateien werden ignoriert.

## Ausführung

- Argumente werden einzeln geshellquotet; Profile/Scripts/Targets werden validiert.
  Eigene Aufgaben aus `tasks.json` sind bewusst freie Befehlszeilen (wie npm-Scripts)
  – sie laufen ebenfalls nur in der Sandbox.
- Live-Log (ANSI bereinigt, begrenzt), Abbrechen/Stoppen, Laufzeit, Exit-Code,
  Historie der letzten Läufe, Kopieren der Ausgabe.
- Services: Port editierbar (wird als `PORT`/`SERVER_PORT` übergeben), Prüfung auf
  bereits belegten Port vor dem Start, Health-Check **vom Mac aus**
  (`127.0.0.1:<port>`, ohne Redirects/Cookies), „Im Browser öffnen“.
  Derselbe Service läuft pro Workspace höchstens einmal.
- Stoppen beendet den gesamten Prozessbaum (auch die von `spring-boot:run`
  geforkte JVM) – SIGTERM, nach 3 s SIGKILL.
- Laufende Services werden anhand ihrer Metadaten wieder angezeigt, wenn die
  Ansicht neu aufgebaut wird, und bleiben stoppbar.

## Sandbox-Besonderheiten

- **Erreichbarkeit:** Ein Service in der Sandbox kann lauschen und ist vom Mac aus
  erreichbar. Build & Deployment darf sich außerdem mit localhost-Ports verbinden, weil
  Dev-Server Hilfsprozesse auf zufälligen Ports nutzen (z. B. Vaadin mit Vite). Agenten
  dürfen das nicht.
- **Eigenes Java-Home:** Java-Programme in der Sandbox sehen `~/Library/Caches/Hearth/home`
  als `user.home` (`JAVA_TOOL_OPTIONS`). Frameworks wie Vaadin schreiben dort ihr
  `~/.vaadin` hin statt in deinen echten Ordner, in dem Node und das IDE-Plugin liegen.
- **Netzwerk nur über den Sandbox-Proxy.** Java ignoriert `HTTPS_PROXY`. Für Maven
  erzeugt jeder Lauf eine temporäre globale Settings-Datei (0600, nur Proxy, wird nach
  dem Lauf gelöscht, Reste nach 24 h entfernt) und übergibt sie mit `-gs`. Deine
  `~/.m2/settings.xml` ist in der Sandbox nicht lesbar (sie enthält oft Passwörter). Gradle bekommt die
  Proxy-Werte über `GRADLE_OPTS`. Go/Node nutzen die Umgebungsvariablen.
- **Nicht freigegebene Ziele** (z. B. ein Repository außerhalb der Allowlist)
  scheitern mit „Operation not permitted“/403. Die App erkennt das und verweist auf
  die Freigabe unter Einstellungen › Sandbox.
- **Caches:** `~/.m2/repository`, `~/.npm` und `~/.gradle` sind in der Sandbox
  höchstens lesbar. Maven, Gradle und npm schreiben deshalb in einen eigenen Cache unter
  `~/Library/Caches/Hearth/` (`m2/repository`, `gradle`, `npm`), gesetzt über
  `MAVEN_ARGS`, `GRADLE_USER_HOME` und `npm_config_cache` im Sandbox-Profil – für
  Build & Deployment und für Agenten. Was schon in `~/.m2/repository` liegt, nutzt
  Maven (ab 3.9) lesend weiter (`maven.repo.local.tail`), Gradle entsprechend
  `~/.gradle/caches` (`GRADLE_RO_DEP_CACHE`). So kann ein Build in der Sandbox keine
  Artefakte in das Repository legen, aus dem deine IDE außerhalb der Sandbox baut.
  Folge: `mvn install` in Hearth landet im Hearth-Cache, nicht in `~/.m2`.
  Go-Caches liegen unter `$TMPDIR/hearth`.
- **JDKs** unter `~/Library/Java/JavaVirtualMachines` (z. B. von IntelliJ) und
  `~/.sdkman/candidates` sind lesbar, ebenso `/Library/Java` und Homebrew.
- **Werkzeuge:** Beim Öffnen wird geprüft, welche Werkzeuge in der Sandbox ausführbar
  sind. Fehlt eines, wird die Aufgabe mit Hinweis deaktiviert; Wrapper (`./mvnw`,
  `./gradlew`) bleiben nutzbar. Zusätzliche Werkzeug-Ordner gibst du unter
  Einstellungen › Sandbox frei.
- **Docker/Compose** ist mangels Socket-Freigabe der Sandbox nicht unterstützt.

## Tests

`scripts/test.sh` (`BuildDeployTests.swift`):

- Erkennung mit Fixture-Projekt (Multi-Module-Maven mit Spring Boot/Actuator/YAML-Port,
  pnpm/Vite, Go `cmd/`, Makefile, eigene Aufgaben, unsichere Eingaben).
- Befehlserzeugung inkl. **tatsächlicher Ausführung** des Maven-Skripts mit Fake-`mvn`
  und Fake-Proxy unter zsh: Argumente, Exit-Code, Settings-Rechte, Löschung.
- Runner gegen eine In-Memory-Sandbox (`FakeCommandRunner`): Ausgabe-Paging, Exit-Codes, Aufräumen,
  Service-Health, Stoppen, Port-Konflikt, fehlende Werkzeuge, Wiederaufnahme,
  Sandbox-Verlust.
- Live gegen echtes nono (`LiveSandboxTests`): Projektordner schreibbar, `.git/hooks`
  gesperrt, keine SSH-Schlüssel und kein Schlüsselbund in der Build-Sandbox.

Die Bedienung im Fenster selbst (Klickwege, Layout) ist noch manuell abzunehmen.
