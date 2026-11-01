import Foundation
import Testing
@testable import Hearth

@MainActor
struct EditorWorkspaceTests {
    @Test func eachSessionKeepsItsOwnTabs() throws {
        let dir = try temporaryFolder("hearth-editor")
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.swift"), b = dir.appendingPathComponent("b.swift"), c = dir.appendingPathComponent("c.swift")
        for f in [a, b, c] { try "x".write(to: f, atomically: true, encoding: .utf8) }

        let layout = LayoutStore()
        let editor = EditorStore(layout: layout)
        editor.workspaces = [:]
        editor.shownWorkspace = nil
        editor.tabs = []
        editor.file = nil
        var selected: URL?
        let keepAll: (String) -> Bool = { _ in true }

        editor.switchWorkspace(to: "run:one", selectedFile: &selected, keep: keepAll)
        editor.open(a); editor.open(b)
        #expect(editor.tabs == [a, b])

        editor.switchWorkspace(to: "run:two", selectedFile: &selected, keep: keepAll)
        #expect(editor.tabs.isEmpty, "Tabs of session one leaked into session two")
        editor.open(c)

        editor.switchWorkspace(to: "run:one", selectedFile: &selected, keep: keepAll)
        #expect(editor.tabs == [a, b])
        #expect(editor.file == b)

        // Deleted files are dropped when a session's tabs come back.
        try FileManager.default.removeItem(at: c)
        editor.switchWorkspace(to: "run:two", selectedFile: &selected, keep: keepAll)
        #expect(editor.tabs.isEmpty)

        // Stashes of removed sessions are dropped.
        editor.switchWorkspace(to: "run:three", selectedFile: &selected) { $0 != "run:one" }
        #expect(editor.workspaces["run:one"] == nil && editor.workspaces["run:two"] != nil)
    }
}
