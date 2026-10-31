import Foundation

enum ModelCatalog {
    static func isCopilot(_ model: JSON) -> Bool {
        model["providerID"]?.string == "github-copilot" || model["canonical"]?.string == "github-copilot"
    }

    /// Unknown policy is not proof of denial, but also not explicit approval.
    /// Only confirmed, picker-enabled models enter the selectable catalog.
    static func confirmedCopilotIDs(_ response: JSON) throws -> Set<String> {
        guard case .array(let rows)? = response["data"] else { throw CopilotModelAccess.Failure.invalidResponse }
        return Set(rows.compactMap { row in
            guard row["model_picker_enabled"] == .bool(true), row["policy"]?["state"]?.string == "enabled" else { return nil }
            return row["id"]?.string
        })
    }

    static func selectable(_ rows: [JSON], copilotIDs: Set<String>?) -> [ModelInfo] {
        var seen = Set<String>()
        return rows.compactMap { row -> ModelInfo? in
            guard row["enabled"] == .bool(true), row["type"] == nil || row["type"] == .string("chat"),
                  let ref = ModelRef(json: row), !ref.id.isEmpty, !ref.providerID.isEmpty else { return nil }
            if isCopilot(row) {
                guard let copilotIDs, copilotIDs.contains(row["modelID"]?.string ?? ref.id) else { return nil }
            }
            guard seen.insert(ref.key).inserted else { return nil }
            return ModelInfo(ref: ref, name: row["name"]?.string ?? ref.id)
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}

/// Read-only Copilot account facts, using the active integration on this server.
/// No credential files, preferences or logs. Never derive an auth host from a repo/model URL.
struct CopilotModelAccess: Sendable {
    var session: URLSession = GitLabTransport.session // ephemeral, redirects denied
    static let publicHosts: Set<String> = ["api.githubcopilot.com", "api.individual.githubcopilot.com",
                                           "api.business.githubcopilot.com", "api.enterprise.githubcopilot.com"]

    enum Failure: LocalizedError {
        case localServerRequired, noAccount, unsupportedOrigin, invalidResponse, unavailable(Int)
        var errorDescription: String? {
            switch self {
            case .localServerRequired: "Modellfreigaben benötigen einen lokalen OpenCode-Server."
            case .noAccount: "Kein eindeutiger aktiver Copilot-OAuth-Zugang in dieser Sandbox."
            case .unsupportedOrigin: "Copilot-Origin nicht freigegeben. Keine Token-Übertragung; Enterprise-/Sonderendpunkte benötigen eine eigene Integration."
            case .invalidResponse: "Copilot lieferte keinen gültigen Modell-Freigabekatalog."
            case .unavailable(let code): "Copilot-Freigaben derzeit nicht prüfbar\(code > 0 ? " (HTTP \(code))" : ""). Nicht bestätigte Modelle werden nicht angeboten."
            }
        }
    }

    static func request(for credentials: JSON) throws -> URLRequest {
        let active = (credentials["data"]?.array ?? []).filter {
            $0["integrationID"]?.string == "github-copilot" && $0["active"] == .bool(true)
        }
        guard active.count == 1, let value = active.first?["value"], value["type"]?.string == "oauth" else { throw Failure.noAccount }
        let metadata = value["metadata"]
        if let metadata {
            guard case .object = metadata else { throw Failure.unsupportedOrigin }
        }
        if let enterprise = metadata?["enterpriseUrl"], enterprise.string == nil { throw Failure.unsupportedOrigin }
        if let endpoint = metadata?["apiEndpoint"], endpoint.string == nil { throw Failure.unsupportedOrigin }
        if let enterprise = metadata?["enterpriseUrl"]?.string, !enterprise.isEmpty {
            guard let origin = GitLabOrigin.parse(enterprise.contains("://") ? enterprise : "https://" + enterprise),
                  origin.value == "https://github.com" else { throw Failure.unsupportedOrigin }
        }
        let endpoint = metadata?["apiEndpoint"]?.string ?? "https://api.githubcopilot.com"
        guard let origin = GitLabOrigin.parse(endpoint), let host = origin.url.host, publicHosts.contains(host),
              origin.url.port == nil else { throw Failure.unsupportedOrigin }
        let refresh = value["refresh"]?.string ?? ""
        let token = refresh.isEmpty ? value["access"]?.string ?? "" : refresh
        guard !token.isEmpty, !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else { throw Failure.noAccount }
        var request = URLRequest(url: origin.url.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("hearth-model-availability", forHTTPHeaderField: "User-Agent")
        // Same account-catalog version used by OpenCode v2.2.0's Copilot integration.
        request.setValue("2026-08-01", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    func confirmedIDs(client: OpenCodeClient) async throws -> Set<String> {
        guard SandboxGitRunner.isLocalServer(client.baseURL) else { throw Failure.localServerRequired }
        let credentials: JSON
        do { credentials = try await client.send("GET", "/api/credential", session: session) }
        catch { throw Failure.unavailable(0) } // Never surface a credential response/debug dump.
        let request = try Self.request(for: credentials)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Failure.unavailable(0) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.unavailable(status) }
        guard let json = JSON.parse(data) else { throw Failure.invalidResponse }
        return try ModelCatalog.confirmedCopilotIDs(json)
    }
}
