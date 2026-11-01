import SwiftUI
import AppKit

/// "Build & Deployment": project tasks and services, executed in Hearth's nono sandbox.
struct BuildDeployView: View {
    @Environment(AppModel.self) private var model
    let root: String
    private let projects: State<[BuildProject]>
    private let scanned: State<Bool>
    private let profiles = State(initialValue: [String: String]())
    private let ports = State(initialValue: [String: String]())
    private let filter = State(initialValue: "")

    init(root: String, preloaded: [BuildProject]? = nil) {
        self.root = root
        projects = State(initialValue: preloaded ?? [])
        scanned = State(initialValue: preloaded != nil)
    }

    private var store: BuildDeployStore { model.builds }
    private var connection: AppModel.BuildShell? { model.buildShell(root: root) }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                Divider()
                if geometry.size.width >= 860 {
                    HSplitView {
                        taskList.frame(minWidth: 340, idealWidth: geometry.size.width * 0.45, maxWidth: .infinity, maxHeight: .infinity)
                        logPane.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if store.selectedRun?.root != root {
                    taskList.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VSplitView {
                        taskList.frame(maxWidth: .infinity, minHeight: 150, maxHeight: .infinity)
                        logPane.frame(maxWidth: .infinity, minHeight: 110, maxHeight: .infinity)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: root) { await rescan() }
        .task(id: "\(root)#\(connection?.id ?? "")") {
            guard let conn = connection else { return }
            await store.adopt(client: conn.client, root: root, serverID: conn.id)
            await store.probeTools(client: conn.client, serverID: conn.id, root: root)
        }
    }

    private func rescan() async {
        let root = root
        let found = await Task.detached { BuildDetector.scan(root: root) }.value
        guard root == self.root else { return }
        projects.wrappedValue = found
        scanned.wrappedValue = true
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            sandboxBadge
            let active = store.runs(for: root).filter { $0.state.isActive }.count
            if active > 0 {
                Pill(text: String(localized: "\(active) active"), color: .accentColor, symbol: "bolt.fill")
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).imageScale(.small)
                TextField("Filter tasks", text: filter.projectedValue).textFieldStyle(.plain)
                if !filter.wrappedValue.isEmpty {
                    Button { filter.wrappedValue = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            .scaledFont(.caption)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 200)
            Button { Task { await rescan() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Rescan project files")
            Menu {
                Button("Remove finished runs") { store.clearFinished(root: root) }
                Divider()
                Button("Edit custom tasks (.hearth/tasks.json)") { openCustomTasks() }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    @ViewBuilder
    private var sandboxBadge: some View {
        if let conn = connection {
            Pill(text: "Sandbox · nono", color: .green, symbol: "lock.shield.fill")
                .help("Every task runs in its own nono sandbox for this folder – never directly on the Mac.")
        } else {
            Pill(text: String(localized: "No sandbox available"), color: .orange, symbol: "exclamationmark.triangle.fill")
                .help("nono was not found (Contents/Helpers/nono or scripts/fetch-nono.sh).")
        }
    }

    private func openCustomTasks() {
        let url = URL(fileURLWithPath: root).appendingPathComponent(".hearth/tasks.json")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(Self.customTemplate.utf8).write(to: url, options: .withoutOverwriting)
        }
        model.editor.open(url)
    }

    static let customTemplate = """
    {
      "tasks": [
        { "name": "Example: build", "command": "mvn -B verify" },
        { "name": "Example: Service", "command": "java -jar target/app.jar", "service": true, "port": 8080, "health": "/actuator/health" }
      ]
    }

    """

    // MARK: Tasks

    @ViewBuilder
    private var taskList: some View {
        if !scanned.wrappedValue {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if projects.wrappedValue.isEmpty {
            ContentUnavailableView("No build configuration found", systemImage: "hammer",
                description: Text("Supported: Maven, Gradle, Node, Go, Makefile and custom tasks in .hearth/tasks.json."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(projects.wrappedValue) { project in
                        let tasks = visible(project.tasks)
                        if !tasks.isEmpty { projectSection(project, tasks: tasks) }
                    }
                }
                .padding(12)
            }
        }
    }

    private func projectSection(_ project: BuildProject, tasks: [BuildTask]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            projectHeader(project)
            let services = tasks.filter { $0.kind == .service }
            if !services.isEmpty {
                VStack(spacing: 6) { ForEach(services) { serviceCard($0, project: project) } }
            }
            let jobs = tasks.filter { $0.kind == .task }
            if !jobs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(jobs.enumerated()), id: \.element.id) { index, task in
                        if index > 0 { Divider().padding(.leading, 36) }
                        taskRow(task, project: project)
                    }
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
            }
        }
    }

    private func visible(_ tasks: [BuildTask]) -> [BuildTask] {
        let query = filter.wrappedValue.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return tasks }
        return tasks.filter { $0.title.lowercased().contains(query) || $0.display.lowercased().contains(query) }
    }

    private func projectHeader(_ project: BuildProject) -> some View {
        HStack(spacing: 8) {
            Image(systemName: project.path.isEmpty ? "shippingbox.fill" : "shippingbox")
                .foregroundStyle(Color.accentColor)
            Text(project.name).scaledFont(.callout).fontWeight(.semibold)
            if !project.path.isEmpty, project.path != project.name {
                Text(project.path).scaledFont(.caption).foregroundStyle(.secondary)
            }
            ForEach(project.tools, id: \.self) { Pill(text: $0 == .custom ? String(localized: "Custom") : $0.rawValue, color: .secondary) }
            Spacer()
            if !project.profiles.isEmpty {
                Picker("Profile", selection: Binding(get: { profiles.wrappedValue[project.id] ?? "" },
                                                    set: { profiles.wrappedValue[project.id] = $0 })) {
                    Text("No profile").tag("")
                    ForEach(project.profiles, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().controlSize(.small).fixedSize()
                .help("Maven profile (-P) for this project’s tasks")
            }
        }
        .padding(.horizontal, 2)
    }

    private func reason(_ task: BuildTask) -> String? {
        guard let conn = connection else { return String(localized: "No sandbox available (nono not found).") }
        return store.unavailableReason(task, serverID: conn.id)
    }

    /// The command without noise flags (full command in the tooltip).
    static func shortCommand(_ task: BuildTask) -> String {
        guard task.script == nil else { return task.display }
        return task.argv.filter { !["-B", "--no-transfer-progress", "--console=plain"].contains($0) }.joined(separator: " ")
    }

    private func taskRow(_ task: BuildTask, project: BuildProject) -> some View {
        let run = store.latestRun(task, root: root)
        let blocked = reason(task)
        let selected = run != nil && store.selectedRunID == run?.id
        return HStack(spacing: 10) {
            stateIcon(run).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).scaledFont(.callout)
                Text(Self.shortCommand(task)).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let run, !run.state.isActive, let end = run.endedAt {
                Text(duration(run.startedAt, end)).scaledFont(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            runButton(task, project: project, run: run, blocked: blocked, prominent: false)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if let run { store.selectedRunID = run.id } }
        .opacity(blocked == nil ? 1 : 0.55)
        .help(blocked ?? task.display)
    }

    private func serviceCard(_ task: BuildTask, project: BuildProject) -> some View {
        let run = store.latestRun(task, root: root)
        let active = run?.state.isActive == true
        let blocked = reason(task)
        let selected = run != nil && store.selectedRunID == run?.id
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(serviceColor(run).opacity(0.15))
                Image(systemName: task.tool == .maven || task.tool == .gradle ? "leaf.fill" : "server.rack")
                    .foregroundStyle(serviceColor(run))
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(task.title).scaledFont(.callout).fontWeight(.medium)
                    serviceStatus(run)
                }
                Text(Self.shortCommand(task)).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Text(":").foregroundStyle(.secondary)
                TextField("Port", text: Binding(get: { ports.wrappedValue[portKey(task)] ?? task.port.map(String.init) ?? "" },
                                                set: { ports.wrappedValue[portKey(task)] = String($0.filter(\.isNumber).prefix(5)) }))
                    .textFieldStyle(.plain).frame(width: 44).monospacedDigit().disabled(active)
                    .help("Port the service listens on (PORT/SERVER_PORT).")
            }
            .scaledFont(.caption)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
            if active, let url = run?.browserURL {
                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless).help("Open \(url.absoluteString) in the browser")
            }
            runButton(task, project: project, run: run, blocked: blocked, prominent: true)
        }
        .padding(10)
        .background(Color.primary.opacity(selected ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? serviceColor(run).opacity(0.5) : Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture { if let run { store.selectedRunID = run.id } }
        .opacity(blocked == nil ? 1 : 0.55)
        .help(blocked ?? task.display)
    }

    private func serviceColor(_ run: BuildRun?) -> Color {
        guard let run else { return .secondary }
        switch run.state {
        case .running, .starting:
            if case .up(let code) = run.health { return code < 500 ? .green : .orange }
            return .orange
        case .failed, .lost: return .red
        default: return .secondary
        }
    }

    @ViewBuilder
    private func serviceStatus(_ run: BuildRun?) -> some View {
        if let run, run.state.isActive {
            Pill(text: healthText(run), color: serviceColor(run), symbol: "circle.fill")
        } else if let run, case .failed = run.state {
            Pill(text: run.state.label, color: .red)
        } else if let run, case .lost = run.state {
            Pill(text: run.state.label, color: .red)
        } else {
            Pill(text: String(localized: "stopped"), color: .secondary)
        }
    }

    private func portKey(_ task: BuildTask) -> String { root + "#" + task.id }

    private func chosenPort(_ task: BuildTask) -> Int? {
        ports.wrappedValue[portKey(task)].flatMap { $0.isEmpty ? nil : BuildDetector.port($0) } ?? task.port
    }

    @ViewBuilder
    private func runButton(_ task: BuildTask, project: BuildProject, run: BuildRun?, blocked: String?, prominent: Bool) -> some View {
        if let run, run.state.isActive {
            Button {
                guard let client = model.runner(id: run.serverID) else { store.serverGone(run.serverID); return }
                Task { await store.stop(run, client: client) }
            } label: {
                Label(prominent ? "Stop" : "Cancel", systemImage: "stop.fill")
                    .labelStyle(.iconOnly).frame(width: 14)
            }
            .buttonStyle(.bordered).tint(.red).controlSize(.small)
            .help(task.kind == .service ? "Stop service" : "Cancel")
        } else {
            let button = Button {
                guard let conn = connection else { return }
                let profile = profiles.wrappedValue[project.id].flatMap { $0.isEmpty ? nil : $0 }
                Task { await store.start(task, root: root, serverID: conn.id, client: conn.client, profile: profile, port: chosenPort(task)) }
            } label: {
                Label("Start", systemImage: "play.fill").labelStyle(.iconOnly).frame(width: 14)
            }
            .controlSize(.small).disabled(blocked != nil)
            .help(task.kind == .service ? "Start the service in the sandbox" : "Run in the sandbox")
            if prominent { button.buttonStyle(.borderedProminent) } else { button.buttonStyle(.bordered) }
        }
    }

    @ViewBuilder
    private func stateIcon(_ run: BuildRun?) -> some View {
        switch run?.state {
        case .none: Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .starting?, .running?: ProgressView().controlSize(.mini)
        case .succeeded?: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .stopped?: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        case .failed?, .lost?: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func healthText(_ run: BuildRun) -> String {
        guard run.port != nil else { return String(localized: "running") }
        switch run.health {
        case .up(let code) where code < 500: return String(localized: "reachable")
        case .up(let code): return "HTTP \(code)"
        case .down, .unknown: return String(localized: "starting…")
        }
    }

    private func duration(_ start: Date, _ end: Date) -> String {
        let seconds = Int(end.timeIntervalSince(start).rounded())
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }

    // MARK: Log

    @ViewBuilder
    private var logPane: some View {
        let rootRuns = store.runs(for: root)
        if let run = store.selectedRun, run.root == root {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    stateIcon(run)
                    Text(run.task.title).scaledFont(.callout).fontWeight(.semibold)
                    Pill(text: run.state.label, color: run.state == .succeeded ? .green : (run.state.isActive ? .accentColor : .secondary))
                    Spacer()
                    if rootRuns.count > 1 {
                        Picker("Run", selection: Binding(get: { run.id }, set: { store.selectedRunID = $0 })) {
                            ForEach(rootRuns.reversed()) { r in
                                Text("\(r.task.title) · \(r.startedAt.formatted(date: .omitted, time: .shortened)) · \(r.state.label)").tag(r.id)
                            }
                        }
                        .labelsHidden().controlSize(.small).frame(maxWidth: 260)
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(run.output, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Copy output")
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                Divider()
                BuildLogView(run: run)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "terminal").font(.system(size: 26)).foregroundStyle(.tertiary)
                Text("No output yet").scaledFont(.callout).foregroundStyle(.secondary)
                Text("Start a task or a service – its log appears here live.")
                    .scaledFont(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.02))
        }
    }
}

/// Small rounded status/label capsule.
private struct Pill: View {
    let text: String
    var color: Color
    var symbol: String?
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small).font(.system(size: 8)) }
            Text(text).lineLimit(1)
        }
        .scaledFont(.caption2).fontWeight(.medium)
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background((color == .secondary ? Color.primary : color).opacity(0.12), in: Capsule())
    }
}

/// Read-only log; follows the end while new output arrives.
private struct BuildLogView: View {
    let run: BuildRun
    var body: some View {
        let text = run.output.isEmpty ? (run.state.isActive ? String(localized: "Waiting for output…") : String(localized: "(no output)")) : run.output
        CodeEditor(text: .constant(text), language: .shell, editable: false,
                   highlightLine: run.state.isActive ? max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count) : nil)
            .id(run.id)
    }
}
