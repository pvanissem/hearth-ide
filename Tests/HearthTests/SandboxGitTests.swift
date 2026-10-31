import Foundation
import Testing
@testable import Hearth

@MainActor
struct SandboxGitTests {
    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw SandboxGitRunner.Failure(message) }
    }

    @Test func directNetworkOperations() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockSandboxHTTP.self]
        let session = URLSession(configuration: config, delegate: GitLabTransport(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let root = URL(fileURLWithPath: "/workspace/repository")
        let client = OpenCodeClient(baseURL: URL(string: "http://127.0.0.1:12345")!, password: "dummy-sandbox-password")
        var runner = SandboxGitRunner(client: client, root: root, session: session)
        runner.pollInterval = .milliseconds(1)
        for operation in [SandboxGitOperation.fetch, .pull, .clone("https://git.example.test/group/repo.git")] {
            MockSandboxHTTP.reset(.success)
            let result = await runner.run(operation)
            try require(result.ok && result.output.contains("Done"), "Sandbox Git \(operation.name) did not finish/drain final output")
            let requests = MockSandboxHTTP.requests
            try require(requests.first?.url?.path == "/api/shell", "Not a direct shell API command")
            try require(!requests.contains { $0.url?.path.contains("/session") == true || $0.url?.path.contains("/prompt") == true }, "Created chat session or LLM prompt")
            try require(requests.last?.httpMethod == "DELETE", "Retained shell not removed")
            try require(requests.filter { $0.url?.path.hasSuffix("/output") == true }.count >= 3, "Output paging not exercised")
            let body = try JSONSerialization.jsonObject(with: requests.first!.httpBody!) as! [String: Any]
            let command = body["command"] as? String ?? ""
            try require(command == operation.command(), "Unexpected command construction")
            try require(body["cwd"] as? String == root.path, "Wrong command directory")
            try require(command.contains("core.hooksPath=/dev/null") && command.contains("core.fsmonitor=false"), "Unsafe hook policy")
            for request in requests {
                try require(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil, "App PAT sent to shell API")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
                try require(query.contains(.init(name: "location[directory]", value: root.path)), "Wrong API location")
            }
        }
        MockSandboxHTTP.reset(.unsupported)
        let unsupported = await runner.run(.fetch)
        try require(!unsupported.ok && unsupported.output.contains("Keine Ausführung auf dem Host"), "Unsupported API fell back to host")
        try require(MockSandboxHTTP.requests.count == 1, "Unsupported API retried a different execution path")

        MockSandboxHTTP.reset(.success)
        runner.timeout = 0
        let timeout = await runner.run(.pull)
        try require(!timeout.ok && MockSandboxHTTP.requests.last?.httpMethod == "DELETE", "Timeout did not cancel retained shell")

        MockSandboxHTTP.reset(.success)
        let remoteClient = OpenCodeClient(baseURL: URL(string: "https://attacker.invalid")!, password: "dummy")
        let invalid = await SandboxGitRunner(client: remoteClient, root: root, session: session).run(.fetch)
        try require(!invalid.ok && MockSandboxHTTP.requests.isEmpty, "Non-loopback shell server accepted")

        for url in ["http://git.example.test/g/r", "https://token@git.example.test/g/r", "ext::sh -c bad", "-u bad", "ssh://git:password@git.example.test/g/r", "https://git.example.test/g/r\nmalicious"] {
            try require(!SandboxGitOperation.validCloneURL(url), "Unsafe clone URL accepted")
        }
        let quoted = SandboxGitOperation.quote("a'b;$(touch /not-executed)")
        try require(quoted == "'a'\\''b;$(touch /not-executed)'", "Shell quoting regression")
        try require(SandboxGitOperation.validCloneURL("git@git.example.test:group/repo.git"), "SSH clone rejected")
    }
}

private final class MockSandboxHTTP: URLProtocol, @unchecked Sendable {
    enum Mode { case success, unsupported }
    private static let lock = NSLock()
    private static var mode = Mode.success
    private static var captured: [URLRequest] = []
    private static var exited = false
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    static func reset(_ value: Mode) {
        lock.lock(); defer { lock.unlock() }
        mode = value; captured = []; exited = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
            recorded.httpBody = data
        }
        Self.captured.append(recorded)
        let mode = Self.mode
        let method = request.httpMethod ?? "GET"
        let path = request.url!.path
        var data: Any = [:]
        var code = 200
        if mode == .unsupported { code = 404 }
        else if method == "POST", path == "/api/shell" {
            data = ["id": "shell_test", "status": "running"]
        } else if method == "GET", path == "/api/shell/shell_test" {
            Self.exited = true
            data = ["id": "shell_test", "status": "exited", "exit": 0]
        } else if method == "GET", path.hasSuffix("/output") {
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            let cursor = Int(items.first { $0.name == "cursor" }?.value ?? "0") ?? 0
            let head = "Receiving objects: 50%\r" + String(repeating: "x", count: 70_000)
            let text = head + (Self.exited ? "\nDone\n" : "")
            let bytes = Data(text.utf8)
            let start = min(cursor, bytes.count), end = min(start + 65536, bytes.count)
            data = ["output": String(decoding: bytes[start..<end], as: UTF8.self), "cursor": end, "size": bytes.count, "truncated": false]
        } else if method != "DELETE" { code = 400 }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: (try? JSONSerialization.data(withJSONObject: ["data": data])) ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
