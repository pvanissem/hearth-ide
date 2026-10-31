import Foundation

/// Editor tabs per session: switching to another agent session or chat shows the files
/// opened there and stashes the current ones until the user comes back.
extension AppModel {
    /// Identifies the selection whose editor state is shown.
    var editorWorkspaceKey: String? {
        if let id = agents.selectedRunID { return "run:" + id }
        if let server = selectedServerID {
            return selectedSessionID.map { "session:\(server)/\($0)" } ?? "sandbox:" + server
        }
        return nil
    }

    /// Call after the selection changed: stashes the shown tabs, shows the selection's.
    func switchEditorWorkspace() {
        let oldKey = shownEditorWorkspace
        guard let newKey = editorWorkspaceKey, oldKey != newKey else { return }
        var stash = editorWorkspaces
        let groups = orderedEditorGroups
        let current = EditorWorkspace(groups: groups.map(EditorSnapshot.init), selectedFile: directorySelectedFile)
        if let oldKey {
            stash[oldKey] = current
        }
        // Tabs not assigned to any session yet (first launch with this feature) go to the new one.
        apply(stash[newKey] ?? (oldKey == nil ? current : EditorWorkspace()), to: groups)
        shownEditorWorkspace = newKey
        // Agent sessions that were removed no longer need their tabs.
        let runIDs = Set(agents.runs.map(\.id))
        stash = stash.filter { key, _ in !key.hasPrefix("run:") || runIDs.contains(String(key.dropFirst(4))) }
        editorWorkspaces = stash
    }

    private var orderedEditorGroups: [EditorGroup] {
        let groups = previewPaneIDs.compactMap { editorGroups[$0] }
        return groups.isEmpty ? [activeEditor] : groups
    }

    private func apply(_ workspace: EditorWorkspace, to groups: [EditorGroup]) {
        for (i, group) in groups.enumerated() {
            var snapshot = i < workspace.groups.count ? workspace.groups[i] : EditorSnapshot()
            // More editors were open there than now: keep the extra tabs in the last one.
            if i == groups.count - 1 {
                for extra in workspace.groups.dropFirst(groups.count) {
                    snapshot.tabs += extra.tabs.filter { !snapshot.tabs.contains($0) }
                }
            }
            snapshot.restore(into: group)
        }
        directorySelectedFile = workspace.selectedFile
        directoryRevealID = UUID()
    }
}

struct EditorWorkspace: Codable {
    var groups: [EditorSnapshot] = []
    var selectedFile: URL?
}

struct EditorSnapshot: Codable {
    var tabs: [URL] = []
    var file: URL?
    var mode: String = AppModel.PreviewMode.file.rawValue
    var line: Int?
    /// History stays in memory only.
    var back: [AppModel.PreviewLocation] = []
    var forward: [AppModel.PreviewLocation] = []

    enum CodingKeys: String, CodingKey { case tabs, file, mode, line }

    init() {}

    @MainActor init(_ group: EditorGroup) {
        tabs = group.tabs
        file = group.file
        mode = group.mode.rawValue
        line = group.line
        back = group.back
        forward = group.forward
    }

    @MainActor func restore(into group: EditorGroup) {
        let existing = tabs.filter { FileManager.default.fileExists(atPath: $0.path) }
        group.tabs = existing
        group.file = file.flatMap { existing.contains($0) ? $0 : nil } ?? existing.first
        group.mode = AppModel.PreviewMode(rawValue: mode) ?? .file
        group.line = group.file == file ? line : nil
        group.back = back
        group.forward = forward
    }
}
