import SwiftUI
import AppKit

/// The file currently shown in the preview, with edit state.
@MainActor
@Observable
final class PreviewDocument {
    enum Kind: Equatable { case text, markdown, image, binary, tooLarge, missing }

    let url: URL
    var kind: Kind = .text
    var text = ""
    var savedText = ""
    var image: NSImage?
    var diskDate: Date?
    var changedOnDisk = false
    let language: SyntaxLanguage

    var isDirty: Bool { kind == .text || kind == .markdown ? !text.isLiterallyEqual(to: savedText) : false }
    var isEditableKind: Bool { kind == .text || kind == .markdown }

    static let maxBytes = 2_000_000
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp", "ico", "svg"]

    init(url: URL) {
        self.url = url
        self.language = SyntaxLanguage.detect(url)
        load()
    }

    private static func modDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func load() {
        changedOnDisk = false
        diskDate = Self.modDate(url)
        guard FileManager.default.fileExists(atPath: url.path) else { kind = .missing; return }
        let ext = url.pathExtension.lowercased()
        if Self.imageExtensions.contains(ext), let img = NSImage(contentsOf: url) {
            image = img
            kind = .image
            return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxBytes else { kind = .tooLarge; return }
        guard let data = try? Data(contentsOf: url), let s = String(data: data, encoding: .utf8) else { kind = .binary; return }
        text = s
        savedText = s
        kind = language == .markdown ? .markdown : .text
    }

    /// Called when the workspace may have changed: reload silently unless the user has unsaved edits.
    func checkDisk() {
        let date = Self.modDate(url)
        guard date != diskDate else { return }
        if isDirty { changedOnDisk = true } else { load() }
    }

    enum SaveResult { case saved, conflict, failed(String) }

    func save(force: Bool = false) -> SaveResult {
        if !force, let d = Self.modDate(url), let known = diskDate, d > known { return .conflict }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            diskDate = Self.modDate(url)
            changedOnDisk = false
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func revert() { text = savedText }
}

struct PreviewView: View {
    @Environment(AppModel.self) private var model
    let root: String
    let paneID: UUID

    var body: some View {
        // Only the editor content is keyed by document (see `content`); tab bar,
        // header and per-pane state stay alive so switching tabs is instant.
        EditorDocumentView(root: root, paneID: paneID)
            .id(root)
    }
}

private struct EditorDocumentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale
    let root: String
    let paneID: UUID

    private var group: EditorGroup { model.editorGroup(paneID) }
    private var isActive: Bool { model.activeEditor === group }
    private func activate() { if !isActive { model.activeEditorID = paneID } }

    private let pendingClose = State(initialValue: URL?.none)
    private let tabDropTarget = State(initialValue: TabDropSlot?.none)
    private let goToLineShown = State(initialValue: false)
    private let goToLineInput = State(initialValue: "")
    private let showRendered = State(initialValue: true)
    private let diffText = State(initialValue: String?.none)
    private let confirmOverwrite = State(initialValue: false)
    private let confirmDiscard = State(initialValue: URL?.none)
    private let fileDiff = State(initialValue: FileDiff())
    /// The file `fileDiff`/`diffText`/`selectedHunk` belong to.
    private let diffFor = State(initialValue: URL?.none)
    private let selectedHunk = State(initialValue: String?.none)
    private let confirmRevertAll = State(initialValue: false)
    private let requests = State(initialValue: LatestRequest<EditorLoadKey>())
    private let advanceAfterRefresh = State(initialValue: false)
    private var diffCacheKey: String? { group.file.map { root + "#" + $0.path } }
    private var currentDiff: FileDiff {
        guard let file = group.file else { return FileDiff() }
        if diffFor.wrappedValue == file { return fileDiff.wrappedValue }
        return diffCacheKey.flatMap { model.fileDiffCache[$0] } ?? FileDiff()
    }
    private var currentDiffText: String? { diffFor.wrappedValue == group.file ? diffText.wrappedValue : nil }
    private var currentSelectedHunk: String? { diffFor.wrappedValue == group.file ? selectedHunk.wrappedValue : nil }
    private var presentation: EditorPresentation { EditorPresentation(root: root, file: group.file) }
    private var displayMode: AppModel.PreviewMode { relativePath == nil ? .file : group.mode }
    private var loadKey: EditorLoadKey { EditorLoadKey(presentation: presentation, mode: displayMode.rawValue, revision: model.workspaceRevision) }

    /// The active tab's document (kept in the model so unsaved edits survive tab switches).
    private var document: PreviewDocument? { group.file.map(model.document(for:)) }

    var body: some View {
        if let url = group.file {
            VStack(spacing: 0) {
                tabBar
                header(url)
                Divider()
                if let doc = document, doc.changedOnDisk {
                    conflictBar(doc)
                }
                if displayMode == .file, !currentDiff.hunks.isEmpty, let doc = document, doc.isEditableKind {
                    changesBar(doc)
                }
                if relativePath == nil {
                    Label("Geöffnete Datei aus einem anderen Workspace – Git-Review ist hier deaktiviert.", systemImage: "folder.badge.questionmark")
                        .scaledFont(.caption).foregroundStyle(.secondary).padding(6)
                }
                if let symbol = model.searchingDefinition {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Suche Definition von „\(symbol)“ …").font(.caption)
                        Spacer()
                    }
                    .padding(6).background(Color.accentColor.opacity(0.08))
                }
                content
                    .overlay(alignment: .top) {
                        if let choices = model.definitionChoices { DefinitionChooser(symbol: choices.symbol, locations: choices.locations, root: root) }
                    }
                    .overlay(alignment: .bottom) {
                        if let id = currentSelectedHunk, let hunk = currentDiff.hunks.first(where: { $0.id == id }),
                           let doc = document {
                            hunkReview(hunk, doc: doc)
                        }
                    }
            }
            .confirmationDialog("Änderungen an „\(pendingClose.wrappedValue?.lastPathComponent ?? "")“ sichern?",
                                isPresented: Binding(get: { pendingClose.wrappedValue != nil }, set: { if !$0 { pendingClose.wrappedValue = nil } }),
                                presenting: pendingClose.wrappedValue) { u in
                Button("Sichern") {
                    if case .saved = model.document(for: u).save(force: false) { model.closeTab(u, in: group); model.workspaceRevision += 1 }
                    else { model.banner = "\(u.lastPathComponent) konnte nicht gesichert werden (extern geändert?)." }
                }
                Button("Nicht sichern", role: .destructive) { model.closeTab(u, in: group) }
                Button("Abbrechen", role: .cancel) {}
            } message: { _ in Text("Ungesicherte Änderungen gehen sonst verloren.") }
            .alert("Gehe zu Zeile", isPresented: goToLineShown.projectedValue) {
                TextField("Zeile", text: goToLineInput.projectedValue)
                Button("Springen") {
                    if let n = Int(goToLineInput.wrappedValue.trimmingCharacters(in: .whitespaces)), n > 0 { group.line = n }
                    goToLineInput.wrappedValue = ""
                }
                Button("Abbrechen", role: .cancel) { goToLineInput.wrappedValue = "" }
            }
            .task(id: loadKey) {
                document?.checkDisk()
                await reload(url)
            }
            .onDisappear {
                var gate = requests.wrappedValue
                gate.invalidate()
                requests.wrappedValue = gate
            }
            .confirmationDialog("Alle \(currentDiff.hunks.count) Änderungen in \(url.lastPathComponent) verwerfen?",
                                isPresented: confirmRevertAll.projectedValue) {
                Button("Alle verwerfen", role: .destructive) { revertAll() }
            } message: {
                Text(currentDiff.untracked
                     ? "Die Datei ist neu und nicht versioniert – sie wird geleert. Löschen kannst du sie im Git-Tab."
                     : "Die Datei wird auf den Stand im Git-Index (zuletzt angenommen bzw. committet) zurückgesetzt.")
            }
            .confirmationDialog("Datei wurde zwischenzeitlich geändert", isPresented: confirmOverwrite.projectedValue) {
                Button("Trotzdem überschreiben", role: .destructive) { save(force: true) }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Der Agent (oder ein anderes Programm) hat die Datei seit dem Öffnen verändert. Deine Version ersetzt diese Änderungen.")
            }
        } else {
            ContentUnavailableView("Keine Datei gewählt", systemImage: "doc.text.magnifyingglass",
                                   description: Text("Datei im Directory- oder Git-Tab anklicken."))
        }
    }

    // MARK: Tabs

    private var tabBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(group.tabs, id: \.self) { url in tab(url).id(url) }
                    // Drop zone after the last tab (append / move here from another editor).
                    Color.clear
                        .frame(minWidth: 60, maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                        .overlay(alignment: .leading) {
                            if tabDropTarget.wrappedValue == .end { Rectangle().fill(Color.accentColor).frame(width: 2) }
                        }
                        .onDrop(of: [.plainText], delegate: TabDropDelegate(model: model, pane: paneID, slot: .end, hover: tabDropTarget))
                }
            }
            .overlay(alignment: .trailing) {
                Button { model.splitEditor(paneID) } label: { Image(systemName: "square.split.2x1") }
                    .buttonStyle(.borderless).padding(.horizontal, 6)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                    .help("Editor teilen: aktuelle Datei rechts daneben öffnen")
            }
            .onChange(of: group.file) { _, u in if let u { proxy.scrollTo(u) } }
        }
        .frame(height: 28 * scale)
        .background(Color.primary.opacity(0.04))
        .overlay(alignment: .bottom) { Divider() }
        // ⌘W closes the active tab (only while tabs are open).
        .background {
            Button("") { if let u = group.file { requestClose(u) } }
                .keyboardShortcut(isActive ? KeyboardShortcut("w", modifiers: .command) : nil).hidden()
        }
    }

    private func tab(_ url: URL) -> some View {
        let active = url == group.file
        let dirty = model.documents[url]?.isDirty == true
        return HStack(spacing: 5) {
            Image(systemName: FileIcon.symbol(for: url)).foregroundStyle(.secondary).font(.system(size: 10 * scale))
            Text(url.lastPathComponent).scaledFont(.caption, bold: active).lineLimit(1)
            TabCloseButton(dirty: dirty) { requestClose(url) }
        }
        .padding(.leading, 10).padding(.trailing, 6)
        .frame(height: 28 * scale)
        .background(active ? Color(nsColor: .textBackgroundColor) : Color.clear)
        .overlay(alignment: .top) { if active { Rectangle().fill(Color.accentColor).frame(height: 2) } }
        .contentShape(Rectangle())
        .onTapGesture { model.draggingTab = nil; activate(); model.openPreview(url, mode: .file) }
        .overlay(alignment: .leading) {
            if tabDropTarget.wrappedValue == .before(url) { Rectangle().fill(Color.accentColor).frame(width: 2) }
        }
        .onDrag {
            model.draggingTab = AppModel.TabDrag(pane: paneID, url: url)
            return NSItemProvider(object: ("hearth-tab:" + url.path) as NSString)
        } preview: {
            Label(url.lastPathComponent, systemImage: FileIcon.symbol(for: url))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .onDrop(of: [.plainText], delegate: TabDropDelegate(model: model, pane: paneID, slot: .before(url), hover: tabDropTarget))
        .help(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        .contextMenu {
            Button("Schließen") { requestClose(url) }
            Button("Nach rechts teilen") { model.splitEditor(paneID, axis: .horizontal, url: url) }
            Button("Nach unten teilen") { model.splitEditor(paneID, axis: .vertical, url: url) }
            let others = model.paneTree.panes.filter { $0.tab == .preview && $0.id != paneID }
            if !others.isEmpty {
                Menu("In anderen Editor verschieben") {
                    ForEach(Array(others.enumerated()), id: \.element.id) { i, p in
                        Button(model.editorGroup(p.id).file?.lastPathComponent ?? "Editor \(i + 2)") {
                            model.moveTab(url, from: paneID, to: p.id)
                        }
                    }
                }
            }
            Divider()
            Button("Andere schließen") { model.closeOtherTabs(in: group, keeping: url) }
            Divider()
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func requestClose(_ url: URL) {
        if model.documents[url]?.isDirty == true { pendingClose.wrappedValue = url } else { model.closeTab(url, in: group) }
    }

    // MARK: Header

    private func header(_ url: URL) -> some View {
        let doc = document
        return HStack(spacing: 8) {
            HStack(spacing: 0) {
                Button { activate(); model.navigateBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(group.back.isEmpty)
                    .keyboardShortcut(isActive ? KeyboardShortcut("[", modifiers: .command) : nil)
                    .help("Zurück (⌘[)")
                Button { activate(); model.navigateForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(group.forward.isEmpty)
                    .keyboardShortcut(isActive ? KeyboardShortcut("]", modifiers: .command) : nil)
                    .help("Vor (⌘])")
            }
            .buttonStyle(.borderless)
            Image(systemName: FileIcon.symbol(for: url)).foregroundStyle(.secondary)
            Text(url.lastPathComponent).font(.callout.bold()).lineLimit(1)
            if doc?.isDirty == true {
                Circle().fill(Color.orange).frame(width: 7, height: 7).help("Ungespeicherte Änderungen")
            }
            if let lang = doc?.language, lang != .plain {
                Text(lang.rawValue).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 5).background(Color.primary.opacity(0.07), in: Capsule())
            }
            Spacer()
            Button {
                activate()
                model.revealEditorFile(group.file, in: root)
            } label: { Image(systemName: "scope") }
                .buttonStyle(.borderless).help("Diese Datei im Directory zeigen und markieren")
            if displayMode == .file, let doc, doc.isEditableKind {
                if doc.kind == .markdown {
                    Picker("", selection: showRendered.projectedValue) {
                        Image(systemName: "doc.richtext").tag(true)
                        Image(systemName: "chevron.left.forwardslash.chevron.right").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().help("Gerendert / Quelltext")
                }
                if doc.isDirty {
                    Button("Verwerfen") { doc.revert() }.controlSize(.small)
                    Button("Sichern") { save(force: false) }
                        .keyboardShortcut(isActive ? KeyboardShortcut("s", modifiers: .command) : nil)
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            Picker("", selection: Binding(get: { displayMode }, set: { group.mode = $0 })) {
                ForEach(AppModel.PreviewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).disabled(mode == .diff && relativePath == nil)
                }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.borderless).help("Im Standardprogramm öffnen")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func conflictBar(_ doc: PreviewDocument) -> some View {
        HStack {
            Label("Die Datei wurde auf der Platte geändert, während du sie bearbeitest.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
            Spacer()
            Button("Neu laden (meine Änderungen verwerfen)") { doc.load() }.controlSize(.small)
            Button("Meine behalten") { doc.changedOnDisk = false }.controlSize(.small)
        }
        .padding(6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if displayMode == .diff {
            if let d = currentDiffText {
                CodeText(text: d.isEmpty ? "Keine Änderungen gegenüber HEAD." : d, diff: true)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let doc = document {
            switch doc.kind {
            case .missing: ContentUnavailableView("Datei gelöscht", systemImage: "doc")
            case .binary: ContentUnavailableView("Binärdatei", systemImage: "doc")
            case .tooLarge: ContentUnavailableView("Datei zu groß für die Vorschau", systemImage: "doc")
            case .image:
                ScrollView([.horizontal, .vertical]) { if let img = doc.image { Image(nsImage: img) } }
            case .markdown where showRendered.wrappedValue:
                ScrollView {
                    MarkdownBlocks(text: doc.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            case .text, .markdown:
                CodeEditor(text: Binding(get: { doc.text }, set: { doc.text = $0 }),
                           language: doc.language,
                           editable: true,
                           highlightLine: group.line,
                           fontSize: 12 * scale,
                            onCommandClick: { symbol, qualifier in
                                activate()
                                Task { await model.goToDefinition(symbol: symbol, qualifier: qualifier) }
                           },
                           hunks: doc.isDirty ? [] : currentDiff.hunks,
                           selectedHunk: currentSelectedHunk,
                           onHunkClick: { h in select(h) },
                            onGoToLine: { goToLineShown.wrappedValue = true },
                            onFocus: { activate() },
                            stateKey: doc.url.path,
                            takesFocusFromPreviousEditor: isActive)
                .help("⌘-Klick auf einen Namen springt zur Definition · ⌘[ zurück")
                .id(doc.url)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Actions

    private func save(force: Bool) {
        guard let doc = document else { return }
        switch doc.save(force: force) {
        case .saved:
            model.toast("Gespeichert: \(doc.url.lastPathComponent)")
            model.workspaceRevision += 1
        case .conflict:
            confirmOverwrite.wrappedValue = true
        case .failed(let msg):
            model.banner = "Speichern fehlgeschlagen: \(msg)"
        }
    }

    // MARK: Inline diff review

    private func changesBar(_ doc: PreviewDocument) -> some View {
        let hunks = currentDiff.hunks
        let added = hunks.reduce(0) { $0 + $1.newCount }
        let removed = hunks.reduce(0) { $0 + $1.oldCount }
        return HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.purple)
            Text(currentDiff.untracked ? "Neue Datei" : "\(hunks.count) Änderung\(hunks.count == 1 ? "" : "en")")
                .scaledFont(.callout, bold: true)
            Text("+\(added)").foregroundStyle(.green).scaledFont(.caption, digits: true)
            Text("−\(removed)").foregroundStyle(.red).scaledFont(.caption, digits: true)
            Spacer()
            if doc.isDirty {
                Text("Erst sichern, dann reviewen").scaledFont(.caption).foregroundStyle(.secondary)
            } else {
                Button { step(-1) } label: { Image(systemName: "chevron.up") }.help("Vorige Änderung (⌥⌘↑)")
                    .keyboardShortcut(isActive ? KeyboardShortcut(.upArrow, modifiers: [.option, .command]) : nil)
                Button { step(1) } label: { Image(systemName: "chevron.down") }.help("Nächste Änderung (⌥⌘↓)")
                    .keyboardShortcut(isActive ? KeyboardShortcut(.downArrow, modifiers: [.option, .command]) : nil)
                Button("Alle annehmen") { acceptAll() }.help("Alle Änderungen dieser Datei stagen (git add)")
                Button("Alle verwerfen", role: .destructive) { confirmRevertAll.wrappedValue = true }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.purple.opacity(0.08))
    }

    private func hunkReview(_ h: DiffHunk, doc: PreviewDocument) -> some View {
        let hunks = currentDiff.hunks
        let index = (hunks.firstIndex { $0.id == h.id } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Änderung \(index)/\(hunks.count)").scaledFont(.caption, bold: true)
                Text(h.kind == .added ? "hinzugefügt" : h.kind == .deleted ? "gelöscht" : "geändert")
                    .scaledFont(.caption).foregroundStyle(.secondary)
                Text(h.newRange.map { "Zeile \($0.lowerBound)–\($0.upperBound)" } ?? "nach Zeile \(h.newStart)")
                    .scaledFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { step(-1) } label: { Image(systemName: "chevron.up") }
                Button { step(1) } label: { Image(systemName: "chevron.down") }
                Button("Zurücksetzen", role: .destructive) { revert(h) }
                    .help("Diese Änderung rückgängig machen (alter Stand aus dem Git-Index)")
                Button("Annehmen") { accept(h) }
                    .buttonStyle(.borderedProminent)
                    .help("Diese Änderung stagen – sie verschwindet aus der Review-Ansicht")
                Button { selectedHunk.wrappedValue = nil } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(h.oldLines.enumerated()), id: \.offset) { _, l in diffLine("−", l, .red) }
                    ForEach(Array(h.newLines.enumerated()), id: \.offset) { _, l in diffLine("+", l, .green) }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 180)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        .shadow(radius: 8, y: 2)
        .padding(10)
        .disabled(doc.isDirty)
    }

    private func diffLine(_ sign: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(sign).foregroundStyle(color).frame(width: 12)
            Text(text.isEmpty ? " " : text).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12 * scale, design: .monospaced))
        .padding(.horizontal, 8).padding(.vertical, 1)
        .background(color.opacity(0.12))
    }

    private func select(_ h: DiffHunk) {
        selectedHunk.wrappedValue = h.id
        group.line = h.anchorLine
    }

    private func step(_ delta: Int) {
        let hunks = currentDiff.hunks
        guard !hunks.isEmpty else { return }
        let current = hunks.firstIndex { $0.id == selectedHunk.wrappedValue }
            ?? (delta > 0 ? -1 : hunks.count)
        select(hunks[(current + delta + hunks.count) % hunks.count])
    }

    private var relativePath: String? {
        group.file.flatMap { EditorPresentation.relativePath($0, root: root) }
    }

    private func reload(_ url: URL) async {
        let key = loadKey
        var gate = requests.wrappedValue
        let ticket = gate.begin(key)
        requests.wrappedValue = gate
        if diffFor.wrappedValue != url {
            // Show cached hunks for this file right away; refresh below.
            selectedHunk.wrappedValue = nil
            diffText.wrappedValue = nil
            fileDiff.wrappedValue = model.fileDiffCache[root + "#" + url.path] ?? FileDiff()
            diffFor.wrappedValue = url
        }
        guard let rel = EditorPresentation.relativePath(url, root: root) else {
            fileDiff.wrappedValue = FileDiff()
            return
        }
        let cacheKey = root + "#" + url.path
        let revision = model.workspaceRevision
        if displayMode == .file, model.fileDiffRevision[cacheKey] == revision, let cached = model.fileDiffCache[cacheKey] {
            // Nothing changed in the workspace since this file's diff was loaded: no Git run.
            fileDiff.wrappedValue = cached
            return
        }
        var text: String?
        if displayMode == .diff {
            let tracked = await Git.run(["ls-files", "--error-unmatch", "--", rel], in: root) != nil
            guard !Task.isCancelled, requests.wrappedValue.accepts(ticket, current: loadKey) else { return }
            text = await Git.diff(path: rel, in: root, untracked: !tracked)
        }
        guard !Task.isCancelled, requests.wrappedValue.accepts(ticket, current: loadKey) else { return }
        let diff = await InlineDiff.load(file: url, root: root)
        guard !Task.isCancelled, requests.wrappedValue.accepts(ticket, current: loadKey) else { return }
        diffText.wrappedValue = text
        model.fileDiffCache[cacheKey] = diff
        model.fileDiffRevision[cacheKey] = revision
        if diffFor.wrappedValue == url {
            if diff.hunks != fileDiff.wrappedValue.hunks || diff.untracked != fileDiff.wrappedValue.untracked { fileDiff.wrappedValue = diff }
            else { fileDiff.wrappedValue.header = diff.header }
        }
        if let id = selectedHunk.wrappedValue, !diff.hunks.contains(where: { $0.id == id }) {
            selectedHunk.wrappedValue = nil
            if advanceAfterRefresh.wrappedValue, let first = diff.hunks.first { select(first) }
        }
        advanceAfterRefresh.wrappedValue = false
    }

    /// After a change: refresh this file's hunks and let Git/Directory panes update.
    private func changed(_ message: String, next: Bool = true) {
        model.toast(message)
        advanceAfterRefresh.wrappedValue = next && selectedHunk.wrappedValue != nil
        model.workspaceRevision += 1
    }

    private func revert(_ h: DiffHunk) {
        guard let doc = document, !doc.isDirty else { return }
        doc.text = InlineDiff.reverting(h, in: doc.text)
        switch doc.save(force: false) {
        case .saved: selectedHunk.wrappedValue = nil; changed("Änderung zurückgesetzt")
        case .conflict: model.banner = "Die Datei wurde zwischenzeitlich geändert – bitte neu laden und erneut versuchen."
            doc.revert()
        case .failed(let msg): model.banner = "Zurücksetzen fehlgeschlagen: \(msg)"; doc.revert()
        }
    }

    private func revertAll() {
        guard let doc = document, !doc.isDirty else { return }
        // Bottom-up so earlier line numbers stay valid.
        var text = doc.text
        for h in currentDiff.hunks.sorted(by: { $0.newStart > $1.newStart }) {
            text = InlineDiff.reverting(h, in: text)
        }
        doc.text = text
        if case .saved = doc.save(force: false) {
            selectedHunk.wrappedValue = nil
            changed("Alle Änderungen verworfen", next: false)
        } else {
            doc.revert()
            model.banner = "Verwerfen fehlgeschlagen – Datei wurde zwischenzeitlich geändert."
        }
    }

    private func accept(_ h: DiffHunk) {
        guard let rel = relativePath else { return }
        let target = presentation
        let diff = currentDiff
        Task {
            let r = await InlineDiff.stage(h, of: diff, file: rel, root: root)
            guard target == presentation, model.workspaceRoot == root else { if r.ok { model.workspaceRevision += 1 }; return }
            if r.ok { selectedHunk.wrappedValue = nil; changed("Änderung angenommen (gestaged)") }
            else { model.banner = "Annehmen fehlgeschlagen: \(r.output)" }
        }
    }

    private func acceptAll() {
        guard let rel = relativePath else { return }
        let target = presentation
        Task {
            let r = await Git.mutate(["add", "--", rel], in: root)
            guard target == presentation, model.workspaceRoot == root else { if r.ok { model.workspaceRevision += 1 }; return }
            if r.ok { selectedHunk.wrappedValue = nil; changed("Alle Änderungen angenommen (gestaged)", next: false) }
            else { model.banner = "Annehmen fehlgeschlagen: \(r.output)" }
        }
    }

}

/// Monospaced text with line numbers; diff lines get colored backgrounds.
struct CodeText: View {
    let text: String
    let diff: Bool
    var highlightLine: Int? = nil

    var body: some View {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        HStack(spacing: 8) {
                            if !diff {
                                Text("\(i + 1)").foregroundStyle(.tertiary).frame(width: 36, alignment: .trailing)
                            }
                            Text(String(line).isEmpty ? " " : String(line))
                                .fixedSize()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(diff ? background(for: line) : (highlightLine == i + 1 ? Color.yellow.opacity(0.25) : .clear))
                        .id(i + 1)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
            }
            .task(id: "\(highlightLine ?? 0)#\(lines.count)") {
                if let l = highlightLine {
                    try? await Task.sleep(for: .milliseconds(50))
                    withAnimation { proxy.scrollTo(l, anchor: .center) }
                }
            }
        }
    }

    private func background(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return .green.opacity(0.15) }
        if line.hasPrefix("-") { return .red.opacity(0.15) }
        if line.hasPrefix("@@") { return .blue.opacity(0.1) }
        return .clear
    }
}

/// Shown when ⌘-click found several declarations.
private struct DefinitionChooser: View {
    @Environment(AppModel.self) private var model
    let symbol: String
    let locations: [SymbolLocation]
    let root: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(locations.count) Definitionen für „\(symbol)“").font(.caption.bold())
                Spacer()
                Button { model.definitionChoices = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(locations) { loc in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Image(systemName: FileIcon.symbol(for: URL(fileURLWithPath: loc.path))).foregroundStyle(.secondary)
                                Text((loc.path as NSString).lastPathComponent).font(.callout.bold())
                                Text(":\(loc.line)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                Text((loc.path as NSString).deletingLastPathComponent).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.head)
                            }
                            Text(loc.preview).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .interactiveRow { model.open(loc, root: root) }
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 8, y: 3)
        .padding(10)
    }
}

/// Tab close button that shows a dot for unsaved changes (× on hover), like IDEs.
private struct TabCloseButton: View {
    @Environment(\.textScale) private var scale
    let dirty: Bool
    let action: () -> Void
    private let hovering = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            Group {
                if dirty && !hovering.wrappedValue {
                    Circle().fill(Color.primary.opacity(0.6)).frame(width: 7 * scale, height: 7 * scale)
                } else {
                    Image(systemName: "xmark").font(.system(size: 8 * scale, weight: .bold))
                }
            }
            .frame(width: 16 * scale, height: 16 * scale)
            .background(hovering.wrappedValue ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering.wrappedValue = $0 }
        .help(dirty ? "Ungesicherte Änderungen – schließen (⌘W)" : "Schließen (⌘W)")
    }
}


enum TabDropSlot: Equatable { case before(URL), end }

/// Reorders editor tabs or moves them between editors. Uses the in-process drag
/// state, so no asynchronous pasteboard decoding and no conflict with pane drags.
struct TabDropDelegate: DropDelegate {
    let model: AppModel
    let pane: UUID
    let slot: TabDropSlot
    let hover: State<TabDropSlot?>

    func validateDrop(info: DropInfo) -> Bool { model.draggingTab != nil }
    func dropEntered(info: DropInfo) { hover.wrappedValue = slot }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        hover.wrappedValue = slot
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if hover.wrappedValue == slot { hover.wrappedValue = nil } }
    func performDrop(info: DropInfo) -> Bool {
        hover.wrappedValue = nil
        guard let drag = model.draggingTab else { return false }
        model.draggingTab = nil
        let target: URL? = if case .before(let url) = slot { url } else { nil }
        model.placeTab(drag.url, from: drag.pane, to: pane, before: target)
        return true
    }
}
