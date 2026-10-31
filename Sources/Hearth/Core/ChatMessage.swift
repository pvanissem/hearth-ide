import Foundation

struct ToolCall: Hashable, Sendable {
    let name: String
    let status: String
    let input: String
    let output: String
}

struct ChatMessage: Identifiable, Hashable, Sendable {
    enum Role: String, Sendable { case user, assistant, system }
    enum Part: Hashable, Sendable {
        case text(String)
        case reasoning(String)
        case tool(ToolCall)
        case failure(ChatFailure)
    }
    let id: String
    let role: Role
    var parts: [Part]

    init(id: String, role: Role, text: String) {
        self.init(id: id, role: role, parts: text.isEmpty ? [] : [.text(text)])
    }

    init(id: String, role: Role, parts: [Part]) {
        self.id = id
        self.role = role
        self.parts = parts
    }

    var text: String {
        parts.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }

    init?(json m: JSON) {
        guard let id = m["id"]?.string, let type = m["type"]?.string else { return nil }
        switch type {
        case "user": self.init(id: id, role: .user, text: m["text"]?.string ?? "")
        case "assistant":
            var parts: [Part] = []
            for part in m["content"]?.array ?? [] {
                switch part["type"]?.string {
                case "text":
                    if let text = part["text"]?.string, !text.isEmpty { parts.append(.text(text)) }
                case "reasoning":
                    if let text = part["text"]?.string, !text.isEmpty { parts.append(.reasoning(text)) }
                case "tool":
                    let state = part["state"] ?? .null
                    let output = state["content"]?.array.compactMap { $0["text"]?.string }.joined(separator: "\n")
                        ?? ChatFailure.parse(state["error"])?.detail ?? ""
                    parts.append(.tool(ToolCall(name: part["name"]?.string ?? "tool", status: state["status"]?.string ?? "",
                                                input: Self.summarize(state["input"]), output: output)))
                default: break
                }
            }
            if let failure = ChatFailure.parse(m["error"]) { parts.append(.failure(failure)) }
            else if m["finish"]?.string == "content-filter" {
                parts.append(.failure(ChatFailure(message: "Der Modellanbieter hat die Antwort blockiert.", code: "content-filter")))
            } else if m["finish"]?.string == "error" { parts.append(.failure(.unspecified)) }
            guard !parts.isEmpty else { return nil }
            self.init(id: id, role: .assistant, parts: parts)
        case "idle" where m["outcome"]?.string == "failed":
            self.init(id: id, role: .assistant, parts: [.failure(ChatFailure.parse(m["error"]) ?? .unspecified)])
        default: return nil
        }
    }

    static func summarize(_ input: JSON?) -> String {
        guard let input else { return "" }
        if let value = input.string { return value }
        for key in ["command", "filePath", "path", "pattern", "url", "query", "description"] {
            if let value = input[key]?.string { return value }
        }
        return input.object.map { "\($0.key)=\($0.value.string ?? "…")" }.sorted().joined(separator: " ")
    }
}

enum ChatTranscript {
    /// Input is chronological. An assistant error and its failed idle marker can
    /// report the same failure: show it once per user turn, not once per SSE event.
    static func history(_ raw: [JSON]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        var seen = Set<String>()
        var turnStart = 0
        for json in raw {
            if json["type"]?.string == "user" { seen = []; turnStart = result.count }
            if json["type"]?.string == "idle", ChatFailure.parse(json["error"]) == nil, !seen.isEmpty { continue }
            guard var message = ChatMessage(json: json) else { continue }
            message.parts = message.parts.filter { part in
                guard case .failure(let failure) = part else { return true }
                if failure == .unspecified && !seen.isEmpty { return false }
                if failure != .unspecified, seen.remove(ChatFailure.unspecified.signature) != nil {
                    for index in (turnStart..<result.count).reversed() {
                        result[index].parts.removeAll { $0 == .failure(.unspecified) }
                        if result[index].parts.isEmpty { result.remove(at: index) }
                    }
                }
                return seen.insert(failure.signature).inserted
            }
            if !message.parts.isEmpty { result.append(message) }
        }
        return result
    }

    static func withLiveFailure(_ messages: [ChatMessage], failure: ChatFailure?) -> [ChatMessage] {
        guard let failure, failure != .unspecified, !hasCurrentFailure(messages, matching: failure) else { return messages }
        var result = messages
        let start = result.lastIndex(where: { $0.role == .user }) ?? result.startIndex
        for index in start..<result.endIndex {
            result[index].parts = result[index].parts.map { $0 == .failure(.unspecified) ? .failure(failure) : $0 }
        }
        return result
    }

    static func hasCurrentFailure(_ messages: [ChatMessage], matching failure: ChatFailure? = nil) -> Bool {
        let start = messages.lastIndex(where: { $0.role == .user }) ?? messages.startIndex
        return messages[start...].contains { message in
            message.parts.contains { part in
                guard case .failure(let existing) = part else { return false }
                return failure == nil || existing.signature == failure?.signature
            }
        }
    }
}
