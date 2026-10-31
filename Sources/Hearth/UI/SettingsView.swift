import SwiftUI
import AppKit

/// Hearth's settings. Sandbox rules are stored by Hearth itself
/// (~/Library/Application Support/Hearth/settings.json) and apply to every
/// sandbox start: agents, Build & Deployment and the Git pane.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Allgemein", systemImage: "gearshape") }
            AgentSettings().tabItem { Label("Agenten", systemImage: "sparkles") }
            SandboxRuleSettings().tabItem { Label("Sandbox", systemImage: "lock.shield") }
            ProjectSettings().tabItem { Label("Projekte", systemImage: "folder.badge.gearshape") }
            CredentialSettings().tabItem { Label("Credentials", systemImage: "key") }
            UpdateSettings(checker: model.updates).tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 720, height: 540)
    }
}

/// Sandbox rules are read at start; offers to restart running sessions.
private struct RestartHint: View {
    @Environment(AppModel.self) private var model
    var text = "Änderungen gelten für neu gestartete Sitzungen."

    var body: some View {
        HStack {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
            let running = model.agents.runningCount
            if running > 0 {
                Button("Laufende Sitzungen neu starten (\(running))") { model.agents.restartRunning() }
                    .controlSize(.small)
                    .help("Beendet die laufenden Agenten und startet sie mit den neuen Regeln. Claude Code und Codex setzen ihr Gespräch fort.")
            }
        }
    }
}

/// One folder grant row: path, read or read+write, remove.
private struct FolderRow: View {
    let folder: SandboxSettings.Folder
    let setWrite: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        HStack {
            Image(systemName: FileManager.default.fileExists(atPath: folder.path) ? "folder" : "questionmark.folder")
                .foregroundStyle(.secondary)
            Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .lineLimit(1).truncationMode(.head).help(folder.path)
            Spacer()
            Picker("", selection: Binding(get: { folder.write }, set: setWrite)) {
                Text("lesen").tag(false)
                Text("lesen + schreiben").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button(action: remove) { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }
}

private func chooseFolder(message: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.message = message
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.resolvingSymlinksInPath().standardizedFileURL.path
}

// MARK: General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    private let terminal = State(initialValue: TerminalLauncher.preferred)
    private let appearance = State(initialValue: AppAppearance.current)
    private let lastWindow = State(initialValue: QuitPreferences.onLastWindow)
    private let onQuit = State(initialValue: QuitPreferences.onQuit)
    private let welcome = State(initialValue: AppModel.welcomeEnabled)

    var body: some View {
        Form {
            Section("Darstellung") {
                Picker("Erscheinungsbild", selection: Binding(get: { appearance.wrappedValue }, set: {
                    appearance.wrappedValue = $0
                    AppAppearance.current = $0
                })) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Terminal") {
                Picker("Externes Terminal", selection: Binding(get: { terminal.wrappedValue }, set: {
                    terminal.wrappedValue = $0
                    TerminalLauncher.preferred = $0
                })) {
                    ForEach(TerminalLauncher.installed) { Text($0.rawValue).tag($0) }
                }
                Text("Die eingebauten Terminals übernehmen Schrift und Farben aus dem iTerm2-Profil, wenn iTerm2 gewählt ist.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Layout") {
                Button("Layout zurücksetzen") { model.resetLayout() }
            }
            Section("Start") {
                Toggle("Willkommensdialog anzeigen, wenn kein Agent läuft", isOn: Binding(
                    get: { welcome.wrappedValue }, set: { welcome.wrappedValue = $0; AppModel.welcomeEnabled = $0 }))
                Button("Willkommensdialog jetzt öffnen") { model.showWelcome = true }
            }
            Section("Beenden") {
                Picker("Beim Schließen des Fensters", selection: Binding(get: { lastWindow.wrappedValue }, set: {
                    lastWindow.wrappedValue = $0
                    QuitPreferences.onLastWindow = $0
                })) {
                    ForEach(QuitPreferences.OnLastWindow.allCases) { Text($0.title).tag($0) }
                }
                Text("Laufende Agent-Sitzungen werden beim Beenden gestoppt; Claude Code und Codex lassen sich danach fortsetzen.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.cli != nil {
                    Picker("devkcode-Sandboxes beim Beenden", selection: Binding(get: { onQuit.wrappedValue }, set: {
                        onQuit.wrappedValue = $0
                        QuitPreferences.onQuit = $0
                    })) {
                        ForEach(QuitPreferences.OnQuit.allCases) { Text($0.title).tag($0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Agents

private struct AgentSettings: View {
    @Environment(AppModel.self) private var model
    private let installed = State(initialValue: [AgentKind: String]())
    private let loaded = State(initialValue: false)

    var body: some View {
        Form {
            Section {
                ForEach(AgentKind.allCases.filter { $0 != .shell }) { kind in
                    agentRow(kind)
                }
            } header: {
                Text("Agenten")
            } footer: {
                Text("Jeder Agent nutzt seinen eigenen Login (Claude-Abo, ChatGPT, GitHub …). „Anmelden“ startet den Login des Agenten in einer Sandbox.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Logins im Schlüsselbund") {
                Toggle("Agenten dürfen den Schlüsselbund verwenden", isOn: Binding(
                    get: { model.sandboxSettings.agentKeychain },
                    set: { on in model.updateSandboxSettings { $0.agentKeychain = on } }))
                Text("Claude Code, Codex und GitHub Copilot speichern ihren Login im macOS-Schlüsselbund. Ohne diese Freigabe müssen sie sich per API-Key anmelden (siehe Credentials).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("MCP-Server") {
                Text("MCP-Server richtest du im jeweiligen Agenten ein, z. B. `claude mcp add` oder in `~/.codex/config.toml`. Sie laufen in derselben Sandbox wie der Agent; zusätzliche Hosts gibst du unter „Sandbox“ frei.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section { RestartHint() }
        }
        .formStyle(.grouped)
        .task {
            guard !loaded.wrappedValue else { return }
            installed.wrappedValue = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: AgentKind.allCases.compactMap { k in SandboxManager.locate(k).map { (k, $0.path) } })
            }.value
            loaded.wrappedValue = true
        }
    }

    private func agentRow(_ kind: AgentKind) -> some View {
        let path = installed.wrappedValue[kind]
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol).frame(width: 20).foregroundStyle(path != nil ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.displayName).bold()
                if let path {
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                } else if loaded.wrappedValue {
                    HStack(spacing: 4) {
                        Text("Nicht installiert:").font(.caption).foregroundStyle(.secondary)
                        Text(kind.installHint).font(.caption.monospaced()).textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(kind.installHint, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).controlSize(.small).help("Befehl kopieren")
                    }
                } else {
                    ProgressView().controlSize(.mini)
                }
                if let config = kind.sandbox.readWrite.first {
                    Text("Einstellungen: \(config)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let config = kind.sandbox.readWrite.first {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + config.dropFirst())) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless).help("Einstellungsordner im Finder öffnen")
                .disabled(!FileManager.default.fileExists(atPath: NSHomeDirectory() + config.dropFirst()))
            }
            Button("Anmelden …") {
                model.startAgent(kind, directory: SandboxManager.loginDirectory.path,
                                 purpose: kind.loginArguments != nil ? .login : .session)
                NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true || $0.title == "Hearth IDE" }?.makeKeyAndOrderFront(nil)
            }
            .disabled(path == nil)
            .help(kind.loginHint)
        }
        .padding(.vertical, 2)
    }
}

// MARK: Sandbox rules

private struct SandboxRuleSettings: View {
    @Environment(AppModel.self) private var model
    private let domain = State(initialValue: "")
    private let port = State(initialValue: "")
    private let previewKind = State(initialValue: AgentKind.claude)
    private let error = State(initialValue: String?.none)

    var body: some View {
        Form {
            Section {
                Label("Schreiben nur im Ordner der Sitzung und im Einstellungsordner des Agenten", systemImage: "folder")
                Label("Gesperrt: SSH-Schlüssel, Shell-Konfiguration, Browserdaten, Cloud-Zugangsdaten, übriges Home", systemImage: "hand.raised")
                Label("Netzwerk: LLM-APIs, Paket-Registries, GitHub/GitLab, Doku und die API-Hosts des Agenten", systemImage: "network")
            } header: {
                Text("Grundregeln (immer aktiv)")
            }
            .font(.callout)

            Section {
                ForEach(model.sandboxSettings.domains, id: \.self) { d in
                    HStack {
                        Text(d).font(.callout.monospaced())
                        Spacer()
                        Button { model.updateSandboxSettings { $0.domains.removeAll { $0 == d } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Domain", text: domain.projectedValue,
                              prompt: Text(verbatim: "api.example.com, *.example.com oder https://github.com/org/**"))
                        .labelsHidden().onSubmit(addDomain)
                    Button("Hinzufügen", action: addDomain)
                        .disabled(!SandboxSettings.validDomain(domain.wrappedValue))
                }
            } header: {
                Text("Zusätzliche Domains")
            } footer: {
                Text("Gilt für alle Sitzungen, Build & Deployment und Git.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(model.sandboxSettings.ports, id: \.self) { p in
                    HStack {
                        Text(verbatim: String(p)).font(.callout.monospaced())
                        Spacer()
                        Button { model.updateSandboxSettings { $0.ports.removeAll { $0 == p } } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("Port", text: port.projectedValue, prompt: Text(verbatim: "8080"))
                        .labelsHidden().frame(width: 100).onSubmit(addPort)
                    Button("Hinzufügen", action: addPort).disabled(Int(port.wrappedValue).map { !(1...65535).contains($0) } ?? true)
                    Spacer()
                }
            } header: {
                Text("Lokale Ports")
            } footer: {
                Text("Ein Dienst in der Sandbox darf auf diesem Port lauschen und sich selbst erreichen (z. B. Spring-Boot-Tests). Build & Deployment gibt den Port eines Dienstes automatisch frei.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(model.sandboxSettings.folders) { f in
                    FolderRow(folder: f,
                              setWrite: { w in model.updateSandboxSettings { s in
                                  if let i = s.folders.firstIndex(where: { $0.path == f.path }) { s.folders[i].write = w } } },
                              remove: { model.updateSandboxSettings { $0.folders.removeAll { $0.path == f.path } } })
                }
                Button { addFolder() } label: { Label("Ordner hinzufügen …", systemImage: "plus") }
                if let error = error.wrappedValue { Text(error).font(.caption).foregroundStyle(.red) }
            } header: {
                Text("Zusätzliche Ordner für alle Sitzungen")
            } footer: {
                Text("Nur für einen Projektordner? Dann unter „Projekte“.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Git-Bereich") {
                Toggle("Fetch, Pull und Clone über SSH erlauben", isOn: Binding(
                    get: { model.sandboxSettings.gitSSH },
                    set: { on in model.updateSandboxSettings { $0.gitSSH = on } }))
                Text("Nur die festen Git-Befehle des Git-Bereichs (kein Agent) dürfen dann ~/.ssh lesen und Port 22 erreichen. Einstellungen wie sshCommand oder credential.helper kommen nur aus deiner globalen ~/.gitconfig, nie aus dem Repository.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Erzeugtes Profil ansehen") {
                HStack {
                    Picker("Agent", selection: previewKind.projectedValue) {
                        ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    Button("Anzeigen") { showProfile() }
                }
                Text("So startet Hearth nono für diesen Agenten (ohne projektbezogene Ordner).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section { RestartHint() }
        }
        .formStyle(.grouped)
    }

    private func addDomain() {
        let d = domain.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard SandboxSettings.validDomain(d) else { return }
        domain.wrappedValue = ""
        model.updateSandboxSettings { if !$0.domains.contains(d) { $0.domains.append(d) } }
    }

    private func addPort() {
        guard let p = Int(port.wrappedValue), (1...65535).contains(p) else { return }
        port.wrappedValue = ""
        model.updateSandboxSettings { if !$0.ports.contains(p) { $0.ports.append(p); $0.ports.sort() } }
    }

    private func addFolder() {
        guard let path = chooseFolder(message: "Ordner, den alle Sandboxes lesen dürfen (Schreiben kannst du danach freigeben)") else { return }
        if let problem = SandboxSettings.validFolder(path) { error.wrappedValue = problem; return }
        error.wrappedValue = nil
        model.updateSandboxSettings { if !$0.folders.contains(where: { $0.path == path }) { $0.folders.append(.init(path: path)) } }
    }

    private func showProfile() {
        let kind = previewKind.wrappedValue
        let profile = SandboxManager.profile(kind: kind, runDirectory: SandboxManager.runDirectory("<sitzung>"),
                                             settings: model.sandboxSettings)
        guard let data = try? JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = SandboxManager.supportDirectory.appendingPathComponent("profil-vorschau-\(kind.rawValue).json")
        try? FileManager.default.createDirectory(at: SandboxManager.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        NSWorkspace.shared.open(url)
    }
}

// MARK: Projects

private struct ProjectSettings: View {
    @Environment(AppModel.self) private var model
    private let selected = State(initialValue: String?.none)
    private let error = State(initialValue: String?.none)

    private var projects: [SandboxSettings.Project] { model.sandboxSettings.projects }
    private var project: SandboxSettings.Project? {
        projects.first { $0.root == selected.wrappedValue } ?? projects.first
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(projects, selection: selected.projectedValue) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name)
                        Text(p.root.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    .tag(p.root)
                }
                Divider()
                HStack {
                    Button { addProject() } label: { Image(systemName: "plus") }.help("Projektordner hinzufügen …")
                    Button { if let p = project { model.updateSandboxSettings { $0.projects.removeAll { $0.root == p.root } } } } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(project == nil).help("Projekt entfernen (die Ordner bleiben unverändert)")
                    Spacer()
                }
                .buttonStyle(.borderless).padding(6)
            }
            .frame(minWidth: 200, maxWidth: 240)

            Group {
                if let p = project {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(p.name).font(.title3.bold())
                            Spacer()
                            Button("Agent hier starten …") { model.agents.startSheet = .init(directory: p.root) }
                        }
                        LabeledContent("Projektordner (lesen + schreiben)") {
                            Text(p.root.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.head)
                        }
                        Text("Zusätzliche Ordner").font(.headline)
                        if p.folders.isEmpty {
                            Text("Noch keine. Beispiel: eine Bibliothek, die der Agent mitlesen soll.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(p.folders) { f in
                            FolderRow(folder: f,
                                      setWrite: { w in model.updateSandboxSettings { s in
                                          guard let pi = s.projects.firstIndex(where: { $0.root == p.root }),
                                                let fi = s.projects[pi].folders.firstIndex(where: { $0.path == f.path }) else { return }
                                          s.projects[pi].folders[fi].write = w } },
                                      remove: { model.updateSandboxSettings { s in
                                          guard let pi = s.projects.firstIndex(where: { $0.root == p.root }) else { return }
                                          s.projects[pi].folders.removeAll { $0.path == f.path } } })
                        }
                        Button { addFolder(to: p) } label: { Label("Ordner hinzufügen …", systemImage: "plus") }
                        if let error = error.wrappedValue { Text(error).font(.caption).foregroundStyle(.red) }
                        Spacer()
                        RestartHint(text: "Gilt für Sitzungen, die in genau diesem Ordner starten.")
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    ContentUnavailableView {
                        Label("Keine Projekte", systemImage: "folder.badge.gearshape")
                    } description: {
                        Text("Ein Projekt gibt Sitzungen in einem Ordner Zugriff auf weitere Ordner, z. B. ein Nachbar-Repository.")
                    } actions: {
                        Button("Projektordner hinzufügen …") { addProject() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380)
        }
    }

    private func addProject() {
        guard let path = chooseFolder(message: "Projektordner wählen (dort startest du die Agenten)") else { return }
        if let problem = SandboxSettings.validFolder(path) { error.wrappedValue = problem; return }
        error.wrappedValue = nil
        model.updateSandboxSettings { if $0.project(for: path) == nil { $0.projects.append(.init(root: path)) } }
        selected.wrappedValue = path
    }

    private func addFolder(to p: SandboxSettings.Project) {
        guard let path = chooseFolder(message: "Zusätzlicher Ordner für „\(p.name)“ (zunächst nur lesend)") else { return }
        if let problem = SandboxSettings.validFolder(path) { error.wrappedValue = problem; return }
        error.wrappedValue = nil
        model.updateSandboxSettings { s in
            guard let i = s.projects.firstIndex(where: { $0.root == p.root }),
                  !s.projects[i].folders.contains(where: { $0.path == path }) else { return }
            s.projects[i].folders.append(.init(path: path))
        }
    }
}

// MARK: Credentials

private struct CredentialSettings: View {
    @Environment(AppModel.self) private var model
    private let name = State(initialValue: "")
    private let mode = State(initialValue: SandboxSettings.Credential.Mode.proxy)
    private let upstream = State(initialValue: "")
    private let header = State(initialValue: "Authorization")
    private let format = State(initialValue: "Bearer {}")
    private let secret = State(initialValue: "")
    private let confirmDelete = State(initialValue: String?.none)
    private let changing = State(initialValue: String?.none)
    private let newSecret = State(initialValue: "")
    private let error = State(initialValue: String?.none)

    var body: some View {
        Form {
            Section {
                if model.sandboxSettings.credentials.isEmpty {
                    Text("Noch keine Credentials.").foregroundStyle(.secondary)
                }
                ForEach(model.sandboxSettings.credentials) { c in credentialRow(c) }
            } header: {
                Text("Credentials")
            } footer: {
                Text("Die Werte liegen im macOS-Schlüsselbund (Dienst „nono“), nicht in Hearth. nono liest sie beim Start einer Sandbox.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Hinzufügen") {
                TextField("Name", text: Binding(get: { name.wrappedValue }, set: { name.wrappedValue = $0.uppercased() }),
                          prompt: Text("z. B. GITHUB_TOKEN"))
                Picker("Art", selection: mode.projectedValue) {
                    Text("Proxy (empfohlen)").tag(SandboxSettings.Credential.Mode.proxy)
                    Text("Umgebungsvariable").tag(SandboxSettings.Credential.Mode.env)
                }
                .pickerStyle(.segmented)
                if mode.wrappedValue == .proxy {
                    TextField("Ziel-API", text: upstream.projectedValue, prompt: Text(verbatim: "https://api.example.com"))
                    TextField("Header", text: header.projectedValue)
                    TextField("Format ({} = Wert)", text: format.projectedValue)
                    Text("In der Sandbox enthält $\(displayName) nur einen Platzhalter. Anfragen an $\(displayName)_BASE_URL leitet nono an die Ziel-API weiter und setzt dort den echten Wert ein.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Der Wert steht im Klartext als $\(displayName) in der Sandbox – der Agent kann ihn lesen.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                SecureField("Wert", text: secret.projectedValue)
                HStack {
                    if let error = error.wrappedValue { Text(error).font(.caption).foregroundStyle(.red) }
                    Spacer()
                    Button("Hinzufügen") { add() }.disabled(!canAdd)
                }
            }
            Section { RestartHint() }
        }
        .formStyle(.grouped)
        .confirmationDialog("Credential „\(confirmDelete.wrappedValue ?? "")“ löschen?",
                            isPresented: Binding(get: { confirmDelete.wrappedValue != nil }, set: { if !$0 { confirmDelete.wrappedValue = nil } })) {
            Button("Löschen", role: .destructive) {
                guard let n = confirmDelete.wrappedValue,
                      let c = model.sandboxSettings.credentials.first(where: { $0.name == n }) else { return }
                CredentialKeychain.delete(account: c.keychainAccount)
                model.updateSandboxSettings { $0.credentials.removeAll { $0.name == n } }
            }
        } message: { Text("Der Wert wird auch aus dem Schlüsselbund entfernt.") }
        .alert("Neuer Wert für \(changing.wrappedValue ?? "")", isPresented: Binding(
            get: { changing.wrappedValue != nil }, set: { if !$0 { changing.wrappedValue = nil; newSecret.wrappedValue = "" } })) {
            SecureField("Wert", text: newSecret.projectedValue)
            Button("Speichern") {
                if let n = changing.wrappedValue, let c = model.sandboxSettings.credentials.first(where: { $0.name == n }),
                   !newSecret.wrappedValue.isEmpty {
                    if !CredentialKeychain.store(newSecret.wrappedValue, account: c.keychainAccount) {
                        model.banner = "Wert konnte nicht im Schlüsselbund gespeichert werden."
                    }
                }
                newSecret.wrappedValue = ""
            }
            Button("Abbrechen", role: .cancel) { newSecret.wrappedValue = "" }
        }
    }

    private var displayName: String { name.wrappedValue.isEmpty ? "NAME" : name.wrappedValue }

    private var canAdd: Bool {
        SandboxSettings.Credential.validName(name.wrappedValue) && !secret.wrappedValue.isEmpty
            && !model.sandboxSettings.credentials.contains { $0.name == name.wrappedValue }
            && (mode.wrappedValue == .env || URL(string: upstream.wrappedValue)?.scheme == "https")
    }

    private func credentialRow(_ c: SandboxSettings.Credential) -> some View {
        let stored = CredentialKeychain.exists(account: c.keychainAccount)
        return HStack {
            Image(systemName: stored ? "key.fill" : "key.slash").foregroundStyle(stored ? Color.secondary : Color.red)
                .help(stored ? "Wert im Schlüsselbund" : "Kein Wert im Schlüsselbund")
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(c.name).bold().font(.callout.monospaced())
                    Text(c.mode == .proxy ? "Proxy" : "Umgebung").font(.caption2).padding(.horizontal, 5)
                        .background((c.mode == .env ? Color.orange : Color.green).opacity(0.15), in: Capsule())
                        .help(c.mode == .env ? "Wert steht im Klartext in der Sandbox" : "Die Sandbox sieht nur einen Platzhalter")
                }
                if c.mode == .proxy {
                    Text("→ \(c.upstream)  ·  \(c.header): \(c.format.replacingOccurrences(of: "{}", with: "…"))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { c.enabled }, set: { on in
                model.updateSandboxSettings { s in if let i = s.credentials.firstIndex(where: { $0.name == c.name }) { s.credentials[i].enabled = on } }
            }))
            .toggleStyle(.switch).labelsHidden().help("In Sandboxes verwenden")
            Button("Wert ändern …") { changing.wrappedValue = c.name }.controlSize(.small)
            Button { confirmDelete.wrappedValue = c.name } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }

    private func add() {
        var c = SandboxSettings.Credential(name: name.wrappedValue, mode: mode.wrappedValue)
        if c.mode == .proxy {
            c.upstream = upstream.wrappedValue.trimmingCharacters(in: .whitespaces)
            c.header = header.wrappedValue.isEmpty ? "Authorization" : header.wrappedValue
            c.format = format.wrappedValue.contains("{}") ? format.wrappedValue : "{}"
        }
        guard CredentialKeychain.store(secret.wrappedValue, account: c.keychainAccount) else {
            error.wrappedValue = "Wert konnte nicht im Schlüsselbund gespeichert werden."
            return
        }
        error.wrappedValue = nil
        model.updateSandboxSettings { $0.credentials.append(c) }
        name.wrappedValue = ""; upstream.wrappedValue = ""; secret.wrappedValue = ""
    }
}

/// Each settings tab on its own, for the offscreen snapshot developer aid.
enum SettingsSnapshot {
    @MainActor static var tabs: [(String, AnyView)] {
        [("general", AnyView(GeneralSettings())), ("agents", AnyView(AgentSettings())),
         ("sandbox", AnyView(SandboxRuleSettings())), ("projects", AnyView(ProjectSettings())),
         ("credentials", AnyView(CredentialSettings()))]
    }
}
