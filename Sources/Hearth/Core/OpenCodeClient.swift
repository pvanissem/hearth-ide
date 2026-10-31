import Foundation

/// Client for the OpenCode v2 HTTP API (`/api/*`) of one sandboxed server.
struct OpenCodeClient: Sendable {
    let baseURL: URL
    let password: String
    var transportSession: URLSession = .shared

    enum ClientError: Error, LocalizedError {
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .http(let code, let body): "HTTP \(code): \(body.prefix(200))"
            }
        }
    }

    private func request(_ method: String, _ path: String,
                         query: [URLQueryItem] = [], body: [String: Any]? = nil) -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        let token = Data("opencode:\(password)".utf8).base64EncodedString()
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    @discardableResult
    func send(_ method: String, _ path: String,
              query: [URLQueryItem] = [], body: [String: Any]? = nil,
              session: URLSession? = nil) async throws -> JSON {
        let (data, resp) = try await (session ?? transportSession).data(for: request(method, path, query: query, body: body))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw ClientError.http(code, String(decoding: data, as: UTF8.self))
        }
        return data.isEmpty ? .null : (JSON.parse(data) ?? .null)
    }

    // MARK: Sessions

    func sessions(directory: String) async throws -> [JSON] {
        try await send("GET", "/api/session", query: [.init(name: "limit", value: "50"),
                                                      .init(name: "archived", value: "false"),
                                                      .init(name: "directory", value: directory)])["data"]?.array ?? []
    }

    func activeSessionIDs() async throws -> Set<String> {
        Set(try await send("GET", "/api/session/active")["data"]?.object.keys.map { $0 } ?? [])
    }

    func createSession(title: String?) async throws -> JSON {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        return try await send("POST", "/api/session", body: body)["data"] ?? .null
    }

    func messages(sessionID: String) async throws -> [JSON] {
        try await send("GET", "/api/session/\(sessionID)/message",
                       query: [.init(name: "limit", value: "200")])["data"]?.array ?? []
    }

    func prompt(sessionID: String, text: String, skills: [String] = [], messageID: String? = nil) async throws {
        var body: [String: Any] = ["text": text]
        if let messageID { body["id"] = messageID }
        if !skills.isEmpty { body["skills"] = skills.map { ["id": $0] } }
        try await send("POST", "/api/session/\(sessionID)/prompt", body: body)
    }

    func skills() async throws -> [JSON] {
        try await send("GET", "/api/skill")["data"]?.array ?? []
    }

    func interrupt(sessionID: String) async throws {
        try await send("POST", "/api/session/\(sessionID)/interrupt")
    }

    func commands() async throws -> [JSON] {
        try await send("GET", "/api/command")["data"]?.array ?? []
    }

    func runCommand(sessionID: String, name: String, arguments: String) async throws {
        try await send("POST", "/api/session/\(sessionID)/command", body: ["name": name, "text": arguments])
    }

    func compact(sessionID: String) async throws {
        try await send("POST", "/api/session/\(sessionID)/compact", body: [:])
    }

    /// Calls a server-side plugin RPC (e.g. copilot-usage/status).
    func rpc(_ id: String, _ method: String, input: [String: Any] = [:]) async throws -> JSON {
        try await send("POST", "/api/rpc/\(id)/\(method)", body: ["input": input])["output"] ?? .null
    }

    /// Usage statistics since `from` (experimental endpoint, used by the copilot-usage plugin too).
    func sessionStats(from: Date) async throws -> JSON {
        try await send("GET", "/api/experimental/session/stats",
                       query: [.init(name: "from", value: String(Int(from.timeIntervalSince1970 * 1000))),
                               .init(name: "tools", value: "none")])["data"] ?? .null
    }

    func updateSession(_ sessionID: String, title: String? = nil, archived: Bool? = nil) async throws {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let archived { body["archived"] = archived }
        try await send("PATCH", "/api/session/\(sessionID)", body: body)
    }

    func deleteSession(_ sessionID: String) async throws {
        try await send("DELETE", "/api/session/\(sessionID)")
    }

    // MARK: Input requests

    func pendingPermissions() async throws -> [JSON] {
        try await send("GET", "/api/permission/request")["data"]?.array ?? []
    }

    func replyPermission(sessionID: String, requestID: String, decision: String) async throws {
        try await send("POST", "/api/session/\(sessionID)/permission/\(requestID)/reply",
                       body: ["decision": decision])
    }

    func pendingForms() async throws -> [JSON] {
        try await send("GET", "/api/form")["data"]?.array ?? []
    }

    func replyForm(sessionID: String, formID: String, answer: [String: Any]) async throws {
        try await send("POST", "/api/session/\(sessionID)/form/\(formID)/reply", body: ["answer": answer])
    }

    func cancelForm(sessionID: String, formID: String) async throws {
        try await send("DELETE", "/api/session/\(sessionID)/form/\(formID)")
    }

    // MARK: Agents & models

    func agents() async throws -> [JSON] {
        try await send("GET", "/api/agent")["data"]?.array ?? []
    }

    func models(directory: String? = nil, session: URLSession? = nil) async throws -> [JSON] {
        try await send("GET", "/api/model", query: directory.map { [.init(name: "location[directory]", value: $0)] } ?? [], session: session)["data"]?.array ?? []
    }

    func defaultModel(directory: String? = nil, session: URLSession? = nil) async throws -> JSON {
        try await send("GET", "/api/model/default", query: directory.map { [.init(name: "location[directory]", value: $0)] } ?? [], session: session)["data"] ?? .null
    }

    func switchAgent(sessionID: String, agent: String) async throws {
        try await send("POST", "/api/session/\(sessionID)/agent", body: ["agent": agent])
    }

    func switchModel(sessionID: String, providerID: String, modelID: String) async throws {
        try await send("POST", "/api/session/\(sessionID)/model",
                       body: ["model": ["id": modelID, "providerID": providerID]])
    }

    // MARK: Events

    /// Server-sent events from `/api/event`. Each element is the decoded `data:` payload.
    func events() -> AsyncThrowingStream<JSON, Error> {
        let req = request("GET", "/api/event")
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var streamReq = req
                    streamReq.timeoutInterval = .infinity
                    let (bytes, resp) = try await transportSession.bytes(for: streamReq)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    guard code == 200 else { throw ClientError.http(code, "event stream") }
                    for try await line in bytes.lines where line.hasPrefix("data:") {
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if let json = JSON.parse(Data(payload.utf8)) { continuation.yield(json) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
