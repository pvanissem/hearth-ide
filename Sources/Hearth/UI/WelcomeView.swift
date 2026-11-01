import SwiftUI
import AppKit

/// Shown on launch when no agent was running: continue in a recent folder or start a new one.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    private let showOnLaunch = State(initialValue: AppModel.welcomeEnabled)

    /// Newest session per folder, so a click starts the same agent there again.
    private var recentAgentFolders: [AgentRun] {
        var seen = Set<String>()
        return model.agents.runs.sorted { $0.updated > $1.updated }
            .filter { $0.purpose == .session && seen.insert($0.directory).inserted }
            .prefix(8).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Willkommen bei Hearth IDE").font(.title.bold())
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Alle Agenten in sicheren Sandboxes – womit möchtest du loslegen?")
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)

            Divider()

            UpdateNoticeBar(checker: model.updates, compact: true)

            VStack(alignment: .leading, spacing: 8) {
                if !recentAgentFolders.isEmpty {
                    Text("Zuletzt verwendete Ordner").font(.caption.bold()).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(recentAgentFolders, id: \.directory) { run in
                                HStack(spacing: 10) {
                                    Image(systemName: run.kind.symbol).foregroundStyle(Color.accentColor).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(run.folderName).font(.body.bold())
                                        HStack(spacing: 4) {
                                            Text(run.kind.displayName)
                                            Text("·")
                                            Text(run.directory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                                .lineLimit(1).truncationMode(.head)
                                            Text("·")
                                            Text(run.updated.formatted(.relative(presentation: .named)))
                                        }
                                        .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                                }
                                .padding(.vertical, 4)
                                .interactiveRow {
                                    model.showWelcome = false
                                    model.startAgent(run.kind, directory: run.directory)
                                }
                                .help("\(run.kind.displayName) in diesem Ordner starten")
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                } else {
                    ContentUnavailableView("Noch keine Sitzungen", systemImage: "flame",
                                           description: Text("Wähle einen Ordner und einen Agenten – Claude Code, Codex, Copilot oder OpenCode."))
                        .frame(maxHeight: 180)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 16)

            Divider()

            HStack {
                Toggle("Beim Start anzeigen", isOn: Binding(get: { showOnLaunch.wrappedValue }, set: {
                    showOnLaunch.wrappedValue = $0
                    AppModel.welcomeEnabled = $0
                }))
                .toggleStyle(.checkbox)
                Spacer()
                Button("Ohne Agent fortfahren") { model.showWelcome = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    model.welcomeStartAgent()
                } label: {
                    Label("Agent starten …", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600)
    }
}
