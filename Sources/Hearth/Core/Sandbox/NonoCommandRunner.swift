import Foundation

/// Runs every command in its own nono sandbox for one folder, never directly on the Mac.
/// The purpose decides the rights (SandboxPolicy): `.build` for Build & Deployment,
/// `.gitNetwork` / `.gitLocal` for the Git pane.
actor NonoCommandRunner: SandboxCommandRunner {
    let root: String
    let purpose: SandboxPurpose

    init(root: String, purpose: SandboxPurpose) {
        self.root = root
        self.purpose = purpose
    }

    /// One command and its merged stdout/stderr. Filled from the pipe's reader thread.
    private final class Entry: @unchecked Sendable {
        let id: String
        let command: String
        let metadata: [String: String]
        let started = Date()
        let process = Process()
        private let lock = NSLock()
        private var buffer = Data()
        private var state = SandboxCommandState.running

        init(id: String, command: String, metadata: [String: String]) {
            self.id = id; self.command = command; self.metadata = metadata
        }

        func append(_ data: Data) { lock.lock(); buffer.append(data); lock.unlock() }

        func page(from cursor: Int, limit: Int) -> SandboxOutputPage {
            lock.lock(); defer { lock.unlock() }
            let start = min(max(cursor, 0), buffer.count)
            let end = min(start + max(limit, 0), buffer.count)
            return SandboxOutputPage(text: String(decoding: buffer[start..<end], as: UTF8.self), next: end, size: buffer.count)
        }

        var current: SandboxCommandState { lock.lock(); defer { lock.unlock() }; return state }

        /// Only the first final state counts (a kill or timeout wins over the exit that follows it).
        func finish(_ final: SandboxCommandState) {
            lock.lock(); defer { lock.unlock() }
            if state == .running { state = final }
        }
    }

    private var entries: [String: Entry] = [:]

    func start(_ request: SandboxCommandRequest) async throws -> String {
        let id = "sh_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Run from the workspace root (the sandbox's read/write folder); enter a project subfolder in the shell.
        var script = request.command
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        let dir = URL(fileURLWithPath: request.cwd).standardizedFileURL.path
        if dir != base {
            guard dir.hasPrefix(base + "/") else { throw SandboxCommandError("Verzeichnis liegt außerhalb des Workspace") }
            script = "cd " + Self.quote(dir) + " && " + request.command
        }
        let network = purpose == .gitNetwork
        let launch = try SandboxManager.prepare(purpose, runID: "cmd-" + id, directory: root,
                                                arguments: ["-f", "-c", script], statusHooks: false,
                                                openPorts: request.port.map { [$0] } ?? [],
                                                gitHosts: network ? Self.gitHosts(root: root) + Self.urlHosts(request.command) : [])
        let entry = Entry(id: id, command: request.command, metadata: request.metadata)
        let process = entry.process
        process.executableURL = URL(fileURLWithPath: launch.executable)
        process.arguments = launch.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: launch.directory)
        process.environment = Dictionary(launch.environment.compactMap { line -> (String, String)? in
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return (String(line[..<eq]), String(line[line.index(after: eq)...]))
        }, uniquingKeysWith: { $1 })
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { entry.append(data) }
        }
        process.terminationHandler = { p in
            // Drain what is left before reporting the end.
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { entry.append(rest) }
            entry.finish(p.terminationReason == .uncaughtSignal ? .killed : .exited(p.terminationStatus))
        }
        try process.run()
        entries[id] = entry
        if let timeout = request.timeout {
            Task { [weak entry] in
                try? await Task.sleep(for: timeout)
                guard let entry, entry.current == .running else { return }
                entry.finish(.timedOut)
                entry.process.terminate()
            }
        }
        return id
    }

    func state(of id: String) async throws -> SandboxCommandState {
        guard let entry = entries[id] else { throw SandboxCommandError("Unbekannter Vorgang") }
        return entry.current
    }

    func output(of id: String, from cursor: Int, limit: Int) async throws -> SandboxOutputPage {
        guard let entry = entries[id] else { throw SandboxCommandError("Unbekannter Vorgang") }
        return entry.page(from: cursor, limit: limit)
    }

    func remove(_ id: String) async {
        if let entry = entries.removeValue(forKey: id), entry.current == .running {
            entry.finish(.killed)
            entry.process.terminate()
        }
        try? FileManager.default.removeItem(at: SandboxManager.runDirectory("cmd-" + id))
    }

    func running() async -> [SandboxCommandInfo] {
        entries.values.filter { $0.current == .running }
            .map { SandboxCommandInfo(id: $0.id, command: $0.command, metadata: $0.metadata, started: $0.started) }
    }

    // MARK: Hosts for Git network commands

    /// Hosts of the repository's remotes, read from .git/config as a plain file (no Git
    /// process, nothing from the repository runs). Fetch/clone only download, so the
    /// Git pane may reach them; agents still need an explicit domain in the settings.
    static func gitHosts(root: String) -> [String] {
        let config = URL(fileURLWithPath: root).appendingPathComponent(".git/config")
        guard let text = try? String(contentsOf: config, encoding: .utf8) else { return [] }
        let urls = text.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("url"), let eq = t.firstIndex(of: "=") else { return nil }
            return t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return Array(Set(urls.compactMap(host(of:)))).sorted()
    }

    /// Hosts of URLs in a command (clone).
    static func urlHosts(_ command: String) -> [String] {
        command.split(whereSeparator: { $0 == " " || $0 == "'" }).compactMap { host(of: String($0)) }
    }

    /// Host of an https/ssh URL or scp-like `user@host:path`; nil for anything else.
    static func host(of url: String) -> String? {
        var host: String?
        if let u = URLComponents(string: url), ["https", "http", "ssh"].contains(u.scheme ?? "") { host = u.host }
        else if url.range(of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:"#, options: .regularExpression) != nil,
                let at = url.firstIndex(of: "@"), let colon = url[at...].firstIndex(of: ":") {
            host = String(url[url.index(after: at)..<colon])
        }
        guard let h = host?.lowercased(), SandboxSettings.validDomain(h) else { return nil }
        return h
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
