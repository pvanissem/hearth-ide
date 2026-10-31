import Foundation

enum SandboxGitOperation: Sendable {
    case fetch, pull, clone(String)

    var name: String {
        switch self { case .fetch: "fetch"; case .pull: "pull"; case .clone: "clone" }
    }

    /// Only fixed operations, never an arbitrary command supplied by a repository.
    func command() throws -> String {
        let args: [String]
        switch self {
        case .fetch: args = ["fetch", "--all", "--prune", "--no-recurse-submodules", "--progress"]
        case .pull: args = ["pull", "--ff-only", "--no-recurse-submodules", "--progress"]
        case .clone(let url):
            guard Self.validCloneURL(url) else { throw SandboxGitRunner.Failure("Bitte eine HTTPS- oder SSH-Git-URL ohne Passwort verwenden.") }
            args = ["clone", "--progress", "--no-recurse-submodules", "--", url, "."]
        }
        // Keep the sandbox's inherited GitLab proxy/credential configuration intact.
        // Helpers/filters may run inside that sandbox, never through the host dispatcher.
        let prefix = ["/usr/bin/env", "GIT_TERMINAL_PROMPT=0", "GCM_INTERACTIVE=never",
                      "GIT_ASKPASS=/usr/bin/false", "SSH_ASKPASS=/usr/bin/false", "SSH_ASKPASS_REQUIRE=never",
                      "/usr/bin/git", "--no-pager", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                      "-c", "diff.external=", "-c", "submodule.recurse=false", "-c", "protocol.ext.allow=never"]
        return (prefix + args).map(Self.quote).joined(separator: " ")
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func validCloneURL(_ value: String) -> Bool {
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        if value.range(of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[^\s]+$"#, options: .regularExpression) != nil { return true }
        guard let url = URLComponents(string: value), ["https", "ssh"].contains(url.scheme ?? ""),
              let host = url.host, !host.isEmpty, url.password == nil, url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true,
              url.scheme != "https" || url.user == nil, !url.path.isEmpty, url.path != "/" else { return false }
        return true
    }
}

/// Direct deterministic commands on the devkcode-managed server's shell API.
/// No host Process, agent prompt, chat session, or access to the app's GitLab PATs.
struct SandboxGitRunner: Sendable {
    let client: OpenCodeClient
    let root: URL
    var session: URLSession = GitLabTransport.session // ephemeral, no redirects/cookies
    var timeout: TimeInterval = 600
    var pollInterval: Duration = .milliseconds(200)

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private var location: [URLQueryItem] { [.init(name: "location[directory]", value: root.path)] }

    static func isLocalServer(_ base: URL) -> Bool {
        base.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(base.host ?? "") &&
            base.port != nil && base.user == nil && base.password == nil &&
            (base.path.isEmpty || base.path == "/") && base.query == nil && base.fragment == nil
    }

    func run(_ operation: SandboxGitOperation,
             progress: @escaping @Sendable (String, Double?) -> Void = { _, _ in }) async -> Git.OpResult {
        var id: String?
        do {
            guard Self.isLocalServer(client.baseURL), root.isFileURL, root.path.hasPrefix("/") else {
                throw Failure("Kein gültiger lokaler devkcode-Sandbox-Server. Kein Host-Fallback.")
            }
            try Task.checkCancellation()
            let created = try await client.send("POST", "/api/shell", query: location,
                body: ["command": try operation.command(), "cwd": root.path,
                       "metadata": ["source": "Hearth IDE", "operation": "git-" + operation.name]], session: session)["data"]
            guard let shellID = created?["id"]?.string, !shellID.isEmpty,
                  shellID.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                throw Failure("Sandbox-Shell lieferte keine gültige Vorgangs-ID.")
            }
            id = shellID
            var status = created ?? .null
            var cursor = 0
            var output = ""
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                try Task.checkCancellation()
                guard Date() < deadline else { throw Failure("Git-Vorgang hat das Zeitlimit erreicht und wird in der Sandbox beendet.") }
                // Drain output by byte cursor, including output larger than one page.
                var more = true
                while more {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw Failure("Zeitlimit beim Lesen der Git-Ausgabe erreicht.") }
                    let page = try await client.send("GET", "/api/shell/\(shellID)/output",
                        query: location + [.init(name: "cursor", value: String(cursor)), .init(name: "limit", value: "65536")], session: session)["data"]
                    let text = page?["output"]?.string ?? ""
                    let next = max(page?["cursor"]?.double.map(Int.init) ?? cursor, cursor + text.utf8.count)
                    let size = page?["size"]?.double.map(Int.init) ?? next
                    more = next > cursor && next < size
                    cursor = next
                    if !text.isEmpty {
                        output += text
                        if output.count > 200_000 { output = "…\n" + output.suffix(180_000) }
                        progress(Self.lastLine(text), Self.fraction(text))
                    }
                }
                let state = status["status"]?.string ?? ""
                if ["exited", "timeout", "killed"].contains(state) {
                    let ok = state == "exited" && status["exit"]?.double == 0
                    await remove(shellID)
                    return Git.OpResult(ok: ok, output: output.isEmpty ? (ok ? "Git \(operation.name) abgeschlossen" : "Git \(operation.name): \(state)") : output.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                guard state == "running" else { throw Failure("Unbekannter Sandbox-Shell-Status: \(state)") }
                try await Task.sleep(for: pollInterval)
                status = try await client.send("GET", "/api/shell/\(shellID)", query: location, session: session)["data"] ?? .null
            }
        } catch {
            if let id { await remove(id) }
            let detail = error is CancellationError ? "Git-Vorgang abgebrochen." : error.localizedDescription
            return Git.OpResult(ok: false, output: detail + "\nKeine Ausführung auf dem Host.")
        }
    }

    private func remove(_ id: String) async {
        let client = client, location = location, session = session
        // Cleanup must survive cancellation of the calling UI task.
        _ = await Task.detached {
            try? await client.send("DELETE", "/api/shell/\(id)", query: location, session: session)
        }.value
    }

    private static func lastLine(_ text: String) -> String {
        text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).last.map(String.init) ?? text
    }

    private static func fraction(_ text: String) -> Double? {
        let line = lastLine(text)
        guard let range = line.range(of: #"\d+%"#, options: .regularExpression), let value = Double(line[range].dropLast()) else { return nil }
        return min(1, max(0, value / 100))
    }
}
