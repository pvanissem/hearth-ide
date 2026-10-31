import Foundation

/// Slash commands contributed by OpenCode *TUI* plugins (e.g. devkcode's
/// /copilot-usage). They run in the terminal client, so the server's
/// /api/command doesn't list them; we discover them from the plugin sources.
struct PluginCommand: Hashable, Sendable {
    let name: String
    let title: String?
    let file: String
}

enum PluginCommands {
    /// Commands the app implements natively; all others are offered in the terminal.
    static let native: Set<String> = ["copilot-usage"]

    /// Plugin folders OpenCode loads: devkcode's team config, global config and
    /// `.opencode` in the repo and all its parents.
    static func pluginDirectories(repoRoot: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs = [
            home.appendingPathComponent(".local/share/devkcode/opencode-team-config/plugins"),
            home.appendingPathComponent(".config/opencode/plugins"),
            home.appendingPathComponent(".config/opencode/plugin"),
        ]
        var dir = URL(fileURLWithPath: repoRoot)
        while dir.path.count > 1 {
            dirs.append(dir.appendingPathComponent(".opencode/plugins"))
            dirs.append(dir.appendingPathComponent(".opencode/plugin"))
            dir.deleteLastPathComponent()
        }
        return dirs
    }

    static func discover(repoRoot: String) -> [PluginCommand] {
        let slash = try! NSRegularExpression(pattern: #"slash\s*:\s*\{\s*name\s*:\s*["'`]([^"'`]+)["'`]"#)
        let title = try! NSRegularExpression(pattern: #"title\s*:\s*["'`]([^"'`]+)["'`]"#)
        var seen = Set<String>()
        var result: [PluginCommand] = []
        for dir in pluginDirectories(repoRoot: repoRoot) {
            guard let it = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            while let url = it.nextObject() as? URL {
                if url.lastPathComponent == "node_modules" { it.skipDescendants(); continue }
                guard ["ts", "js", "mjs", "tsx"].contains(url.pathExtension),
                      let text = try? String(contentsOf: url, encoding: .utf8), text.contains("slash") else { continue }
                let ns = text as NSString
                for m in slash.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let name = ns.substring(with: m.range(at: 1))
                    guard seen.insert(name).inserted else { continue }
                    // Nearest "title:" before the slash definition (same command object).
                    let before = NSRange(location: max(0, m.range.location - 400), length: min(400, m.range.location))
                    let t = title.matches(in: text, range: before).last.map { ns.substring(with: $0.range(at: 1)) }
                    result.append(PluginCommand(name: name, title: t, file: url.path))
                }
            }
        }
        return result.sorted { $0.name < $1.name }
    }
}

/// Data shown by the native /copilot-usage dialog.
struct CopilotUsage: Identifiable, Sendable {
    struct ModelRow: Hashable, Sendable {
        let name: String
        let cost: Double
        let steps: Int
    }
    let id = UUID()
    var used: Double?
    var entitlement: Double?
    var remaining: Double?
    var fraction: Double?
    var overage: Bool?
    var reset: String?
    var githubError: String?
    var models: [ModelRow] = []
    var statsError: String?
}
