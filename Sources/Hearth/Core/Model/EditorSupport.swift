import Foundation

/// Cancellation alone doesn't stop detached filesystem/process work. Only the
/// latest ticket for the current context may publish into a visible view.
struct LatestRequest<Key: Equatable & Sendable>: Sendable {
    struct Ticket: Sendable { let key: Key; let generation: UUID }
    private var generation = UUID()
    mutating func invalidate() { generation = UUID() }
    mutating func begin(_ key: Key) -> Ticket {
        invalidate()
        return Ticket(key: key, generation: generation)
    }
    func accepts(_ ticket: Ticket, current: Key?) -> Bool {
        current == ticket.key && generation == ticket.generation
    }
}

struct EditorPresentation: Hashable, Sendable {
    let root: String
    let file: URL?

    static func relativePath(_ file: URL, root: String) -> String? {
        guard file.isFileURL else { return nil }
        let base = URL(fileURLWithPath: root).standardizedFileURL.path
        let path = file.standardizedFileURL.path
        let prefix = base == "/" ? "/" : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}

struct EditorLoadKey: Hashable, Sendable {
    let presentation: EditorPresentation
    let mode: String
    let revision: Int
}

enum TabOrdering {
    /// `tabs` with `url` inserted before `target` (nil or unknown = at the end), removing any
    /// earlier occurrence. Dropping a tab onto itself leaves the order unchanged.
    static func place(_ url: URL, in tabs: [URL], before target: URL?) -> [URL] {
        if target == url, tabs.contains(url) { return tabs }
        var result = tabs.filter { $0 != url }
        let index = target.flatMap { result.firstIndex(of: $0) } ?? result.count
        result.insert(url, at: index)
        return result
    }
}
