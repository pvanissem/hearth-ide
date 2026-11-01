import Foundation
import Testing
@testable import Hearth

struct AgentHomeTests {
    @Test func linksAreRestoredAndSeedsCopiedOnce() throws {
        let dir = try temporaryFolder("hearth-home")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let home = dir.appendingPathComponent("home").path, support = dir.appendingPathComponent("support").path
        try fm.createDirectory(atPath: home + "/.claude/skills/demo", withIntermediateDirectories: true)
        try "Regeln".write(toFile: home + "/.claude/CLAUDE.md", atomically: true, encoding: .utf8)
        try #"{"theme":"dark"}"#.write(toFile: home + "/.claude/settings.json", atomically: true, encoding: .utf8)

        let layout = AgentHome.layout(for: .claude, support: support, home: home)
        let root = try need(layout.root)
        try layout.prepare()
        try require(try fm.destinationOfSymbolicLink(atPath: root + "/CLAUDE.md") == home + "/.claude/CLAUDE.md", "CLAUDE.md not linked")
        try require(try fm.destinationOfSymbolicLink(atPath: root + "/skills") == home + "/.claude/skills", "skills not linked")
        try require(!fm.fileExists(atPath: root + "/agents"), "Link to a missing folder created")
        try require(try String(contentsOfFile: root + "/settings.json", encoding: .utf8).contains("dark"), "Settings not seeded")

        // The agent may change its own copy and replace links; the next start puts the links back.
        try #"{"hooks":{}}"#.write(toFile: root + "/settings.json", atomically: true, encoding: .utf8)
        try fm.removeItem(atPath: root + "/CLAUDE.md")
        try "untergeschoben".write(toFile: root + "/CLAUDE.md", atomically: true, encoding: .utf8)
        try layout.prepare()
        try require(try fm.destinationOfSymbolicLink(atPath: root + "/CLAUDE.md") == home + "/.claude/CLAUDE.md", "Replaced link not restored")
        try require(try String(contentsOfFile: root + "/settings.json", encoding: .utf8).contains("hooks"), "Own settings overwritten")
        // Nothing flows back to the host.
        try require(try String(contentsOfFile: home + "/.claude/settings.json", encoding: .utf8) == #"{"theme":"dark"}"#, "Host settings changed")
    }

    @Test func eachAgentHasAPlan() {
        for kind in AgentKind.allCases {
            let layout = AgentHome.layout(for: kind, support: "/s", home: "/h")
            switch kind {
            case .claude, .codex, .opencode:
                #expect(layout.root == "/s/agents/\(kind.rawValue)" && !layout.environment.isEmpty, "\(kind) without own folder")
                #expect(layout.hostReadWrite.isEmpty, "\(kind) still writes the host folder")
            case .gemini, .copilot:
                #expect(!layout.writeProtectedFiles.isEmpty, "\(kind) without write protection")
            case .shell:
                #expect(layout.root == nil && layout.hostReadWrite.isEmpty)
            }
        }
    }
}
