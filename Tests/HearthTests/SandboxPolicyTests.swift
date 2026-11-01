import Foundation
import Testing
@testable import Hearth

/// The rights of every kind of sandbox. Golden files under Tests/HearthTests/Golden hold the
/// exact nono profiles, so any change to a sandbox's rights shows up as a diff in review.
/// Regenerate with `HEARTH_UPDATE_GOLDEN=1 scripts/test.sh --filter SandboxPolicyTests`.
struct SandboxPolicyTests {
    static let home = "/Users/test"
    static let support = home + "/Library/Application Support/Hearth"
    static let workdir = home + "/code/project"

    static func context(_ settings: SandboxSettings = SandboxSettings(), gitHosts: [String] = []) -> SandboxContext {
        SandboxContext(home: home, support: support, runDirectory: support + "/runs/run-1", workdir: workdir,
                       settings: settings, gitHosts: gitHosts)
    }

    static let purposes: [(String, SandboxPurpose)] =
        AgentKind.allCases.map { ("agent-" + $0.rawValue, SandboxPurpose.agent($0)) }
        + [("build", .build), ("git-network", .gitNetwork), ("git-local", .gitLocal)]

    @Test(arguments: purposes.map(\.0))
    func profileMatchesGolden(_ name: String) throws {
        let purpose = try need(Self.purposes.first { $0.0 == name }?.1)
        let policy = SandboxPolicy.make(purpose, Self.context(gitHosts: purpose == .gitNetwork ? ["gitlab.example.test"] : []))
        let actual = String(decoding: policy.profileData, as: UTF8.self) + "\n"
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden/\(name).json")
        if ProcessInfo.processInfo.environment["HEARTH_UPDATE_GOLDEN"] != nil {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try actual.write(to: file, atomically: true, encoding: .utf8)
        }
        let expected = try String(contentsOf: file, encoding: .utf8)
        #expect(actual == expected, "Profile for \(name) changed. Review the rights, then update the golden file.")
    }

    @Test(arguments: purposes.map(\.0))
    func noSandboxGetsTheUsersCredentialsOrConfiguration(_ name: String) throws {
        let purpose = try need(Self.purposes.first { $0.0 == name }?.1)
        let policy = SandboxPolicy.make(purpose, Self.context())
        let writable = policy.readWrite + policy.readWriteFiles
        for forbidden in [".claude", ".claude.json", ".codex", ".config/opencode", ".zshrc", ".aws", ".gnupg", ".ssh"] {
            #expect(!writable.contains(Self.home + "/" + forbidden), "\(name) may write ~/\(forbidden)")
        }
        // Only the Git network step may read SSH keys or reach port 22.
        let ssh = policy.read.contains(Self.home + "/.ssh") || policy.seatbeltRules.contains { $0.contains("*:22") }
        #expect(ssh == (purpose == .gitNetwork), "\(name): SSH access is \(ssh)")
        // Every sandbox protects the project's Git hooks.
        #expect(policy.seatbeltRules.contains { $0.contains(Self.workdir + "/.git/hooks") }, "\(name) may write .git/hooks")
    }

    @Test func agentsUseTheirOwnConfigurationFolder() {
        for (kind, variable) in [(AgentKind.claude, "CLAUDE_CONFIG_DIR"), (.codex, "CODEX_HOME"), (.opencode, "XDG_CONFIG_HOME")] {
            let policy = SandboxPolicy.make(.agent(kind), Self.context())
            let folder = Self.support + "/agents/" + kind.rawValue
            #expect(policy.readWrite.contains(folder), "\(kind) cannot write its own folder")
            #expect(policy.environment[variable]?.hasPrefix(folder) == true, "\(kind) not pointed at its folder")
        }
        let claude = SandboxPolicy.make(.agent(.claude), Self.context())
        #expect(claude.read.contains(Self.home + "/.claude/CLAUDE.md") && claude.read.contains(Self.home + "/.claude/skills"),
                "User instructions/skills not readable")
        // Agents without a config-dir variable: the files that run commands stay write-protected.
        let gemini = SandboxPolicy.make(.agent(.gemini), Self.context())
        #expect(gemini.seatbeltRules.contains { $0.contains(Self.home + "/.gemini/settings.json") })
        let copilot = SandboxPolicy.make(.agent(.copilot), Self.context())
        #expect(copilot.seatbeltRules.contains { $0.contains(Self.home + "/.copilot/mcp-config.json") })
    }

    /// Maven, Gradle and npm can't write the user's caches (read-only in nono's runtime groups),
    /// so builds and agents get a private, writable cache that reuses the host's downloads.
    @Test func buildToolsGetAPrivateWritableCache() {
        let cache = Self.home + "/Library/Caches/Hearth"
        for purpose in [SandboxPurpose.build, .agent(.claude), .agent(.shell)] {
            let policy = SandboxPolicy.make(purpose, Self.context())
            let maven = policy.environment["MAVEN_ARGS"] ?? ""
            #expect(maven.contains("-Dmaven.repo.local=\(cache)/m2/repository"), "\(purpose): Maven cache")
            #expect(maven.contains("-Dmaven.repo.local.tail=\(Self.home)/.m2/repository"), "\(purpose): ~/.m2 fallback")
            #expect(!maven.contains(" \(Self.home)/Library/Application"), "MAVEN_ARGS is split at spaces")
            #expect(policy.environment["GRADLE_USER_HOME"] == cache + "/gradle")
            #expect(policy.environment["npm_config_cache"] == cache + "/npm")
            #expect(!policy.readWrite.contains(Self.home + "/.m2") && !policy.readWrite.contains(Self.home + "/.m2/repository"),
                    "\(purpose) may write the host's Maven repository")
        }
        #expect(SandboxPolicy.make(.gitNetwork, Self.context()).environment["MAVEN_ARGS"] == nil)
        // Java gets a private user.home (Vaadin & co. write ~/.vaadin, which holds host tools).
        #expect(SandboxPolicy.make(.build, Self.context()).environment["JAVA_TOOL_OPTIONS"] == "-Duser.home=\(cache)/home")
    }

    /// Dev servers (e.g. Vaadin + Vite) connect to helpers on random localhost ports.
    @Test func onlyBuildsReachLocalhost() {
        let rule = #"(allow network-outbound (remote tcp "localhost:*"))"#
        for (name, purpose) in Self.purposes {
            #expect(SandboxPolicy.make(purpose, Self.context()).seatbeltRules.contains(rule) == (purpose == .build), "\(name)")
        }
    }

    @Test func keychainOnlyWhereNeeded() {
        let keychains = Self.home + "/Library/Keychains"
        #expect(SandboxPolicy.make(.agent(.claude), Self.context()).readWrite.contains(keychains))
        var off = SandboxSettings()
        off.agentKeychain = false
        #expect(!SandboxPolicy.make(.agent(.claude), Self.context(off)).readWrite.contains(keychains))
        #expect(!SandboxPolicy.make(.build, Self.context()).readWrite.contains(keychains))
        #expect(!SandboxPolicy.make(.gitLocal, Self.context()).readWrite.contains(keychains))
        #expect(!SandboxPolicy.make(.agent(.opencode), Self.context()).readWrite.contains(keychains))
        #expect(SandboxPolicy.make(.gitNetwork, Self.context()).readWrite.contains(keychains))
    }

    @Test func gitNetworkHostsOnlyForTheNetworkStep() {
        let hosts = ["gitlab.example.test"]
        #expect(SandboxPolicy.make(.gitNetwork, Self.context(gitHosts: hosts)).domains.contains("gitlab.example.test"))
        #expect(!SandboxPolicy.make(.gitLocal, Self.context(gitHosts: hosts)).domains.contains("gitlab.example.test"))
        var ssh = SandboxSettings()
        ssh.gitSSH = false
        let noSSH = SandboxPolicy.make(.gitNetwork, Self.context(ssh))
        #expect(!noSSH.read.contains(Self.home + "/.ssh") && !noSSH.seatbeltRules.contains { $0.contains("*:22") })
    }

    @Test func credentialsAndUserRules() {
        var settings = SandboxSettings()
        settings.domains = ["api.example.test", "bad domain", "*.example.org"]
        settings.ports = [8080, 0, 70000]
        settings.folders = [.init(path: Self.home + "/shared", write: true), .init(path: Self.home + "/.ssh/keys"),
                            .init(path: Self.home + "/Library/Application Support/Hearth"), .init(path: "/etc")]
        settings.credentials = [
            .init(name: "GITHUB_TOKEN", mode: .proxy, upstream: "https://api.github.com"),
            .init(name: "PLAIN_KEY", mode: .env),
            .init(name: "INSECURE", mode: .proxy, upstream: "http://api.example.test"),
            .init(name: "NONO_EVIL", mode: .env),
            .init(name: "OFF_TOKEN", mode: .env, enabled: false),
        ]
        let p = SandboxPolicy.make(.build, Self.context(settings))
        #expect(p.domains.contains("api.example.test") && p.domains.contains("*.example.org") && !p.domains.contains("bad domain"))
        #expect(p.openPorts == [8080])
        #expect(p.readWrite.contains(Self.home + "/shared"))
        #expect(!p.read.contains(Self.home + "/.ssh/keys") && !p.readWrite.contains(Self.support) && !p.read.contains("/etc"),
                "Protected or outside folders granted")
        #expect(p.credentialRoutes.keys.sorted() == ["github_token"])
        #expect(p.credentialRoutes["github_token"]?["upstream"] == "https://api.github.com")
        #expect(p.envCredentials == ["hearth.plain_key": "PLAIN_KEY"])
        #expect(p.credentialFlags == ["--credential", "github_token"])
    }

    @Test func seatbeltStringsAreEscaped() {
        #expect(SandboxPolicy.sbString(#"/a "b" \c"#) == #""/a \"b\" \\c""#)
    }

    @Test func protectedFolders() {
        let h = Self.home, s = Self.support
        for bad in [s, s + "/agents/claude", h + "/Library", h + "/Library/LaunchAgents", h + "/.claude", h + "/.claude/projects",
                    h + "/.config", h + "/.config/opencode", h + "/.ssh", h + "/.aws/x", h + "/.zshrc"] {
            #expect(SandboxSettings.protectedReason(bad, home: h, support: s) != nil, "\(bad) accepted")
        }
        // Cloud drives inside ~/Library are documents, not settings; the rest of ~/Library stays blocked.
        let iCloud = h + "/Library/Mobile Documents"
        for bad in [iCloud, iCloud + "/iCloud~md~obsidian", iCloud + "/iCloud~md~obsidian/Library", h + "/Library/CloudStorage",
                    iCloud + "/com~apple~CloudDocs/../../Preferences"] {
            #expect(SandboxSettings.protectedReason(bad, home: h, support: s) != nil, "\(bad) accepted")
        }
        for ok in [h + "/code/project", h + "/Documents/notes", h + "/.local/share/x",
                   iCloud + "/com~apple~CloudDocs", iCloud + "/com~apple~CloudDocs/Lofi/2026 Reise Jakarta",
                   iCloud + "/iCloud~md~obsidian/Documents/Vault", h + "/Library/CloudStorage/Dropbox/project",
                   h + "/Library/CloudStorage/OneDrive-Personal"] {
            #expect(SandboxSettings.protectedReason(ok, home: h, support: s) == nil, "\(ok) rejected")
        }
        #expect(SandboxSettings.validFolder("/etc", home: h, support: s) != nil)
    }
}
