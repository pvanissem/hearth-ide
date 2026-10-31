import Foundation

/// Loosely typed JSON so the app tolerates additive changes in the OpenCode API.
enum JSON: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    static func parse(_ data: Data) -> JSON? { try? JSONDecoder().decode(JSON.self, from: data) }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    var object: [String: JSON] { if case .object(let o) = self { return o }; return [:] }
}

extension String {
    /// Exact UTF-16 equality without Swift's Unicode canonical-equivalence work.
    /// `==` normalizes, which is costly for whole documents compared on every render.
    func isLiterallyEqual(to other: String) -> Bool {
        utf16.count == other.utf16.count && (self as NSString).isEqual(to: other)
    }
}
