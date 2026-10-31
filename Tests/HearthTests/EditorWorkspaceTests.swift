import Foundation
import Testing
@testable import Hearth

@MainActor
struct EditorWorkspaceTests {
    @Test func eachSessionKeepsItsOwnTabs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Isolated support folder; snapshot mode keeps the user's UI state untouched.
        setenv("HEARTH_SUPPORT_DIR", dir.path, 1)
        setenv("HEARTH_SNAPSHOT", "1", 1)
        let a = dir.appendingPathComponent("a.swift"), b = dir.appendingPathComponent("b.swift"), c = dir.appendingPathComponent("c.swift")
        for f in [a, b, c] { try "x".write(to: f, atomically: true, encoding: .utf8) }

        let model = AppModel()
        model.editorWorkspaces = [:]
        model.shownEditorWorkspace = nil
        model.openTabs = []
        model.previewFile = nil

        model.selectedServerID = "s1"; model.selectedSessionID = "one"
        model.switchEditorWorkspace()
        model.openPreview(a); model.openPreview(b)
        #expect(model.openTabs == [a, b])

        model.selectedSessionID = "two"
        model.switchEditorWorkspace()
        #expect(model.openTabs.isEmpty, "Tabs of session one leaked into session two")
        model.openPreview(c)

        model.selectedSessionID = "one"
        model.switchEditorWorkspace()
        #expect(model.openTabs == [a, b])
        #expect(model.previewFile == b)

        // Deleted files are dropped when a session's tabs come back.
        try FileManager.default.removeItem(at: c)
        model.selectedSessionID = "two"
        model.switchEditorWorkspace()
        #expect(model.openTabs.isEmpty)
    }
}
