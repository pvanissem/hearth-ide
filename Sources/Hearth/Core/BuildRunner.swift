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
            case .starting: "startet …"
            case .running: "läuft"
            case .succeeded: "erfolgreich"
            case .failed(let reason): reason
            case .stopped: "gestoppt"
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

/// The subset of the OpenCode shell API needed here; abstracted for tests.
protocol SandboxShellAPI: Sendable {
    func send(_ method: String, _ path: String, query: [URLQueryItem], body: [String: Any]?, session: URLSession?) async throws -> JSON
}
extension OpenCodeClient: SandboxShellAPI {}

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
        return "„\(tool)“ ist in dieser Sandbox nicht verfügbar. Die Freigabe muss im devkcode-Profil erfolgen; es gibt keinen Host-Fallback."
    }

    private static func location(_ root: String) -> [URLQueryItem] { [.init(name: "location[directory]", value: root)] }

    // MARK: Tools

    func probeTools(client: SandboxShellAPI, serverID: String, root: String) async {
        guard availableTools[serverID] == nil else { return }
        let script = Self.probedTools.map { "command -v \($0) >/dev/null 2>&1 && echo \($0)" }.joined(separator: "; ") + "; true"
        guard let result = try? await runToEnd(client: client, root: root, command: script, operation: "tool-probe") else { return }
        availableTools[serverID] = Set(result.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { Self.probedTools.contains($0) })
    }

    /// Short helper commands (tool probe) – bounded output, always removed.
    private func runToEnd(client: SandboxShellAPI, root: String, command: String, operation: String) async throws -> String {
        let created = try await client.send("POST", "/api/shell", query: Self.location(root),
            body: ["command": command, "cwd": root, "timeout": 30_000,
                   "metadata": ["source": Self.source, "operation": operation]], session: GitLabTransport.session)["data"]
        guard let id = created?["id"]?.string, Self.validShellID(id) else { throw SandboxGitRunner.Failure("Ungültige Shell-ID") }
        defer { Task.detached { _ = try? await client.send("DELETE", "/api/shell/\(id)", query: Self.location(root), body: nil, session: GitLabTransport.session) } }
        for _ in 0..<150 {
            let status = try await client.send("GET", "/api/shell/\(id)", query: Self.location(root), body: nil, session: GitLabTransport.session)["data"]
            if status?["status"]?.string != "running" { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let page = try await client.send("GET", "/api/shell/\(id)/output",
            query: Self.location(root) + [.init(name: "cursor", value: "0"), .init(name: "limit", value: "8192")], body: nil, session: GitLabTransport.session)["data"]
        return page?["output"]?.string ?? ""
    }

    static func validShellID(_ id: String) -> Bool {
        !id.isEmpty && id.count < 200 && id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    // MARK: Start / stop

    @discardableResult
    func start(_ task: BuildTask, root: String, serverID: String, client: SandboxShellAPI,
               profile: String? = nil, port overridePort: Int? = nil) async -> BuildRun? {
        if let existing = activeRun(task, root: root) { selectedRunID = existing.id; return existing }
        let port = task.kind == .service ? (overridePort ?? task.port) : nil
        let command = BuildCommand.render(task, profile: profile, port: port)
        let run = BuildRun(task: task, root: root, serverID: serverID, port: port, command: command)
        runs.append(run)
        trimHistory()
        selectedRunID = run.id
        if let reason = unavailableReason(task, serverID: serverID) {
            finish(run, .failed("nicht verfügbar"), note: reason)
            return run
        }
        if let port, await probe.status(port: port) != nil {
            finish(run, .failed("Port belegt"), note: "Port \(port) ist auf diesem Mac bereits belegt. Bitte den anderen Prozess beenden oder einen anderen Port wählen.")
            return run
        }
        guard let cwd = Self.workingDirectory(root: root, project: task.project) else {
            finish(run, .failed("ungültiges Verzeichnis"), note: "Projektverzeichnis liegt außerhalb des Workspace.")
            return run
        }
        var metadata: [String: Any] = ["source": Self.source, "kind": Self.kind, "task": task.id, "root": root,
                                       "title": task.title, "service": task.kind == .service, "display": task.display,
                                       "tool": task.tool.rawValue, "project": task.project]
        if let port { metadata["port"] = port }
        if let health = task.healthPath { metadata["health"] = health }
        do {
            let created = try await client.send("POST", "/api/shell", query: Self.location(root),
                body: ["command": command, "cwd": cwd, "metadata": metadata], session: GitLabTransport.session)["data"]
            guard let id = created?["id"]?.string, Self.validShellID(id) else {
                throw SandboxGitRunner.Failure("Sandbox-Shell lieferte keine gültige Vorgangs-ID.")
            }
            run.shellID = id
            adopted.insert(id)
            if run.stopRequested { await stop(run, client: client); return run }
            run.state = .running
            append(run, "$ \(task.display)\n")
            poll(run, client: client)
        } catch {
            finish(run, .failed("Start fehlgeschlagen"), note: error.localizedDescription + "\nKeine Ausführung auf dem Host.")
        }
        return run
    }

    func stop(_ run: BuildRun, client: SandboxShellAPI) async {
        run.stopRequested = true
        guard let id = run.shellID else { if run.state.isActive { finish(run, .stopped) }; return }
        _ = try? await client.send("DELETE", "/api/shell/\(id)", query: Self.location(run.root), body: nil, session: GitLabTransport.session)
        if run.state.isActive { finish(run, .stopped) }
    }

    func clearFinished(root: String) {
        runs.removeAll { $0.root == root && !$0.state.isActive }
        if selectedRun == nil { selectedRunID = runs.last(where: { $0.root == root })?.id }
    }

    /// Server went away (sandbox stopped / reconnect): processes in it are gone.
    func serverGone(_ serverID: String) {
        for run in runs where run.serverID == serverID && run.state.isActive {
            finish(run, .lost("Sandbox beendet"), note: "Die Verbindung zur Sandbox ist weg; ihre Prozesse wurden mit ihr beendet.")
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
    func adopt(client: SandboxShellAPI, root: String, serverID: String) async {
        guard let list = try? await client.send("GET", "/api/shell", query: Self.location(root), body: nil, session: GitLabTransport.session)["data"]?.array else { return }
        for item in list {
            guard let id = item["id"]?.string, Self.validShellID(id), !adopted.contains(id),
                  let meta = item["metadata"], meta["source"]?.string == Self.source, meta["kind"]?.string == Self.kind,
                  meta["root"]?.string == root, let taskID = meta["task"]?.string else { continue }
            adopted.insert(id)
            let service = meta["service"] == .bool(true)
            let port = meta["port"]?.double.flatMap { BuildDetector.port(String(Int($0))) }
            let task = BuildTask(id: taskID, tool: BuildTask.Tool(rawValue: meta["tool"]?.string ?? "") ?? .custom,
                                 project: meta["project"]?.string ?? "", title: meta["title"]?.string ?? taskID,
                                 kind: service ? .service : .task, script: meta["display"]?.string ?? "", port: port,
                                 healthPath: meta["health"]?.string)
            let started = item["time"]?["started"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
            let run = BuildRun(task: task, root: root, serverID: serverID, port: port, command: item["command"]?.string ?? "", startedAt: started)
            run.shellID = id
            run.state = .running
            runs.append(run)
            poll(run, client: client)
        }
    }

    // MARK: Polling

    private func poll(_ run: BuildRun, client: SandboxShellAPI) {
        guard let id = run.shellID else { return }
        let location = Self.location(run.root)
        let interval = pollInterval
        pollers[run.id] = Task { [weak self] in
            var cursor = 0
            var failures = 0
            var lastHealth = ContinuousClock.now - .seconds(60)
            while !Task.isCancelled {
                guard let self, run.state.isActive else { return }
                do {
                    var more = true
                    while more {
                        let page = try await client.send("GET", "/api/shell/\(id)/output",
                            query: location + [.init(name: "cursor", value: String(cursor)), .init(name: "limit", value: "65536")],
                            body: nil, session: GitLabTransport.session)["data"]
                        let text = page?["output"]?.string ?? ""
                        let next = max(page?["cursor"]?.double.map(Int.init) ?? cursor, cursor + text.utf8.count)
                        let size = page?["size"]?.double.map(Int.init) ?? next
                        more = next > cursor && next < size
                        cursor = next
                        if !text.isEmpty { self.append(run, text) }
                    }
                    let status = try await client.send("GET", "/api/shell/\(id)", query: location, body: nil, session: GitLabTransport.session)["data"] ?? .null
                    failures = 0
                    let state = status["status"]?.string ?? ""
                    if state != "running" {
                        guard run.state.isActive else { return }
                        let code = status["exit"]?.double.map { Int($0) }
                        if run.stopRequested || state == "killed" { self.finish(run, .stopped) }
                        else if state == "exited", code == 0 { self.finish(run, run.task.kind == .service ? .failed("beendet") : .succeeded) }
                        else if state == "timeout" { self.finish(run, .failed("Zeitlimit")) }
                        else { self.finish(run, .failed("Exit \(code.map(String.init) ?? state)"), note: Self.networkHint(run.output)) }
                        _ = try? await client.send("DELETE", "/api/shell/\(id)", query: location, body: nil, session: GitLabTransport.session)
                        return
                    }
                } catch is CancellationError { return }
                catch {
                    failures += 1
                    if failures >= 5 {
                        self.finish(run, .lost("Verbindung verloren"), note: error.localizedDescription)
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
        return "Netzwerkzugriff in der Sandbox verweigert" + (host.map { " (vermutlich \($0))" } ?? "")
            + ". Nicht freigegebene Ziele lassen sich mit „devkcode allow-domain <host>“ für das Profil freigeben; danach Sandbox neu starten."
    }

    private static let maxOutput = 400_000

    private func append(_ run: BuildRun, _ text: String) {
        run.output += Self.clean(text)
        if run.output.count > Self.maxOutput {
            run.output = "… (ältere Ausgabe gekürzt)\n" + run.output.suffix(Self.maxOutput * 9 / 10)
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
