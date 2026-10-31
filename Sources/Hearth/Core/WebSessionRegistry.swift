import Foundation

/// Shared ISO-8601 parsing. Creating an `ISO8601DateFormatter` loads ICU data and is
/// expensive, and the registries are polled every few seconds, so the formatters are reused.
enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain = ISO8601DateFormatter()

    static func date(_ s: String) -> Date? {
        fractional.date(from: s) ?? plain.date(from: s)
    }
}

/// Read-only view on devkcode's web-session registry
/// (`~/.local/share/devkcode/web-sessions/registry.json`).
struct WebSessionEntry: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let repoRoot: String
    let profileName: String?
    let projectName: String?
    let port: String
    let pid: Int?
    let status: String
    let password: String?
    /// ISO-8601 time of the last `devkcode web` start.
    let lastStartedAtRaw: String?

    enum CodingKeys: String, CodingKey {
        case id, repoRoot, profileName, projectName, port, pid, status, password
        case lastStartedAtRaw = "lastStartedAt"
    }

    var lastStartedAt: Date? {
        lastStartedAtRaw.flatMap(ISO8601.date)
    }

    var isRunning: Bool { status == "running" }
    var baseURL: URL? { URL(string: "http://127.0.0.1:\(port)") }
    var displayName: String {
        projectName ?? URL(fileURLWithPath: repoRoot).lastPathComponent
    }
}

enum WebSessionRegistry {
    static let supportedVersion = 1

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/devkcode/web-sessions/registry.json")
    }

    struct File: Decodable {
        let version: Int
        let entries: [WebSessionEntry]
    }

    enum LoadError: Error, LocalizedError {
        case unsupportedVersion(Int)
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v):
                "devkcode web-session registry version \(v) is not supported (expected \(WebSessionRegistry.supportedVersion))"
            }
        }
    }

    static func load(from url: URL = defaultURL) throws -> [WebSessionEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> [WebSessionEntry] {
        let file = try JSONDecoder().decode(File.self, from: data)
        guard file.version == supportedVersion else { throw LoadError.unsupportedVersion(file.version) }
        return file.entries
    }

    /// The registry may still say "running" after a crash; verify the PID.
    static func isAlive(_ entry: WebSessionEntry) -> Bool {
        guard entry.isRunning, let pid = entry.pid, pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0
    }
}

/// Read-only view on devkcode's sandbox registry (every `devkcode run`,
/// `~/.local/share/devkcode/sandboxes/registry.json`) – what the dashboard lists.
struct SandboxEntry: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let profileName: String?
    let projectName: String?
    let repoRoot: String
    let pid: Int?
    let status: String
    let lastStartedAt: Date?

    enum Resolved: String, Sendable { case stopped, terminal, orphaned }

    /// Same rule as the dashboard: "running" with a dead PID is orphaned.
    var resolved: Resolved {
        guard status == "running" else { return .stopped }
        guard let pid, pid > 0, kill(pid_t(pid), 0) == 0 else { return .orphaned }
        return .terminal
    }
}

enum SandboxRegistry {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/devkcode/sandboxes/registry.json")
    }

    private struct File: Decodable {
        let version: Int
        let entries: [SandboxEntry]
    }

    static func load(from url: URL = defaultURL) -> [SandboxEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            ISO8601.date(try d.singleValueContainer().decode(String.self)) ?? .distantPast
        }
        guard let file = try? decoder.decode(File.self, from: data), file.version == 1 else { return [] }
        return file.entries
    }
}

/// One row in "not connected" sandboxes: merged from web sessions and `devkcode run` history.
struct SandboxListing: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable { case stopped, terminal, orphaned }
    let root: String
    let name: String
    let profile: String?
    let project: String?
    let state: State
    let lastStarted: Date?
    var id: String { root + "#" + (project ?? "") }
}
