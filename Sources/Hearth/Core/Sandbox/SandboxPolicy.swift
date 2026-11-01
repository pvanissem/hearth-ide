import Foundation

/// What a sandbox is for. Every nono profile Hearth writes comes from exactly one purpose,
/// so the rights of each kind of process are defined in one place and covered by tests.
enum SandboxPurpose: Equatable {
    /// An agent session (or its login).
    case agent(AgentKind)
    /// Build & Deployment tasks and services.
    case build
    /// Git fetch/clone: may read SSH keys, use the keychain and reach the remote over SSH.
    case gitNetwork
    /// Git fast-forward after a fetch: no keys, no keychain (repository filters run here).
    case gitLocal

    var isAgent: Bool {
        if case .agent = self { return true }
        return false
    }

    var kind: AgentKind {
        if case .agent(let kind) = self { return kind }
        return .shell
    }
}

/// Everything that varies between machines and runs. Kept out of the policy itself so
/// the same inputs always give the same profile (see SandboxPolicyTests).
struct SandboxContext: Equatable {
    var home: String
    var support: String
    var runDirectory: String
    var workdir: String?
    var settings: SandboxSettings
    /// Script files referenced by the agent's own hooks (read-only).
    var hookScripts: [String] = []
    /// Hosts of the repository's remotes (Git network only).
    var gitHosts: [String] = []
    var extraDomains: [String] = []
    var extraPorts: [Int] = []
}

/// Resolved rights of one sandbox; `profile` turns them into nono's JSON.
struct SandboxPolicy: Equatable {
    var readWrite: [String] = []
    var read: [String] = []
    var readWriteFiles: [String] = []
    var readFiles: [String] = []
    var bypassProtection: [String] = []
    var groups: [String] = []
    var domains: [String] = []
    var openPorts: [Int] = []
    var envCredentials: [String: String] = [:]
    var credentialRoutes: [String: [String: String]] = [:]
    var openURLOrigins: [String] = []
    var allowLocalhostURLs = false
    var environment: [String: String] = [:]
    var seatbeltRules: [String] = []
    var name: String
    var description: String

    /// Toolchains every sandbox may use to build and test the project (read-only grants).
    static let runtimeGroups = ["node_runtime", "bun_runtime", "python_runtime", "go_runtime", "go_runtime_macos",
                                "rust_runtime", "java_runtime", "git_config", "user_caches_macos"]

    static func make(_ purpose: SandboxPurpose, _ c: SandboxContext) -> SandboxPolicy {
        let kind = purpose.kind
        let spec = kind.sandbox
        let agentHome = AgentHome.layout(for: kind, support: c.support, home: c.home)
        let keychains = c.home + "/Library/Keychains"
        var p = SandboxPolicy(name: "hearth-\(Self.slug(purpose))",
                              description: "Hearth IDE: \(Self.title(purpose)) (generated, do not edit)")
        p.groups = runtimeGroups + spec.groups

        // Files: the run folder, the agent's private home (or its own folder), read-only links.
        p.readWrite = [c.runDirectory]
        if let root = agentHome.root { p.readWrite.append(root) }
        p.readWrite += agentHome.hostReadWrite
        p.read += agentHome.linkTargets
        if spec.keychain && c.settings.agentKeychain {
            // Claude Code, Codex and Copilot keep their login in the login keychain.
            p.readWrite.append(keychains)
            p.bypassProtection.append(keychains)
        }
        // The user's extra folders: everywhere, and for this project folder.
        var folders = c.settings.folders
        if let dir = c.workdir, let project = c.settings.project(for: dir) { folders += project.folders }
        for folder in folders where SandboxSettings.validFolder(folder.path, home: c.home, support: c.support) == nil {
            if folder.write { p.readWrite.append(folder.path) } else { p.read.append(folder.path) }
        }
        p.readFiles = c.hookScripts

        // Git network: SSH keys (read), known_hosts, keychain for HTTPS logins, port 22.
        if purpose == .gitNetwork {
            if c.settings.gitSSH {
                let ssh = c.home + "/.ssh"
                p.read.append(ssh)
                p.bypassProtection.append(ssh)
                p.readWriteFiles.append(ssh + "/known_hosts")
                p.seatbeltRules.append(#"(allow network-outbound (remote tcp "*:22"))"#)
            }
            if !p.readWrite.contains(keychains) { p.readWrite.append(keychains) }
            if !p.bypassProtection.contains(keychains) { p.bypassProtection.append(keychains) }
        }

        // Network: nono's developer profile, the agent's API hosts, the user's additions.
        p.domains = spec.domains + c.extraDomains + c.settings.domains.filter(SandboxSettings.validDomain)
        if purpose == .gitNetwork { p.domains += c.gitHosts }
        p.openPorts = Array(Set(spec.openPorts + c.extraPorts + c.settings.ports.filter { (1...65535).contains($0) })).sorted()

        // Credentials: proxy routes (the sandbox only sees a placeholder token) or plain env.
        for cred in c.settings.credentials where cred.enabled && SandboxSettings.Credential.validName(cred.name) {
            switch cred.mode {
            case .env:
                p.envCredentials[cred.keychainAccount] = cred.name
            case .proxy:
                guard URL(string: cred.upstream)?.scheme == "https" else { continue }
                p.credentialRoutes[cred.routeName] = [
                    "upstream": cred.upstream, "credential_key": cred.keychainAccount, "env_var": cred.name,
                    "inject_mode": "header", "inject_header": cred.header.isEmpty ? "Authorization" : cred.header,
                    "credential_format": cred.format.contains("{}") ? cred.format : "{}",
                ]
            }
        }

        p.openURLOrigins = spec.openURLOrigins
        p.allowLocalhostURLs = spec.allowLocalhost
        p.environment = spec.environment.merging(agentHome.environment) { $1 }

        // Build tools: the user's caches (~/.m2, ~/.npm, ~/.gradle) are read-only in the
        // sandbox, so Maven, Gradle and npm write into a private cache instead and still
        // reuse what the host already downloaded.
        if purpose == .build || purpose.isAgent {
            // JDKs installed per user (IntelliJ, SDKMAN) and Gradle's download cache, read-only.
            p.read += [c.home + "/Library/Java/JavaVirtualMachines", c.home + "/.sdkman/candidates",
                       c.home + "/.gradle/caches"]
            p.environment.merge(Self.buildToolEnvironment(home: c.home)) { current, _ in current }
        }

        // Write protection: files on the host that run commands outside the sandbox.
        let protectedFiles = agentHome.writeProtectedFiles
        var protectedFolders = agentHome.writeProtectedFolders
        if let dir = c.workdir { protectedFolders.append(dir + "/.git/hooks") }
        p.seatbeltRules += protectedFiles.map { "(deny file-write* (literal \(Self.sbString($0))))" }
        p.seatbeltRules += protectedFolders.flatMap {
            ["(deny file-write* (literal \(Self.sbString($0))))", "(deny file-write* (subpath \(Self.sbString($0))))"]
        }

        p.readWrite = Self.unique(p.readWrite)
        p.read = Self.unique(p.read)
        p.bypassProtection = Self.unique(p.bypassProtection).sorted()
        return p
    }

    /// nono's profile JSON.
    var profile: [String: Any] {
        var filesystem: [String: Any] = ["allow": readWrite]
        if !read.isEmpty { filesystem["read"] = read }
        if !readWriteFiles.isEmpty { filesystem["allow_file"] = readWriteFiles }
        if !readFiles.isEmpty { filesystem["read_file"] = readFiles }
        if !bypassProtection.isEmpty { filesystem["bypass_protection"] = bypassProtection }

        var network: [String: Any] = ["network_profile": "developer"]
        if !domains.isEmpty { network["allow_domain"] = domains }
        if !openPorts.isEmpty { network["open_port"] = openPorts }
        if !credentialRoutes.isEmpty {
            network["credentials"] = credentialRoutes.keys.sorted()
            network["custom_credentials"] = credentialRoutes
        }

        var profile: [String: Any] = [
            "extends": "default",
            "meta": ["name": name, "description": description],
            "groups": ["include": groups],
            "workdir": ["access": "readwrite"],
            "filesystem": filesystem,
            "network": network,
        ]
        if !envCredentials.isEmpty { profile["env_credentials"] = envCredentials }
        if !openURLOrigins.isEmpty || allowLocalhostURLs {
            profile["open_urls"] = ["allow_origins": openURLOrigins, "allow_localhost": allowLocalhostURLs]
        }
        if !environment.isEmpty { profile["environment"] = ["set_vars": environment] }
        if !seatbeltRules.isEmpty { profile["unsafe_macos_seatbelt_rules"] = seatbeltRules }
        return profile
    }

    var profileData: Data {
        (try? JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// `--credential` flags that activate the profile's proxy routes.
    var credentialFlags: [String] { credentialRoutes.keys.sorted().flatMap { ["--credential", $0] } }

    /// Private caches for build tools, under ~/Library/Caches (writable via user_caches_macos).
    /// Maven ≥ 3.9 reads the host's ~/.m2/repository as a read-only "tail"; Gradle uses
    /// ~/.gradle/caches as its read-only dependency cache.
    static func buildToolEnvironment(home: String) -> [String: String] {
        let cache = home + "/Library/Caches/Hearth"
        return [
            "MAVEN_ARGS": "-Dmaven.repo.local=\(cache)/m2/repository -Dmaven.repo.local.tail=\(home)/.m2/repository",
            "GRADLE_USER_HOME": cache + "/gradle",
            "GRADLE_RO_DEP_CACHE": home + "/.gradle/caches",
            "npm_config_cache": cache + "/npm",
        ]
    }

    // MARK: Helpers

    /// A Seatbelt string literal.
    static func sbString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func slug(_ purpose: SandboxPurpose) -> String {
        switch purpose {
        case .agent(let kind): kind.rawValue
        case .build: "build"
        case .gitNetwork: "git-network"
        case .gitLocal: "git-local"
        }
    }

    private static func title(_ purpose: SandboxPurpose) -> String {
        switch purpose {
        case .agent(let kind): kind.displayName
        case .build: "Build & Deployment"
        case .gitNetwork: String(localized: "Git (network)")
        case .gitLocal: String(localized: "Git (local)")
        }
    }
}
