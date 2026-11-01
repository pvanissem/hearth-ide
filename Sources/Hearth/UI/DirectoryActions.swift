import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// File management is intentionally limited to the displayed workspace.
enum WorkspaceFiles {
    static func contains(_ url: URL, root: URL) -> Bool {
        guard url.isFileURL, root.isFileURL else { return false }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    static func destination(name: String, in directory: URL, root: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"),
              name != ".git", !directory.resolvingSymlinksInPath().pathComponents.contains(".git"),
              !name.contains("\0"), contains(directory, root: root) else {
            throw Failure("Bitte einen gültigen Namen innerhalb des Workspace angeben.")
        }
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw Failure("Unter diesem Namen existiert bereits eine Datei oder ein Ordner.")
        }
        return url
    }

    static func moveDestination(source: URL, directory: URL, root: URL) throws -> URL {
        guard contains(source, root: root), source.resolvingSymlinksInPath().path != root.resolvingSymlinksInPath().path,
              !source.resolvingSymlinksInPath().pathComponents.contains(".git") else {
            throw Failure("Dieser Pfad darf hier nicht verschoben werden.")
        }
        let target = try destination(name: source.lastPathComponent, in: directory, root: root)
        // Resolve existing directories, not the nonexistent destination leaf:
        // Foundation can otherwise normalize /private/var and /var differently.
        let parent = directory.resolvingSymlinksInPath().path
        let sourcePath = source.resolvingSymlinksInPath().path
        guard parent != sourcePath, !parent.hasPrefix(sourcePath + "/") else {
            throw Failure("Ein Ordner kann nicht in sich selbst verschoben werden.")
        }
        return target
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

struct DirectoryCreateMenu: View {
    @Environment(AppModel.self) private var model
    let directory: URL
    let root: String

    var body: some View {
        Button("Neue Datei …") { model.createWorkspaceItem(in: directory, root: root, folder: false) }
        Button("Neuer Ordner …") { model.createWorkspaceItem(in: directory, root: root, folder: true) }
    }
}

struct DirectoryItemMenu: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let root: String

    var body: some View {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            DirectoryCreateMenu(directory: url, root: root)
            Divider()
        }
        Button("Umbenennen …") { model.changeWorkspaceItem(url, root: root, rename: true) }
        Button("Verschieben …") { model.changeWorkspaceItem(url, root: root, rename: false) }
        Button("In den Papierkorb …", role: .destructive) { model.trashWorkspaceItem(url, root: root) }
    }
}

extension AppModel {
    func revealEditorFile(_ focused: URL? = nil, in root: String) {
        guard let file = focused ?? editor.file, WorkspaceFiles.contains(file, root: URL(fileURLWithPath: root)) else {
            banner = "Die aktive Editor-Datei liegt nicht in diesem Workspace."
            return
        }
        var parent = file.deletingLastPathComponent().standardizedFileURL
        let base = URL(fileURLWithPath: root).standardizedFileURL
        while parent.path != base.path && parent.path.hasPrefix(base.path + "/") {
            workspace.expandedPaths.insert(parent.path)
            parent.deleteLastPathComponent()
        }
        workspace.selectedFile = file
        workspace.revealID = UUID()
        layout.maximizedPane = nil
        if !layout.paneTree.contains(tab: .directory) { layout.addPane(.directory) }
    }

    @discardableResult
    func moveWorkspaceItem(_ source: URL, into directory: URL, root: String) -> Bool {
        workspaceAction {
            try validateWorkspaceChange(source, root: root)
            let target = try WorkspaceFiles.moveDestination(source: source, directory: directory, root: URL(fileURLWithPath: root))
            try performWorkspaceMove(source, to: target, root: root)
        }
    }

    private func performWorkspaceMove(_ source: URL, to target: URL, root: String) throws {
        let canonicalSource = source.resolvingSymlinksInPath().path
        let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent != canonicalSource, !parent.hasPrefix(canonicalSource + "/") else {
            throw WorkspaceFiles.Failure("Ein Ordner kann nicht in sich selbst verschoben werden.")
        }
        try validateWorkspaceChange(source, root: root)
        try FileManager.default.moveItem(at: source, to: target)
        workspace.expandedPaths = Set(workspace.expandedPaths.map {
            $0 == source.path || $0.hasPrefix(source.path + "/") ? target.path + String($0.dropFirst(source.path.count)) : $0
        })
        workspace.expandedPaths.insert(target.deletingLastPathComponent().path)
        if let selected = workspace.selectedFile, selected == source || selected.path.hasPrefix(source.path + "/") {
            workspace.selectedFile = URL(fileURLWithPath: target.path + String(selected.path.dropFirst(source.path.count)))
        }
        updateWorkspaceTabs(from: source, to: target)
    }

    @discardableResult
    private func workspaceAction(_ action: () throws -> Void) -> Bool {
        do {
            try action()
            workspace.revision += 1
            return true
        } catch { banner = error.localizedDescription; return false }
    }

    private func askName(title: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        let field = NSTextField(string: initial)
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    func createWorkspaceItem(in directory: URL, root: String, folder: Bool) {
        guard let name = askName(title: folder ? "Neuer Ordner" : "Neue Datei", initial: "") else { return }
        workspaceAction {
            let target = try WorkspaceFiles.destination(name: name, in: directory, root: URL(fileURLWithPath: root))
            if folder {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            } else {
                try Data().write(to: target, options: .withoutOverwriting)
                editor.open(target)
            }
        }
    }

    /// Blocks changes that would orphan an unsaved buffer, including nested files.
    private func validateWorkspaceChange(_ url: URL, root: String) throws {
        let base = URL(fileURLWithPath: root).standardizedFileURL
        guard url.resolvingSymlinksInPath().standardizedFileURL.path != base.resolvingSymlinksInPath().path,
              WorkspaceFiles.contains(url, root: base),
              !url.resolvingSymlinksInPath().pathComponents.contains(".git") else {
            throw WorkspaceFiles.Failure("Dieser Pfad darf hier nicht verändert werden.")
        }
        let canonicalSource = url.resolvingSymlinksInPath().path
        guard !editor.unsavedDocuments.contains(where: {
            let path = $0.url.resolvingSymlinksInPath().path
            return path == canonicalSource || path.hasPrefix(canonicalSource + "/")
        }) else {
            throw WorkspaceFiles.Failure("Bitte die ungespeicherten Dateien in diesem Pfad zuerst sichern oder ihre Änderungen verwerfen.")
        }
    }

    func changeWorkspaceItem(_ url: URL, root: String, rename: Bool) {
        workspaceAction {
            try validateWorkspaceChange(url, root: root)
            let directory: URL
            let name: String
            if rename {
                guard let answer = askName(title: "Umbenennen", initial: url.lastPathComponent) else { return }
                if answer == url.lastPathComponent { return }
                directory = url.deletingLastPathComponent()
                name = answer
            } else {
                let panel = NSOpenPanel()
                panel.title = "Zielordner für „\(url.lastPathComponent)“"
                panel.directoryURL = URL(fileURLWithPath: root)
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.allowsMultipleSelection = false
                panel.canCreateDirectories = false
                guard panel.runModal() == .OK, let selected = panel.url else { return }
                directory = selected
                name = url.lastPathComponent
            }
            let target = try WorkspaceFiles.destination(name: name, in: directory, root: URL(fileURLWithPath: root))
            try performWorkspaceMove(url, to: target, root: root)
        }
    }

    func trashWorkspaceItem(_ url: URL, root: String) {
        workspaceAction {
            try validateWorkspaceChange(url, root: root)
            let alert = NSAlert()
            alert.messageText = "„\(url.lastPathComponent)“ in den Papierkorb verschieben?"
            alert.informativeText = "Bei Ordnern wird auch der gesamte Inhalt verschoben. Wiederherstellen ist über den Finder möglich."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "In den Papierkorb")
            alert.addButton(withTitle: "Abbrechen")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try validateWorkspaceChange(url, root: root)
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            updateWorkspaceTabs(from: url, to: nil)
        }
    }

    private func updateWorkspaceTabs(from source: URL, to destination: URL?) {
        // Include the active/restored group even before its pane has appeared.
        let groups = Array(editor.groups.values) + [editor.active]
        for group in groups {
            let active = group.file
            for old in group.tabs where old == source || old.path.hasPrefix(source.path + "/") {
                let replacement = destination.map { URL(fileURLWithPath: $0.path + String(old.path.dropFirst(source.path.count))) }
                if let replacement {
                    group.tabs = group.tabs.map { $0 == old ? replacement : $0 }
                    if active == old { group.file = replacement }
                } else {
                    group.remove(old)
                }
                editor.documents[old] = nil
            }
            // Old paths must not remain in navigation history after a rename/delete.
            group.back.removeAll { $0.url == source || $0.url.path.hasPrefix(source.path + "/") }
            group.forward.removeAll { $0.url == source || $0.url.path.hasPrefix(source.path + "/") }
        }
    }
}

/// Only accept drags created by this app instance, never Finder/external file drags.
struct WorkspaceFileDrag: Codable {
    static let type = UTType(exportedAs: "io.github.pvanissem.hearth.workspace-file", conformingTo: .data)
    static let pasteboardType = NSPasteboard.PasteboardType(type.identifier)
    let source: URL
    let root: String
    let token: UUID

    var provider: NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: Self.type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    var pasteboardItem: NSPasteboardItem {
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(self) { item.setData(data, forType: Self.pasteboardType) }
        return item
    }

    static func decode(_ data: Data, root: String, token: UUID) -> WorkspaceFileDrag? {
        guard data.count < 16_384, let drag = try? JSONDecoder().decode(Self.self, from: data), drag.token == token,
              URL(fileURLWithPath: drag.root).resolvingSymlinksInPath().standardizedFileURL.path ==
                URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        return drag
    }
}

struct WorkspaceFileDrop: ViewModifier {
    let directory: URL?
    let root: String
    let model: AppModel
    private let targeted = State(initialValue: false)

    func body(content: Content) -> some View {
        if let directory {
            content
                .background(targeted.wrappedValue ? Color.accentColor.opacity(0.18) : Color.clear)
                .onDrop(of: [WorkspaceFileDrag.type], delegate: WorkspaceRootDrop(directory: directory, root: root,
                    model: model, targeted: targeted.projectedValue))
        } else { content }
    }
}

private struct WorkspaceRootDrop: DropDelegate {
    let directory: URL
    let root: String
    let model: AppModel
    let targeted: Binding<Bool>
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [WorkspaceFileDrag.type]) }
    func dropEntered(info: DropInfo) { targeted.wrappedValue = true }
    func dropExited(info: DropInfo) { targeted.wrappedValue = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        targeted.wrappedValue = false
        guard let provider = info.itemProviders(for: [WorkspaceFileDrag.type]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: WorkspaceFileDrag.type.identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in
                guard let drag = WorkspaceFileDrag.decode(data, root: root, token: model.workspace.dragToken) else { return }
                model.moveWorkspaceItem(drag.source, into: directory, root: root)
            }
        }
        return true
    }
}

@MainActor
private final class DirectoryMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invoke(_ sender: NSMenuItem) { action() }
}

extension AppModel {
    func directoryMenu(for file: FileNode?, root: String, markers: [String: String]) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let target = DirectoryMenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(DirectoryMenuAction.invoke(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            menu.addItem(item)
        }
        let directory = file?.isDirectory == true ? file!.url : URL(fileURLWithPath: root)
        if file == nil || file?.isDirectory == true {
            add("Neue Datei …") { self.createWorkspaceItem(in: directory, root: root, folder: false) }
            add("Neuer Ordner …") { self.createWorkspaceItem(in: directory, root: root, folder: true) }
            menu.addItem(.separator())
        }
        guard let file else {
            add("Aktualisieren") { self.workspace.revision += 1 }
            return menu
        }
        let url = file.url
        if !file.isDirectory {
            add("Im Editor öffnen") { self.editor.open(url) }
            let relative = String(url.path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if markers[relative] != nil { add("Diff anzeigen") { self.editor.open(url, mode: .diff) } }
        }
        add("Umbenennen …") { self.changeWorkspaceItem(url, root: root, rename: true) }
        add("Verschieben …") { self.changeWorkspaceItem(url, root: root, rename: false) }
        add("In den Papierkorb …") { self.trashWorkspaceItem(url, root: root) }
        menu.addItem(.separator())
        add("Im Standardprogramm öffnen") { NSWorkspace.shared.open(url) }
        add("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        add("Pfad kopieren") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
        add("Relativen Pfad kopieren") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(url.path.dropFirst(root.count + 1)), forType: .string)
        }
        add("Im Chat erwähnen") { self.mention(url) }
        return menu
    }
}
