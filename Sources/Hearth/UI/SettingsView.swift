import SwiftUI
import AppKit

/// Dashboard features of `devkcode dashboard`, backed by the devkcode CLI.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Allgemein", systemImage: "gearshape") }
            UpdateSettings(checker: model.updates).tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            ProjectSettings().tabItem { Label("Projekte", systemImage: "folder.badge.gearshape") }
            NetworkSettings().tabItem { Label("Netzwerk", systemImage: "network") }
            MCPSettings().tabItem { Label("MCP", systemImage: "puzzlepiece.extension") }
            CredentialSettings().tabItem { Label("Credentials", systemImage: "key") }
        }
        .frame(width: 680, height: 500)
        .task {
            model.reloadDevkConfig()
            await model.loadProfiles()
        }
    }
}

/// Hint shown after changes that only apply to newly started sandboxes.
private struct RestartHint: View {
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        HStack {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !model.servers.isEmpty {
                Button("Laufende Sandboxes neu starten (\(model.servers.count))") {
                    Task { await model.restartAllSandboxes() }
                }
                .controlSize(.small)
                .help("Beendet laufende Agent-Arbeit in allen Sandboxes")
            }
        }
    }
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
            Section("Standardprofil (devkcode profile)") {
                if model.profiles.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Lade Profile …") }
                }
                ForEach(model.profiles) { p in
                    HStack(alignment: .top) {
                        Image(systemName: model.devkConfig.activeProfile == p.name ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(model.devkConfig.activeProfile == p.name ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack { Text(p.name).bold(); ProfileBadge(name: p.name) }
                            if let d = p.description { Text(d).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                    }
                    .interactiveRow(selected: model.devkConfig.activeProfile == p.name) {
                        Task { await model.devk(["profile", p.name], success: "Standardprofil: \(p.name)") }
                    }
                }
                Text("Gilt für neu gestartete Sandboxes ohne explizites Profil.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Terminal für „Im Terminal öffnen“") {
                Picker("Terminal", selection: Binding(get: { terminal.wrappedValue }, set: {
                    terminal.wrappedValue = $0
                    TerminalLauncher.preferred = $0
                })) {
                    ForEach(TerminalLauncher.installed) { Text($0.rawValue).tag($0) }
                }
            }
            Section("Layout") {
                Button("Inspector-Layout zurücksetzen") { model.resetLayout() }
            }
            Section("Start") {
                Toggle("Willkommensdialog anzeigen, wenn keine Sandbox läuft", isOn: Binding(
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
                Picker("Laufende Sandboxes beim Beenden", selection: Binding(get: { onQuit.wrappedValue }, set: {
                    onQuit.wrappedValue = $0
                    QuitPreferences.onQuit = $0
                })) {
                    ForEach(QuitPreferences.OnQuit.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Projects

private struct ProjectSettings: View {
    @Environment(AppModel.self) private var model
    private let selected = State(initialValue: String?.none)
    private let newName = State(initialValue: "")
    private let renameTo = State(initialValue: "")
    private let renaming = State(initialValue: false)
    private let confirmDelete = State(initialValue: false)

    private var project: DevkProject? {
        model.devkConfig.projects.first { $0.name == selected.wrappedValue } ?? model.devkConfig.projects.first
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(model.devkConfig.projects, selection: selected.projectedValue) { p in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name)
                        Text(URL(fileURLWithPath: p.root).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(p.name)
                }
                Divider()
                HStack {
                    Button { register() } label: { Image(systemName: "plus") }.help("Projekt registrieren …")
                    Button { confirmDelete.wrappedValue = true } label: { Image(systemName: "minus") }
                        .disabled(project == nil).help("Projekt entfernen")
                    Spacer()
                }
                .buttonStyle(.borderless).padding(6)
            }
            .frame(minWidth: 180, maxWidth: 220)

            if let p = project {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(p.name).font(.title3.bold())
                        Button { renameTo.wrappedValue = p.name; renaming.wrappedValue = true } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless)
                        Spacer()
                        Button("Starten …") { model.startRequest = .init(root: p.root, project: p.name, profile: nil) }
                    }
                    LabeledContent("Wurzel (r+w)") { Text(p.root).textSelection(.enabled).lineLimit(1).truncationMode(.head) }
                    Text("Zusätzliche Verzeichnisse").font(.headline)
                    ForEach(p.extraDirs, id: \.path) { d in
                        HStack {
                            Image(systemName: "folder")
                            Text(d.path).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Picker("", selection: Binding(get: { d.write }, set: { w in setWrite(p, d, w) })) {
                                Text("lesen").tag(false)
                                Text("lesen+schreiben").tag(true)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                            Button { Task { await model.devk(["project", "remove-dir", p.name, d.path]) } } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button { addDir(p) } label: { Label("Verzeichnis hinzufügen …", systemImage: "plus") }
                    Spacer()
                    RestartHint(text: "Freigaben wirken beim nächsten Start der Sandbox.")
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .confirmationDialog("Projekt „\(p.name)“ entfernen?", isPresented: confirmDelete.projectedValue) {
                    Button("Entfernen", role: .destructive) { Task { await model.devk(["project", "unregister", p.name]) } }
                } message: { Text("Die Verzeichnisse selbst bleiben unverändert.") }
                .alert("Projekt umbenennen", isPresented: renaming.projectedValue) {
                    TextField("Name", text: renameTo.projectedValue)
                    Button("Umbenennen") {
                        Task {
                            if await model.devk(["project", "rename", p.name, renameTo.wrappedValue]) {
                                selected.wrappedValue = renameTo.wrappedValue
                            }
                        }
                    }
                    Button("Abbrechen", role: .cancel) {}
                }
            } else {
                ContentUnavailableView("Keine Projekte", systemImage: "folder.badge.gearshape",
                                       description: Text("Ein Projekt gibt einer Sandbox Zugriff auf weitere Verzeichnisse."))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func register() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Wurzelverzeichnis des Projekts wählen"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.lastPathComponent
        Task {
            if await model.devk(["project", "register", name], in: url.path) { selected.wrappedValue = name }
        }
    }

    private func addDir(_ p: DevkProject) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Zusätzliches Verzeichnis für „\(p.name)“ (zunächst nur lesend)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.devk(["project", "add-dir", p.name, url.path]) }
    }

    private func setWrite(_ p: DevkProject, _ d: DevkProject.Dir, _ write: Bool) {
        guard write != d.write else { return }
        Task {
            guard await model.devk(["project", "remove-dir", p.name, d.path], success: "") else { return }
            await model.devk(["project", "add-dir", p.name, d.path] + (write ? ["--write"] : []),
                             success: write ? "Schreibzugriff erteilt" : "Nur noch lesend")
        }
    }
}

// MARK: Network

private struct NetworkSettings: View {
    @Environment(AppModel.self) private var model
    private let domain = State(initialValue: "")
    private let port = State(initialValue: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                GroupBox("Erlaubte Domains (allow-domain)") {
                    VStack(alignment: .leading) {
                        List(model.devkConfig.allowDomains, id: \.self) { d in
                            HStack {
                                Text(d).font(.callout.monospaced())
                                Spacer()
                                Button { Task { await model.devk(["allow-domain", "remove", d]) } } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("z. B. api.example.com oder https://github.com/org/**", text: domain.projectedValue)
                                .onSubmit(addDomain)
                            Button("Hinzufügen", action: addDomain).disabled(domain.wrappedValue.isEmpty)
                        }
                    }
                }
                GroupBox("Listen-Ports (allow-port)") {
                    VStack(alignment: .leading) {
                        List(model.devkConfig.openPorts, id: \.self) { p in
                            HStack {
                                Text("\(p)").font(.callout.monospaced())
                                Spacer()
                                Button { Task { await model.devk(["allow-port", "remove", "\(p)"]) } } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        HStack {
                            TextField("Port", text: port.projectedValue).frame(width: 80).onSubmit(addPort)
                            Button("Hinzufügen", action: addPort).disabled(Int(port.wrappedValue) == nil)
                        }
                    }
                }
                .frame(width: 220)
            }
            Text("Persönliche, lokale Ausnahmen zusätzlich zu den Team-Regeln des Profils. Sie gelten für alle Profile.")
                .font(.caption).foregroundStyle(.secondary)
            RestartHint(text: "Netzwerkregeln liest nono nur beim Start.")
        }
        .padding()
    }

    private func addDomain() {
        let d = domain.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty else { return }
        domain.wrappedValue = ""
        Task { await model.devk(["allow-domain", "add", d]) }
    }

    private func addPort() {
        guard let p = Int(port.wrappedValue) else { return }
        port.wrappedValue = ""
        Task { await model.devk(["allow-port", "add", "\(p)"]) }
    }
}

// MARK: MCP

private struct MCPSettings: View {
    @Environment(AppModel.self) private var model
    private let name = State(initialValue: "")
    private let remote = State(initialValue: false)
    private let target = State(initialValue: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.devkConfig.mcpServers.isEmpty {
                ContentUnavailableView("Keine persönlichen MCP-Server", systemImage: "puzzlepiece.extension")
                    .frame(maxHeight: 180)
            } else {
                List(model.devkConfig.mcpServers) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(s.name).bold()
                                Text(s.type).font(.caption2).padding(.horizontal, 4).background(Color.primary.opacity(0.08), in: Capsule())
                            }
                            Text(s.url ?? s.command ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { s.enabled }, set: { on in
                            Task { await model.devk(["mcp", on ? "enable" : "disable", s.name]) }
                        }))
                        .toggleStyle(.switch).labelsHidden()
                        Button { Task { await model.devk(["mcp", "remove", s.name]) } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            GroupBox("Server hinzufügen") {
                VStack(alignment: .leading) {
                    HStack {
                        TextField("Name", text: name.projectedValue).frame(width: 140)
                        Picker("", selection: remote.projectedValue) {
                            Text("lokal (Befehl)").tag(false)
                            Text("remote (URL)").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    HStack {
                        TextField(remote.wrappedValue ? "https://mcp.example.com/mcp" : "npx -y some-mcp-server", text: target.projectedValue)
                        Button("Hinzufügen") { add() }
                            .disabled(name.wrappedValue.isEmpty || target.wrappedValue.isEmpty)
                    }
                    Text("Header, Umgebungsvariablen und OAuth weiterhin per CLI (`devkcode mcp add --help`).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            }
            Spacer()
            RestartHint(text: "MCP-Änderungen wirken beim nächsten Start.")
        }
        .padding()
    }

    private func add() {
        let args = remote.wrappedValue
            ? ["mcp", "add", name.wrappedValue, "--type", "remote", "--url", target.wrappedValue]
            : ["mcp", "add", name.wrappedValue, "--type", "local", "--command", target.wrappedValue]
        Task {
            if await model.devk(args) { name.wrappedValue = ""; target.wrappedValue = "" }
        }
    }
}

// MARK: Credentials

private struct CredentialSettings: View {
    @Environment(AppModel.self) private var model
    private let name = State(initialValue: "")
    private let proxy = State(initialValue: true)
    private let upstream = State(initialValue: "")
    private let confirmDelete = State(initialValue: String?.none)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(model.devkConfig.credentials) { c in
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(c.name).bold().font(.callout.monospaced())
                            Text(c.mode).font(.caption2).padding(.horizontal, 4)
                                .background((c.mode == "env" ? Color.orange : Color.green).opacity(0.15), in: Capsule())
                                .help(c.mode == "env" ? "Wert liegt im Klartext in der Sandbox" : "Wert verlässt den Host nie (Proxy-Injektion)")
                        }
                        Text([c.description, c.upstream.map { "→ \($0)" }].compactMap { $0 }.joined(separator: "  "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Wert ändern …") { model.openCredentialSetup(["credential", "update", c.name]) }
                        .controlSize(.small)
                    Button { confirmDelete.wrappedValue = c.name } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            GroupBox("Credential hinzufügen") {
                VStack(alignment: .leading) {
                    HStack {
                        TextField("NAME (z. B. CONFLUENCE)", text: name.projectedValue).frame(width: 200)
                        Picker("", selection: proxy.projectedValue) {
                            Text("http-proxy (empfohlen)").tag(true)
                            Text("env").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    if proxy.wrappedValue {
                        TextField("Upstream, z. B. https://api.example.com", text: upstream.projectedValue)
                    } else {
                        Label("env: Der Wert landet im Klartext als Umgebungsvariable in der Sandbox.", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Text("Der geheime Wert wird im Terminal eingegeben und läuft nie durch diese App.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Im Terminal anlegen …") { add() }
                            .disabled(name.wrappedValue.isEmpty || (proxy.wrappedValue && upstream.wrappedValue.isEmpty))
                    }
                }
                .padding(4)
            }
            HStack {
                Button("Neu laden") { model.reloadDevkConfig() }
                Spacer()
            }
            RestartHint(text: "Credentials wirken beim nächsten Start.")
        }
        .padding()
        .confirmationDialog("Credential „\(confirmDelete.wrappedValue ?? "")“ löschen?",
                            isPresented: Binding(get: { confirmDelete.wrappedValue != nil }, set: { if !$0 { confirmDelete.wrappedValue = nil } })) {
            Button("Löschen", role: .destructive) {
                if let n = confirmDelete.wrappedValue { Task { await model.devk(["credential", "remove", n]) } }
            }
        }
    }

    private func add() {
        var args = ["credential", "add", name.wrappedValue.uppercased()]
        if proxy.wrappedValue { args += ["--mode", "http-proxy", "--upstream", upstream.wrappedValue] }
        model.openCredentialSetup(args)
    }
}
