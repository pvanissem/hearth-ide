import Foundation
import Observation

enum AgentStatus: String, Sendable {
    case running = "RUNNING"
    case needsInput = "NEEDS INPUT"
    case blocked = "BLOCKED"
    case done = "DONE"
    case idle = "IDLE"
    case inactive = "INACTIVE"

    /// Lower sorts first in the inbox: things needing attention on top.
    var priority: Int {
        switch self {
        case .needsInput: 0
        case .blocked: 1
        case .running: 2
        case .done: 3
        case .idle: 4
        case .inactive: 5
        }
    }
}

struct SessionItem: Identifiable, Hashable, Sendable {
    let id: String
    let serverID: String
    var title: String
    var directory: String
    var updated: Date
    var agent: String?
    var model: ModelRef?
    var status: AgentStatus
    var lastError: String?
}

struct ModelRef: Hashable, Sendable {
    let providerID: String
    let id: String
    var key: String { "\(providerID)/\(id)" }

    init(providerID: String, id: String) {
        self.providerID = providerID
        self.id = id
    }

    init?(json: JSON?) {
        guard let p = json?["providerID"]?.string, let id = json?["id"]?.string else { return nil }
        self.init(providerID: p, id: id)
    }
}

struct AgentInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String?
}

struct ModelInfo: Identifiable, Hashable, Sendable {
    let ref: ModelRef
    let name: String
    var id: String { ref.key }
}

struct SkillInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String?
    /// Name usable after "/", e.g. "Code Review" → "code-review".
    var slug: String {
        name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    }
}

struct PermissionRequest: Identifiable, Hashable, Sendable {
    let id: String
    let sessionID: String
    let action: String
    let resources: [String]
    let message: String?
}

/// Live connection to one sandboxed `opencode serve` started by devkcode.
@MainActor
@Observable
final class ServerConnection: Identifiable {
    let entry: WebSessionEntry
    let client: OpenCodeClient
    var sessions: [String: SessionItem] = [:]
    var permissions: [String: PermissionRequest] = [:]
    var forms: [String: FormRequest] = [:]
    var agents: [AgentInfo] = []
    var models: [ModelInfo] = []
    var modelsLoading = false
    var modelsError: String?
    /// Slash commands defined on the server (built-in like /init, /review plus custom ones).
    var commands: [(name: String, description: String?)] = []
    /// Slash commands from OpenCode TUI plugins (not listed by the server).
    var pluginCommands: [PluginCommand] = []
    var skills: [SkillInfo] = []
    var defaultModel: ModelRef?
    var connected = false
    private(set) var connectionEpoch = UUID()
    var error: String?
    /// Live failures survive list refreshes and switching away from a session.
    /// Persisted assistant/idle errors are also decoded from message history.
    var sessionFailures: [String: ChatFailure] = [:]
    private var submittingSessions: Set<String> = []
    /// Invoked for every event so the app model can update open chats.
    var onEvent: ((String, JSON) -> Void)?
    var onLoaded: ((ServerConnection) -> Void)?

    private var eventTask: Task<Void, Never>?
    private let notify: (String, String) -> Void
    private let modelAccess: CopilotModelAccess
    private var modelRefreshTask: Task<Void, Never>?

    nonisolated var id: String { entry.id }

    init(entry: WebSessionEntry, client: OpenCodeClient,
         notify: @escaping (String, String) -> Void = { Notifier.notify(title: $0, body: $1) },
         modelAccess: CopilotModelAccess = CopilotModelAccess()) {
        self.entry = entry
        self.client = client
        self.notify = notify
        self.modelAccess = modelAccess
    }

    func start() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        eventTask?.cancel()
        eventTask = nil
        modelRefreshTask?.cancel()
        connected = false
    }

    private func runLoop() async {
        while !Task.isCancelled {
            connectionEpoch = UUID()
            do {
                try await reload()
                connected = true
                error = nil
                for try await event in client.events() {
                    handle(event)
                }
            } catch {
                if Task.isCancelled { return }
                self.connected = false
                self.error = error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    func reload() async throws {
        async let list = client.sessions(directory: entry.repoRoot)
        async let active = client.activeSessionIDs()
        async let perms = client.pendingPermissions()
        async let formList = client.pendingForms()
        let (sessionJSON, activeIDs, permJSON) = try await (list, active, perms)
        let formJSON = (try? await formList) ?? []
        if agents.isEmpty { await loadCatalog() }

        var next: [String: SessionItem] = [:]
        for s in sessionJSON {
            guard let id = s["id"]?.string, s["parentID"]?.string == nil else { continue }
            let updated = s["time"]?["updated"]?.double ?? 0
            let status: AgentStatus = sessionFailures[id] != nil ? .blocked
                : (activeIDs.contains(id) || submittingSessions.contains(id)) ? .running
                : (s["outcome"]?.string == "failed" ? .blocked : .idle)
            next[id] = SessionItem(
                id: id, serverID: entry.id,
                title: Self.displayTitle(s["title"]?.string, id: id, created: s["time"]?["created"]?.double),
                directory: s["location"]?["directory"]?.string ?? entry.repoRoot,
                updated: Date(timeIntervalSince1970: updated / 1000),
                agent: s["agent"]?.string,
                model: ModelRef(json: s["model"]),
                status: status == .idle && sessions[id]?.status == .done ? .done : status,
                lastError: sessionFailures[id]?.detail)
        }
        permissions = [:]
        for p in permJSON { addPermission(p) }
        forms = [:]
        for f in formJSON { if let form = FormRequest(json: f) { forms[form.id] = form } }
        for p in permissions.values { next[p.sessionID]?.status = .needsInput }
        for f in forms.values { next[f.sessionID]?.status = .needsInput }
        sessions = next
        sessionFailures = sessionFailures.filter { next[$0.key] != nil }
        submittingSessions = submittingSessions.intersection(next.keys)
        onLoaded?(self)
    }

    /// OpenCode leaves new sessions without a title (or with the raw ID) until the
    /// first answer; show something readable instead.
    static func displayTitle(_ title: String?, id: String, created: Double?) -> String {
        if let t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty, !t.hasPrefix("ses_") { return t }
        guard let created else { return "Neue Session" }
        let date = Date(timeIntervalSince1970: created / 1000)
        return "Neue Session · " + date.formatted(date: .abbreviated, time: .shortened)
    }

    func loadCatalog() async {
        if let a = try? await client.agents() {
            agents = a.compactMap { j in
                guard let id = j["id"]?.string, j["mode"]?.string != "subagent", j["hidden"] != .bool(true) else { return nil }
                return AgentInfo(id: id, name: j["name"]?.string ?? id, description: j["description"]?.string)
            }
        }
        // Account lookup must not delay loading sessions/permissions into the inbox.
        Task { [weak self] in await self?.refreshModels() }
        let root = entry.repoRoot
        pluginCommands = await Task.detached { PluginCommands.discover(repoRoot: root) }.value
        if let s = try? await client.skills() {
            skills = s.compactMap { j in
                guard let id = j["id"]?.string, let name = j["name"]?.string else { return nil }
                return SkillInfo(id: id, name: name, description: j["description"]?.string)
            }
        }
        if let c = try? await client.commands() {
            commands = c.compactMap { j in j["name"]?.string.map { ($0, j["description"]?.string) } }
        }
    }

    /// The initial server snapshot can precede provider/plugin settlement.
    /// Share in-flight refreshes; never replace unknown availability with the full catalog.
    func refreshModels() async {
        if let task = modelRefreshTask { await task.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.modelsLoading = true
            defer { self.modelsLoading = false }
            guard SandboxGitRunner.isLocalServer(self.client.baseURL) else {
                self.models = []; self.defaultModel = nil
                self.modelsError = CopilotModelAccess.Failure.localServerRequired.localizedDescription
                return
            }
            do {
                let raw = try await self.client.models(directory: self.entry.repoRoot, session: self.modelAccess.session)
                var ids: Set<String>?
                var availabilityError: String?
                if raw.contains(where: ModelCatalog.isCopilot) {
                    do { ids = try await self.modelAccess.confirmedIDs(client: self.client) }
                    catch { availabilityError = error.localizedDescription }
                }
                guard !Task.isCancelled else { return }
                let selectable = ModelCatalog.selectable(raw, copilotIDs: ids)
                let defaultRef = ModelRef(json: try? await self.client.defaultModel(directory: self.entry.repoRoot, session: self.modelAccess.session))
                guard !Task.isCancelled else { return }
                self.models = selectable
                // Preserve the server's current/default label, even when it must
                // not be offered as a new selection. Never silently switch it.
                self.defaultModel = defaultRef
                self.modelsError = availabilityError
            } catch {
                guard !Task.isCancelled else { return }
                self.models = []; self.defaultModel = nil
                self.modelsError = "Modellkatalog derzeit nicht verfügbar. Bitte aktualisieren."
            }
        }
        modelRefreshTask = task
        await task.value
        modelRefreshTask = nil
    }

    private func addPermission(_ p: JSON) {
        guard let id = p["id"]?.string, let sid = p["sessionID"]?.string else { return }
        permissions[id] = PermissionRequest(
            id: id, sessionID: sid,
            action: p["action"]?.string ?? "permission",
            resources: p["resources"]?.array.compactMap(\.string) ?? [],
            message: p["message"]?.string)
    }

    func handle(_ event: JSON) {
        guard let type = event["type"]?.string else { return }
        let data = event["data"] ?? .null
        let sid = data["sessionID"]?.string
        switch type {
        case "session.created", "session.updated", "session.deleted":
            if event["location"]?["directory"]?.string ?? entry.repoRoot == entry.repoRoot {
                Task { try? await reload() }
            }
        case "session.execution.started":
            if let sid { beginRun(sid) }
        case "session.execution.succeeded":
            if let sid { sessionFailures[sid] = nil; submittingSessions.remove(sid) }
            set(sid, .done)
        case "session.execution.interrupted":
            if let sid { sessionFailures[sid] = nil; submittingSessions.remove(sid) }
            set(sid, .idle)
        case "session.execution.failed", "session.error":
            if let sid { recordFailure(sid, ChatFailure.parse(data) ?? .unspecified) }
        case "permission.asked":
            addPermission(data)
            set(sid, .needsInput)
        case "permission.replied", "permission.rejected":
            if let rid = data["requestID"]?.string ?? data["id"]?.string { permissions[rid] = nil }
            set(sid, .running)
        case "form.created":
            if let form = FormRequest(json: data["form"] ?? data) {
                forms[form.id] = form
                set(form.sessionID, .needsInput)
            }
        case "form.replied", "form.cancelled":
            if let fid = data["id"]?.string { forms[fid] = nil }
            set(sid, .running)
        case "session.agent.selected", "session.model.selected":
            Task { try? await reload() }
        default:
            break
        }
        // Consumers must see the updated status/error, not the previous run's state.
        onEvent?(type, event)
    }

    func beginRun(_ sid: String, submitting: Bool = false) {
        sessionFailures[sid] = nil
        sessions[sid]?.lastError = nil
        if submitting { submittingSessions.insert(sid) } else { submittingSessions.remove(sid) }
        set(sid, .running)
    }

    func finishSubmission(_ sid: String) { submittingSessions.remove(sid) }

    func recordFailure(_ sid: String, _ failure: ChatFailure) {
        guard sessions[sid] != nil else { return }
        // A subsequent generic failure event must not replace a useful provider code.
        if failure != .unspecified || sessionFailures[sid] == nil {
            if sessionFailures[sid]?.code == nil || failure.code != nil { sessionFailures[sid] = failure }
        }
        submittingSessions.remove(sid)
        sessions[sid]?.lastError = sessionFailures[sid]?.detail
        set(sid, .blocked)
    }

    private func set(_ sid: String?, _ status: AgentStatus) {
        guard let sid, sessions[sid] != nil else { return }
        let changed = sessions[sid]?.status != status
        sessions[sid]?.status = status
        if status == .done || status == .idle || status == .running {
            sessions[sid]?.lastError = nil
            sessionFailures[sid] = nil
        }
        sessions[sid]?.updated = Date()
        if changed && (status == .needsInput || status == .blocked) {
            notify(sessions[sid]?.title ?? "Hearth IDE", status.rawValue)
        }
    }
}
