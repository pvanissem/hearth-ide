import Foundation

/// Minimal GitHub Actions REST client (github.com and GitHub Enterprise), shaped like
/// GitLabAPI so the Pipelines pane can show both. Workflow runs map to pipelines.
struct GitHubAPI: CIClient {
    let remote: CIRemote
    let credential: CICredential
    var session: URLSession = NoRedirectTransport.session
    /// Fetches the signed log URL GitHub redirects to (no credentials, no further redirects).
    var logSession: URLSession = NoRedirectTransport.session

    enum APIError: LocalizedError, Equatable {
        case http(Int, String)
        case unauthorizedOrigin, readOnly, notGitHub, badLogLocation
        var errorDescription: String? {
            switch self {
            case .unauthorizedOrigin: "Dieser HTTPS-Origin ist für diesen Token nicht freigegeben."
            case .readOnly: "Für Schreibaktionen bitte einen separaten Token mit „Actions: Read and write“ für diesen Server freigeben."
            case .notGitHub: "Das Repository ist kein GitHub-Repository der Form owner/repo."
            case .badLogLocation: "GitHub lieferte keine gültige Adresse für das Job-Log."
            case .http(401, _): "GitHub lehnt den Token ab (401). Token abgelaufen?"
            case .http(403, _): "Keine Berechtigung (403). Der Token braucht für dieses Repository „Actions: Read“ (Lesen) bzw. „Actions: Read and write“ (Starten, Wiederholen, Abbrechen); auch das API-Limit kann erreicht sein."
            case .http(404, _): "Repository oder Lauf nicht gefunden – oder dem Token fehlt der Zugriff auf dieses Repository (404)."
            case .http(422, let body): body.contains("workflow_dispatch")
                ? "Dieser Workflow lässt sich nicht von Hand starten (kein „workflow_dispatch“-Trigger)."
                : "GitHub lehnt die Aktion ab (422): \(body.prefix(160))"
            case .http(let c, let b): "GitHub-Fehler \(c): \(b.prefix(160))"
            }
        }
    }

    private var repo: String { remote.path }

    func authorizedRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) throws -> URLRequest {
        guard remote.provider == .gitHub, remote.path.split(separator: "/").count == 2 else { throw APIError.notGitHub }
        guard CIOrigin.parse(remote.origin.value) == remote.origin, remote.origin == credential.origin else {
            throw APIError.unauthorizedOrigin
        }
        guard method == "GET" || credential.allowsWrites else { throw APIError.readOnly }
        var comps = URLComponents(url: remote.apiBase, resolvingAgainstBaseURL: false)!
        comps.percentEncodedPath = remote.apiBase.path + path
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("Hearth-IDE", forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        req.timeoutInterval = 20
        return req
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Data {
        let (data, resp) = try await send(try authorizedRequest(method, path, query: query, body: body))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    /// Sends a request; a renamed or moved repository answers with a redirect to
    /// `<api>/repositories/<id>/…` on the same API origin, which is followed (with the token).
    /// Any other redirect is returned to the caller unchanged.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        var current = request
        for _ in 0..<3 {
            let (data, resp) = try await session.data(for: current)
            guard let http = resp as? HTTPURLResponse, [301, 302, 307, 308].contains(http.statusCode),
                  let location = http.value(forHTTPHeaderField: "Location"),
                  let next = Self.movedRepositoryURL(location, apiBase: remote.apiBase) else { return (data, resp) }
            current.url = next
        }
        throw APIError.http(310, "Zu viele Weiterleitungen")
    }

    /// The redirect target if it is GitHub's address for a moved repository on the same API origin.
    static func movedRepositoryURL(_ location: String, apiBase: URL) -> URL? {
        guard let url = URL(string: location), url.scheme == "https", url.user == nil, url.password == nil,
              url.host?.lowercased() == apiBase.host?.lowercased(), url.port == apiBase.port,
              url.path.hasPrefix(apiBase.path + "/repositories/"),
              url.path.range(of: #"^.*/repositories/\d+/actions/"#, options: .regularExpression) != nil else { return nil }
        return url
    }

    // MARK: Reading

    func pipelines(ref: String?) async throws -> [CIPipeline] {
        var q = [URLQueryItem(name: "per_page", value: "15")]
        if let ref { q.append(URLQueryItem(name: "branch", value: ref)) }
        let data = try await request("GET", "/repos/\(repo)/actions/runs", query: q)
        return (JSON.parse(data)?["workflow_runs"]?.array ?? []).compactMap(Self.pipeline)
    }

    func jobs(pipeline: Int) async throws -> [CIJob] {
        let data = try await request("GET", "/repos/\(repo)/actions/runs/\(pipeline)/jobs",
                                     query: [URLQueryItem(name: "per_page", value: "100"), URLQueryItem(name: "filter", value: "latest")])
        return (JSON.parse(data)?["jobs"]?.array ?? []).compactMap(Self.job)
    }

    /// GitHub answers with a redirect to a short-lived signed URL. That URL is fetched without
    /// the token, so the credential never leaves the approved API origin.
    func log(job: Int) async throws -> String {
        let (data, resp) = try await send(try authorizedRequest("GET", "/repos/\(repo)/actions/jobs/\(job)/logs"))
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        var raw: Data
        if (200..<300).contains(code) {
            raw = data
        } else if [301, 302, 303, 307, 308].contains(code) {
            guard let location = http?.value(forHTTPHeaderField: "Location"), let url = URL(string: location),
                  url.scheme == "https", url.user == nil, url.password == nil else { throw APIError.badLogLocation }
            var signed = URLRequest(url: url)
            signed.setValue("Hearth-IDE", forHTTPHeaderField: "User-Agent")
            signed.timeoutInterval = 30
            let (logData, logResp) = try await logSession.data(for: signed)
            let logCode = (logResp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(logCode) else { throw APIError.http(logCode, "Log nicht abrufbar") }
            raw = logData
        } else {
            throw APIError.http(code, String(decoding: data, as: UTF8.self))
        }
        if raw.count > 8_000_000 { raw = raw.suffix(8_000_000) }
        return Self.cleanLog(String(decoding: raw, as: UTF8.self))
    }

    func workflows() async throws -> [CIWorkflow] {
        let data = try await request("GET", "/repos/\(repo)/actions/workflows", query: [URLQueryItem(name: "per_page", value: "100")])
        return (JSON.parse(data)?["workflows"]?.array ?? []).compactMap { w in
            guard let id = w["id"]?.double.map(Int.init), w["state"]?.string == "active" else { return nil }
            return CIWorkflow(id: id, name: w["name"]?.string ?? "Workflow", path: w["path"]?.string ?? "")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Actions

    func retry(pipeline: Int) async throws { _ = try await request("POST", "/repos/\(repo)/actions/runs/\(pipeline)/rerun-failed-jobs") }
    func cancel(pipeline: Int) async throws { _ = try await request("POST", "/repos/\(repo)/actions/runs/\(pipeline)/cancel") }
    func retry(job: Int) async throws { _ = try await request("POST", "/repos/\(repo)/actions/jobs/\(job)/rerun") }
    func play(job: Int) async throws { throw APIError.http(422, "GitHub Actions kennt keine manuellen Jobs.") }

    func run(ref: String, workflow: CIWorkflow?) async throws {
        guard let workflow else { throw APIError.http(422, "Bitte einen Workflow wählen.") }
        _ = try await request("POST", "/repos/\(repo)/actions/workflows/\(workflow.id)/dispatches", body: ["ref": ref])
    }

    // MARK: Mapping

    /// GitHub's status + conclusion in GitLab's vocabulary (what CIStatus shows).
    static func status(_ status: String?, _ conclusion: String?) -> String {
        switch status {
        case "completed":
            switch conclusion {
            case "success": "success"
            case "failure", "timed_out", "startup_failure": "failed"
            case "cancelled": "canceled"
            case "skipped", "neutral", "stale": "skipped"
            case "action_required": "manual"
            default: conclusion ?? "unknown"
            }
        case "in_progress": "running"
        case "queued", "waiting", "requested", "pending": "pending"
        default: status ?? "unknown"
        }
    }

    static func pipeline(_ j: JSON) -> CIPipeline? {
        guard let id = j["id"]?.double.map(Int.init) else { return nil }
        return CIPipeline(id: id, iid: j["run_number"]?.double.map(Int.init) ?? id, ref: j["head_branch"]?.string ?? "",
                          sha: j["head_sha"]?.string ?? "", status: status(j["status"]?.string, j["conclusion"]?.string),
                          source: j["event"]?.string ?? "", createdAt: j["created_at"]?.string.flatMap(ISO8601.date),
                          webURL: j["html_url"]?.string.flatMap(URL.init(string:)), name: j["name"]?.string)
    }

    /// Matrix and reusable-workflow jobs are named "group / job": the group becomes the stage.
    static func job(_ j: JSON) -> CIJob? {
        guard let id = j["id"]?.double.map(Int.init) else { return nil }
        let full = j["name"]?.string ?? "job"
        let parts = full.components(separatedBy: " / ")
        let started = j["started_at"]?.string.flatMap(ISO8601.date)
        let completed = j["completed_at"]?.string.flatMap(ISO8601.date)
        let duration = started.flatMap { s in completed.map { $0.timeIntervalSince(s) } }.map { max(0, $0) }
        return CIJob(id: id, name: parts.count > 1 ? parts.dropFirst().joined(separator: " / ") : full,
                     stage: parts.count > 1 ? parts[0] : (j["workflow_name"]?.string ?? "Jobs"),
                     status: status(j["status"]?.string, j["conclusion"]?.string), duration: duration,
                     webURL: j["html_url"]?.string.flatMap(URL.init(string:)))
    }

    /// Without the timestamp in front of every line and with readable group markers.
    static func cleanLog(_ raw: String) -> String {
        raw.strippingANSI
            .replacingOccurrences(of: #"(?m)^\uFEFF?\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z ?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "##[group]", with: "▸ ")
            .replacingOccurrences(of: "##[endgroup]\n", with: "")
            .replacingOccurrences(of: "##[endgroup]", with: "")
            .replacingOccurrences(of: "##[error]", with: "✖ ")
            .replacingOccurrences(of: "##[warning]", with: "⚠ ")
    }
}
