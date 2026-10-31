import Foundation
import Security

/// A canonical HTTPS origin, independent of any repository-controlled project path.
struct GitLabOrigin: Hashable, Codable, Sendable {
    let url: URL
    var value: String { url.absoluteString }
    var authority: String { String(value.dropFirst("https://".count)) }

    static func parse(_ value: String) -> GitLabOrigin? {
        guard let c = URLComponents(string: value), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, c.path.isEmpty || c.path == "/",
              c.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        var clean = URLComponents()
        clean.scheme = "https"
        clean.host = host.lowercased()
        clean.port = c.port == 443 ? nil : c.port
        guard let url = clean.url else { return nil }
        return GitLabOrigin(url: url)
    }
}

/// Parsing a remote does NOT authorize this server to receive a token.
struct GitLabRemote: Hashable, Sendable {
    let origin: GitLabOrigin
    let path: String          // e.g. "group/project"
    var host: String { origin.authority }

    var webURL: URL { URL(string: "https://\(host)/\(path)")! }
    var apiBase: URL { URL(string: "https://\(host)/api/v4")! }

    /// Parses git@host:group/repo.git, ssh://git@host[:port]/group/repo.git and https://host/group/repo.git.
    static func parse(_ remote: String) -> GitLabRemote? {
        var s = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        if let m = s.range(of: #"^[\w.-]+@([^:/]+):(.+)$"#, options: .regularExpression), m.lowerBound == s.startIndex {
            let parts = s.split(separator: "@", maxSplits: 1)[1].split(separator: ":", maxSplits: 1)
            return validated(origin: "https://\(parts[0])", path: String(parts[1]))
        }
        guard let url = URL(string: s), let host = url.host, ["https", "ssh"].contains(url.scheme ?? ""),
              url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme != "https" || url.user == nil else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let port = url.scheme == "https" ? url.port.map { ":\($0)" } ?? "" : ""
        return validated(origin: "https://\(host)\(port)", path: path)
    }

    private static func validated(origin: String, path: String) -> GitLabRemote? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let origin = GitLabOrigin.parse(origin), segments.count >= 2,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
                  $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil }) else { return nil }
        return GitLabRemote(origin: origin, path: path)
    }

    static func of(repo: String) async -> GitLabRemote? {
        guard let url = await Git.run(["config", "--get", "remote.origin.url"], in: repo) else { return nil }
        return parse(url)
    }
}

struct GitLabCredential: Sendable {
    let origin: GitLabOrigin
    let token: String
    let allowsWrites: Bool
}

/// Keychain entries scoped to one HTTPS origin and to read or write access.
enum GitLabToken {
    static let service = "hearth-gitlab"
    private static func account(_ origin: GitLabOrigin, writing: Bool) -> String {
        origin.value + (writing ? "#write" : "#read")
    }

    static func load(origin: GitLabOrigin, writing: Bool) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(origin, writing: writing),
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    @discardableResult
    static func save(_ token: String, origin: GitLabOrigin, writing: Bool) -> Bool {
        delete(origin: origin, writing: writing)
        let attrs: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account(origin, writing: writing),
                                    kSecAttrLabel as String: "Hearth IDE GitLab \(origin.value) \(writing ? "write" : "read")",
                                    kSecValueData as String: Data(token.utf8)]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func delete(origin: GitLabOrigin, writing: Bool) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account(origin, writing: writing)] as CFDictionary)
    }
}

struct CIPipeline: Identifiable, Hashable, Sendable {
    let id: Int
    let iid: Int
    let ref: String
    let sha: String
    let status: String
    let source: String
    let createdAt: Date?
    let webURL: URL?

    init?(json j: JSON) {
        guard let id = j["id"]?.double.map(Int.init) else { return nil }
        self.id = id
        iid = j["iid"]?.double.map(Int.init) ?? id
        ref = j["ref"]?.string ?? ""
        sha = j["sha"]?.string ?? ""
        status = j["status"]?.string ?? "unknown"
        source = j["source"]?.string ?? ""
        createdAt = j["created_at"]?.string.flatMap(GitLabAPI.date)
        webURL = j["web_url"]?.string.flatMap(URL.init(string:))
    }
}

struct CIJob: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let stage: String
    let status: String
    let duration: Double?
    let allowFailure: Bool
    let webURL: URL?

    init?(json j: JSON) {
        guard let id = j["id"]?.double.map(Int.init) else { return nil }
        self.id = id
        name = j["name"]?.string ?? "job"
        stage = j["stage"]?.string ?? ""
        status = j["status"]?.string ?? "unknown"
        duration = j["duration"]?.double
        allowFailure = j["allow_failure"] == .bool(true)
        webURL = j["web_url"]?.string.flatMap(URL.init(string:))
    }
}

/// Minimal GitLab REST client for pipelines and jobs.
struct GitLabAPI: Sendable {
    let remote: GitLabRemote
    let credential: GitLabCredential
    var session: URLSession = GitLabTransport.session

    enum APIError: LocalizedError {
        case http(Int, String)
        case unauthorizedOrigin, readOnly
        var errorDescription: String? {
            switch self {
            case .unauthorizedOrigin: "Dieser HTTPS-Origin ist für diesen Token nicht freigegeben."
            case .readOnly: "Für Schreibaktionen bitte einen separaten Token mit Scope api für diesen Server freigeben."
            case .http(401, _): "GitLab lehnt den Token ab (401). Token abgelaufen oder ohne Scope read_api/api?"
            case .http(403, _): "Keine Berechtigung (403). Für Starten/Wiederholen braucht der Token den Scope „api“ und du mindestens Developer-Rechte – geschützte Branches/Umgebungen können zusätzlich gesperrt sein."
            case .http(404, _): "Projekt nicht gefunden oder keine Berechtigung (404)."
            case .http(let c, let b): "GitLab-Fehler \(c): \(b.prefix(160))"
            }
        }
    }

    static func date(_ s: String) -> Date? { ISO8601.date(s) }

    private var project: String {
        remote.path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? remote.path
    }

    func authorizedRequest(_ method: String, _ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard GitLabOrigin.parse(remote.origin.value) == remote.origin,
              remote.origin == credential.origin else { throw APIError.unauthorizedOrigin }
        guard method == "GET" || credential.allowsWrites else { throw APIError.readOnly }
        var comps = URLComponents(url: remote.apiBase, resolvingAgainstBaseURL: false)!
        comps.percentEncodedPath = remote.apiBase.path + path
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(credential.token, forHTTPHeaderField: "PRIVATE-TOKEN")
        req.timeoutInterval = 20
        return req
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = []) async throws -> Data {
        let req = try authorizedRequest(method, path, query: query)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    func pipelines(ref: String?) async throws -> [CIPipeline] {
        var q = [URLQueryItem(name: "per_page", value: "15"), URLQueryItem(name: "order_by", value: "id")]
        if let ref { q.append(URLQueryItem(name: "ref", value: ref)) }
        let data = try await request("GET", "/projects/\(project)/pipelines", query: q)
        return (JSON.parse(data)?.array ?? []).compactMap(CIPipeline.init(json:))
    }

    func jobs(pipeline: Int) async throws -> [CIJob] {
        let data = try await request("GET", "/projects/\(project)/pipelines/\(pipeline)/jobs",
                                     query: [URLQueryItem(name: "per_page", value: "100"),
                                             URLQueryItem(name: "include_retried", value: "false")])
        return (JSON.parse(data)?.array ?? []).compactMap(CIJob.init(json:)).sorted { $0.id < $1.id }
    }

    func trace(job: Int) async throws -> String {
        String(decoding: try await request("GET", "/projects/\(project)/jobs/\(job)/trace"), as: UTF8.self)
    }

    func retry(pipeline: Int) async throws { _ = try await request("POST", "/projects/\(project)/pipelines/\(pipeline)/retry") }
    func cancel(pipeline: Int) async throws { _ = try await request("POST", "/projects/\(project)/pipelines/\(pipeline)/cancel") }
    func retry(job: Int) async throws { _ = try await request("POST", "/projects/\(project)/jobs/\(job)/retry") }

    /// Starts a job waiting in "manual" state.
    func play(job: Int) async throws { _ = try await request("POST", "/projects/\(project)/jobs/\(job)/play") }

    /// Creates a new pipeline for a branch or tag.
    func runPipeline(ref: String) async throws {
        _ = try await request("POST", "/projects/\(project)/pipeline", query: [URLQueryItem(name: "ref", value: ref)])
    }

    /// Page where the user can create a token with the right scope prefilled.
    static func tokenPage(host: String, writing: Bool = false) -> URL {
        URL(string: "https://\(host)/-/user_settings/personal_access_tokens?name=hearth&scopes=\(writing ? "api" : "read_api")")!
    }
}

/// No credential forwarding through redirects, even to another path on the same host.
final class GitLabTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: GitLabTransport(), delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CIStatus {
    static func isActive(_ s: String) -> Bool {
        ["running", "pending", "created", "preparing", "waiting_for_resource", "scheduled"].contains(s)
    }

    static func symbol(_ s: String) -> String {
        switch s {
        case "success": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        case "running": "arrow.triangle.2.circlepath.circle.fill"
        case "pending", "created", "preparing", "waiting_for_resource", "scheduled": "clock.fill"
        case "canceled", "canceling": "slash.circle.fill"
        case "skipped": "forward.circle.fill"
        case "manual": "gearshape.circle.fill"
        default: "questionmark.circle.fill"
        }
    }

    static func label(_ s: String) -> String {
        switch s {
        case "success": "erfolgreich"
        case "failed": "fehlgeschlagen"
        case "running": "läuft"
        case "pending", "created", "preparing", "waiting_for_resource": "wartet"
        case "scheduled": "geplant"
        case "canceled", "canceling": "abgebrochen"
        case "skipped": "übersprungen"
        case "manual": "manuell"
        default: s
        }
    }
}
