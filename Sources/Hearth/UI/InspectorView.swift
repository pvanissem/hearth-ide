import SwiftUI
import UniformTypeIdentifiers

/// The whole window content: one tree of movable, resizable panes.
struct WorkspaceLayoutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let id = model.maximizedPane, let pane = model.paneTree.pane(id) {
                PaneView(pane: pane)
            } else {
                PaneTreeView(node: model.paneTree)
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.maximizedPane)
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { PaneSizes.shared.root = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in PaneSizes.shared.root = f }
            }
        }
        .overlay { windowEdgeHighlight }
        .task(id: "\(model.workspaceRoot ?? "")#\(model.workspaceRevision)") {
            guard let root = model.workspaceRoot else { model.gitSnapshot = GitSnapshot(); return }
            let revision = model.workspaceRevision
            let snapshot = await Git.snapshot(of: root)
            guard !Task.isCancelled, model.workspaceRoot == root, model.workspaceRevision == revision else { return }
            model.gitSnapshot = snapshot
        }
    }
}

extension WorkspaceLayoutView {
    /// Strip along the whole window edge while a pane is dragged there.
    @ViewBuilder
    var windowEdgeHighlight: some View {
        if let zone = model.windowDropZone {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let r: CGRect = switch zone {
                case .windowLeft: CGRect(x: 0, y: 0, width: w * 0.3, height: h)
                case .windowRight: CGRect(x: w * 0.7, y: 0, width: w * 0.3, height: h)
                case .windowTop: CGRect(x: 0, y: 0, width: w, height: h * 0.3)
                default: CGRect(x: 0, y: h * 0.7, width: w, height: h * 0.3)
                }
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2))
                    .overlay {
                        Label(zone == .windowBottom || zone == .windowTop ? "Über die ganze Breite" : "Über die ganze Höhe",
                              systemImage: "rectangle.bottomthird.inset.filled")
                            .font(.callout.bold()).foregroundStyle(Color.accentColor)
                    }
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
            }
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.1), value: zone)
        }
    }
}

/// Renders the split tree recursively with resizable dividers.
struct PaneTreeView: View {
    let node: PaneNode

    var body: some View {
        switch node {
        case .leaf(let pane):
            PaneView(pane: pane)
        case .split(let id, let axis, let children):
            SplitStack(id: id, axis: axis, count: children.count) { i in
                AnyView(PaneTreeView(node: children[i]))
            }
        }
    }
}

private let paneDragPrefix = "hearth-pane:"

struct PaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let pane: InspectorPane
    private let dropZone = State(initialValue: AppModel.DropZone?.none)

    private var zoomArea: TextArea { .pane(pane.id, pane.tab) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .zoomableText(zoomArea, model: model)
        }
        .overlay { dropHighlight }
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { PaneSizes.shared[pane.id] = g.frame(in: .global) }
                    .onChange(of: g.frame(in: .global)) { _, f in PaneSizes.shared[pane.id] = f }
            }
        }
        .onDrop(of: [.plainText], delegate: PaneDropDelegate(target: pane.id, zone: dropZone, model: model))
    }

    // MARK: Header (drag handle)

    private var header: some View {
        let maximized = model.maximizedPane == pane.id
        return HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                .help("Ziehen, um den Bereich zu verschieben")
            Menu {
                ForEach(InspectorTab.allCases) { tab in
                    Button { model.setTab(tab, for: pane.id) } label: { Label(tab.title, systemImage: tab.symbol) }
                }
            } label: {
                Label(pane.tab.title, systemImage: pane.tab.symbol).scaledFont(.caption, bold: true)
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            Menu {
                Button { model.zoom(zoomArea, by: 1.1) } label: { Label("Größer", systemImage: "plus.magnifyingglass") }
                Button { model.zoom(zoomArea, by: 1 / 1.1) } label: { Label("Kleiner", systemImage: "minus.magnifyingglass") }
                Divider()
                Button("Zurücksetzen (\(Int((model.textScale(zoomArea.base) * 100).rounded())) %)") { model.resetZoom(zoomArea) }
            } label: {
                let percent = Int((model.textScale(zoomArea) * 100).rounded())
                if percent == 100 { Image(systemName: "textformat.size") } else { Text("\(percent) %").font(.caption2.monospacedDigit()) }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.secondary)
            .help("Schriftgröße dieses Bereichs (auch ⌘-Scrollen oder Zwei-Finger-Zoom über dem Bereich)")
            // Layout actions only make sense for panes in the main window's tree.
            if model.paneTree.pane(pane.id) != nil {
                Button { model.split(pane.id, axis: .horizontal) } label: { Image(systemName: "rectangle.split.2x1") }
                    .help("Rechts teilen")
                Button { model.split(pane.id, axis: .vertical) } label: { Image(systemName: "rectangle.split.1x2") }
                    .help("Unten teilen")
                Button { model.toggleMaximize(pane.id) } label: {
                    Image(systemName: maximized ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(maximized ? "Wiederherstellen (Doppelklick auf die Kopfzeile)" : "Maximieren (Doppelklick auf die Kopfzeile)")
                Button {
                    if let tab = model.detach(pane.id) { openWindow(value: tab) }
                } label: { Image(systemName: "macwindow.on.rectangle") }
                    .help("In eigenem Fenster öffnen")
                if model.paneTree.panes.count > 1 {
                    Button { model.closePane(pane.id) } label: { Image(systemName: "xmark") }
                        .help("Bereich schließen")
                }
            }
        }
        .buttonStyle(.borderless)
        .scaledFont(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.toggleMaximize(pane.id) }
        .onDrag {
            model.draggingTab = nil
            return NSItemProvider(object: (paneDragPrefix + pane.id.uuidString) as NSString)
        } preview: {
            Label(pane.tab.title, systemImage: pane.tab.symbol)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }
    }

    // MARK: Drop target preview

    @ViewBuilder
    private var dropHighlight: some View {
        if let zone = dropZone.wrappedValue, !zone.isWindowEdge {
            GeometryReader { geo in
                let r = Self.rect(for: zone, in: geo.size)
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2))
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .overlay {
                        if zone == .center {
                            Label("Tauschen", systemImage: "arrow.left.arrow.right").font(.callout.bold())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
            }
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.1), value: zone)
        }
    }

    static func rect(for zone: AppModel.DropZone, in size: CGSize) -> CGRect {
        let w = size.width, h = size.height
        switch zone {
        case .left: return CGRect(x: 0, y: 0, width: w / 2, height: h)
        case .right: return CGRect(x: w / 2, y: 0, width: w / 2, height: h)
        case .top: return CGRect(x: 0, y: 0, width: w, height: h / 2)
        case .bottom: return CGRect(x: 0, y: h / 2, width: w, height: h / 2)
        case .center: return CGRect(x: w * 0.2, y: h * 0.2, width: w * 0.6, height: h * 0.6)
        default: return .zero
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch pane.tab {
        case .sessions: InboxView()
        case .chat: ChatView()
        case .terminal: TerminalPaneView(root: model.workspaceRoot)
        default:
            if let root = model.workspaceRoot {
                workspaceContent(root)
            } else {
                ContentUnavailableView("Kein Workspace", systemImage: "folder",
                                       description: Text("Wähle eine Session oder Sandbox."))
            }
        }
    }

    @ViewBuilder
    private func workspaceContent(_ root: String) -> some View {
        switch pane.tab {
        case .directory: DirectoryView(root: root, markers: model.gitSnapshot.markers)
        case .git: GitView(root: root, snapshot: model.gitSnapshot)
        case .preview:
            PreviewView(root: root, paneID: pane.id)
                .simultaneousGesture(TapGesture().onEnded { model.activeEditorID = pane.id })
        case .pipelines: PipelinesView(root: root)
        case .tests: TestsView(root: root)
        case .architecture: ArchitectureView(root: root)
        case .build: BuildDeployView(root: root)
        case .sessions, .chat, .terminal: EmptyView()
        }
    }
}

/// Decides left/right/top/bottom/center from the pointer position (outer 30 % = edge, middle = swap).
private struct PaneDropDelegate: DropDelegate {
    let target: UUID
    let zone: State<AppModel.DropZone?>
    let model: AppModel

    /// Outer 30 % of a pane = dock beside it, middle = swap. Within 32 pt of a pane side that is
    /// also the window border, dock along the whole window edge instead.
    private func zoneFor(_ info: DropInfo, frame: CGRect?) -> AppModel.DropZone {
        guard let frame, frame.width > 0, frame.height > 0 else { return .center }
        let p = info.location
        let edgeBand: CGFloat = 32
        if let root = PaneSizes.shared.root {
            let touches: [(AppModel.DropZone, Bool, CGFloat)] = [
                (.windowLeft, abs(frame.minX - root.minX) < 3, p.x),
                (.windowRight, abs(frame.maxX - root.maxX) < 3, frame.width - p.x),
                (.windowTop, abs(frame.minY - root.minY) < 3, p.y),
                (.windowBottom, abs(frame.maxY - root.maxY) < 3, frame.height - p.y),
            ]
            if let hit = touches.filter({ $0.1 && $0.2 < edgeBand }).min(by: { $0.2 < $1.2 }) { return hit.0 }
        }
        let x = p.x / frame.width, y = p.y / frame.height
        let edges: [(AppModel.DropZone, Double)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        let nearest = edges.min { $0.1 < $1.1 }!
        return nearest.1 < 0.3 ? nearest.0 : .center
    }

    func validateDrop(info: DropInfo) -> Bool { model.draggingTab == nil && info.hasItemsConforming(to: [.plainText]) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard model.draggingTab == nil else { return DropProposal(operation: .forbidden) }
        let z = zoneFor(info, frame: PaneSizes.shared[target])
        zone.wrappedValue = z
        model.windowDropZone = z.isWindowEdge ? z : nil
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        zone.wrappedValue = nil
        model.windowDropZone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let z = zoneFor(info, frame: PaneSizes.shared[target])
        zone.wrappedValue = nil
        model.windowDropZone = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, s.hasPrefix(paneDragPrefix),
                  let source = UUID(uuidString: String(s.dropFirst(paneDragPrefix.count))) else { return }
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.2)) { model.movePane(source, onto: target, zone: z) }
            }
        }
        return true
    }
}

/// Last known frame of each pane in global coordinates (DropInfo only carries a location).
@MainActor
final class PaneSizes {
    static let shared = PaneSizes()
    private var frames: [UUID: CGRect] = [:]
    /// Frame of the whole layout (window content) in global coordinates.
    var root: CGRect?
    subscript(id: UUID) -> CGRect? {
        get { frames[id] }
        set { frames[id] = newValue }
    }
}

// MARK: Directory

struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }

    static let hidden: Set<String> = [".git", ".DS_Store", ".build", "node_modules", ".idea", ".swiftpm"]

    func children(revealing file: URL? = nil) -> [FileNode] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        return urls
            .filter { !Self.hidden.contains($0.lastPathComponent) || file?.path.hasPrefix($0.path + "/") == true || file?.path == $0.path }
            .map { FileNode(url: $0, isDirectory: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) }
            .sorted { ($0.isDirectory ? 0 : 1, $0.name.lowercased()) < ($1.isDirectory ? 0 : 1, $1.name.lowercased()) }
    }
}

struct DirectoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale
    let root: String
    let markers: [String: String]
    private let query = State(initialValue: "")
    private let results = State(initialValue: [FileSearch.Match]())
    private let searching = State(initialValue: false)

    var body: some View {
        let _ = model.workspaceRevision
        VStack(spacing: 0) {
            HStack {
                Text(URL(fileURLWithPath: root).lastPathComponent).scaledFont(.caption, bold: true).lineLimit(1)
                Spacer()
                Button { model.revealEditorFile(in: root) } label: { Image(systemName: "scope") }
                    .buttonStyle(.borderless).help("Aktive Editor-Datei im Directory zeigen und markieren")
                    .disabled(model.previewFile == nil)
                Menu {
                    DirectoryCreateMenu(directory: URL(fileURLWithPath: root), root: root)
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Datei oder Ordner im Workspace anlegen")
                Button { model.workspaceRevision += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Verzeichnis aktualisieren")
            }
            .padding(.horizontal, 8).padding(.top, 6)
            .modifier(WorkspaceFileDrop(directory: URL(fileURLWithPath: root), root: root, model: model))
            SearchField(text: query.projectedValue, prompt: "Dateien suchen …")
            Divider()
            if query.wrappedValue.count >= 2 {
                tree(matches: results.wrappedValue)
                .overlay(alignment: .topLeading) {
                    if results.wrappedValue.isEmpty && !searching.wrappedValue {
                        Text("Keine Treffer").foregroundStyle(.secondary).padding(8).allowsHitTesting(false)
                    }
                }
                .busyOverlay(searching.wrappedValue && results.wrappedValue.isEmpty, label: "Suche …")
                .task(id: "\(root)#\(query.wrappedValue)#\(model.workspaceRevision)") {
                    try? await Task.sleep(for: .milliseconds(150))
                    if Task.isCancelled { return }
                    searching.wrappedValue = true
                    let found = await FileSearch.find(query.wrappedValue, in: root)
                    guard !Task.isCancelled else { return }
                    results.wrappedValue = found
                    searching.wrappedValue = false
                }
            } else {
                tree()
            }
        }
        .onChange(of: model.directoryRevealID) { query.wrappedValue = "" }
    }

    private func tree(matches: [FileSearch.Match]? = nil) -> some View {
        NativeDirectoryTree(root: root, markers: markers, expandedPaths: model.directoryExpandedPaths,
            selectedFile: model.directorySelectedFile ?? model.previewFile, revealID: model.directoryRevealID,
            revision: model.workspaceRevision, scale: scale, dragToken: model.directoryDragToken, matches: matches,
            select: { file in
                model.directorySelectedFile = file.url
                if !file.isDirectory { model.openPreview(file.url) }
                else if matches != nil {
                    model.directoryExpandedPaths.insert(file.url.path)
                    model.revealEditorFile(file.url, in: root)
                }
            }, expand: { url, expanded in
                if expanded { model.directoryExpandedPaths.insert(url.path) }
                else { model.directoryExpandedPaths.remove(url.path) }
            }, move: { source, destination in
                let oldSelection = model.directorySelectedFile
                model.directorySelectedFile = source
                let moved = model.moveWorkspaceItem(source, into: destination, root: root)
                if !moved { model.directorySelectedFile = oldSelection }
                return moved
            }, menu: { file in model.directoryMenu(for: file, root: root, markers: markers) })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
        }
        .padding(6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
        .padding(6)
    }
}

enum FileIcon {
    static func symbol(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift", "go", "java", "kt", "js", "ts", "tsx", "jsx", "py", "rb", "rs", "c", "h", "cpp", "sh":
            "chevron.left.forwardslash.chevron.right"
        case "md", "markdown", "txt": "doc.text"
        case "json", "yaml", "yml", "toml", "xml", "plist": "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "heic": "photo"
        case "pdf": "doc.richtext"
        default: "doc"
        }
    }
}

/// Case-insensitive search over file paths below a root; skips heavy folders.
enum FileSearch {
    struct Match: Identifiable, Hashable, Sendable {
        let relativePath: String
        let isDirectory: Bool
        var id: String { relativePath }
        var name: String { (relativePath as NSString).lastPathComponent }
    }

    static let limit = 300
    static let skipped: Set<String> = FileNode.hidden.union(["target", "dist", "build", "vendor", ".gradle", ".venv"])

    static func find(_ query: String, in root: String) async -> [Match] {
        await Task.detached(priority: .userInitiated) {
            let terms = query.lowercased().split(separator: " ").map(String.init)
            let rootURL = URL(fileURLWithPath: root)
            guard let it = FileManager.default.enumerator(
                at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
            var nameHits: [Match] = []
            var pathHits: [Match] = []
            while let url = it.nextObject() as? URL {
                if Task.isCancelled || nameHits.count >= limit { break }
                let name = url.lastPathComponent
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if skipped.contains(name) {
                    if isDir { it.skipDescendants() }
                    continue
                }
                let rel = String(url.path.dropFirst(rootURL.path.count + 1))
                let lowerRel = rel.lowercased()
                guard terms.allSatisfy(lowerRel.contains) else { continue }
                let match = Match(relativePath: rel, isDirectory: isDir)
                // Rank hits in the file name above hits only in the path.
                if terms.allSatisfy(name.lowercased().contains) { nameHits.append(match) } else { pathHits.append(match) }
            }
            return Array((nameHits + pathHits).prefix(limit))
        }.value
    }
}

// MARK: Git

struct GitView: View {
    @Environment(AppModel.self) private var model
    let root: String
    let snapshot: GitSnapshot

    private let branches = State(initialValue: [Git.Branch]())
    private let branchFilter = State(initialValue: "")
    private let showRemote = State(initialValue: false)
    private let busy = State(initialValue: String?.none)
    private let pendingCheckout = State(initialValue: Git.Branch?.none)
    private let pendingDelete = State(initialValue: Git.Branch?.none)
    private let pendingDiscard = State(initialValue: GitFileChange?.none)
    private let newBranchBase = State(initialValue: String?.none)
    private let newBranchName = State(initialValue: "")
    private let shownCommit = State(initialValue: String?.none)
    private let collapsed = State(initialValue: Set<String>())

    static func color(for marker: String) -> Color {
        switch marker {
        case "M": .orange
        case "A", "U": .green
        case "D": .red
        case "R": .blue
        default: .secondary
        }
    }

    var body: some View {
        if !snapshot.isRepo {
            ContentUnavailableView("Kein Git-Repository", systemImage: "arrow.triangle.branch")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    headerCard
                    section("Änderungen", count: snapshot.changes.count) { changesList }
                    section("Branches", count: visibleBranches.count) { branchList }
                    section("Letzte Commits", count: snapshot.recentCommits.count) { commitList }
                }
                .padding(8)
            }
            .busyOverlay(busy.wrappedValue != nil, label: busy.wrappedValue)
            .task(id: "\(root)#\(model.workspaceRevision)") { await reloadBranches() }
            .confirmationDialog(checkoutTitle, isPresented: isPresent(pendingCheckout), presenting: pendingCheckout.wrappedValue) { b in
                Button("Wechseln") { Task { await run("Wechsle zu \(b.localName) …") { await Git.checkout(b, in: root) } } }
            } message: { _ in
                Text(snapshot.changes.isEmpty
                     ? "Der Agent arbeitet danach auf diesem Branch."
                     : "Es gibt \(snapshot.changes.count) nicht committete Änderungen. Git übernimmt sie, sofern keine Konflikte entstehen – sonst bricht der Wechsel ab.")
            }
            .confirmationDialog("Branch „\(pendingDelete.wrappedValue?.name ?? "")“ löschen?",
                                isPresented: isPresent(pendingDelete), presenting: pendingDelete.wrappedValue) { b in
                Button("Löschen", role: .destructive) {
                    Task { await run("Lösche \(b.name) …") { await Git.mutate(["branch", "-d", b.name], in: root) } }
                }
            } message: { _ in Text("Nur möglich, wenn der Branch gemergt ist (git branch -d).") }
            .confirmationDialog("Änderungen an „\(pendingDiscard.wrappedValue?.path ?? "")“ verwerfen?",
                                isPresented: isPresent(pendingDiscard), presenting: pendingDiscard.wrappedValue) { c in
                Button("Verwerfen", role: .destructive) { Task { await discard(c) } }
            } message: { _ in Text("Das lässt sich nicht rückgängig machen.") }
            .alert("Neuer Branch", isPresented: Binding(get: { newBranchBase.wrappedValue != nil },
                                                        set: { if !$0 { newBranchBase.wrappedValue = nil } })) {
                TextField("feature/…", text: newBranchName.projectedValue)
                Button("Anlegen & wechseln") {
                    let base = newBranchBase.wrappedValue ?? "HEAD"
                    let name = newBranchName.wrappedValue.trimmingCharacters(in: .whitespaces)
                    Task { await run("Lege \(name) an …") { await Git.mutate(["switch", "-c", name, base], in: root) } }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Basis: \(newBranchBase.wrappedValue ?? "")")
            }
        }
    }

    // MARK: Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.accentColor)
                Text(snapshot.branch).scaledFont(.body, bold: true, mono: true).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button { startNewBranch(from: snapshot.branch) } label: { Image(systemName: "plus") }
                    .help("Neuer Branch vom aktuellen Stand")
            }
            if let up = snapshot.upstream {
                HStack(spacing: 8) {
                    Label("\(snapshot.ahead)", systemImage: "arrow.up").foregroundStyle(snapshot.ahead > 0 ? .primary : .secondary)
                    Label("\(snapshot.behind)", systemImage: "arrow.down").foregroundStyle(snapshot.behind > 0 ? .orange : .secondary)
                    Text(up).foregroundStyle(.secondary).lineLimit(1)
                }
                .scaledFont(.caption)
            } else {
                Text("Kein Upstream").scaledFont(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button { Task { await run("Fetch in Sandbox …") { await model.networkGit(.fetch, in: root) } } } label: {
                    Label("Fetch", systemImage: "arrow.triangle.2.circlepath")
                }
                Button { Task { await run("Pull in Sandbox …") { await model.networkGit(.pull, in: root) } } } label: {
                    Label("Pull", systemImage: "arrow.down.circle")
                }
                .disabled(snapshot.upstream == nil)
            }
            .controlSize(.small)
        }
        .buttonStyle(.bordered)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, count: Int, @ViewBuilder content: () -> Content) -> some View {
        let isCollapsed = collapsed.wrappedValue.contains(title)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                Text(title).scaledFont(.caption, bold: true)
                Text("\(count)").scaledFont(.caption2, digits: true)
                    .padding(.horizontal, 5).background(Color.primary.opacity(0.08), in: Capsule())
                Spacer()
            }
            .foregroundStyle(.secondary)
            .interactiveRow {
                withAnimation(.easeOut(duration: 0.15)) {
                    if isCollapsed { collapsed.wrappedValue.remove(title) } else { collapsed.wrappedValue.insert(title) }
                }
            }
            if !isCollapsed { content() }
        }
    }

    @ViewBuilder
    private var changesList: some View {
        if snapshot.changes.isEmpty {
            Label("Working tree sauber", systemImage: "checkmark.circle").scaledFont(.callout).foregroundStyle(.secondary)
                .padding(.leading, 6)
        }
        ForEach(snapshot.changes) { change in
            let url = URL(fileURLWithPath: root).appendingPathComponent(change.path)
            HStack(spacing: 6) {
                Text(change.marker).scaledFont(.callout, bold: true, mono: true)
                    .foregroundStyle(Self.color(for: change.marker)).frame(width: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(url.lastPathComponent).lineLimit(1)
                    Text((change.path as NSString).deletingLastPathComponent).scaledFont(.caption2)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                Spacer()
                if change.added + change.removed > 0 {
                    Text("+\(change.added)").foregroundStyle(.green).scaledFont(.caption, digits: true)
                    Text("-\(change.removed)").foregroundStyle(.red).scaledFont(.caption, digits: true)
                }
            }
            .interactiveRow(selected: model.previewFile == url && model.previewMode == .diff) {
                model.openPreview(url, mode: .diff)
            }
            .help("Klicken für Diff")
            .contextMenu {
                FileContextMenu(url: url, changed: true)
                Divider()
                Button(role: .destructive) { pendingDiscard.wrappedValue = change } label: {
                    Label("Änderungen verwerfen …", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    private var visibleBranches: [Git.Branch] {
        let filter = branchFilter.wrappedValue.lowercased()
        return branches.wrappedValue.filter {
            $0.isRemote == showRemote.wrappedValue && (filter.isEmpty || $0.name.lowercased().contains(filter))
        }
    }

    @ViewBuilder
    private var branchList: some View {
        HStack(spacing: 4) {
            Picker("", selection: showRemote.projectedValue) {
                Text("Lokal").tag(false)
                Text("Remote").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            SearchField(text: branchFilter.projectedValue, prompt: "Filter")
        }
        ForEach(visibleBranches) { b in
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: b.isCurrent ? "checkmark.circle.fill" : (b.isRemote ? "cloud" : "arrow.triangle.branch"))
                    .foregroundStyle(b.isCurrent ? Color.green : .secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(b.name).scaledFont(.callout, mono: true).fontWeight(b.isCurrent ? .bold : .regular).lineLimit(1)
                        if let track = b.track {
                            Text(track).scaledFont(.caption2).foregroundStyle(.orange)
                        }
                    }
                    Text("\(b.date) · \(b.subject)").scaledFont(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .interactiveRow(selected: b.isCurrent) {
                if !b.isCurrent { pendingCheckout.wrappedValue = b }
            }
            .help(b.isCurrent ? "Aktueller Branch" : "Klicken zum Auschecken")
            .contextMenu {
                if !b.isCurrent {
                    Button { pendingCheckout.wrappedValue = b } label: { Label("Auschecken", systemImage: "arrow.right.circle") }
                }
                Button { startNewBranch(from: b.name) } label: { Label("Neuer Branch von hier …", systemImage: "plus") }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(b.name, forType: .string)
                    model.toast("Branch-Name kopiert")
                } label: { Label("Name kopieren", systemImage: "doc.on.doc") }
                if !b.isRemote && !b.isCurrent {
                    Divider()
                    Button(role: .destructive) { pendingDelete.wrappedValue = b } label: { Label("Löschen …", systemImage: "trash") }
                }
            }
        }
    }

    @ViewBuilder
    private var commitList: some View {
        ForEach(snapshot.recentCommits, id: \.self) { line in
            let hash = String(line.prefix { $0 != " " })
            HStack(spacing: 6) {
                Text(hash).scaledFont(.caption, mono: true).foregroundStyle(Color.accentColor)
                Text(line.dropFirst(hash.count + 1)).scaledFont(.caption).lineLimit(1)
                Spacer()
            }
            .interactiveRow(selected: shownCommit.wrappedValue == hash) { shownCommit.wrappedValue = hash }
            .popover(isPresented: Binding(get: { shownCommit.wrappedValue == hash },
                                          set: { if !$0 { shownCommit.wrappedValue = nil } }), arrowEdge: .leading) {
                CommitDetail(hash: hash, root: root).frame(width: 560, height: 420)
            }
        }
    }

    // MARK: Actions

    private var checkoutTitle: String {
        "Zu „\(pendingCheckout.wrappedValue?.localName ?? "")“ wechseln?"
    }

    private func isPresent<T>(_ state: State<T?>) -> Binding<Bool> {
        Binding(get: { state.wrappedValue != nil }, set: { if !$0 { state.wrappedValue = nil } })
    }

    private func startNewBranch(from base: String) {
        newBranchName.wrappedValue = ""
        newBranchBase.wrappedValue = base
    }

    private func reloadBranches() async {
        branches.wrappedValue = await Git.branches(in: root)
    }

    private func run(_ label: String, _ op: () async -> Git.OpResult) async {
        busy.wrappedValue = label
        let result = await op()
        busy.wrappedValue = nil
        if result.ok {
            model.toast(result.output.lastNonEmptyLines(1).isEmpty ? "Erledigt" : result.output.lastNonEmptyLines(1))
        } else {
            model.banner = "Git: " + result.output.lastNonEmptyLines(4)
        }
        model.workspaceRevision += 1
        await reloadBranches()
    }

    private func discard(_ change: GitFileChange) async {
        await run("Verwerfe \(change.path) …") {
            if change.code == "??" { return await Git.mutate(["clean", "-f", "--", change.path], in: root) }
            return await Git.mutate(["restore", "--staged", "--worktree", "--source=HEAD", "--", change.path], in: root)
        }
    }
}

struct CommitDetail: View {
    let hash: String
    let root: String
    private let text = State(initialValue: String?.none)

    var body: some View {
        Group {
            if let t = text.wrappedValue {
                CodeText(text: t, diff: true)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { text.wrappedValue = await Git.show(commit: hash, in: root) }
    }
}

/// A pane shown in its own window (e.g. on a second screen).
struct DetachedPaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    let tab: InspectorTab

    var body: some View {
        // Reuse the normal pane (header, zoom, content) with a stable id per tab.
        PaneView(pane: InspectorPane(id: Self.id(for: tab), tab: tab))
            .navigationTitle("Hearth IDE – \(tab.title)")
            .toolbar {
                ToolbarItem {
                    Button {
                        model.dock(tab)
                        dismissWindow(value: tab)
                    } label: { Label("Wieder andocken", systemImage: "rectangle.portrait.and.arrow.forward") }
                        .help("Zurück ins Hauptfenster")
                }
            }
            .background(WindowAutosave(name: "HearthPane-\(tab.rawValue)"))
            .onAppear { model.detachedTabs.insert(tab) }
            .onDisappear {
                // Closing during quit keeps the window in the list so it reopens next launch.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if !model.quitting { model.detachedTabs.remove(tab) }
                }
            }
    }

    /// Deterministic id so the pane keeps its state while the window is open.
    static func id(for tab: InspectorTab) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in tab.rawValue.utf8.enumerated() { bytes[i % 16] ^= b }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
