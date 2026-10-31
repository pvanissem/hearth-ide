import Foundation
import Testing
@testable import Hearth

@MainActor
struct ModelsAndSessionListTests {
    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw SandboxGitRunner.Failure(message) }
    }
    private func json(_ data: Any) throws -> JSON { JSON.parse(try JSONSerialization.data(withJSONObject: data))! }

    @Test func modelFactsAndCredentialOrigins() throws {
        let account = try json(["data": [
            ["id": "allowed", "model_picker_enabled": true, "policy": ["state": "enabled"]],
            ["id": "disabled", "model_picker_enabled": true, "policy": ["state": "disabled"]],
            ["id": "unknown", "model_picker_enabled": true],
            ["id": "unconfigured", "model_picker_enabled": true, "policy": ["state": "unconfigured"]],
            ["id": "utility", "model_picker_enabled": false, "policy": ["state": "enabled"]]
        ]])
        let ids = try ModelCatalog.confirmedCopilotIDs(account)
        try require(ids == ["allowed"], "Unconfirmed or hidden Copilot model is selectable")
        do {
            _ = try ModelCatalog.confirmedCopilotIDs(json(["data": ["unexpected": true]]))
            throw SandboxGitRunner.Failure("Malformed policy response accepted")
        } catch is CopilotModelAccess.Failure {}
        let rows = try json(["data": [
            ["id": "alias", "modelID": "allowed", "providerID": "github-copilot", "name": "Allowed", "enabled": true],
            ["id": "disabled", "providerID": "github-copilot", "enabled": true],
            ["id": "unknown", "providerID": "github-copilot", "enabled": true],
            ["id": "allowed-but-local-off", "modelID": "allowed", "providerID": "github-copilot", "enabled": false],
            ["id": "missing-flag", "modelID": "allowed", "providerID": "github-copilot"],
            ["id": "other", "providerID": "other", "enabled": true],
            ["id": "image", "providerID": "other", "enabled": true, "type": "image"]
        ]])["data"]!.array
        try require(Set(ModelCatalog.selectable(rows, copilotIDs: ids).map(\.ref.id)) == ["alias", "other"], "Account/local/type filters not intersected")
        try require(ModelCatalog.selectable(rows, copilotIDs: nil).map(\.ref.id) == ["other"], "Availability failure offered all Copilot models")

        func credentials(endpoint: String = "https://api.githubcopilot.com", enterprise: String? = nil, token: String = "dummy-copilot") throws -> JSON {
            var metadata = ["apiEndpoint": endpoint]
            if let enterprise { metadata["enterpriseUrl"] = enterprise }
            return try json(["data": [["id": "account", "integrationID": "github-copilot", "active": true,
                "value": ["type": "oauth", "refresh": token, "access": "unused", "metadata": metadata]]]])
        }
        let request = try CopilotModelAccess.request(for: credentials())
        try require(request.url?.absoluteString == "https://api.githubcopilot.com/models", "Unexpected credential destination")
        try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer dummy-copilot", "Wrong active account credential")
        var ambiguous = try credentials()
        if case .object(var object) = ambiguous, let first = object["data"]?.array.first {
            object["data"] = .array([first, first]); ambiguous = .object(object)
        }
        do {
            _ = try CopilotModelAccess.request(for: ambiguous)
            throw SandboxGitRunner.Failure("Ambiguous active account selected")
        } catch is CopilotModelAccess.Failure {}
        for endpoint in ["https://attacker.invalid", "https://api.githubcopilot.com.attacker.invalid", "http://api.githubcopilot.com",
                         "https://api.githubcopilot.com:8443", "https://api.githubcopilot.com/path", "https://api.githubcopilot.com?x=1",
                         "https://api.githubcopilot.com@attacker.invalid"] {
            do {
                _ = try CopilotModelAccess.request(for: credentials(endpoint: endpoint))
                throw SandboxGitRunner.Failure("Credential accepted for unapproved origin")
            } catch is CopilotModelAccess.Failure {}
        }
        do {
            _ = try CopilotModelAccess.request(for: credentials(enterprise: "company.ghe.com"))
            throw SandboxGitRunner.Failure("Enterprise credential sent to public origin")
        } catch is CopilotModelAccess.Failure {}
        do {
            _ = try CopilotModelAccess.request(for: credentials(token: "dummy\r\nX-Header:bad"))
            throw SandboxGitRunner.Failure("Invalid token accepted")
        } catch is CopilotModelAccess.Failure {}
    }

    @Test func catalogRefreshAndFailureAreSafe() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ModelAccessHTTP.self]
        let transport = URLSession(configuration: config, delegate: GitLabTransport(), delegateQueue: nil)
        defer { transport.invalidateAndCancel() }
        let entry = try JSONDecoder().decode(WebSessionEntry.self, from: Data(#"{"id":"models","repoRoot":"/workspace","port":"12345","status":"running"}"#.utf8))
        let client = OpenCodeClient(baseURL: URL(string: "http://127.0.0.1:12345")!, password: "dummy-server", transportSession: transport)
        let connection = ServerConnection(entry: entry, client: client, notify: { _, _ in }, modelAccess: CopilotModelAccess(session: transport))
        ModelAccessHTTP.reset(.success)
        async let one: Void = connection.refreshModels()
        async let two: Void = connection.refreshModels()
        _ = await (one, two)
        try require(Set(connection.models.map(\.ref.id)) == ["allowed", "other"], "Refresh does not use account approvals")
        try require(connection.modelsError == nil && !connection.modelsLoading, "Loading state not cleared")
        try require(ModelAccessHTTP.requests.filter { $0.url?.path == "/models" }.count == 1, "Concurrent refresh duplicated credential requests")
        let suggestions = SlashCommands.suggestions(draft: "/model ", server: [], models: connection.models, agents: [])
        try require(!suggestions.contains { $0.insertion.contains("unknown") || $0.insertion.contains("disabled") }, "Slash model menu bypasses availability")
        for request in ModelAccessHTTP.requests where request.url?.host == "api.githubcopilot.com" {
            try require(request.value(forHTTPHeaderField: "Authorization") == "Bearer dummy-copilot", "Local auth leaked into external request")
            try require(request.httpMethod == "GET" && request.httpBody == nil, "Account policy lookup is not read-only")
        }
        ModelAccessHTTP.reset(.unavailable)
        await connection.refreshModels()
        try require(connection.models.map(\.ref.id) == ["other"] && connection.modelsError != nil, "Failure restored full Copilot catalog")
        try require(connection.modelsError?.contains("do-not-display") != true, "Remote error body exposed")
        ModelAccessHTTP.reset(.untrustedOrigin)
        await connection.refreshModels()
        try require(connection.models.map(\.ref.id) == ["other"], "Unknown endpoint bypasses account checks")
        try require(ModelAccessHTTP.requests.allSatisfy { $0.url?.host == "127.0.0.1" }, "Token left local server for unknown endpoint")
        ModelAccessHTTP.reset(.revoked)
        await connection.refreshModels()
        try require(connection.models.map(\.ref.id) == ["other"], "Revoked policy remained cached")
    }

    @Test func sessionGroupsPersistAndKeepSelection() throws {
        let first = SessionListDisclosure.key(root: "/workspace/a", project: nil)
        let second = SessionListDisclosure.key(root: "/workspace/b", project: "b")
        var state = SessionListDisclosure()
        try require(state.isExpanded(first) && state.attentionExpanded, "Groups unexpectedly collapsed by default")
        state.setExpanded(false, for: first)
        state.attentionExpanded = false
        let restored = try JSONDecoder().decode(SessionListDisclosure.self, from: JSONEncoder().encode(state))
        try require(!restored.isExpanded(first) && restored.isExpanded(second) && !restored.attentionExpanded, "Disclosure state not independent/persisted")
        state.setExpanded(true, for: first)
        try require(state.isExpanded(first), "Group cannot reopen")
        let sessions = (0..<8).map { SessionItem(id: "s\($0)", serverID: "server", title: "Session", directory: "/workspace/a", updated: Date(), status: .idle) }
        let preview = SessionListDisclosure.preview(sessions, limit: 5, selectedID: "s7")
        try require(preview.count == 6 && preview.last?.id == "s7", "Selected session hidden by preview limit")
        try require(SessionListDisclosure.preview(sessions, limit: 5, selectedID: "s1").count == 5, "Selected session duplicated")
    }
}

private final class ModelAccessHTTP: URLProtocol, @unchecked Sendable {
    enum Mode { case success, unavailable, untrustedOrigin, revoked }
    private static let lock = NSLock()
    private static var mode = Mode.success
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func reset(_ value: Mode) { lock.lock(); defer { lock.unlock() }; mode = value; recorded = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.recorded.append(request); let mode = Self.mode; Self.lock.unlock()
        let payload: [String: Any]
        var status = 200
        switch request.url!.path {
        case "/api/model": payload = ["data": [
            ["id": "allowed", "providerID": "github-copilot", "enabled": true],
            ["id": "unknown", "providerID": "github-copilot", "enabled": true],
            ["id": "other", "providerID": "other", "enabled": true]
        ]]
        case "/api/model/default": payload = ["data": ["id": "unknown", "providerID": "github-copilot"]]
        case "/api/credential": payload = ["data": [["id": "account", "integrationID": "github-copilot", "active": true,
            "value": ["type": "oauth", "refresh": "dummy-copilot", "access": "unused", "metadata": ["apiEndpoint": mode == .untrustedOrigin ? "https://attacker.invalid" : "https://api.githubcopilot.com"]]]]]
        case "/models":
            if mode == .unavailable { status = 503; payload = ["error": "do-not-display-dummy-secret"] }
            else { payload = ["data": [
                ["id": "allowed", "model_picker_enabled": true, "policy": ["state": mode == .revoked ? "disabled" : "enabled"]],
                ["id": "unknown", "model_picker_enabled": true]
            ]] }
        default: status = 404; payload = [:]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
