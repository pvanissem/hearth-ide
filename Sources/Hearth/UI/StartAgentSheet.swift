import SwiftUI
import AppKit

/// Start an agent in a folder: pick folder and agent, or run the agent's login.
struct StartAgentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: AgentHost.StartAgentRequest
    private let directory = State(initialValue: "")
    private let kind = State(initialValue: AgentKind.claude)
    private let installed = State(initialValue: [AgentKind: Bool]())

    static let lastDirectoryKey = "agents.lastDirectory"
    static let lastKindKey = "agents.lastKind"

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Agent starten").font(.title2.bold())
                Text("Der Agent arbeitet in einer nono-Sandbox: Er darf nur in diesem Ordner schreiben und nur bekannte Entwickler-Hosts erreichen.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Ordner").font(.headline)
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(directory.wrappedValue.isEmpty ? "Kein Ordner gewählt"
                         : directory.wrappedValue.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.head)
                        .foregroundStyle(directory.wrappedValue.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Wählen …") { chooseFolder() }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                if let problem = folderProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                } else if let project = model.sandboxSettings.project(for: directory.wrappedValue), !project.folders.isEmpty {
                    Label("Projekt-Freigaben: " + project.folders.map { URL(fileURLWithPath: $0.path).lastPathComponent + ($0.write ? " (schreiben)" : " (lesen)") }
                            .joined(separator: ", "), systemImage: "folder.badge.gearshape")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Agent").font(.headline)
                VStack(spacing: 2) {
                    ForEach(AgentKind.allCases) { k in
                        agentRow(k)
                    }
                }
                .padding(4)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                if kind.wrappedValue != .shell {
                    Button("Anmelden …") { start(.login) }
                        .disabled(!canStart || (kind.wrappedValue.loginArguments == nil))
                        .help(kind.wrappedValue.loginHint)
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Starten") { start(.session) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStart)
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            let defaults = UserDefaults.standard
            directory.wrappedValue = request.directory
                ?? defaults.string(forKey: Self.lastDirectoryKey)
                ?? model.workspaceRoot
                ?? model.agents.runs.max(by: { $0.updated < $1.updated })?.directory
                ?? ""
            let found = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: AgentKind.allCases.map { ($0, SandboxManager.locate($0) != nil) })
            }.value
            installed.wrappedValue = found
            let preferred = request.kind ?? defaults.string(forKey: Self.lastKindKey).flatMap(AgentKind.init)
            if let preferred, found[preferred] == true { kind.wrappedValue = preferred }
            else if found[kind.wrappedValue] != true, let first = AgentKind.allCases.first(where: { found[$0] == true }) {
                kind.wrappedValue = first
            }
        }
    }

    private func agentRow(_ k: AgentKind) -> some View {
        let available = installed.wrappedValue[k]
        let selected = kind.wrappedValue == k
        return HStack(spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            Image(systemName: k.symbol).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(k.displayName)
                if available == false {
                    Text("Nicht installiert – \(k.installHint)").font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else if k == .claude {
                    Text("Läuft als Terminal in der Chat-Ansicht (nutzt dein Claude-Abo)").font(.caption).foregroundStyle(.secondary)
                } else if k == .shell {
                    Text("zsh in derselben Sandbox, zum Ausprobieren der Regeln").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if available == nil { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .opacity(available == false ? 0.55 : 1)
        .onTapGesture { if available != false { kind.wrappedValue = k } }
    }

    private var folderProblem: String? {
        let dir = directory.wrappedValue
        guard !dir.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        if !resolved.hasPrefix(NSHomeDirectory() + "/") { return "Der Ordner muss unterhalb deines Home-Verzeichnisses liegen." }
        if !FileManager.default.fileExists(atPath: resolved) { return "Der Ordner existiert nicht." }
        return nil
    }

    private var canStart: Bool {
        !directory.wrappedValue.isEmpty && folderProblem == nil && installed.wrappedValue[kind.wrappedValue] == true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Wählen"
        if !directory.wrappedValue.isEmpty { panel.directoryURL = URL(fileURLWithPath: directory.wrappedValue) }
        if panel.runModal() == .OK, let url = panel.url { directory.wrappedValue = url.path }
    }

    private func start(_ purpose: AgentRun.Purpose) {
        let defaults = UserDefaults.standard
        defaults.set(directory.wrappedValue, forKey: Self.lastDirectoryKey)
        defaults.set(kind.wrappedValue.rawValue, forKey: Self.lastKindKey)
        model.startAgent(kind.wrappedValue, directory: directory.wrappedValue, purpose: purpose)
        dismiss()
    }
}
