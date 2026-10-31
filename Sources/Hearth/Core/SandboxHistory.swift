import Foundation

/// Merge both registries before sorting. Web entries must not lose their date or
/// be hidden behind an older terminal record for the same repository/project.
enum SandboxHistory {
    static func merged(terminal: [SandboxEntry], web: [WebSessionEntry],
                       lastUsed: [String: Date] = [:]) -> [SandboxListing] {
        var rows: [String: SandboxListing] = [:]
        for entry in terminal {
            let state: SandboxListing.State = switch entry.resolved {
            case .stopped: .stopped
            case .terminal: .terminal
            case .orphaned: .orphaned
            }
            let row = SandboxListing(root: entry.repoRoot, name: entry.name, profile: entry.profileName,
                project: entry.projectName, state: state, lastStarted: entry.lastStartedAt)
            if rows[row.id] == nil || (row.lastStarted ?? .distantPast) > (rows[row.id]?.lastStarted ?? .distantPast) { rows[row.id] = row }
        }
        for entry in web {
            let key = entry.repoRoot + "#" + (entry.projectName ?? "")
            let old = rows[key]
            let newer = old == nil || (entry.lastStartedAt ?? .distantPast) >= (old?.lastStarted ?? .distantPast)
            rows[key] = SandboxListing(root: entry.repoRoot, name: old?.name ?? entry.displayName,
                profile: newer ? entry.profileName : old?.profile, project: entry.projectName,
                state: old?.state ?? .stopped, lastStarted: newer ? entry.lastStartedAt : old?.lastStarted)
        }
        return rows.values.map { row in
            // The compatibility field lastStarted is used as the effective activity
            // date in the welcome list; UI labels it "Zuletzt verwendet".
            SandboxListing(root: row.root, name: row.name, profile: row.profile, project: row.project,
                state: row.state, lastStarted: [row.lastStarted, lastUsed[row.id]].compactMap { $0 }.max())
        }.sorted {
            let left = $0.lastStarted ?? .distantPast, right = $1.lastStarted ?? .distantPast
            if left != right { return left > right }
            if $0.name != $1.name { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            return $0.id < $1.id
        }
    }
}
