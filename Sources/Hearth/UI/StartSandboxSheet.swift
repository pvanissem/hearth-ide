import SwiftUI
import AppKit

/// Colored capsule showing which devkcode Contract profile a sandbox runs with.
struct ProfileBadge: View {
    @Environment(\.textScale) private var scale
    let name: String?

    static func color(_ name: String?) -> Color {
        switch name {
        case "secure-mode": .green
        case "qa-agent": .purple
        case "devk-helpers": .blue
        case "devk-default", nil: .gray
        default: .orange
        }
    }

    var body: some View {
        Text(name ?? "Standard")
            .font(.system(size: 9 * scale, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(Self.color(name))
            .background(Self.color(name).opacity(0.14), in: Capsule())
            .help("Contract-Profil: \(name ?? "aktives Standardprofil")")
    }
}

/// Start a sandbox for a folder or registered project with a chosen profile.
struct StartSandboxSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AppModel.StartRequest

    private let root: State<String>
    private let project: State<String?>
    private let profile: State<String?>

    enum Source: String, CaseIterable { case existing = "Vorhandenes Verzeichnis", clone = "Git-Repository klonen" }
    private let source = State(initialValue: Source.existing)
    private let cloneURL = State(initialValue: "")
    private let parentDir = State(initialValue: StartSandboxSheet.defaultParent)
    private let folderName = State(initialValue: "")
    private let folderEdited = State(initialValue: false)
    private let cloneStatus = State(initialValue: String?.none)
    private let cloneFraction = State(initialValue: Double?.none)
    private let cloneError = State(initialValue: String?.none)

    static var defaultParent: String {
        let ideaProjects = NSHomeDirectory() + "/IdeaProjects"
        return FileManager.default.fileExists(atPath: ideaProjects) ? ideaProjects : NSHomeDirectory()
    }

    private var cloneDestination: URL {
        URL(fileURLWithPath: parentDir.wrappedValue).appendingPathComponent(folderName.wrappedValue)
    }

    /// Why the clone can't start yet (nil = ready).
    private var cloneProblem: String? {
        let url = cloneURL.wrappedValue
        if url.isEmpty { return nil }
        if !Git.looksLikeCloneURL(url) { return "Keine gültige Git-URL (z. B. git@github.com:user/repo.git)." }
        if folderName.wrappedValue.isEmpty || [".", ".."].contains(folderName.wrappedValue) || folderName.wrappedValue.contains("/") { return "Ungültiger Ordnername." }
        let parentPath = URL(fileURLWithPath: parentDir.wrappedValue).resolvingSymlinksInPath().path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        if parentPath != homePath && !parentPath.hasPrefix(homePath + "/") { return "Der Zielordner muss unterhalb deines Benutzerordners liegen (devkcode-Sandbox)." }
        let canonicalParent = cloneDestination.deletingLastPathComponent().resolvingSymlinksInPath()
        let reserved = canonicalParent.appendingPathComponent(cloneDestination.lastPathComponent).path
        if FileManager.default.fileExists(atPath: cloneDestination.path), !model.cloneDirectories.contains(reserved) { return "\(cloneDestination.path) existiert bereits." }
        return nil
    }

    private var cloning: Bool { cloneStatus.wrappedValue != nil }

    init(request: AppModel.StartRequest) {
        self.request = request
        root = State(initialValue: request.root ?? "")
        project = State(initialValue: request.project)
        profile = State(initialValue: request.profile)
    }

    private var projectsForRoot: [DevkProject] {
        model.devkConfig.projects.filter { $0.root == root.wrappedValue }
    }

    private var knownRoots: [String] {
        var roots = Set(model.entries.map(\.repoRoot))
        model.devkConfig.projects.forEach { roots.insert($0.root) }
        return roots.sorted { URL(fileURLWithPath: $0).lastPathComponent.lowercased() < URL(fileURLWithPath: $1).lastPathComponent.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sandbox starten").font(.title2.bold())

            Picker("", selection: source.projectedValue) {
                ForEach(Source.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(cloning)

            if source.wrappedValue == .existing {
                GroupBox("Verzeichnis") {
                    HStack {
                        Menu {
                            ForEach(knownRoots, id: \.self) { r in
                                Button(URL(fileURLWithPath: r).lastPathComponent) { setRoot(r) }
                            }
                        } label: {
                            Text(root.wrappedValue.isEmpty ? "Bekanntes Repo wählen …" : root.wrappedValue)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Button("Ordner …") { pickFolder() }
                    }
                    .padding(4)
                }
            } else {
                cloneSection
            }

            GroupBox("Profil") {
                VStack(alignment: .leading, spacing: 4) {
                    profileRow(nil, "Aktives Standardprofil (\(model.devkConfig.activeProfile ?? "devk-default"))", nil)
                    ForEach(model.profiles) { p in profileRow(p.name, p.name, p.description) }
                    if model.profiles.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Profile werden geladen …").font(.caption) }
                    }
                }
                .padding(4)
            }

            if source.wrappedValue == .existing {
            GroupBox("Projekt (zusätzliche Verzeichnisse)") {
                VStack(alignment: .leading, spacing: 4) {
                    if projectsForRoot.isEmpty {
                        Text("Für dieses Verzeichnis ist kein Projekt registriert.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("", selection: project.projectedValue) {
                            Text("Ohne Projekt-Freigaben").tag(String?.none)
                            ForEach(projectsForRoot) { p in
                                Text("\(p.name) (+\(p.extraDirs.count) Verz.)").tag(Optional(p.name))
                            }
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                    }
                }
                .padding(4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }

            if let running = model.servers.values.first(where: { $0.entry.repoRoot == root.wrappedValue }) {
                Label("Läuft bereits mit Profil \(running.entry.profileName ?? "?"). Eine Änderung startet die Sandbox neu und beendet laufende Agent-Arbeit.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .disabled(cloning)
                if source.wrappedValue == .existing {
                    Button("Starten") {
                        let r = root.wrappedValue, pj = project.wrappedValue, pf = profile.wrappedValue
                        dismiss()
                        Task { await model.startSandbox(root: r, project: pj, profile: pf) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(root.wrappedValue.isEmpty)
                } else {
                    Button("Klonen & starten") { Task { await cloneAndStart() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(cloning || cloneURL.wrappedValue.isEmpty || cloneProblem != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await model.loadProfiles() }
    }

    // MARK: Clone

    private var cloneSection: some View {
        GroupBox("Repository") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("git@github.com:user/repo.git oder https://…", text: Binding(
                    get: { cloneURL.wrappedValue },
                    set: { url in
                        cloneURL.wrappedValue = url
                        cloneError.wrappedValue = nil
                        if !folderEdited.wrappedValue { folderName.wrappedValue = Git.repoName(from: url) }
                    }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(cloning)
                HStack(spacing: 6) {
                    Text("Ziel:").foregroundStyle(.secondary)
                    Button(parentDir.wrappedValue.replacingOccurrences(of: NSHomeDirectory(), with: "~")) { pickParent() }
                        .disabled(cloning)
                    Text("/").foregroundStyle(.secondary)
                    TextField("ordner", text: Binding(get: { folderName.wrappedValue }, set: {
                        folderName.wrappedValue = $0
                        folderEdited.wrappedValue = true
                    }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .disabled(cloning)
                }
                if let status = cloneStatus.wrappedValue {
                    VStack(alignment: .leading, spacing: 4) {
                        if let f = cloneFraction.wrappedValue {
                            ProgressView(value: f)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        Text(status).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let problem = cloneError.wrappedValue ?? cloneProblem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Zuerst startet eine devkcode-Sandbox im neuen Zielordner. Darin wird direkt geklont – mit deren Netzwerk- und Git-Zugang, ohne Agenten-Prompt oder Host-Fallback. Für GitLab ggf. vorher devkcode gitlab login ausführen.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    private func pickParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: parentDir.wrappedValue)
        panel.prompt = "Als Zielordner wählen"
        if panel.runModal() == .OK, let url = panel.url { parentDir.wrappedValue = url.path }
    }

    private func cloneAndStart() async {
        let url = cloneURL.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let dest = cloneDestination
        cloneError.wrappedValue = nil
        cloneStatus.wrappedValue = "Verbinde …"
        cloneFraction.wrappedValue = nil
        let result = await model.cloneRepository(url, to: dest, profile: profile.wrappedValue) { line, fraction in
            Task { @MainActor in
                cloneStatus.wrappedValue = line
                if let fraction { cloneFraction.wrappedValue = fraction }
            }
        }
        cloneStatus.wrappedValue = nil
        guard result.ok else {
            cloneError.wrappedValue = "Klonen fehlgeschlagen: " + (result.output.isEmpty ? "unbekannter Fehler" : result.output)
            return
        }
        dismiss()
        model.toast("\(dest.lastPathComponent) geklont")
    }

    private func profileRow(_ value: String?, _ title: String, _ description: String?) -> some View {
        let selected = profile.wrappedValue == value
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                    if let value { ProfileBadge(name: value) }
                }
                if let description { Text(description).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .interactiveRow(selected: selected) { profile.wrappedValue = value }
    }

    private func setRoot(_ r: String) {
        root.wrappedValue = r
        let projects = model.devkConfig.projects.filter { $0.root == r }
        project.wrappedValue = model.devkConfig.rememberedProjects[r] ?? (projects.count == 1 ? projects[0].name : nil)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { setRoot(url.path) }
    }
}
