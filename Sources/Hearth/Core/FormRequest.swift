import Foundation

/// A question the agent asks via OpenCode's form API (rendered as a card in the chat).
struct FormRequest: Identifiable, Hashable, Sendable {
    struct Option: Hashable, Sendable {
        let value: String
        let label: String
        let description: String?
    }

    enum Kind: Hashable, Sendable {
        case string(options: [Option], placeholder: String?)
        case number(integer: Bool)
        case boolean
        case multiselect(options: [Option], maxItems: Int?, custom: Bool)
        case external(url: String)
        case unknown
    }

    struct Condition: Hashable, Sendable {
        let key: String
        let equal: Bool
        let value: FormValue
    }

    struct Field: Identifiable, Hashable, Sendable {
        let key: String
        let title: String
        let description: String?
        let required: Bool
        let kind: Kind
        let when: [Condition]
        let defaultValue: FormValue?
        var id: String { key }
    }

    let id: String
    let sessionID: String
    let title: String
    let fields: [Field]

    init?(json f: JSON) {
        guard let id = f["id"]?.string, let sid = f["sessionID"]?.string else { return nil }
        self.id = id
        self.sessionID = sid
        self.title = f["title"]?.string ?? "Rückfrage"
        self.fields = (f["fields"]?.array ?? []).compactMap(Field.init(json:))
    }

    /// Fields whose `when` conditions hold for the current answers.
    func visibleFields(_ answers: [String: FormValue]) -> [Field] {
        fields.filter { field in
            field.when.allSatisfy { c in Self.matches(answers[c.key], c.value) == c.equal }
        }
    }

    /// Single-choice multiselects answer with a one-element list; compare by membership.
    static func matches(_ answer: FormValue?, _ expected: FormValue) -> Bool {
        if case .list(let l)? = answer, case .string(let s) = expected { return l.contains(s) }
        return answer == expected
    }

    func missingRequired(_ answers: [String: FormValue]) -> Bool {
        visibleFields(answers).contains { f in
            guard f.required else { return false }
            switch answers[f.key] {
            case nil: return true
            case .string(let s)?: return s.isEmpty
            case .list(let l)?: return l.isEmpty
            default: return false
            }
        }
    }
}

enum FormValue: Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case list([String])

    init?(json: JSON?) {
        switch json {
        case .string(let s)?: self = .string(s)
        case .number(let n)?: self = .number(n)
        case .bool(let b)?: self = .bool(b)
        case .array(let a)?: self = .list(a.compactMap(\.string))
        default: return nil
        }
    }

    var any: Any {
        switch self {
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .list(let l): l
        }
    }
}

extension FormRequest.Field {
    init?(json f: JSON) {
        guard let key = f["key"]?.string, f["hidden"] != .bool(true) else { return nil }
        self.key = key
        self.title = f["title"]?.string ?? key
        self.description = f["description"]?.string
        self.required = f["required"] == .bool(true)
        self.defaultValue = FormValue(json: f["default"])
        self.when = (f["when"]?.array ?? []).compactMap { w in
            guard let k = w["key"]?.string, let v = FormValue(json: w["value"]) else { return nil }
            return FormRequest.Condition(key: k, equal: w["op"]?.string != "neq", value: v)
        }
        let options = (f["options"]?.array ?? []).compactMap { o -> FormRequest.Option? in
            guard let v = o["value"]?.string else { return nil }
            return FormRequest.Option(value: v, label: o["label"]?.string ?? v, description: o["description"]?.string)
        }
        switch f["type"]?.string {
        case "string": kind = .string(options: options, placeholder: f["placeholder"]?.string)
        case "number": kind = .number(integer: false)
        case "integer": kind = .number(integer: true)
        case "boolean": kind = .boolean
        case "multiselect":
            kind = .multiselect(options: options, maxItems: f["maxItems"]?.double.map(Int.init),
                                custom: f["custom"] == .bool(true))
        case "external": kind = .external(url: f["url"]?.string ?? "")
        default: kind = .unknown
        }
    }
}
