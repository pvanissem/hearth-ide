import Foundation

/// Runs shell commands inside a sandbox and reports their output and status.
/// Build & Deployment and the Git pane only ever execute through this protocol;
/// there is no host fallback. `NonoCommandRunner` is the real implementation,
/// tests use an in-memory one.
protocol SandboxCommandRunner: Sendable {
    func start(_ request: SandboxCommandRequest) async throws -> String
    func state(of id: String) async throws -> SandboxCommandState
    func output(of id: String, from cursor: Int, limit: Int) async throws -> SandboxOutputPage
    /// Stops the command if it still runs and forgets it.
    func remove(_ id: String) async
    /// Commands still running (to re-attach services after the view was rebuilt).
    func running() async -> [SandboxCommandInfo]
}

struct SandboxCommandRequest: Sendable, Equatable {
    var command: String
    /// Working directory inside the sandbox's folder.
    var cwd: String
    /// Local port the command may listen on (services).
    var port: Int?
    var timeout: Duration?
    /// Free-form labels, e.g. which build task started the command.
    var metadata: [String: String] = [:]
}

enum SandboxCommandState: Sendable, Equatable {
    case running
    case exited(Int32)
    case timedOut
    case killed

    var isRunning: Bool { self == .running }
}

struct SandboxOutputPage: Sendable, Equatable {
    var text: String
    /// Cursor for the next read.
    var next: Int
    /// Bytes of output so far.
    var size: Int
}

struct SandboxCommandInfo: Sendable, Equatable {
    let id: String
    let command: String
    let metadata: [String: String]
    let started: Date
}

struct SandboxCommandError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
