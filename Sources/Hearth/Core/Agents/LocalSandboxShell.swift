import Foundation

/// The OpenCode shell API subset Build & Deployment uses (`/api/shell…`), served
/// locally: every command runs in its own nono sandbox for the workspace, never
/// directly on the Mac. Lets the build pane work for agent sessions without a
/// devkcode/OpenCode server.
actor LocalSandboxShell: HearthSandboxShell {
    let root: String
    /// Git pane shells may use SSH keys, the keychain and port 22 (see SandboxManager.profile).
    let gitAccess: Bool

    init(root: String, gitAccess: Bool = false) { self.root = root; self.gitAccess = gitAccess }

    /// One command and its merged stdout/stderr. Filled from the pipe's reader thread.
    private final class Entry: @unchecked Sendable {
        let id: String
        let command: String
        let metadata: [String: Any]
        let started = Date()
        let process = Process()
        private let lock = NSLock()
        private var buffer = Data()
        private var _status = "running"
        private var _exit: Int32?

        init(id: String, command: String, metadata: [String: Any]) {
            self.id = id; self.command = command; self.metadata = metadata
        }

        func append(_ data: Data) { lock.lock(); buffer.append(data); lock.unlock() }
        func output(from cursor: Int, limit: Int) -> (String, Int, Int) {
            lock.lock(); defer { lock.unlock() }
            let start = min(max(cursor, 0), buffer.count)
            let end = min(start + limit, buffer.count)
            return (String(decoding: buffer[start..<end], as: UTF8.self), end, buffer.count)
        }
        var state: (String, Int32?) { lock.lock(); defer { lock.unlock() }; return (_status, _exit) }
        func finish(_ status: String?, exit: Int32) {
            lock.lock(); defer { lock.unlock() }
            guard _status == "running" else { return }
            _status = status ?? "exited"; _exit = exit
        }
        func mark(_ status: String) { lock.lock(); if _status == "running" { _status = status }; lock.unlock() }
    }

    private var entries: [String: Entry] = [:]

    func send(_ method: String, _ path: String, query: [URLQueryItem], body: [String: Any]?, session: URLSession?) async throws -> JSON {
        let parts = path.split(separator: "/").map(String.init)   // ["api", "shell", id?, "output"?]
        guard parts.count >= 2, parts[0] == "api", parts[1] == "shell" else { throw Failure("Nicht unterstützt: \(path)") }
        func q(_ name: String) -> Int? { query.first { $0.name == name }?.value.flatMap(Int.init) }
        switch (method, parts.count) {
        case ("POST", 2):
            return try wrap(["id": create(body ?? [:]), "status": "running"])
        case ("GET", 2):
            return try wrap(entries.values.filter { $0.state.0 == "running" }.map { e in
                ["id": e.id, "command": e.command, "metadata": e.metadata,
                 "status": "running", "time": ["started": e.started.timeIntervalSince1970 * 1000]] as [String: Any]
            })
        case ("GET", 3):
            guard let e = entries[parts[2]] else { throw Failure("Unbekannter Vorgang") }
            let (status, code) = e.state
            var data: [String: Any] = ["id": e.id, "status": status]
            if let code { data["exit"] = Int(code) }
            return try wrap(data)
        case ("GET", 4) where parts[3] == "output":
            guard let e = entries[parts[2]] else { throw Failure("Unbekannter Vorgang") }
            let (text, cursor, size) = e.output(from: q("cursor") ?? 0, limit: q("limit") ?? 65536)
            return try wrap(["output": text, "cursor": cursor, "size": size])
        case ("DELETE", 3):
            if let e = entries.removeValue(forKey: parts[2]), e.state.0 == "running" {
                e.mark("killed")
                e.process.terminate()
            }
            try? FileManager.default.removeItem(at: SandboxManager.runDirectory("build-" + parts[2]))
            return .null
        default:
            throw Failure("Nicht unterstützt: \(method) \(path)")
        }
    }

    private func create(_ body: [String: Any]) throws -> String {
        guard let command = body["command"] as? String else { throw Failure("Kein Befehl") }
        let id = "sh_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let metadata = body["metadata"] as? [String: Any] ?? [:]
        var ports: [Int] = []
        if let port = metadata["port"] as? Int { ports.append(port) }
        // Run from the workspace root (the sandbox's read/write folder); enter a project subfolder in the shell.
        var script = command
        if let cwd = body["cwd"] as? String, cwd != root {
            let base = URL(fileURLWithPath: root).standardizedFileURL.path
            let dir = URL(fileURLWithPath: cwd).standardizedFileURL.path
            guard dir.hasPrefix(base + "/") else { throw Failure("Verzeichnis liegt außerhalb des Workspace") }
            script = "cd '\(dir.replacingOccurrences(of: "'", with: "'\\''"))' && " + command
        }
        let launch = try SandboxManager.prepare(kind: .shell, runID: "build-" + id, directory: root,
                                                agentArguments: ["-f", "-c", script], statusHooks: false, openPorts: ports,
                                                gitAccess: gitAccess)
        let entry = Entry(id: id, command: command, metadata: metadata)
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
            entry.finish(p.terminationReason == .uncaughtSignal ? "killed" : nil, exit: p.terminationStatus)
        }
        try process.run()
        entries[id] = entry
        if let ms = body["timeout"] as? Int {
            Task { [weak entry] in
                try? await Task.sleep(for: .milliseconds(ms))
                guard let entry, entry.state.0 == "running" else { return }
                entry.mark("timeout")
                entry.process.terminate()
            }
        }
        return id
    }

    private func wrap(_ data: Any) throws -> JSON {
        let raw = try JSONSerialization.data(withJSONObject: ["data": data])
        return JSON.parse(raw) ?? .null
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
