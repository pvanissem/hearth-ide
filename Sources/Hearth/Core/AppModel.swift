import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class AppModel {
    let updates = UpdateChecker()
    let builds = BuildDeployStore()
    /// Agent sessions running in Hearth's own nono sandbox (terminal chat).
    let agents = AgentHost()
    var cli: DevkCLI? = DevkCLI.locate()
    var entries: [WebSessionEntry] = []
    var servers: [String: ServerConnection] = [:]
    var selectedSessionID: String? { didSet { saveSelection() } }
    var selectedServerID: String? { didSet { saveSelection() } }
    private var chatStore = ChatRenderStore()
    private var chatRequests = LatestRequest<ChatSelection>()
    private var chatConnectionEpochs: [String: UUID] = [:]
    var chatViewGeneration = UUID()
    var chatIsLoading = false
    var chatSelection: ChatSelection? {
        guard let serverID = selectedServerID, let sessionID = selectedSessionID else { return nil }
        return ChatSelection(serverID: serverID, sessionID: sessionID)
    }
    var messages: [ChatMessage] { chatSelection.map { chatStore.messages(for: $0) } ?? [] }
    var chatIsSynchronizing: Bool { chatSelection.map { chatStore.isSynchronizing($0) } ?? false }
    var chatLoadFailure: ChatFailure?
    var sessionListDisclosure: SessionListDisclosure = UIStateStore.load(.sessionListDisclosure) ?? SessionListDisclosure() {
        didSet { UIStateStore.save(sessionListDisclosure, as: .sessionListDisclosure) }
    }
    var banner: String?
    var busy = false
    /// File shown in the active editor (Preview pane).
    var previewFile: URL? {
        get { activeEditor.file }
        set { activeEditor.file = newValue }
    }

    // MARK: Editor groups (one per Preview pane, each with its own tabs)

    var editorGroups: [UUID: EditorGroup] = [:]
    /// Preview pane that receives openPreview() and the editor shortcuts.
    var activeEditorID: UUID? { didSet { if oldValue != activeEditorID { invalidateDefinition() } } }
    /// Holds tabs while no Preview pane exists (e.g. restored state before layout).
    private let looseEditor = EditorGroup()

    func editorGroup(_ paneID: UUID) -> EditorGroup {
        if let g = editorGroups[paneID] { return g }
        // The first pane adopts the tabs opened while no pane existed.
        let g = editorGroups.isEmpty ? looseEditor : EditorGroup()
        editorGroups[paneID] = g
        return g
    }

    private var previewPaneIDs: [UUID] {
        let main = paneTree.panes.filter { $0.tab == .preview }.map(\.id)
        return detachedTabs.contains(.preview) ? main + [DetachedPaneView.id(for: .preview)] : main
    }

    var activeEditor: EditorGroup {
        let ids = previewPaneIDs
        if let id = activeEditorID, ids.contains(id), let g = editorGroups[id] { return g }
        if let id = ids.first(where: { editorGroups[$0] != nil }) { return editorGroups[id]! }
        return editorGroups.isEmpty ? looseEditor : (ids.first.map { editorGroups[$0] } ?? nil) ?? looseEditor
    }

    /// Opens a second editor next to `paneID`, showing `url` (or the same file).
    func splitEditor(_ paneID: UUID, axis: SplitAxis = .horizontal, url: URL? = nil) {
        let source = editorGroup(paneID)
        let pane = InspectorPane(tab: .preview)
        paneTree = paneTree.splitting(paneID, axis: axis, with: pane)
        let g = EditorGroup()
        editorGroups[pane.id] = g
        if let u = url ?? source.file {
            g.tabs = [u]
            g.file = u
            g.mode = source.mode
        }
        activeEditorID = pane.id
    }

    /// Moves a tab from one editor to another.
    struct TabDrag: Equatable { let pane: UUID; let url: URL }
    /// Tab currently being dragged (in-process); pane drop zones ignore such drags.
    var draggingTab: TabDrag?

    /// Reorders a tab within an editor, or moves it into another editor, before `target`
    /// (nil = at the end). The moved tab becomes the visible one.
    func placeTab(_ url: URL, from: UUID, to: UUID, before target: URL?) {
        let src = editorGroup(from), dst = editorGroup(to)
        guard src.tabs.contains(url) else { return }
        dst.tabs = TabOrdering.place(url, in: dst.tabs, before: target)
        if src !== dst { src.remove(url) }
        dst.file = url
        activeEditorID = to
    }

    func moveTab(_ url: URL, from: UUID, to: UUID) {
        let src = editorGroup(from), dst = editorGroup(to)
        if !dst.tabs.contains(url) { dst.tabs.append(url) }
        dst.file = url
        src.remove(url)
        activeEditorID = to
    }
    /// Bumped whenever the agent may have changed files; inspector tabs reload on change.
    var workspaceRevision = 0
    var directoryExpandedPaths: Set<String> = []
    var directorySelectedFile: URL?
    var directoryRevealID = UUID()
    let directoryDragToken = UUID()
    /// Empty clone targets created by this app instance may be retried, never arbitrary folders.
    var cloneDirectories: Set<String> = []

    /// Directory the inspector shows: the selected session's, else its sandbox repo.
    var workspaceRoot: String? {
        agents.selectedRun?.directory ?? selectedSession?.directory ?? server(for: selectedServerID)?.entry.repoRoot
    }

    func openPreview(_ url: URL, mode: PreviewMode = .file, line: Int? = nil, recordHistory: Bool = true) {
        if previewFile != url {
            invalidateDefinition()
        }
        if recordHistory, let current = previewFile, current != url || previewLine != line {
            previewBack.append(PreviewLocation(url: current, line: previewLine))
            if previewBack.count > 50 { previewBack.removeFirst() }
            previewForward.removeAll()
        }
        if !openTabs.contains(url) {
            // Open next to the current tab, like IDEs do.
            let at = previewFile.flatMap { openTabs.firstIndex(of: $0) }.map { $0 + 1 } ?? openTabs.count
            openTabs.insert(url, at: at)
        }
        previewFile = url
        previewMode = mode
        previewLine = line
        if previewPaneIDs.isEmpty, let last = paneTree.panes.last {
            split(last.id, axis: .vertical, tab: .preview)
        }
    }

    enum PreviewMode: String, CaseIterable { case file = "Datei", diff = "Diff" }
    var previewMode: PreviewMode {
        get { activeEditor.mode }
        set { activeEditor.mode = newValue }
    }
    /// Line to highlight and scroll to in the file preview.
    var previewLine: Int? {
        get { activeEditor.line }
        set { activeEditor.line = newValue }
    }

    // MARK: Editor tabs

    var openTabs: [URL] {
        get { activeEditor.tabs }
        set { activeEditor.tabs = newValue }
    }
    /// Open documents keep unsaved edits while switching tabs.
    var documents: [URL: PreviewDocument] = [:]
    /// Last known unstaged hunks per "root#path" so revisiting a tab shows them instantly.
    @ObservationIgnored var fileDiffCache: [String: FileDiff] = [:]
    /// workspaceRevision at which each cached diff was loaded.
    @ObservationIgnored var fileDiffRevision: [String: Int] = [:]

    func document(for url: URL) -> PreviewDocument {
        if let d = documents[url] { return d }
        let d = PreviewDocument(url: url)
        documents[url] = d
        return d
    }

    var unsavedDocuments: [PreviewDocument] { documents.values.filter(\.isDirty) }

    /// Closes a tab without asking (callers confirm unsaved changes first).
    func closeTab(_ url: URL) { closeTab(url, in: activeEditor) }

    func closeTab(_ url: URL, in group: EditorGroup) {
        group.remove(url)
        // Documents are shared between editors; drop it once no editor shows it.
        if !editorGroups.values.contains(where: { $0.tabs.contains(url) }) && !looseEditor.tabs.contains(url) {
            documents[url] = nil
        }
    }

    func closeOtherTabs(keeping url: URL) { closeOtherTabs(in: activeEditor, keeping: url) }

    func closeOtherTabs(in group: EditorGroup, keeping url: URL) {
        for t in group.tabs where t != url && documents[t]?.isDirty != true { closeTab(t, in: group) }
    }

    // MARK: Code navigation

    struct PreviewLocation: Equatable {
        let url: URL
        let line: Int?
    }

    var previewBack: [PreviewLocation] {
        get { activeEditor.back }
        set { activeEditor.back = newValue }
    }
    var previewForward: [PreviewLocation] {
        get { activeEditor.forward }
        set { activeEditor.forward = newValue }
    }
    /// Set when a ⌘-click matched several declarations; the preview shows a chooser.
    var definitionChoices: (symbol: String, locations: [SymbolLocation])?
    var searchingDefinition: String?
    private var definitionGeneration = UUID()
    private func invalidateDefinition() {
        definitionGeneration = UUID(); searchingDefinition = nil; definitionChoices = nil
    }

    func navigateBack() {
        guard let target = previewBack.popLast() else { return }
        if let current = previewFile { previewForward.append(PreviewLocation(url: current, line: previewLine)) }
        openPreview(target.url, mode: .file, line: target.line, recordHistory: false)
    }

    func navigateForward() {
        guard let target = previewForward.popLast() else { return }
        if let current = previewFile { previewBack.append(PreviewLocation(url: current, line: previewLine)) }
        openPreview(target.url, mode: .file, line: target.line, recordHistory: false)
    }

    func goToDefinition(symbol: String, qualifier: String?) async {
        guard let root = workspaceRoot else { return }
        let editor = activeEditor
        let file = editor.file
        let generation = UUID()
        definitionGeneration = generation
        let current = previewFile.flatMap { $0.path.hasPrefix(root) ? String($0.path.dropFirst(root.count + 1)) : nil }
        searchingDefinition = symbol
        let results = await SymbolFinder.find(symbol: symbol, qualifier: qualifier, root: root, currentFile: current)
        guard definitionGeneration == generation else { return }
        guard !Task.isCancelled, workspaceRoot == root, activeEditor === editor, editor.file == file else {
            invalidateDefinition()
            return
        }
        searchingDefinition = nil
        definitionChoices = nil
        // Ignore the declaration the user is already looking at (⌘-click on the definition itself).
        let others = results.filter { !($0.path == current && $0.line == previewLine) }
        switch others.count {
        case 0:
            toast(results.isEmpty ? "Keine Definition für „\(symbol)“ gefunden" : "Das ist bereits die Definition von „\(symbol)“")
        case 1:
            open(others[0], root: root)
        default:
            definitionChoices = (symbol, others)
        }
    }

    func open(_ location: SymbolLocation, root: String) {
        definitionChoices = nil
        openPreview(URL(fileURLWithPath: root).appendingPathComponent(location.path), mode: .file, line: location.line)
    }

    /// Sends a prepared instruction to the selected session's agent.
    func ask(_ prompt: String) {
        guard let selection = chatSelection else {
            banner = "Wähle zuerst links eine Session, die den Auftrag bekommen soll."
            return
        }
        Task { await send(prompt, to: selection) }
        toast("Auftrag an den Agenten gesendet")
    }

    /// Opens `fileName:line` from a stack trace if the file exists in the workspace.
    func reveal(fileName: String, line: Int?) async {
        guard let root = workspaceRoot else { return }
        let hits = await FileSearch.find(fileName, in: root).filter { !$0.isDirectory && $0.name == fileName }
        guard !Task.isCancelled, workspaceRoot == root else { return }
        if let hit = hits.first {
            openPreview(URL(fileURLWithPath: root).appendingPathComponent(hit.relativePath), mode: .file, line: line)
        } else {
            toast("\(fileName) nicht im Workspace gefunden")
        }
    }

    /// Drafts belong to sessions; delayed native text callbacks must not edit another chat.
    private var chatDrafts: [ChatSelection: String] = [:]
    private var unscopedDraft = ""
    var draft: String {
        get { draft(for: chatSelection) }
        set { setDraft(newValue, for: chatSelection) }
    }
    func draft(for selection: ChatSelection?) -> String {
        selection.map { chatDrafts[$0] ?? "" } ?? unscopedDraft
    }
    func setDraft(_ text: String, for selection: ChatSelection?) {
        if let selection { chatDrafts[selection] = text } else { unscopedDraft = text }
    }

    func mention(_ url: URL) {
        let path = workspaceRoot.map { url.path.hasPrefix($0) ? String(url.path.dropFirst($0.count + 1)) : url.path } ?? url.path
        draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + "`\(path)` "
        toast("Im Chat eingefügt: \(path)")
    }

    private var toastTask: Task<Void, Never>?

    /// Short-lived confirmation message.
    func toast(_ message: String) {
        banner = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, banner == message { banner = nil }
        }
    }

    // MARK: Window layout (every area is a movable pane)

    var paneTree: PaneNode = LayoutPreset.standard.build().0 {
        didSet {
            // Drop stored sizes for splits that no longer exist or changed child count.
            let ids = paneTree.splitIDs
            splitWeights = splitWeights.filter { ids.contains($0.key) }
            UIStateStore.save(paneTree, as: .paneTree)
        }
    }
    /// Relative child sizes per split (sums to 1), persisted.
    var splitWeights: [UUID: [Double]] = [:] {
        didSet { UIStateStore.save(splitWeights, as: .splitWeights) }
    }
    var gitSnapshot = GitSnapshot()

    func weights(for id: UUID, count: Int) -> [Double] {
        if let w = splitWeights[id], w.count == count { return w }
        return Array(repeating: 1 / Double(count), count: count)
    }

    func split(_ paneID: UUID, axis: SplitAxis, tab: InspectorTab? = nil) {
        let used = Set(paneTree.panes.map(\.tab))
        let next = tab ?? InspectorTab.allCases.first { !used.contains($0) && $0.needsWorkspace } ?? .preview
        paneTree = paneTree.splitting(paneID, axis: axis, with: InspectorPane(tab: next))
    }

    func closePane(_ id: UUID) {
        guard paneTree.panes.count > 1, let tree = paneTree.removing(id) else { return }
        if maximizedPane == id { maximizedPane = nil }
        paneTree = tree
        if let g = editorGroups[id], editorGroups.count > 1 {
            editorGroups[id] = nil
            // Keep unsaved documents reachable: move their tabs to another editor.
            if let other = previewPaneIDs.first.flatMap({ editorGroups[$0] }) {
                for t in g.tabs where documents[t]?.isDirty == true && !other.tabs.contains(t) { other.tabs.append(t) }
            }
        }
    }

    /// Pane filling the whole window (double-click on a pane header), nil = normal layout.
    var maximizedPane: UUID?

    func toggleMaximize(_ id: UUID) {
        maximizedPane = maximizedPane == id ? nil : id
    }

    enum DropZone: Equatable {
        case left, right, top, bottom, center
        /// Along the whole window edge (full width/height).
        case windowLeft, windowRight, windowTop, windowBottom

        var isWindowEdge: Bool { [.windowLeft, .windowRight, .windowTop, .windowBottom].contains(self) }
    }

    /// Window-edge drop preview shown over the whole layout while dragging.
    var windowDropZone: DropZone?

    /// Drag & drop: move `source` next to `target` (or swap contents on center).
    func movePane(_ source: UUID, onto target: UUID, zone: DropZone) {
        guard source != target, let moving = paneTree.pane(source), let other = paneTree.pane(target) else { return }
        if zone == .center {
            paneTree = paneTree.updating(source, tab: other.tab).updating(target, tab: moving.tab)
            return
        }
        guard let without = paneTree.removing(source) else { return }
        if zone.isWindowEdge {
            paneTree = without
            dock(moving, atWindowEdge: zone)
            return
        }
        let axis: SplitAxis = zone == .left || zone == .right ? .horizontal : .vertical
        paneTree = without.inserting(moving, at: target, axis: axis, before: zone == .left || zone == .top)
    }

    /// Puts a pane along a whole window edge, e.g. a terminal across the full width at the bottom.
    func dock(_ pane: InspectorPane, atWindowEdge zone: DropZone) {
        let axis: SplitAxis = zone == .windowLeft || zone == .windowRight ? .horizontal : .vertical
        let before = zone == .windowLeft || zone == .windowTop
        let share = 0.3   // new pane's share of the window
        if case .split(let id, let a, var children) = paneTree, a == axis {
            // Root already splits along this axis: add another column/row at the edge.
            let old = weights(for: id, count: children.count).map { $0 * (1 - share) }
            if before { children.insert(.leaf(pane), at: 0) } else { children.append(.leaf(pane)) }
            paneTree = .split(id: id, axis: a, children: children)
            splitWeights[id] = before ? [share] + old : old + [share]
        } else {
            let id = UUID()
            paneTree = .split(id: id, axis: axis, children: before ? [.leaf(pane), paneTree] : [paneTree, .leaf(pane)])
            splitWeights[id] = before ? [share, 1 - share] : [1 - share, share]
        }
    }

    func addPane(_ tab: InspectorTab, atWindowEdge zone: DropZone) {
        maximizedPane = nil
        if let existing = paneTree.panes.first(where: { $0.tab == tab }), let without = paneTree.removing(existing.id) {
            paneTree = without   // move it instead of duplicating
        }
        dock(InspectorPane(tab: tab), atWindowEdge: zone)
    }

    /// Adds an area at the right edge of the window (unless it is already open).
    func addPane(_ tab: InspectorTab) {
        maximizedPane = nil
        if paneTree.contains(tab: tab) {
            toast("„\(tab.title)“ ist bereits offen")
            return
        }
        let new = InspectorPane(tab: tab)
        switch paneTree {
        case .split(let id, .horizontal, var children):
            children.append(.leaf(new))
            paneTree = .split(id: id, axis: .horizontal, children: children)
        default:
            paneTree = .split(id: UUID(), axis: .horizontal, children: [paneTree, .leaf(new)])
        }
    }

    func apply(_ preset: LayoutPreset) {
        let (tree, weights) = preset.build()
        maximizedPane = nil
        paneTree = tree
        splitWeights = weights
    }

    // MARK: Detached pane windows

    /// Tabs currently shown in their own window (opened via openWindow(value:)).
    var detachedTabs: Set<InspectorTab> = [] {
        didSet { if !quitting { UIStateStore.save(detachedTabs.map(\.rawValue).sorted(), as: .detachedTabs) } }
    }
    /// Set while the app terminates so closing windows don't forget they were open.
    var quitting = false

    /// Tabs that had their own window when the app was last quit.
    var savedDetachedTabs: [InspectorTab] {
        (UIStateStore.load(.detachedTabs) as [String]?)?.compactMap(InspectorTab.init(rawValue:)) ?? []
    }

    /// Removes the pane from the main layout; the caller opens the window.
    func detach(_ id: UUID) -> InspectorTab? {
        guard let pane = paneTree.pane(id) else { return nil }
        if paneTree.panes.count > 1 { closePane(id) }
        detachedTabs.insert(pane.tab)
        return pane.tab
    }

    func dock(_ tab: InspectorTab) {
        detachedTabs.remove(tab)
        if !paneTree.contains(tab: tab) { addPane(tab) }
    }

    func setTab(_ tab: InspectorTab, for id: UUID) {
        paneTree = paneTree.updating(id, tab: tab)
    }

    func resetLayout() { apply(.standard) }

    // MARK: GitLab token

    var gitLabReadTokens: [GitLabOrigin: String] = [:]
    var gitLabWriteTokens: [GitLabOrigin: String] = [:]
    var gitLabLoadedOrigins: Set<GitLabOrigin> = []
    private var gitLabCredentialRevision: [GitLabOrigin: Int] = [:]

    func loadGitLabToken(for origin: GitLabOrigin) async {
        guard !gitLabLoadedOrigins.contains(origin) else { return }
        gitLabLoadedOrigins.insert(origin)
        let approved = UserDefaults.standard.stringArray(forKey: "gitlab.approvedOrigins.v2") ?? []
        guard Snapshotter.directory == nil, approved.contains(origin.value) else { return }
        let revision = gitLabCredentialRevision[origin, default: 0]
        let (read, write) = await Task.detached {
            (GitLabToken.load(origin: origin, writing: false), GitLabToken.load(origin: origin, writing: true))
        }.value
        guard gitLabCredentialRevision[origin, default: 0] == revision else { return }
        gitLabReadTokens[origin] = read
        gitLabWriteTokens[origin] = write
    }

    /// Only call after explicit confirmation of the displayed HTTPS origin.
    func saveGitLabToken(_ token: String, for origin: GitLabOrigin, writing: Bool) -> Bool {
        guard GitLabToken.save(token, origin: origin, writing: writing) else { return false }
        gitLabCredentialRevision[origin, default: 0] += 1
        if writing { gitLabWriteTokens[origin] = token } else { gitLabReadTokens[origin] = token }
        var approved = Set(UserDefaults.standard.stringArray(forKey: "gitlab.approvedOrigins.v2") ?? [])
        approved.insert(origin.value)
        UserDefaults.standard.set(Array(approved).sorted(), forKey: "gitlab.approvedOrigins.v2")
        return true
    }

    func gitLabAPI(for remote: GitLabRemote, writing: Bool = false) -> GitLabAPI? {
        // A write token is never silently used for polling/read requests.
        guard let token = (writing ? gitLabWriteTokens : gitLabReadTokens)[remote.origin] else { return nil }
        return GitLabAPI(remote: remote, credential: GitLabCredential(origin: remote.origin, token: token, allowsWrites: writing))
    }

    func revokeGitLabOrigin(_ origin: GitLabOrigin) {
        gitLabCredentialRevision[origin, default: 0] += 1
        gitLabReadTokens[origin] = nil
        gitLabWriteTokens[origin] = nil
        GitLabToken.delete(origin: origin, writing: false)
        GitLabToken.delete(origin: origin, writing: true)
        let approved = UserDefaults.standard.stringArray(forKey: "gitlab.approvedOrigins.v2") ?? []
        UserDefaults.standard.set(approved.filter { $0 != origin.value }, forKey: "gitlab.approvedOrigins.v2")
    }

    // MARK: Text zoom

    var textScales: [String: Double] = [:] {
        didSet { UIStateStore.save(textScales, as: .textScales) }
    }
    /// Area under the mouse; ⌘-scroll / pinch zoom applies there.
    var hoveredArea: TextArea?
    var hoveringDiagram = false
    private var zoomMonitor: TextZoomMonitor?

    static let textScaleRange: ClosedRange<Double> = 0.7...2.2

    func textScale(_ area: TextArea) -> Double {
        textScales[area.rawValue] ?? (area.base == area ? 1 : textScale(area.base))
    }

    func zoom(_ area: TextArea, by factor: Double) {
        let next = min(max(textScale(area) * factor, Self.textScaleRange.lowerBound), Self.textScaleRange.upperBound)
        guard abs(next - textScale(area)) > 0.001 else { return }
        textScales[area.rawValue] = next
        let name = switch area {
        case .chat: "Chat"; case .inspector: "Inspector"; case .sidebar: "Sessions"
        case .pane(_, let tab): tab.title
        }
        toast("Schriftgröße \(name): \(Int((next * 100).rounded())) %")
    }

    func zoomAll(by factor: Double) {
        TextArea.allCases.forEach { zoom($0, by: factor) }
        for key in textScales.keys where key.hasPrefix("pane:") {
            textScales[key] = min(max(textScales[key]! * factor, Self.textScaleRange.lowerBound), Self.textScaleRange.upperBound)
        }
    }

    func resetZoom(_ area: TextArea) {
        textScales[area.rawValue] = nil
        toast("Schriftgröße zurückgesetzt")
    }

    func resetZoom() {
        textScales = [:]
        toast("Schriftgröße zurückgesetzt")
    }

    /// Defaults applied to newly created sessions (last explicit choice).
    var preferredModel: ModelRef? {
        didSet { UIStateStore.save(preferredModel.map { [$0.providerID, $0.id] }, as: .preferredModel) }
    }
    var preferredAgent: String? {
        didSet { UIStateStore.save(preferredAgent, as: .preferredAgent) }
    }

    private var pollTask: Task<Void, Never>?
    /// Selection to restore once the matching server has connected.
    private var pendingRestore: (server: String, session: String?)?

    init() {
        Notifier.requestAuthorization()
        restoreUIState()
        agents.onAttention = { [weak self] run in
            guard let self else { return }
            let visible = NSApp.isActive && self.agents.selectedRunID == run.id
            guard !visible else {
                // The user is looking at it: a finished turn needs no further attention.
                self.agents.acknowledge(run)
                return
            }
            let what = run.status == .needsInput ? "wartet auf dich" : "ist fertig"
            Notifier.notify(title: run.title, body: "\(run.kind.displayName) \(what)" + (run.detail.map { ": \($0)" } ?? "."))
        }
        // Resolve the login shell's PATH off the main thread before the first start.
        Task.detached(priority: .utility) { _ = SandboxManager.searchPath }
        autostartAgentForDevelopment()
        if Snapshotter.directory == nil { zoomMonitor = TextZoomMonitor(model: self) }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshRegistry()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Developer aid: `HEARTH_AUTOSTART_AGENT=claude HEARTH_AUTOSTART_DIR=<dir>` starts an agent at
    /// launch; `HEARTH_AUTOSTART_PROMPT` then confirms the folder-trust question and types the prompt.
    private func autostartAgentForDevelopment() {
        let env = ProcessInfo.processInfo.environment
        if let path = env["HEARTH_WINDOW_SNAPSHOT"] {
            // Writes the main window's layer tree to a PNG every few seconds (no screen-recording permission needed).
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3))
                    Snapshotter.writeWindow(to: URL(fileURLWithPath: path))
                }
            }
        }
        if env["HEARTH_SHOW_START_SHEET"] != nil {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.showWelcome = false
                try? await Task.sleep(for: .milliseconds(400))
                self?.agents.startSheet = .init()
            }
        }
        guard let raw = env["HEARTH_AUTOSTART_AGENT"], let kind = AgentKind(rawValue: raw),
              let dir = env["HEARTH_AUTOSTART_DIR"] else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self else { return }
            self.showWelcome = false
            self.startAgent(kind, directory: dir)
            if let wanted = env["HEARTH_AUTOSTART_BUILD"] {
                // Opens Build & Deployment and runs the first task whose id/title contains the text.
                if !self.paneTree.contains(tab: .build) { self.addPane(.build) }
                let projects = BuildDetector.scan(root: dir)
                if let task = projects.flatMap(\.tasks).first(where: { $0.id.contains(wanted) || $0.title.contains(wanted) }),
                   let shell = self.buildShell(root: dir) {
                    await self.builds.start(task, root: dir, serverID: shell.id, client: shell.client)
                }
            }
            guard let prompt = env["HEARTH_AUTOSTART_PROMPT"], let run = self.agents.selectedRun else { return }
            try? await Task.sleep(for: .seconds(6))
            run.terminal?.send(txt: "\r")
            try? await Task.sleep(for: .seconds(3))
            run.terminal?.send(txt: prompt)
            try? await Task.sleep(for: .milliseconds(500))
            run.terminal?.send(txt: "\r")
        }
    }

    private func restoreUIState() {
        // Read the weights first: assigning paneTree prunes (and re-saves) splitWeights.
        let saved: [UUID: [Double]] = UIStateStore.load(.splitWeights) ?? [:]
        if let tree: PaneNode = UIStateStore.load(.paneTree), !tree.panes.isEmpty {
            if tree.contains(tab: .sessions) || tree.contains(tab: .chat) {
                paneTree = tree
                splitWeights = saved
            } else {
                // Layout from before sessions/chat became panes: keep the inspector arrangement on the right.
                let id = UUID()
                paneTree = .split(id: id, axis: .horizontal, children: [
                    .leaf(InspectorPane(tab: .sessions)), .leaf(InspectorPane(tab: .chat)), tree,
                ])
                splitWeights = saved.merging([id: [0.2, 0.45, 0.35]]) { $1 }
            }
        } else {
            apply(.standard)
        }
        if let m: [String] = UIStateStore.load(.preferredModel), m.count == 2 {
            preferredModel = ModelRef(providerID: m[0], id: m[1])
        }
        preferredAgent = UIStateStore.load(.preferredAgent)
        if let z: [String: Double] = UIStateStore.load(.textScales) { textScales = z }
        if let raw: String = UIStateStore.load(.previewMode), let mode = PreviewMode(rawValue: raw) { previewMode = mode }
        if let paths: [String] = UIStateStore.load(.openTabs) {
            openTabs = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        }
        if let path: String = UIStateStore.load(.previewFile), FileManager.default.fileExists(atPath: path) {
            previewFile = URL(fileURLWithPath: path)
            if !openTabs.contains(previewFile!) { openTabs.append(previewFile!) }
        }
        if let sel: [String] = UIStateStore.load(.selection), let server = sel.first {
            pendingRestore = (server, sel.count > 1 ? sel[1] : nil)
        }
    }

    private func saveSelection() {
        UIStateStore.save([selectedServerID, selectedSessionID].compactMap { $0 }, as: .selection)
    }

    /// Called whenever a server (re)loads its sessions.
    /// Repo whose sandbox the user just started: open its most recent session once loaded.
    private var openNewestAfterStart: String?
    /// Sandbox starts (id + start time) already checked for devkcode's auto-created session.
    private var cleanedStarts: Set<String> = []

    func serverDidLoad(_ conn: ServerConnection) {
        if chatConnectionEpochs[conn.id] != conn.connectionEpoch {
            // Delta delivery may have a gap after reconnect. Wait for canonical
            // text.ended/history rather than stitching the gap to an old prefix.
            chatStore.discardStreams(serverID: conn.id)
            chatConnectionEpochs[conn.id] = conn.connectionEpoch
        }
        let key = conn.id + "#" + (conn.entry.lastStartedAt?.timeIntervalSince1970.description ?? "")
        if !cleanedStarts.contains(key) {
            cleanedStarts.insert(key)
            Task { await dropAutoCreatedSession(conn) }
        }
        guard let pending = pendingRestore, pending.server == conn.id else {
            if selectedServerID == conn.id, let selection = chatSelection {
                Task { await loadMessages(for: selection) }
            }
            return
        }
        pendingRestore = nil
        if let sid = pending.session, let item = conn.sessions[sid] { select(item) } else { selectSandbox(conn.id) }
    }

    /// `devkcode web` creates an empty session on every start (for its browser UI). If the
    /// repo already has other sessions, delete that empty one and open the most recent instead.
    private func dropAutoCreatedSession(_ conn: ServerConnection) async {
        let root = conn.entry.repoRoot
        guard let list = try? await conn.client.sessions(directory: root) else { return }
        var fresh: [String] = [], older: [(id: String, updated: Double)] = []
        for s in list {
            guard let id = s["id"]?.string, s["parentID"]?.string == nil else { continue }
            let title = s["title"]?.string ?? ""
            let untitled = title.isEmpty || title.hasPrefix("ses_") || title.lowercased().hasPrefix("new session")
            // Any empty, untitled session is a leftover (devkcode web also creates one when it
            // just reuses a running sandbox, without a new start time); keep the open one.
            if untitled, id != selectedSessionID || openNewestAfterStart == root,
               (try? await conn.client.messages(sessionID: id))?.isEmpty ?? false {
                fresh.append(id)
            } else {
                older.append((id, s["time"]?["updated"]?.double ?? 0))
            }
        }
        let newest = older.max(by: { $0.updated < $1.updated })
        if newest != nil {   // first start of a repo: keep the new session
            for id in fresh { try? await conn.client.deleteSession(id) }
            try? await conn.reload()
        }
        let selectionGone = selectedServerID == conn.id && (selectedSessionID.map { conn.sessions[$0] == nil } ?? true)
        if openNewestAfterStart == root || selectionGone {
            openNewestAfterStart = nil
            if let id = newest?.id ?? fresh.first, let item = conn.sessions[id] { select(item) }
        }
    }

    // MARK: Registry / servers

    // MARK: Welcome

    static let showWelcomeKey = "ui.showWelcomeOnLaunch"
    var showWelcome = false
    private var welcomeChecked = false

    static var welcomeEnabled: Bool {
        get { UserDefaults.standard.object(forKey: showWelcomeKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: showWelcomeKey) }
    }

    /// Leaves the welcome dialog and opens the start sheet (sheets can't stack).
    func welcomeStartNew(_ prefill: StartRequest = .init()) {
        showWelcome = false
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            if cli == nil { agents.startSheet = .init(directory: prefill.root) } else { startRequest = prefill }
        }
    }

    /// Opens the agent start sheet from the welcome dialog (sheets can't stack).
    func welcomeStartAgent(_ prefill: AgentHost.StartAgentRequest = .init()) {
        showWelcome = false
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            agents.startSheet = prefill
        }
    }

    func refreshRegistry() {
        do {
            // Assign only on change: every write invalidates the observing SwiftUI views.
            let newEntries = try WebSessionRegistry.load()
            if newEntries != entries { entries = newEntries }
            let newSandboxEntries = SandboxRegistry.load()
            if newSandboxEntries != sandboxEntries { sandboxEntries = newSandboxEntries }
        } catch {
            banner = error.localizedDescription
            return
        }
        defer {
            // Greet once per launch, but only when nothing was already running in the background.
            if !welcomeChecked {
                welcomeChecked = true
                showWelcome = servers.isEmpty && agents.runningCount == 0 && Self.welcomeEnabled && Snapshotter.directory == nil
            }
        }
        for entry in entries {
            let alive = WebSessionRegistry.isAlive(entry)
            if alive, let existing = servers[entry.id], existing.entry != entry {
                // Restarted with another profile/port/password: reconnect with fresh data.
                existing.stop()
                retireChatConnection(entry.id)
                servers[entry.id] = nil
            }
            if alive, servers[entry.id] == nil,
               let url = entry.baseURL, let pw = entry.password {
                let conn = ServerConnection(entry: entry, client: OpenCodeClient(baseURL: url, password: pw))
                conn.onEvent = { [weak self, weak conn] type, event in
                    guard let self, let conn, self.servers[entry.id] === conn else { return }
                    self.handleChatEvent(serverID: entry.id, type: type, event: event)
                }
                conn.onLoaded = { [weak self] c in
                    guard let self, self.servers[c.id] === c else { return }
                    self.serverDidLoad(c)
                }
                servers[entry.id] = conn
                conn.start()
            } else if !alive, let conn = servers[entry.id] {
                conn.stop()
                retireChatConnection(entry.id)
                servers[entry.id] = nil
            }
        }
    }

    private func retireChatConnection(_ serverID: String) {
        builds.serverGone(serverID)
        chatStore.discardStreams(serverID: serverID)
        chatConnectionEpochs[serverID] = nil
        if selectedServerID == serverID {
            chatRequests.invalidate()
            chatViewGeneration = UUID()
            chatIsLoading = false
        }
    }

    /// `devkcode run` history (what the dashboard's Sandboxes tab shows).
    var sandboxEntries: [SandboxEntry] = []
    var sandboxLastUsed: [String: Date] = UIStateStore.load(.sandboxLastUsed) ?? [:] {
        didSet { UIStateStore.save(sandboxLastUsed, as: .sandboxLastUsed) }
    }

    var recentSandboxes: [SandboxListing] {
        SandboxHistory.merged(terminal: sandboxEntries, web: entries, lastUsed: sandboxLastUsed)
    }

    private func recordSandboxUse(_ entry: WebSessionEntry) {
        sandboxLastUsed[entry.repoRoot + "#" + (entry.projectName ?? "")] = Date()
    }

    func openRecentSandbox(_ row: SandboxListing) async {
        refreshRegistry()
        if let conn = servers.values.first(where: { $0.entry.repoRoot == row.root }) {
            if conn.entry.projectName != row.project || (row.profile != nil && conn.entry.profileName != row.profile) {
                // A history row must not silently restart an active sandbox with different grants.
                welcomeStartNew(.init(root: row.root, project: row.project, profile: row.profile))
                return
            }
            do { try await conn.reload() } catch { banner = error.localizedDescription; return }
            let selected = selectedServerID == conn.id ? selectedSessionID.flatMap { conn.sessions[$0] } : nil
            if let session = selected ?? conn.sessions.values.max(by: { $0.updated < $1.updated }) { select(session) }
            else { selectSandbox(conn.id) }
        } else {
            await startSandbox(root: row.root, project: row.project, profile: row.profile)
        }
    }

    /// Every known sandbox that hearth isn't connected to, merged from the web-session
    /// and the `devkcode run` registries (one row per repo + project), newest first.
    var inactiveSandboxes: [SandboxListing] {
        let connected = Set(servers.values.map(\.entry.repoRoot))
        return SandboxHistory.merged(terminal: sandboxEntries, web: entries).filter { !connected.contains($0.root) }
    }

    var inbox: [SessionItem] {
        servers.values.flatMap(\.sessions.values).sorted {
            ($0.status.priority, $1.updated) < ($1.status.priority, $0.updated)
        }
    }

    func server(for id: String?) -> ServerConnection? { id.flatMap { servers[$0] } }

    var selectedSession: SessionItem? {
        guard let sid = selectedSessionID else { return nil }
        return server(for: selectedServerID)?.sessions[sid]
    }

    func start(entry: WebSessionEntry) async {
        await startSandbox(root: entry.repoRoot, project: entry.projectName, profile: entry.profileName)
    }

    func start(directory: URL) async {
        await startSandbox(root: directory.path, project: nil, profile: nil)
    }

    /// Starts (or restarts with different settings) the web sandbox for a repo.
    func startSandbox(root: String, project: String?, profile: String?) async {
        if let running = servers.values.first(where: { $0.entry.repoRoot == root }),
           (profile != nil && running.entry.profileName != profile) || running.entry.projectName != project {
            // Grants and network policy are fixed at start, so a different profile/project needs a restart.
            await stop(entry: running.entry)
        }
        let name = project ?? URL(fileURLWithPath: root).lastPathComponent
        await runCLI("Starte \(name)\(profile.map { " mit Profil \($0)" } ?? "") …") { cli in
            try await cli.startWeb(repoRoot: root, project: project, profile: profile)
        }
        reloadDevkConfig()
        openNewestAfterStart = root
        // A reused (already running) sandbox doesn't reconnect, so clean up here as well.
        if let conn = servers.values.first(where: { $0.entry.repoRoot == root }) {
            try? await Task.sleep(for: .seconds(1))
            await dropAutoCreatedSession(conn)
        }
    }

    // MARK: devkcode configuration (dashboard features)

    var devkConfig = DevkConfig.load()
    var profiles: [DevkProfile] = []
    /// Set to show the "start sandbox" sheet, optionally prefilled.
    var startRequest: StartRequest?

    struct StartRequest: Identifiable {
        let id = UUID()
        var root: String?
        var project: String?
        var profile: String?
    }

    func reloadDevkConfig() {
        devkConfig = DevkConfig.load()
    }

    func loadProfiles() async {
        guard profiles.isEmpty, let cli else { return }
        profiles = await DevkConfig.profiles(cli: cli)
    }

    /// Runs a devkcode settings command and refreshes the config view afterwards.
    @discardableResult
    func devk(_ args: [String], in dir: String? = nil, success: String? = nil) async -> Bool {
        guard let cli else { banner = "devkcode wurde nicht gefunden"; return false }
        do {
            let r = try await cli.run(args, in: dir ?? NSHomeDirectory())
            reloadDevkConfig()
            if r.status == 0 {
                let last = r.output.strippingANSI.lastNonEmptyLines(1)
                toast(success ?? (last.contains("repair completed") ? "Gespeichert" : last))
                return true
            }
            banner = r.output.strippingANSI.lastNonEmptyLines(3)
        } catch {
            banner = error.localizedDescription
        }
        return false
    }

    struct ForgetRequest: Identifiable {
        let id = UUID()
        let root: String
        let project: String?
        let name: String
        let running: Bool
        let inTerminal: Bool
    }

    /// Pending "remove sandbox" confirmation.
    var forgetRequest: ForgetRequest?

    /// Removes a sandbox from devkcode's lists (like "d" in the dashboard); never touches files.
    func forgetSandbox(root: String, project: String?, name: String) async {
        // A sandbox hearth is connected to is stopped first (otherwise it would just reappear).
        if let running = servers.values.first(where: { $0.entry.repoRoot == root && $0.entry.projectName == project }) {
            await stop(entry: running.entry)
        }
        do {
            let r = try RegistryCleanup.forget(root: root, project: project)
            refreshRegistry()
            toast(r.sandboxEntries + r.webEntries > 0 ? "„\(name)“ aus der Liste entfernt" : "„\(name)“ war bereits entfernt")
        } catch {
            banner = "Entfernen fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Stops all running sandboxes (used when quitting the app).
    func stopAllSandboxes() async {
        let running = servers.values.map(\.entry)
        banner = "Stoppe \(running.count) Sandbox(es) …"
        busy = true
        for entry in running {
            servers[entry.id]?.stop()
            _ = try? await cli?.stopWeb(repoRoot: entry.repoRoot)
        }
        busy = false
    }

    /// Restarts all running sandboxes so changed network rules/MCP/credentials apply.
    func restartAllSandboxes() async {
        for conn in servers.values {
            let e = conn.entry
            await stop(entry: e)
            await startSandbox(root: e.repoRoot, project: e.projectName, profile: e.profileName)
        }
    }

    /// Secrets are typed in a real terminal so they never pass through this app.
    func openCredentialSetup(_ args: [String]) {
        guard let cli else { return }
        let command = ([cli.executable.path] + args).map(TerminalLauncher.shellQuote).joined(separator: " ")
        Task {
            if let err = await TerminalLauncher.launch(TerminalLauncher.preferred, command: command) {
                banner = err
            } else {
                toast("Eingabe im Terminal fortsetzen – danach hier auf „Neu laden“")
            }
        }
    }

    func stop(entry: WebSessionEntry) async {
        await runCLI("Stoppe \(entry.displayName) …") { cli in
            try await cli.stopWeb(repoRoot: entry.repoRoot)
        }
    }

    private func runCLI(_ label: String, _ action: (DevkCLI) async throws -> DevkCLI.Result) async {
        guard let cli else { banner = "devkcode wurde nicht gefunden"; return }
        busy = true
        banner = label
        defer { busy = false }
        do {
            let result = try await action(cli)
            banner = result.status == 0 ? nil : result.output.lastNonEmptyLines(3)
        } catch {
            banner = error.localizedDescription
        }
        refreshRegistry()
    }

    // MARK: Chat

    /// Build & Deployment shells: the devkcode/OpenCode server of this workspace when one is
    /// connected, otherwise Hearth's own nono sandbox for the folder.
    @ObservationIgnored private var localShells: [String: LocalSandboxShell] = [:]

    struct BuildShell {
        let id: String
        let client: SandboxShellAPI
        let label: String
        let isLocal: Bool
    }

    func buildShell(root: String) -> BuildShell? {
        if let conn = server(for: selectedServerID), conn.connected, conn.entry.repoRoot == root || selectedSession?.directory == root {
            return BuildShell(id: conn.id, client: conn.client, label: conn.entry.profileName ?? "aktiv", isLocal: false)
        }
        guard SandboxManager.locateNono() != nil else { return nil }
        let id = "local:" + root
        let shell = localShells[id] ?? LocalSandboxShell(root: root)
        localShells[id] = shell
        return BuildShell(id: id, client: shell, label: "nono", isLocal: true)
    }

    func buildShell(id: String) -> SandboxShellAPI? {
        if let conn = server(for: id) { return conn.client }
        return localShells[id]
    }

    /// Shows an agent session (terminal chat) and its folder in the inspector.
    func selectRun(_ id: String) {
        guard let run = agents.run(id) else { return }
        agents.acknowledge(run)
        guard agents.selectedRunID != id else { return }
        if workspaceRoot != run.directory { gitSnapshot = GitSnapshot(); invalidateDefinition() }
        agents.selectedRunID = id
        selectedSessionID = nil
        selectedServerID = nil
        workspaceRevision += 1
        chatViewGeneration = UUID()
        chatIsLoading = false
        chatLoadFailure = nil
        chatRequests.invalidate()
    }

    /// Starts an agent in the sandbox and shows it.
    func startAgent(_ kind: AgentKind, directory: String, purpose: AgentRun.Purpose = .session) {
        let run = agents.start(kind: kind, directory: directory, purpose: purpose)
        selectRun(run.id)
        if let error = run.error { banner = error }
    }

    func select(_ session: SessionItem) {
        agents.selectedRunID = nil
        if let entry = servers[session.serverID]?.entry { recordSandboxUse(entry) }
        let selection = ChatSelection(serverID: session.serverID, sessionID: session.id)
        if chatSelection == selection {
            if !chatIsLoading { Task { await loadMessages(for: selection) } }
            return
        }
        if chatSelection == nil, !unscopedDraft.isEmpty {
            chatDrafts[selection] = (chatDrafts[selection] ?? "") + unscopedDraft
            unscopedDraft = ""
        }
        if workspaceRoot != session.directory { gitSnapshot = GitSnapshot(); invalidateDefinition() }
        selectedServerID = session.serverID
        selectedSessionID = session.id
        workspaceRevision += 1
        chatStore.select(selection)
        chatViewGeneration = UUID()
        chatIsLoading = true
        chatLoadFailure = nil
        chatRequests.invalidate()
        Task { await loadMessages(for: selection) }
    }

    func selectSandbox(_ serverID: String) {
        agents.selectedRunID = nil
        if let entry = servers[serverID]?.entry { recordSandboxUse(entry) }
        guard selectedServerID != serverID || selectedSessionID != nil else { return }
        if workspaceRoot != servers[serverID]?.entry.repoRoot { gitSnapshot = GitSnapshot(); invalidateDefinition() }
        selectedServerID = serverID
        selectedSessionID = nil
        workspaceRevision += 1
        chatViewGeneration = UUID()
        chatIsLoading = false
        chatLoadFailure = nil
        chatRequests.invalidate()
    }

    func newSession(on serverID: String, expectedGeneration: UUID? = nil) async {
        guard let conn = servers[serverID] else { return }
        let generation = expectedGeneration ?? chatViewGeneration
        do {
            let s = try await conn.client.createSession(title: nil)
            if let id = s["id"]?.string {
                // Apply the last explicit choices so new sessions start the way the user works.
                if let m = preferredModel, conn.models.contains(where: { $0.ref == m }) {
                    try? await conn.client.switchModel(sessionID: id, providerID: m.providerID, modelID: m.id)
                }
                if let a = preferredAgent, conn.agents.contains(where: { $0.id == a }) {
                    try? await conn.client.switchAgent(sessionID: id, agent: a)
                }
            }
            try await conn.reload()
            if chatViewGeneration == generation, servers[serverID] === conn,
               let id = s["id"]?.string, let item = conn.sessions[id] { select(item) }
        } catch { banner = error.localizedDescription }
    }

    func loadMessages(for expected: ChatSelection? = nil) async {
        guard let selection = chatSelection, expected == nil || expected == selection,
              let conn = servers[selection.serverID] else { return }
        let ticket = chatRequests.begin(selection)
        chatIsLoading = true
        defer { if servers[selection.serverID] === conn, chatRequests.accepts(ticket, current: chatSelection) { chatIsLoading = false } }
        do {
            let raw = try await conn.client.messages(sessionID: selection.sessionID)
            guard !Task.isCancelled, servers[selection.serverID] === conn, chatRequests.accepts(ticket, current: chatSelection) else { return }
            chatStore.load(Array(raw.reversed()), for: selection)
            chatLoadFailure = nil
        } catch {
            guard !Task.isCancelled, servers[selection.serverID] === conn, chatRequests.accepts(ticket, current: chatSelection) else { return }
            chatLoadFailure = Self.chatFailure(error)
        }
    }

    func send(_ text: String, to target: ChatSelection? = nil) async {
        guard let selection = target ?? chatSelection, let conn = servers[selection.serverID],
              conn.sessions[selection.sessionID] != nil else { return }
        let sid = selection.sessionID
        recordSandboxUse(conn.entry)
        if SlashCommands.parse(text) != nil, selection != chatSelection {
            setDraft(text, for: selection)
            banner = "Session gewechselt: Der Slash-Befehl wurde nicht ausgeführt und liegt wieder im Entwurf der ursprünglichen Session."
            return
        }
        if let cmd = SlashCommands.parse(text), await runSlash(cmd.name, cmd.arguments, sessionID: sid, conn: conn) {
            return
        }
        let messageID = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        chatStore.appendUser(id: messageID, text: text, to: selection)
        conn.beginRun(sid, submitting: true)
        defer { conn.finishSubmission(sid) }
        do { try await conn.client.prompt(sessionID: sid, text: text, messageID: messageID) }
        catch { conn.recordFailure(sid, Self.chatFailure(error)) }
    }

    private static func chatFailure(_ error: Error) -> ChatFailure {
        if case OpenCodeClient.ClientError.http(let status, let body) = error {
            return .http(status: status, body: body)
        }
        return ChatFailure(message: error.localizedDescription)
    }

    /// Shown as a sheet by the native /copilot-usage command.
    var copilotUsage: CopilotUsage?

    /// Same data as devkcode's copilot-usage TUI plugin: GitHub quota via the
    /// plugin's server RPC plus this month's per-model cost from OpenCode stats.
    func showCopilotUsage(_ conn: ServerConnection) async {
        var u = CopilotUsage()
        do {
            let q = try await conn.client.rpc("copilot-usage", "status")
            u.used = q["used"]?.double
            u.entitlement = q["entitlement"]?.double
            u.remaining = q["remaining"]?.double
            u.fraction = q["fraction"]?.double
            u.reset = q["reset"]?.string
            if case .bool(let b)? = q["overage"] { u.overage = b }
            u.githubError = q["error"]?.string
        } catch {
            u.githubError = error.localizedDescription
        }
        do {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let start = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
            let stats = try await conn.client.sessionStats(from: start)
            u.models = (stats["models"]?.array ?? []).compactMap { m in
                guard m["model"]?["providerID"]?.string == "github-copilot", let id = m["model"]?["id"]?.string else { return nil }
                let variant = m["model"]?["variant"]?.string
                return .init(name: variant.map { $0 == "default" ? id : "\(id) (\($0))" } ?? id,
                             cost: m["cost"]?.double ?? 0, steps: Int(m["steps"]?.double ?? 0))
            }.sorted { $0.cost > $1.cost }
        } catch {
            u.statsError = error.localizedDescription
        }
        copilotUsage = u
    }

    /// Suggestions for the "/" popup in the composer.
    func slashSuggestions(for draft: String) -> [SlashItem] {
        guard let conn = server(for: selectedServerID) else { return [] }
        return SlashCommands.suggestions(draft: draft, server: conn.commands, plugins: conn.pluginCommands,
                                         skills: conn.skills, models: conn.models, agents: conn.agents)
    }

    /// Handles a slash command. Returns false if it is unknown, so the text is sent as a normal prompt.
    private func runSlash(_ name: String, _ args: String, sessionID sid: String, conn: ServerConnection) async -> Bool {
        switch name.lowercased() {
        case "new":
            await newSession(on: conn.id)
        case "model":
            guard let m = conn.models.first(where: { $0.ref.key == args || $0.ref.id == args || $0.name.caseInsensitiveCompare(args) == .orderedSame }) else {
                banner = args.isEmpty ? "Modell angeben, z. B. /model claude-sonnet-5.5" : "Unbekanntes Modell: \(args)"
                return true
            }
            await switchModel(m.ref)
            toast("Modell: \(m.name)")
        case "agent":
            guard let a = conn.agents.first(where: { $0.id == args || $0.name.caseInsensitiveCompare(args) == .orderedSame }) else {
                banner = args.isEmpty ? "Agent angeben, z. B. /agent plan" : "Unbekannter Agent: \(args)"
                return true
            }
            await switchAgent(a.id)
            toast("Agent: \(a.name)")
        case "compact":
            do { try await conn.client.compact(sessionID: sid); toast("Verlauf wird zusammengefasst …") }
            catch { banner = error.localizedDescription }
        case "stop":
            await interrupt()
        case "rename":
            if let item = conn.sessions[sid], !args.isEmpty { await rename(item, to: args) }
        case "terminal":
            if let item = conn.sessions[sid] { openInTerminal(item) }
        case "help":
            let names = (SlashCommands.app.map(\.name) + conn.commands.map(\.name) + conn.pluginCommands.map(\.name)
                + conn.skills.map(\.slug)).map { "/" + $0 }
            banner = "Befehle: " + names.joined(separator: "  ")
        case _ where conn.skills.contains(where: { $0.slug == name.lowercased() }):
            let skill = conn.skills.first { $0.slug == name.lowercased() }!
            let text = args.isEmpty ? "Nutze den Skill „\(skill.name)“." : args
            let selection = ChatSelection(serverID: conn.id, sessionID: sid)
            let id = "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            chatStore.appendUser(id: id, text: "/\(skill.slug) \(args)", to: selection)
            conn.beginRun(sid, submitting: true)
            defer { conn.finishSubmission(sid) }
            do { try await conn.client.prompt(sessionID: sid, text: text, skills: [skill.id], messageID: id) }
            catch { conn.recordFailure(sid, Self.chatFailure(error)) }
        case "copilot-usage":
            await showCopilotUsage(conn)
        case _ where conn.pluginCommands.contains(where: { $0.name == name }):
            // TUI-only plugin command: continue in the terminal client, command is on the clipboard.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("/" + name, forType: .string)
            if let item = conn.sessions[sid] { openInTerminal(item) }
            toast("/\(name) läuft nur in der Terminal-Oberfläche – Befehl ist in der Zwischenablage")
        default:
            guard conn.commands.contains(where: { $0.name == name }) else { return false }
            conn.beginRun(sid, submitting: true)
            defer { conn.finishSubmission(sid) }
            do {
                try await conn.client.runCommand(sessionID: sid, name: name, arguments: args)
                await loadMessages(for: ChatSelection(serverID: conn.id, sessionID: sid))
            } catch { conn.recordFailure(sid, Self.chatFailure(error)) }
        }
        return true
    }

    func interrupt(for target: ChatSelection? = nil) async {
        guard let selection = target ?? chatSelection, let conn = servers[selection.serverID] else { return }
        let sid = selection.sessionID
        try? await conn.client.interrupt(sessionID: sid)
    }

    // MARK: Session management

    enum SessionAction { case stop, archive, delete }

    func perform(_ action: SessionAction, on item: SessionItem) async {
        guard let conn = servers[item.serverID] else { return }
        do {
            switch action {
            case .stop:
                try await conn.client.interrupt(sessionID: item.id)
            case .archive:
                try await conn.client.updateSession(item.id, archived: true)
            case .delete:
                if item.status == .running { try? await conn.client.interrupt(sessionID: item.id) }
                try await conn.client.deleteSession(item.id)
            }
            if action != .stop, selectedSessionID == item.id, selectedServerID == item.serverID {
                selectSandbox(item.serverID)
            }
            try await conn.reload()
        } catch { banner = error.localizedDescription }
    }

    // MARK: Questions, agent & model

    func reply(_ form: FormRequest, answers: [String: FormValue]) async {
        let owners = servers.values.filter { $0.forms[form.id]?.sessionID == form.sessionID }
        guard owners.count == 1, let conn = owners.first else { banner = "Diese Frage ist nicht mehr eindeutig einer laufenden Sandbox zugeordnet."; return }
        let visible = Set(form.visibleFields(answers).map(\.key))
        let answer = answers.filter { visible.contains($0.key) }.mapValues(\.any)
        do {
            try await conn.client.replyForm(sessionID: form.sessionID, formID: form.id, answer: answer)
            conn.forms[form.id] = nil
        } catch { banner = error.localizedDescription }
    }

    func cancel(_ form: FormRequest) async {
        let owners = servers.values.filter { $0.forms[form.id]?.sessionID == form.sessionID }
        guard owners.count == 1, let conn = owners.first else { banner = "Diese Frage ist nicht mehr aktuell."; return }
        do {
            try await conn.client.cancelForm(sessionID: form.sessionID, formID: form.id)
            conn.forms[form.id] = nil
        } catch { banner = error.localizedDescription }
    }

    func switchAgent(_ agent: String, for target: ChatSelection? = nil) async {
        guard let selection = target ?? chatSelection, let conn = servers[selection.serverID] else { return }
        let sid = selection.sessionID
        do {
            try await conn.client.switchAgent(sessionID: sid, agent: agent)
            conn.sessions[sid]?.agent = agent
            preferredAgent = agent
        } catch { banner = error.localizedDescription }
    }

    func switchModel(_ model: ModelRef, for target: ChatSelection? = nil) async {
        guard let selection = target ?? chatSelection, let conn = servers[selection.serverID] else { return }
        let sid = selection.sessionID
        await conn.refreshModels()
        guard servers[selection.serverID] === conn, conn.sessions[sid] != nil else { return }
        guard conn.models.contains(where: { $0.ref == model }) else {
            banner = conn.modelsError ?? "Für dieses Modell liegt keine bestätigte Freigabe vor. Bitte die Modellliste aktualisieren."
            return
        }
        do {
            try await conn.client.switchModel(sessionID: sid, providerID: model.providerID, modelID: model.id)
            conn.sessions[sid]?.model = model
            preferredModel = model
        } catch { banner = error.localizedDescription }
    }

    /// Continues the session in the classic TUI via `devkcode run --session <id>`.
    func openInTerminal(_ item: SessionItem, app: TerminalLauncher.App? = nil) {
        guard let cli else { banner = "devkcode wurde nicht gefunden"; return }
        let entry = servers[item.serverID]?.entry
        let target = app ?? TerminalLauncher.preferred
        let command = TerminalLauncher.command(
            devkcode: cli.executable.path, directory: entry?.repoRoot ?? item.directory,
            profile: entry?.profileName, project: entry?.projectName, sessionID: item.id)
        banner = "Öffne Session in \(target.rawValue) …"
        Task {
            if let error = await TerminalLauncher.launch(target, command: command) {
                banner = "\(target.rawValue) konnte nicht geöffnet werden: \(error)"
            } else {
                banner = nil
            }
        }
    }

    func rename(_ item: SessionItem, to title: String) async {        guard let conn = servers[item.serverID], !title.isEmpty else { return }
        do {
            try await conn.client.updateSession(item.id, title: title)
            try await conn.reload()
        } catch { banner = error.localizedDescription }
    }

    func reply(_ permission: PermissionRequest, decision: String) async {
        let owners = servers.values.filter { $0.permissions[permission.id]?.sessionID == permission.sessionID }
        guard owners.count == 1, let conn = owners.first else { banner = "Diese Freigabe ist nicht mehr aktuell oder nicht eindeutig zugeordnet."; return }
        do {
            try await conn.client.replyPermission(sessionID: permission.sessionID,
                                                  requestID: permission.id, decision: decision)
            conn.permissions[permission.id] = nil
        } catch { banner = error.localizedDescription }
    }

    private func handleChatEvent(serverID: String, type: String, event: JSON) {
        let dirty = ["session.tool.success", "session.tool.failed", "session.tool.ended", "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"].contains(type)
        if dirty, let connection = servers[serverID] {
            let sid = event["data"]?["sessionID"]?.string
            let root = sid.flatMap { connection.sessions[$0]?.directory }
                ?? event["location"]?["directory"]?.string ?? connection.entry.repoRoot
            let workspace = workspaceRoot
            let overlaps = workspace.map { $0 == root || $0.hasPrefix(root + "/") || root.hasPrefix($0 + "/") } ?? false
            let visibleFile = editorGroups.values.compactMap(\.file).contains { EditorPresentation.relativePath($0, root: root) != nil }
            if overlaps || visibleFile { workspaceRevision += 1 }
        }
        guard let sid = event["data"]?["sessionID"]?.string,
              servers[serverID]?.sessions[sid] != nil else { return }
        let selection = ChatSelection(serverID: serverID, sessionID: sid)
        let data = event["data"] ?? .null
        let selected = selection == chatSelection
        if type.hasPrefix("session.text.") { chatStore.consume(type, data: data, for: selection) }
        if type == "session.message.content.updated" {
            chatStore.discardStream(for: selection, messageID: data["messageID"]?.string)
        }
        if !selected {
            if ["session.step.ended", "session.step.failed", "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"].contains(type) {
                chatStore.finishBackground(for: selection, messageID: data["assistantMessageID"]?.string)
            }
            return
        }
        switch type {
        case "session.text.ended", "session.agent.selected", "session.model.selected":
            if type != "session.text.ended" { workspaceRevision += 1 }
            Task { await loadMessages(for: selection) }
        case "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted", "session.error":
            Task { await loadMessages(for: selection) }
        case "session.step.ended", "session.step.failed", "session.message.content.updated":
            Task { await loadMessages(for: selection) }
        case _ where type.hasPrefix("session.tool."):
            if type.hasSuffix(".ended") || type.hasSuffix(".started") || type.hasSuffix(".failed") || type.hasSuffix(".success") || type.hasSuffix(".called") {
                Task { await loadMessages(for: selection) }
            }
        default:
            break
        }
    }
}

extension String {
    func lastNonEmptyLines(_ n: Int) -> String {
        split(separator: "\n").suffix(n).joined(separator: "\n")
    }
}

/// Tabs and navigation state of one editor (Preview pane).
@Observable
final class EditorGroup {
    var tabs: [URL] = [] { didSet { UIStateStore.save(tabs.map(\.path), as: .openTabs) } }
    var file: URL? { didSet { UIStateStore.save(file?.path, as: .previewFile) } }
    var mode: AppModel.PreviewMode = .file { didSet { UIStateStore.save(mode.rawValue, as: .previewMode) } }
    var line: Int?
    var back: [AppModel.PreviewLocation] = []
    var forward: [AppModel.PreviewLocation] = []

    func remove(_ url: URL) {
        guard let i = tabs.firstIndex(of: url) else { return }
        tabs.remove(at: i)
        if file == url {
            file = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)]
            line = nil
        }
    }
}
