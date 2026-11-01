import Foundation

/// Hearth's own configuration folder for an agent (S2 in docs/review-security-architecture.md).
///
/// An agent may write its state, but its configuration also holds things that execute
/// commands (Claude Code hooks and MCP servers, Codex `notify`, OpenCode plugins). If the
/// agent could write the user's real `~/.claude`, those commands would run unsandboxed the
/// next time the CLI is used in a normal terminal. So each agent gets a private folder
/// under Hearth's support directory. The user's instructions, skills, agents and commands
/// are linked in read-only; settings are copied once. Nothing flows back to the host.
///
/// CLIs without a reliable config-dir variable (Gemini, Copilot) keep their own folder,
/// but the files that run commands are write-protected (`writeProtected`).
struct AgentHome: Equatable {
    struct Link: Equatable {
        /// Path inside the agent home.
        let name: String
        /// Host path it points to (granted read-only).
        let target: String
    }

    let kind: AgentKind
    /// Private, writable folder (nil: the agent keeps its default folder).
    let root: String?
    let environment: [String: String]
    /// Read-only links into the user's own configuration (only created when the target exists).
    let links: [Link]
    /// Copied once from the host when missing in the home: (path inside home, host source).
    let seeds: [Link]
    /// Host folders the agent may still write (agents without a private home).
    let hostReadWrite: [String]
    /// Host files the agent must not write, even inside `hostReadWrite`.
    let writeProtectedFiles: [String]
    /// Host folders the agent must not write, even inside `hostReadWrite`.
    let writeProtectedFolders: [String]

    /// Host paths the agent may read through `links`.
    var linkTargets: [String] { links.map(\.target) }

    static func layout(for kind: AgentKind, support: String, home: String) -> AgentHome {
        let dir = support + "/agents/" + kind.rawValue
        func host(_ path: String) -> String { home + "/" + path }
        func linked(_ folder: String, _ names: [String], into prefix: String = "") -> [Link] {
            names.map { Link(name: prefix + $0, target: host(folder + "/" + $0)) }
        }
        switch kind {
        case .claude:
            return AgentHome(kind: kind, root: dir, environment: ["CLAUDE_CONFIG_DIR": dir],
                             links: linked(".claude", ["CLAUDE.md", "skills", "agents", "commands", "output-styles"]),
                             seeds: [Link(name: "settings.json", target: host(".claude/settings.json"))],
                             hostReadWrite: [], writeProtectedFiles: [], writeProtectedFolders: [])
        case .codex:
            return AgentHome(kind: kind, root: dir, environment: ["CODEX_HOME": dir],
                             links: linked(".codex", ["AGENTS.md", "prompts", "skills"]),
                             seeds: [Link(name: "config.toml", target: host(".codex/config.toml"))],
                             hostReadWrite: [], writeProtectedFiles: [], writeProtectedFolders: [])
        case .opencode:
            return AgentHome(kind: kind, root: dir,
                             environment: ["XDG_CONFIG_HOME": dir + "/config", "XDG_DATA_HOME": dir + "/data",
                                           "XDG_STATE_HOME": dir + "/state", "XDG_CACHE_HOME": dir + "/cache"],
                             links: linked(".config/opencode", ["AGENTS.md", "agent", "agents", "command", "commands"],
                                           into: "config/opencode/")
                                 + [Link(name: "config/git", target: host(".config/git"))],
                             seeds: [Link(name: "config/opencode/opencode.json", target: host(".config/opencode/opencode.json")),
                                     Link(name: "config/opencode/opencode.jsonc", target: host(".config/opencode/opencode.jsonc"))],
                             hostReadWrite: [], writeProtectedFiles: [], writeProtectedFolders: [])
        case .gemini:
            return AgentHome(kind: kind, root: nil, environment: [:], links: [], seeds: [],
                             hostReadWrite: [host(".gemini")],
                             writeProtectedFiles: [host(".gemini/settings.json")],
                             writeProtectedFolders: [host(".gemini/extensions")])
        case .copilot:
            return AgentHome(kind: kind, root: nil, environment: [:], links: [], seeds: [],
                             hostReadWrite: [host(".copilot"), host(".config/github-copilot")],
                             writeProtectedFiles: [host(".copilot/mcp-config.json")],
                             writeProtectedFolders: [])
        case .shell:
            return AgentHome(kind: kind, root: nil, environment: [:], links: [], seeds: [],
                             hostReadWrite: [], writeProtectedFiles: [], writeProtectedFolders: [])
        }
    }

    /// Creates the folder, refreshes the read-only links and copies missing seeds.
    func prepare() throws {
        let fm = FileManager.default
        guard let root else {
            for dir in hostReadWrite where !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            return
        }
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for link in links {
            let path = root + "/" + link.name
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            // The agent can write its home: always replace whatever is there with the expected link.
            if (try? fm.destinationOfSymbolicLink(atPath: path)) == link.target { continue }
            if (try? fm.attributesOfItem(atPath: path)) != nil { try fm.removeItem(atPath: path) }
            if fm.fileExists(atPath: link.target) { try fm.createSymbolicLink(atPath: path, withDestinationPath: link.target) }
        }
        for seed in seeds {
            let path = root + "/" + seed.name
            guard (try? fm.attributesOfItem(atPath: path)) == nil, fm.fileExists(atPath: seed.target) else { continue }
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try fm.copyItem(atPath: seed.target, toPath: path)
        }
    }

    /// Where Claude Code keeps its transcripts for this home (used to decide whether a session can resume).
    static func claudeProjects(support: String) -> String { support + "/agents/claude/projects" }
}
