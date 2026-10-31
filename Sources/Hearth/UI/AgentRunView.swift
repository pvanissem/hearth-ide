import SwiftUI
import AppKit


/// The chat area for an agent that runs as a terminal (Claude Code and every agent
/// without a native chat yet): same header and status as a native chat, with the
/// agent's own interface below.
struct AgentRunView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.textScale) private var scale
    let run: AgentRun
    private let renaming = State(initialValue: false)
    private let newTitle = State(initialValue: "")

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = run.error {
                notice(error, symbol: "exclamationmark.triangle.fill", color: .red)
            } else if let detail = run.detail, run.status == .needsInput {
                notice(detail, symbol: "hand.raised.fill", color: .orange)
            }
            ZStack {
                if run.terminal != nil || run.launchCount > 0 {
                    AgentTerminalHost(run: run, launchCount: run.launchCount, dark: colorScheme == .dark, scale: scale)
                } else {
                    resumePlaceholder
                }
                if !run.isRunning, run.terminal != nil {
                    VStack {
                        Spacer()
                        HStack(spacing: 10) {
                            Text(run.exitCode.map { "Sitzung beendet (Code \($0))" } ?? "Sitzung beendet").font(.callout)
                            if run.purpose == .session {
                                Button(run.sessionID != nil ? "Fortsetzen" : "Neu starten") { model.agents.resume(run) }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(14)
                    }
                }
            }
        }
        .alert("Sitzung umbenennen", isPresented: renaming.projectedValue) {
            TextField("Titel", text: newTitle.projectedValue)
            Button("Umbenennen") { model.agents.rename(run, to: newTitle.wrappedValue) }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: run.kind.symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(run.title).scaledFont(.headline).lineLimit(1)
                    if run.status != .idle { StatusBadge(status: run.status) }
                }
                HStack(spacing: 4) {
                    Text(run.kind.displayName)
                    Text("·")
                    Text(run.directory.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.head)
                }
                .scaledFont(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            SandboxBadge(kind: run.kind, running: run.isRunning)
            if run.isRunning {
                Button { model.agents.stop(run) } label: { Image(systemName: "stop.circle") }
                    .help("Sitzung beenden")
            } else if run.purpose == .session {
                Button { model.agents.resume(run) } label: { Image(systemName: "play.circle") }
                    .help(run.sessionID != nil ? "Gespräch fortsetzen" : "Neu starten")
            }
            Menu {
                Button("Umbenennen …") { newTitle.wrappedValue = run.title; renaming.wrappedValue = true }
                Button("Neue Sitzung im selben Ordner") { model.startAgent(run.kind, directory: run.directory) }
                Button("Im Finder zeigen") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: run.directory) }
                Divider()
                Button("Sandbox-Profil anzeigen") {
                    NSWorkspace.shared.open(SandboxManager.runDirectory(run.id).appendingPathComponent("nono-profile.json"))
                }
                Button("Sandbox-Protokoll anzeigen") {
                    NSWorkspace.shared.open(SandboxManager.runDirectory(run.id).appendingPathComponent("nono.log"))
                }
                Divider()
                Button("Sitzung entfernen", role: .destructive) { model.agents.remove(run) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func notice(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).scaledFont(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(color.opacity(0.08))
    }

    private var resumePlaceholder: some View {
        ContentUnavailableView {
            Label(run.title, systemImage: run.kind.symbol)
        } description: {
            Text(run.sessionID != nil
                 ? "Diese Sitzung ist beendet. \(run.kind.displayName) kann das Gespräch in einer neuen Sandbox fortsetzen."
                 : "Diese Sitzung ist beendet.")
        } actions: {
            Button(run.sessionID != nil ? "Fortsetzen" : "Neu starten") { model.agents.resume(run) }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Shows that the agent runs sandboxed, with what the sandbox allows on hover.
struct SandboxBadge: View {
    let kind: AgentKind
    let running: Bool

    var body: some View {
        Label("Sandbox", systemImage: running ? "lock.shield.fill" : "lock.shield")
            .font(.caption.bold())
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(running ? Color.green : Color.secondary)
            .background((running ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
            .help(summary)
    }

    private var summary: String {
        let spec = kind.sandbox
        var lines = ["nono-Sandbox (Seatbelt)",
                     "Schreiben: nur dieser Ordner" + (spec.readWrite.isEmpty ? "" : " und " + spec.readWrite.joined(separator: ", ")),
                     "Gesperrt: SSH-Schlüssel, Shell-Konfiguration, Browserdaten, übriges Home",
                     "Netzwerk: LLM-APIs, Paket-Registries, GitHub/GitLab, Doku" + (spec.domains.isEmpty ? "" : ", " + spec.domains.joined(separator: ", "))]
        if spec.keychain { lines.append("Schlüsselbund: freigegeben (Login des Agenten)") }
        return lines.joined(separator: "\n")
    }
}

/// Hosts a run's long-lived terminal view. Switching sessions only moves the view;
/// the process keeps running.
struct AgentTerminalHost: NSViewRepresentable {
    let run: AgentRun
    let launchCount: Int
    let dark: Bool
    let scale: Double

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let terminal = run.terminal else {
            container.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        if terminal.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            terminal.removeFromSuperview()
            terminal.frame = container.bounds
            terminal.autoresizingMask = [.width, .height]
            container.addSubview(terminal)
            DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
        }
        if run.themedDark != dark || run.themedScale != scale {
            TerminalTheme.apply(to: terminal, dark: dark, scale: scale)
            run.themedDark = dark
            run.themedScale = scale
        }
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        // Detach only; the terminal (and its process) belongs to the run.
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Inbox row for an agent session.
struct AgentRunRow: View {
    @Environment(AppModel.self) private var model
    let run: AgentRun
    private let renaming = State(initialValue: false)
    private let newTitle = State(initialValue: "")

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: run.kind.symbol).foregroundStyle(run.isRunning ? Color.accentColor : .secondary)
                    .frame(width: 16)
                Text(run.title).lineLimit(1)
                Spacer(minLength: 4)
                if run.status != .idle && run.status != .inactive { StatusBadge(status: run.status) }
            }
            HStack(spacing: 4) {
                Text(run.folderName)
                Text("·")
                Text(run.isRunning ? "läuft" : "beendet")
                Text("·")
                Text(run.updated.formatted(.relative(presentation: .named)))
            }
            .scaledFont(.caption).foregroundStyle(.secondary)
            if let detail = run.detail, run.status == .needsInput || run.status == .done {
                Text(detail).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if let error = run.error {
                Text(error).scaledFont(.caption).foregroundStyle(.red).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if run.isRunning {
                Button { model.agents.stop(run) } label: { Label("Sitzung beenden", systemImage: "stop.circle") }
            } else if run.purpose == .session {
                Button { model.agents.resume(run); model.selectRun(run.id) } label: {
                    Label(run.sessionID != nil ? "Fortsetzen" : "Neu starten", systemImage: "play.circle")
                }
            }
            Button { newTitle.wrappedValue = run.title; renaming.wrappedValue = true } label: {
                Label("Umbenennen …", systemImage: "pencil")
            }
            Button { model.startAgent(run.kind, directory: run.directory) } label: {
                Label("Neue Sitzung im selben Ordner", systemImage: "plus.bubble")
            }
            Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: run.directory) } label: {
                Label("Im Finder zeigen", systemImage: "folder")
            }
            Divider()
            Button(role: .destructive) { model.agents.remove(run) } label: { Label("Entfernen", systemImage: "trash") }
        }
        .alert("Sitzung umbenennen", isPresented: renaming.projectedValue) {
            TextField("Titel", text: newTitle.projectedValue)
            Button("Umbenennen") { model.agents.rename(run, to: newTitle.wrappedValue) }
            Button("Abbrechen", role: .cancel) {}
        }
    }
}
