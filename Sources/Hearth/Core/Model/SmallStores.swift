import Foundation
import Observation

/// What the inspector shows for the selected session's folder: Git state, directory
/// tree state and a revision that bumps whenever files may have changed.
@MainActor
@Observable
final class WorkspaceState {
    /// Bumped whenever the agent may have changed files; inspector tabs reload on change.
    var revision = 0
    var gitSnapshot = GitSnapshot()
    var expandedPaths: Set<String> = []
    var selectedFile: URL?
    var revealID = UUID()
    let dragToken = UUID()
    /// Empty clone targets created by this app instance may be retried, never arbitrary folders.
    var cloneDirectories: Set<String> = []
}

/// Text size per area (chat, inspector, sidebar, single panes), ⌘-scroll / pinch zoom.
@MainActor
@Observable
final class TextZoomStore {
    var scales: [String: Double] = UIStateStore.load(.textScales) ?? [:] {
        didSet { UIStateStore.save(scales, as: .textScales) }
    }
    /// Area under the mouse; ⌘-scroll / pinch zoom applies there.
    var hoveredArea: TextArea?
    var hoveringDiagram = false
    @ObservationIgnored var notify: (String) -> Void = { _ in }

    static let range: ClosedRange<Double> = 0.7...2.2

    func scale(_ area: TextArea) -> Double {
        scales[area.rawValue] ?? (area.base == area ? 1 : scale(area.base))
    }

    func zoom(_ area: TextArea, by factor: Double) {
        let next = min(max(scale(area) * factor, Self.range.lowerBound), Self.range.upperBound)
        guard abs(next - scale(area)) > 0.001 else { return }
        scales[area.rawValue] = next
        let name = switch area {
        case .chat: "Chat"; case .inspector: "Inspector"; case .sidebar: "Sessions"
        case .pane(_, let tab): tab.title
        }
        notify("Schriftgröße \(name): \(Int((next * 100).rounded())) %")
    }

    func zoomAll(by factor: Double) {
        TextArea.allCases.forEach { zoom($0, by: factor) }
        for key in scales.keys where key.hasPrefix("pane:") {
            scales[key] = min(max(scales[key]! * factor, Self.range.lowerBound), Self.range.upperBound)
        }
    }

    func reset(_ area: TextArea) {
        scales[area.rawValue] = nil
        notify("Schriftgröße zurückgesetzt")
    }

    func reset() {
        scales = [:]
        notify("Schriftgröße zurückgesetzt")
    }
}

/// GitLab access tokens per approved HTTPS origin (CI/CD pane), read and write kept apart.
@MainActor
@Observable
final class GitLabAccounts {
    var readTokens: [GitLabOrigin: String] = [:]
    var writeTokens: [GitLabOrigin: String] = [:]
    var loadedOrigins: Set<GitLabOrigin> = []
    private var credentialRevision: [GitLabOrigin: Int] = [:]
    private static let approvedKey = "gitlab.approvedOrigins.v2"

    func load(for origin: GitLabOrigin) async {
        guard !loadedOrigins.contains(origin) else { return }
        loadedOrigins.insert(origin)
        let approved = UserDefaults.standard.stringArray(forKey: Self.approvedKey) ?? []
        guard Snapshotter.directory == nil, approved.contains(origin.value) else { return }
        let revision = credentialRevision[origin, default: 0]
        let (read, write) = await Task.detached {
            (GitLabToken.load(origin: origin, writing: false), GitLabToken.load(origin: origin, writing: true))
        }.value
        guard credentialRevision[origin, default: 0] == revision else { return }
        readTokens[origin] = read
        writeTokens[origin] = write
    }

    /// Only call after explicit confirmation of the displayed HTTPS origin.
    func save(_ token: String, for origin: GitLabOrigin, writing: Bool) -> Bool {
        guard GitLabToken.save(token, origin: origin, writing: writing) else { return false }
        credentialRevision[origin, default: 0] += 1
        if writing { writeTokens[origin] = token } else { readTokens[origin] = token }
        var approved = Set(UserDefaults.standard.stringArray(forKey: Self.approvedKey) ?? [])
        approved.insert(origin.value)
        UserDefaults.standard.set(Array(approved).sorted(), forKey: Self.approvedKey)
        return true
    }

    func api(for remote: GitLabRemote, writing: Bool = false) -> GitLabAPI? {
        // A write token is never silently used for polling/read requests.
        guard let token = (writing ? writeTokens : readTokens)[remote.origin] else { return nil }
        return GitLabAPI(remote: remote, credential: GitLabCredential(origin: remote.origin, token: token, allowsWrites: writing))
    }

    func revoke(_ origin: GitLabOrigin) {
        credentialRevision[origin, default: 0] += 1
        readTokens[origin] = nil
        writeTokens[origin] = nil
        GitLabToken.delete(origin: origin, writing: false)
        GitLabToken.delete(origin: origin, writing: true)
        let approved = UserDefaults.standard.stringArray(forKey: Self.approvedKey) ?? []
        UserDefaults.standard.set(approved.filter { $0 != origin.value }, forKey: Self.approvedKey)
    }
}
