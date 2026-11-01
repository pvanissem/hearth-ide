import Foundation
import Testing
@testable import Hearth

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ value: Bool, _ message: String) throws {
    if !value { throw TestFailure(description: message) }
}

func need<T>(_ value: T?, _ message: String = "Erwarteter Wert fehlt") throws -> T {
    guard let value else { throw TestFailure(description: message) }
    return value
}

/// A fresh folder under the temporary directory, removed by the caller.
func temporaryFolder(_ name: String = "hearth-test") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

/// In-memory sandbox: every started command plays the same script. Each output read
/// advances one step, like a process producing output over time.
final class FakeCommandRunner: SandboxCommandRunner, @unchecked Sendable {
    enum Step { case output(String), exit(Int32), running }
    private let lock = NSLock()
    private var _requests: [SandboxCommandRequest] = []
    private var _removed: [String] = []
    private var script: [Step] = []
    private var output = ""
    private var state = SandboxCommandState.running
    private var counter = 0
    var failStart = false
    var list: [SandboxCommandInfo] = []

    var requests: [SandboxCommandRequest] { lock.lock(); defer { lock.unlock() }; return _requests }
    var removed: [String] { lock.lock(); defer { lock.unlock() }; return _removed }

    init(_ steps: [Step] = []) { script = steps }

    func reset(_ steps: [Step]) {
        lock.lock(); defer { lock.unlock() }
        _requests = []; _removed = []; script = steps; output = ""; state = .running; failStart = false
    }

    private func advance() {
        guard !script.isEmpty else { return }
        switch script.removeFirst() {
        case .output(let text): output += text
        case .exit(let code): state = .exited(code)
        case .running: script.insert(.running, at: 0)
        }
    }

    func start(_ request: SandboxCommandRequest) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        _requests.append(request)
        if failStart { throw SandboxCommandError("Sandbox nicht verfügbar") }
        counter += 1
        return "sh_\(counter)"
    }

    func state(of id: String) async throws -> SandboxCommandState {
        lock.lock(); defer { lock.unlock() }
        // A real process keeps working between polls.
        advance()
        return state
    }

    func output(of id: String, from cursor: Int, limit: Int) async throws -> SandboxOutputPage {
        lock.lock(); defer { lock.unlock() }
        advance()
        let bytes = Array(output.utf8)
        let start = min(max(cursor, 0), bytes.count), end = min(start + limit, bytes.count)
        return SandboxOutputPage(text: String(decoding: bytes[start..<end], as: UTF8.self), next: end, size: bytes.count)
    }

    func remove(_ id: String) async {
        lock.lock(); defer { lock.unlock() }
        _removed.append(id)
        if state == .running { state = .killed }
    }

    func running() async -> [SandboxCommandInfo] { list }
}
