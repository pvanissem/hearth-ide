import SwiftUI
import AppKit

struct InboxView: View {
    @Environment(AppModel.self) private var model
    private let showStopped = State(initialValue: false)
    private let showAllSessions = State(initialValue: Set<String>())
    private let onlyAttention = State(initialValue: false)

    private static let recentLimit = 5

    var body: some View {
        let attention = model.inbox.filter { $0.status.priority <= AgentStatus.done.priority }
        let attentionIDs = Set(attention.map(\.id))

        List(selection: Binding(
            get: { model.selectedSessionID },
            set: { id in
                if let item = model.inbox.first(where: { $0.id == id }) { model.select(item) }
            })) {
            Section(isExpanded: Binding(get: { model.sessionListDisclosure.attentionExpanded },
                                        set: { model.sessionListDisclosure.attentionExpanded = $0 })) {
                if attention.isEmpty {
                    Text("Alles ruhig – kein Agent wartet.").foregroundStyle(.secondary).scaledFont(.callout)
                }
                if !attention.isEmpty {
                    Text("\(attention.count) Sessions mit Aktivität, Ergebnissen, Rückfragen oder Fehlern.")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
                if !attention.isEmpty || onlyAttention.wrappedValue {
                    Button(onlyAttention.wrappedValue ? "Alle Sessions anzeigen" : "Nur diese Sessions anzeigen") {
                        onlyAttention.wrappedValue.toggle()
                    }
                    .buttonStyle(.link).scaledFont(.caption)
                }
            } header: {
                Text("Braucht Aufmerksamkeit (\(attention.count))\(onlyAttention.wrappedValue ? " · Filter aktiv" : "")").scaledFont(.caption, bold: true)
            }

            ForEach(runningServers) { conn in
                let all = conn.sessions.values.filter { !onlyAttention.wrappedValue || attentionIDs.contains($0.id) }
                    .sorted {
                        if $0.status.priority != $1.status.priority { return $0.status.priority < $1.status.priority }
                        if $0.updated != $1.updated { return $0.updated > $1.updated }
                        return $0.id < $1.id
                    }
                let key = SessionListDisclosure.key(root: conn.entry.repoRoot, project: conn.entry.projectName)
                let showingAll = showAllSessions.wrappedValue.contains(conn.id)
                let shown = showingAll ? all : SessionListDisclosure.preview(all, limit: Self.recentLimit, selectedID: model.selectedSessionID)
                if !onlyAttention.wrappedValue || !all.isEmpty {
                    Section(isExpanded: Binding(get: { model.sessionListDisclosure.isExpanded(key) },
                                                set: { model.sessionListDisclosure.setExpanded($0, for: key) })) {
                        ForEach(shown) {
                            SessionRow(item: $0, showSandbox: false).tag($0.id)
                        }
                        if showingAll ? all.count > Self.recentLimit : shown.count < all.count {
                            Button(showingAll ? "Weniger anzeigen" : "Alle \(all.count) anzeigen") {
                                if showingAll { showAllSessions.wrappedValue.remove(conn.id) }
                                else { showAllSessions.wrappedValue.insert(conn.id) }
                            }
                            .buttonStyle(.link).scaledFont(.caption)
                        }
                    } header: {
                        SandboxHeader(conn: conn, expand: { model.sessionListDisclosure.setExpanded(true, for: key) })
                    }
                }
            }

            let inactive = model.inactiveSandboxes
            if !inactive.isEmpty {
                Section {
                    DisclosureGroup("Weitere Sandboxes (\(inactive.count))", isExpanded: showStopped.projectedValue) {
                        ForEach(inactive) { row in
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(row.name).foregroundStyle(.secondary).lineLimit(1)
                                        ProfileBadge(name: row.profile)
                                    }
                                    HStack(spacing: 4) {
                                        switch row.state {
                                        case .terminal:
                                            Label("läuft im Terminal", systemImage: "terminal").foregroundStyle(.green)
                                        case .orphaned:
                                            Label("verwaist", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                                                .help("Als laufend eingetragen, der Prozess existiert aber nicht mehr (wie „orphaned“ im Dashboard).")
                                        case .stopped:
                                            EmptyView()
                                        }
                                        if let project = row.project { Text("Projekt \(project)") }
                                        if let d = row.lastStarted { Text(d.formatted(.relative(presentation: .named))) }
                                    }
                                    .scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Starten") {
                                    Task { await model.startSandbox(root: row.root, project: row.project, profile: row.profile) }
                                }
                                .controlSize(.small).disabled(model.busy)
                                .help("In Hearth IDE starten (devkcode web) mit Profil \(row.profile ?? "Standard")")
                                Button { model.startRequest = .init(root: row.root, project: row.project, profile: row.profile) } label: {
                                    Image(systemName: "slider.horizontal.3")
                                }
                                .buttonStyle(.borderless).help("Mit anderem Profil/Projekt starten …")
                            }
                            .contextMenu {
                                Button { Task { await model.startSandbox(root: row.root, project: row.project, profile: row.profile) } } label: {
                                    Label("Starten", systemImage: "play")
                                }
                                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: row.root) } label: {
                                    Label("Im Finder zeigen", systemImage: "folder")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    model.forgetRequest = .init(root: row.root, project: row.project, name: row.name,
                                                                running: false, inTerminal: row.state == .terminal)
                                } label: { Label("Aus Liste entfernen …", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Opaque like every other pane; the sidebar style alone draws a translucent vibrancy material.
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .confirmationDialog("„\(model.forgetRequest?.name ?? "")“ aus der Liste entfernen?",
                            isPresented: Binding(get: { model.forgetRequest != nil }, set: { if !$0 { model.forgetRequest = nil } }),
                            presenting: model.forgetRequest) { req in
            Button(req.running ? "Stoppen und entfernen" : "Entfernen", role: .destructive) {
                Task { await model.forgetSandbox(root: req.root, project: req.project, name: req.name) }
            }
        } message: { req in
            Text((req.running ? "Die Sandbox wird gestoppt, laufende Agent-Arbeit bricht ab. " : "")
                 + (req.inTerminal ? "Die Terminal-Sitzung (devkcode run) läuft weiter, sie wird nur nicht mehr gelistet. " : "")
                 + "Entfernt wird nur der Eintrag in devkcodes Liste (wie „d“ im Dashboard) – Repository, Dateien und Sessions bleiben erhalten. Beim nächsten Start ist die Sandbox wieder da.")
        }
    }

    private var runningServers: [ServerConnection] {
        model.servers.values.sorted { $0.entry.displayName < $1.entry.displayName }
    }
}

struct SandboxHeader: View {
    @Environment(AppModel.self) private var model
    let conn: ServerConnection
    var expand: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(conn.connected ? .green : .orange).frame(width: 7, height: 7)
                .help(conn.error ?? "verbunden")
            Text(conn.entry.displayName).scaledFont(.headline).lineLimit(1).truncationMode(.middle)
            Text("(\(conn.sessions.count))").scaledFont(.caption).foregroundStyle(.secondary)
            if conn.sessions.values.contains(where: { $0.status == .needsInput || $0.status == .blocked }) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    .help("Diese Sandbox enthält Rückfragen oder Fehler – auch im zugeklappten Zustand.")
            }
            ProfileBadge(name: conn.entry.profileName)
            Spacer()
            Button {
                let generation = model.chatViewGeneration
                expand()
                Task { await model.newSession(on: conn.id, expectedGeneration: generation) }
            } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless).help("Neue Session")
            Menu {
                Button("Workspace anzeigen") { model.selectSandbox(conn.id) }
                Button("Profil/Projekt wechseln …") {
                    model.startRequest = .init(root: conn.entry.repoRoot, project: conn.entry.projectName, profile: conn.entry.profileName)
                }
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: conn.entry.repoRoot)
                }
                Divider()
                Button("Sandbox stoppen", role: .destructive) { Task { await model.stop(entry: conn.entry) } }
                Button("Stoppen und aus Liste entfernen …", role: .destructive) {
                    model.forgetRequest = .init(root: conn.entry.repoRoot, project: conn.entry.projectName,
                                                name: conn.entry.displayName, running: true, inTerminal: false)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .textCase(nil)
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let item: SessionItem
    let showSandbox: Bool
    private let confirmDelete = State(initialValue: false)
    private let renaming = State(initialValue: false)
    private let newTitle = State(initialValue: "")

    var body: some View {
        rowContent
            .contextMenu {
                if item.status == .running || item.status == .needsInput {
                    Button { Task { await model.perform(.stop, on: item) } } label: {
                        Label("Agent stoppen", systemImage: "stop.circle")
                    }
                }
                Button {
                    newTitle.wrappedValue = item.title
                    renaming.wrappedValue = true
                } label: { Label("Umbenennen …", systemImage: "pencil") }
                Button { model.openInTerminal(item) } label: { Label("Im Terminal öffnen", systemImage: "terminal") }
                Divider()
                Button { Task { await model.perform(.archive, on: item) } } label: {
                    Label("Archivieren", systemImage: "archivebox")
                }
                Button(role: .destructive) { confirmDelete.wrappedValue = true } label: {
                    Label("Löschen …", systemImage: "trash")
                }
            }
            .confirmationDialog("Session „\(item.title)“ löschen?", isPresented: confirmDelete.projectedValue) {
                Button("Löschen", role: .destructive) { Task { await model.perform(.delete, on: item) } }
            } message: {
                Text("Verlauf und Session werden endgültig entfernt. Änderungen an Dateien bleiben erhalten.")
            }
            .alert("Session umbenennen", isPresented: renaming.projectedValue) {
                TextField("Titel", text: newTitle.projectedValue)
                Button("Umbenennen") { Task { await model.rename(item, to: newTitle.wrappedValue) } }
                Button("Abbrechen", role: .cancel) {}
            }
    }

    private var rowContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(item.title).lineLimit(1)
                Spacer(minLength: 4)
                if item.status != .idle { StatusBadge(status: item.status) }
            }
            HStack(spacing: 4) {
                if showSandbox { Text(URL(fileURLWithPath: item.directory).lastPathComponent) ; Text("·") }
                Text(item.updated.formatted(.relative(presentation: .named)))
            }
            .scaledFont(.caption).foregroundStyle(.secondary)
            if let err = item.lastError {
                Text(err).scaledFont(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusBadge: View {
    @Environment(\.textScale) private var scale
    let status: AgentStatus

    var color: Color {
        switch status {
        case .running: .blue
        case .needsInput: .orange
        case .blocked: .red
        case .done: .green
        case .idle, .inactive: .secondary
        }
    }

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 9 * scale, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}
