import Foundation
import Observation

/// One execution of a BuildTask inside the sandbox (via OpenCode's /api/shell).
@MainActor
@Observable
final class BuildRun: Identifiable {
    enum State: Equatable, Sendable {
        case starting, running, succeeded, failed(String), stopped, lost(String)
        var isActive: Bool { self == .starting || self == .running }
        var label: String {
            switch self {
            case .starting: String(localized: "starting…")
            case .running: String(localized: "running")
            case .succeeded: String(localized: "succeeded")
            case .failed(let reason): reason
            case .stopped: String(localized: "stopped")
            case .lost(let reason): reason
            }
        }
    }
    enum Health: Equatable, Sendable { case unknown, up(Int), down }

    let id = UUID()
    let task: BuildTask
    let root: String
    let serverID: String
    let port: Int?
    let command: String
    var shellID: String?
    var state: State = .starting
    var output = ""
    var health: Health = .unknown
    let startedAt: Date
    var endedAt: Date?
    var stopRequested = false

    init(task: BuildTask, root: String, serverID: String, port: Int?, command: String, startedAt: Date = Date()) {
        self.task = task; self.root = root; self.serverID = serverID; self.port = port
        self.command = command; self.startedAt = startedAt
    }

    var browserURL: URL? { port.flatMap { URL(string: "http://localhost:\($0)") } }
}

/// Checks whether something answers on a host localhost port (no redirects/cookies).
struct LocalPortProbe: Sendable {
    var session: URLSession = LocalPortProbe.defaultSession
    static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 1.5
        config.connectionProxyDictionary = [:]
        return URLSession(configuration: config, delegate: UpdateTransport(), delegateQueue: nil)
    }()

    /// nil = nothing listening, otherwise the HTTP status (or 0 for a non-HTTP answer).
    func status(port: Int, path: String = "/") async -> Int? {
        guard (1...65535).contains(port), path.hasPrefix("/"),
              let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 1.5)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch let error as URLError where [.badServerResponse, .cannotParseResponse, .networkConnectionLost].contains(error.code) {
            return 0
        } catch { return nil }
    }
}

@MainActor
@Observable
final class BuildDeployStore {
    private(set) var runs: [BuildRun] = []
    /// Tools available inside each sandbox (serverID -> executables).
    private(set) var availableTools: [String: Set<String>] = [:]
    var selectedRunID: UUID?
    var probe = LocalPortProbe()
    var pollInterval: Duration = .milliseconds(300)
    var healthInterval: Duration = .seconds(2)
    private var pollers: [UUID: Task<Void, Never>] = [:]
    private var adopted: Set<String> = []

    static let source = "Hearth IDE"
    static let kind = "build-deploy"
    static let probedTools = ["mvn", "java", "gradle", "node", "npm", "pnpm", "yarn", "go", "make"]

    var selectedRun: BuildRun? { runs.first { $0.id == selectedRunID } }

    func runs(for root: String) -> [BuildRun] { runs.filter { $0.root == root } }
    func activeRun(_ task: BuildTask, root: String) -> BuildRun? {
        runs.last { $0.root == root && $0.task.id == task.id && $0.state.isActive }
    }
    func latestRun(_ task: BuildTask, root: String) -> BuildRun? {
        runs.last { $0.root == root && $0.task.id == task.id }
    }

    /// Why a task cannot run in this sandbox (nil = runnable or unknown yet).
    func unavailableReason(_ task: BuildTask, serverID: String) -> String? {
        guard let tool = task.requiredTool, let tools = availableTools[serverID], !tools.contains(tool) else { return nil }
        return String(localized: "“\(tool)” is not available in this sandbox. There is no host fallback.")
    }

    // MARK: Tools

    func probeTools(client: any SandboxCommandRunner, serverID: String, root: String) async {
        guard availableTools[serverID] == nil else { return }
        let script = Self.probedTools.map { "command -v \($0) >/dev/null 2>&1 && echo \($0)" }.joined(separator: "; ") + "; true"
        guard let result = try? await runToEnd(client: client, root: root, command: script, operation: "tool-probe") else { return }
        availableTools[serverID] = Set(result.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { Self.probedTools.contains($0) })
    }

    /// Short helper commands (tool probe) – bounded output, always removed.
    private func runToEnd(client: any SandboxCommandRunner, root: String, command: String, operation: String) async throws -> String {
        let id = try await client.start(SandboxCommandRequest(command: command, cwd: root, timeout: .seconds(30),
                                                              metadata: ["source": Self.source, "operation": operation]))
        defer { Task.detached { await client.remove(id) } }
        for _ in 0..<150 {
            if try await client.state(of: id) != .running { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        return try await client.output(of: id, from: 0, limit: 8192).text
    }

    static func validShellID(_ id: String) -> Bool {
        !id.isEmpty && id.count < 200 && id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    // MARK: Start / stop

    @discardableResult
    func start(_ task: BuildTask, root: String, serverID: String, client: any SandboxCommandRunner,
               profile: String? = nil, port overridePort: Int? = nil) async -> BuildRun? {
        if let existing = activeRun(task, root: root) { selectedRunID = existing.id; return existing }
        let port = task.kind == .service ? (overridePort ?? task.port) : nil
        let command = BuildCommand.render(task, profile: profile, port: port)
        let run = BuildRun(task: task, root: root, serverID: serverID, port: port, command: command)
        runs.append(run)
        trimHistory()
        selectedRunID = run.id
        if let reason = unavailableReason(task, serverID: serverID) {
            finish(run, .failed(String(localized: "not available")), note: reason)
            return run
        }
        if let port, await probe.status(port: port) != nil {
            finish(run, .failed(String(localized: "port in use")), note: String(localized: "Port \(port) is already in use on this Mac. Stop the other process or choose another port."))
            return run
        }
        guard let cwd = Self.workingDirectory(root: root, project: task.project) else {
            finish(run, .failed(String(localized: "invalid folder")), note: String(localized: "The project folder is outside the workspace."))
            return run
        }
        var metadata: [String: String] = ["source": Self.source, "kind": Self.kind, "task": task.id, "root": root,
                                          "title": task.title, "service": task.kind == .service ? "true" : "false",
                                          "display": task.display, "tool": task.tool.rawValue, "project": task.project]
        if let port { metadata["port"] = String(port) }
        if let health = task.healthPath { metadata["health"] = health }
        do {
            let id = try await client.start(SandboxCommandRequest(command: command, cwd: cwd, port: port, metadata: metadata))
            guard Self.validShellID(id) else { throw SandboxCommandError(String(localized: "The sandbox returned no valid command ID.")) }
            run.shellID = id
            adopted.insert(id)
            if run.stopRequested { await stop(run, client: client); return run }
            run.state = .running
            append(run, "$ \(task.display)\n")
            poll(run, client: client)
        } catch {
            finish(run, .failed("start failed"), note: error.localizedDescription + String(localized: "\nNothing was run on the host."))
        }
        return run
    }

    func stop(_ run: BuildRun, client: any SandboxCommandRunner) async {
        run.stopRequested = true
        guard let id = run.shellID else { if run.state.isActive { finish(run, .stopped) }; return }
        await client.remove(id)
        if run.state.isActive { finish(run, .stopped) }
    }

    func clearFinished(root: String) {
        runs.removeAll { $0.root == root && !$0.state.isActive }
        if selectedRun == nil { selectedRunID = runs.last(where: { $0.root == root })?.id }
    }

    /// Server went away (sandbox stopped / reconnect): processes in it are gone.
    func serverGone(_ serverID: String) {
        for run in runs where run.serverID == serverID && run.state.isActive {
            finish(run, .lost("sandbox ended"), note: String(localized: "The connection to the sandbox is gone; its processes ended with it."))
        }
        availableTools[serverID] = nil
    }

    static func workingDirectory(root: String, project: String) -> String? {
        let base = URL(fileURLWithPath: root).standardizedFileURL
        guard !project.isEmpty else { return base.path }
        guard !project.hasPrefix("/"), !project.split(separator: "/").contains("..") else { return nil }
        let dir = base.appendingPathComponent(project).standardizedFileURL
        return dir.path.hasPrefix(base.path + "/") ? dir.path : nil
    }

    // MARK: Reattach

    /// Services started earlier (by this or a previous app launch) keep running in
    /// the sandbox. Re-adopt them by their metadata so they can be watched/stopped.
    func adopt(client: any SandboxCommandRunner, root: String, serverID: String) async {
        for item in await client.running() {
            let meta = item.metadata
            guard Self.validShellID(item.id), !adopted.contains(item.id),
                  meta["source"] == Self.source, meta["kind"] == Self.kind,
                  meta["root"] == root, let taskID = meta["task"] else { continue }
            let id = item.id
            adopted.insert(id)
            let service = meta["service"] == "true"
            let port = meta["port"].flatMap { BuildDetector.port($0) }
            let task = BuildTask(id: taskID, tool: BuildTask.Tool(rawValue: meta["tool"] ?? "") ?? .custom,
                                 project: meta["project"] ?? "", title: meta["title"] ?? taskID,
                                 kind: service ? .service : .task, script: meta["display"] ?? "", port: port,
                                 healthPath: meta["health"])
            let run = BuildRun(task: task, root: root, serverID: serverID, port: port, command: item.command, startedAt: item.started)
            run.shellID = id
            run.state = .running
            runs.append(run)
            poll(run, client: client)
        }
    }

    // MARK: Polling

    private func poll(_ run: BuildRun, client: any SandboxCommandRunner) {
        guard let id = run.shellID else { return }
        let interval = pollInterval
        pollers[run.id] = Task { [weak self] in
            var cursor = 0
            var failures = 0
            var lastHealth = ContinuousClock.now - .seconds(60)
            while !Task.isCancelled {
                guard let self, run.state.isActive else { return }
                do {
                    // State first: output written before the exit is then complete below.
                    let state = try await client.state(of: id)
                    while true {
                        let page = try await client.output(of: id, from: cursor, limit: 65536)
                        guard page.next > cursor else { break }
                        cursor = page.next
                        if !page.text.isEmpty { self.append(run, page.text) }
                        if cursor >= page.size { break }
                    }
                    failures = 0
                    if state != .running {
                        guard run.state.isActive else { return }
                        // Clean up in the sandbox first: once the run shows as finished, nothing of it is left.
                        await client.remove(id)
                        switch state {
                        case _ where run.stopRequested, .killed: self.finish(run, .stopped)
                        case .exited(0): self.finish(run, run.task.kind == .service ? .failed(String(localized: "ended")) : .succeeded)
                        case .timedOut: self.finish(run, .failed(String(localized: "timed out")))
                        default: self.finish(run, .failed(SandboxGitRunner.describe(state)), note: Self.networkHint(run.output))
                        }
                        return
                    }
                } catch is CancellationError { return }
                catch {
                    failures += 1
                    if failures >= 5 {
                        self.finish(run, .lost(String(localized: "connection lost")), note: error.localizedDescription)
                        return
                    }
                }
                if run.task.kind == .service, let port = run.port, ContinuousClock.now - lastHealth >= self.healthInterval {
                    lastHealth = ContinuousClock.now
                    let status = await self.probe.status(port: port, path: run.task.healthPath ?? "/")
                    if run.state.isActive { run.health = status.map { .up($0) } ?? .down }
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Sandbox network denials look like generic I/O errors to build tools.
    static func networkHint(_ output: String) -> String? {
        let tail = String(output.suffix(20_000))
        guard tail.contains("Operation not permitted") || tail.contains("403 Forbidden") || tail.contains("CONNECT tunnel failed")
                || tail.contains("proxyconnect") || tail.contains("Proxy Authentication Required") else { return nil }
        let host = tail.range(of: #"https?://[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, options: .regularExpression)
            .map { String(tail[$0]).replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression) }
        return String(localized: "Network access denied in the sandbox") + (host.map { String(localized: " (probably \($0))") } ?? "")
            + String(localized: ". Allow the host in Settings › Sandbox, then run the task again.")
    }

    private static let maxOutput = 400_000

    private func append(_ run: BuildRun, _ text: String) {
        run.output += Self.clean(text)
        if run.output.count > Self.maxOutput {
            run.output = String(localized: "… (older output trimmed)\n") + run.output.suffix(Self.maxOutput * 9 / 10)
        }
    }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]|\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private func finish(_ run: BuildRun, _ state: BuildRun.State, note: String? = nil) {
        if let note { append(run, (run.output.isEmpty || run.output.hasSuffix("\n") ? "" : "\n") + "⚠︎ " + note + "\n") }
        run.state = state
        run.endedAt = Date()
        if state != .running { run.health = .unknown }
        pollers[run.id]?.cancel()
        pollers[run.id] = nil
    }

    private func trimHistory() {
        let finished = runs.filter { !$0.state.isActive }
        if finished.count > 30 {
            let drop = Set(finished.prefix(finished.count - 30).map(\.id))
            runs.removeAll { drop.contains($0.id) }
        }
    }
}
