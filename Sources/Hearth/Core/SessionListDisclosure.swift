import Foundation

/// Shared across sidebar instances, reconnects and restarts; not keyed by transient connection objects.
struct SessionListDisclosure: Codable, Equatable {
    var collapsed: Set<String> = []
    var attentionExpanded = true

    static func key(root: String, project: String?) -> String { root + "#" + (project ?? "") }
    func isExpanded(_ key: String) -> Bool { !collapsed.contains(key) }
    mutating func setExpanded(_ expanded: Bool, for key: String) {
        if expanded { collapsed.remove(key) } else { collapsed.insert(key) }
    }

    static func preview(_ sessions: [SessionItem], limit: Int, selectedID: String?) -> [SessionItem] {
        var result = Array(sessions.prefix(limit))
        // A selected/new session must not disappear behind the recent-items limit.
        if let selected = sessions.first(where: { $0.id == selectedID }), !result.contains(where: { $0.id == selected.id }) {
            result.append(selected)
        }
        return result
    }
}
