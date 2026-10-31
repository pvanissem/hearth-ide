import Foundation

/// Provider errors are data, never Markdown/HTML or executable instructions.
/// Keep the original chain for copying while surfacing a nested provider message/code.
struct ChatFailure: Hashable, Sendable {
    let message: String
    let detail: String
    let code: String?
    let status: Int?

    init(message: String, detail: String? = nil, code: String? = nil, status: Int? = nil) {
        self.message = String(message.prefix(6_000))
        let raw = detail ?? message
        self.detail = String(raw.prefix(100_000)) + (raw.count > 100_000 ? "\n… (gekürzt)" : "")
        self.code = code.map { String($0.prefix(120)) }
        self.status = status
    }

    var title: String {
        if code?.lowercased() == "cyber_policy" { return "Anfrage durch Sicherheitsrichtlinie blockiert" }
        if code?.lowercased() == "content-filter" { return "Antwort vom Modellanbieter blockiert" }
        if status == 429 { return "Anfragelimit des Anbieters erreicht" }
        return "Agentantwort fehlgeschlagen"
    }

    // Transport and persisted errors may omit HTTP status but describe the same failure.
    var signature: String { "\(code?.lowercased() ?? "")|\(message)" }
    static let unspecified = ChatFailure(message: "Die Ausführung ist fehlgeschlagen. Der Server hat keine weiteren Fehlerdetails geliefert.")

    static func http(status: Int, body: String) -> ChatFailure {
        let parsed = parse(.string(body))
        return ChatFailure(message: parsed?.message ?? "HTTP \(status)", detail: body, code: parsed?.code, status: status)
    }

    static func parse(_ json: JSON?) -> ChatFailure? { parse(json, depth: 0) }

    private static func parse(_ json: JSON?, depth: Int) -> ChatFailure? {
        guard depth < 8, let json else { return nil }
        if let raw = json.string {
            let raw = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100_000))
            guard !raw.isEmpty else { return nil }
            if let structured = JSON.parse(Data(raw.utf8)), structured.object.isEmpty == false,
               let nested = parse(structured, depth: depth + 1) {
                return ChatFailure(message: nested.message, detail: raw, code: nested.code, status: nested.status)
            }
            if let embedded = embeddedError(in: raw), let nested = parse(embedded, depth: depth + 1) {
                return ChatFailure(message: nested.message, detail: raw, code: nested.code, status: nested.status)
            }
            return ChatFailure(message: raw)
        }
        guard !json.object.isEmpty else { return nil }
        let direct = json["message"]?.string
        let nested = parse(json["error"], depth: depth + 1)
            ?? parse(json["response"]?["body"], depth: depth + 1)
            ?? parse(json["cause"], depth: depth + 1)
            ?? parse(json["data"]?["error"], depth: depth + 1)
            ?? parse(json["data"]?["message"], depth: depth + 1)
        let wrappedMessage = direct.flatMap { parse(.string($0), depth: depth + 1) }
        let codeOnly = json["code"]?.string.map { ChatFailure(message: "Fehlercode: \($0)", code: $0) }
        let coded = (nested?.code != nil ? nested : nil) ?? (wrappedMessage?.code != nil ? wrappedMessage : nil)
        guard let best = coded ?? nested ?? wrappedMessage ?? codeOnly else { return nil }
        let code = best.code ?? json["code"]?.string
        let status = (json["status"]?.double ?? json["statusCode"]?.double).flatMap { value -> Int? in
            value.isFinite && (100...599).contains(value) ? Int(value) : nil
        } ?? best.status
        let details = [direct, json["response"]?["body"]?.string, nested?.detail]
            .compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.joined(separator: "\n\n")
        return ChatFailure(message: best.message, detail: details.isEmpty ? best.detail : details, code: code, status: status)
    }

    /// E.g. `reading SSE event: {"error":{"message":...,"code":"cyber_policy"}}`.
    /// Balance JSON braces rather than interpreting the surrounding error string.
    private static func embeddedError(in text: String) -> JSON? {
        guard let start = text.range(of: #"\{\s*"error"\s*:"#, options: .regularExpression)?.lowerBound else { return nil }
        var depth = 0, quoted = false, escaped = false
        for index in text[start...].indices {
            let char = text[index]
            if quoted {
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { quoted = false }
            } else if char == "\"" { quoted = true }
            else if char == "{" { depth += 1 }
            else if char == "}" {
                depth -= 1
                if depth == 0 { return JSON.parse(Data(text[start...index].utf8)) }
            }
        }
        return nil
    }
}

enum ChatActivity {
    static func showsWorking(status: AgentStatus, awaitingInput: Bool, connectionFailed: Bool) -> Bool {
        status == .running && !awaitingInput && !connectionFailed
    }
}
