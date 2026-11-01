import Foundation
import Security

/// The user's own sandbox rules, on top of Hearth's defaults. Stored in
/// ~/Library/Application Support/Hearth/settings.json and read by every sandbox
/// start (agents, Build & Deployment, Git). Never part of a repository, so an
/// agent cannot widen its own sandbox.
struct SandboxSettings: Codable, Equatable {
    struct Folder: Codable, Equatable, Hashable, Identifiable {
        var path: String
        var write = false
        var id: String { path }
    }

    /// Extra folders for sandboxes started in `root` (exactly that folder).
    struct Project: Codable, Equatable, Identifiable {
        var root: String
        var folders: [Folder] = []
        var id: String { root }
        var name: String { URL(fileURLWithPath: root).lastPathComponent }
    }

    /// A secret from the keychain (service "nono"), given to every sandbox.
    struct Credential: Codable, Equatable, Identifiable {
        enum Mode: String, Codable, CaseIterable { case proxy, env }
        /// Upper-case name, e.g. GITHUB_TOKEN; also the environment variable inside the sandbox.
        var name: String
        var mode: Mode = .proxy
        /// proxy: the API origin the secret is sent to, e.g. https://api.github.com
        var upstream: String = ""
        var header: String = "Authorization"
        /// `{}` is replaced by the secret.
        var format: String = "Bearer {}"
        var enabled = true
        var id: String { name }

        var keychainAccount: String { "hearth." + name.lowercased() }
        var routeName: String { name.lowercased() }
        /// Sandbox variable with the proxy address (nono's naming: route name + _BASE_URL).
        var baseURLVariable: String { name.uppercased() + "_BASE_URL" }

        static func validName(_ name: String) -> Bool {
            name.range(of: #"^[A-Z][A-Z0-9_]{1,63}$"#, options: .regularExpression) != nil && !name.hasPrefix("NONO_")
        }
    }

    var domains: [String] = []
    var ports: [Int] = []
    var folders: [Folder] = []
    var projects: [Project] = []
    var credentials: [Credential] = []
    /// Claude Code, Codex and Copilot keep their login in the keychain.
    var agentKeychain = true
    /// Git pane over SSH: read ~/.ssh, write known_hosts, TCP port 22.
    var gitSSH = true

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        ports = try c.decodeIfPresent([Int].self, forKey: .ports) ?? []
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        projects = try c.decodeIfPresent([Project].self, forKey: .projects) ?? []
        credentials = try c.decodeIfPresent([Credential].self, forKey: .credentials) ?? []
        agentKeychain = try c.decodeIfPresent(Bool.self, forKey: .agentKeychain) ?? true
        gitSSH = try c.decodeIfPresent(Bool.self, forKey: .gitSSH) ?? true
    }

    func project(for root: String) -> Project? {
        let resolved = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        return projects.first { URL(fileURLWithPath: $0.root).resolvingSymlinksInPath().standardizedFileURL.path == resolved }
    }

    // MARK: Storage

    static var url: URL { SandboxManager.supportDirectory.appendingPathComponent("settings.json") }

    static func load() -> SandboxSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(SandboxSettings.self, from: data) else { return SandboxSettings() }
        return settings
    }

    func save() throws {
        try FileManager.default.createDirectory(at: SandboxManager.supportDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url, options: .atomic)
    }

    // MARK: Validation

    /// A hostname, `*.suffix` or an https URL with a path glob, as nono accepts them.
    static func validDomain(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !v.contains(" ") else { return false }
        if v.hasPrefix("https://") { return URL(string: v)?.host?.contains(".") == true }
        return v.range(of: #"^(\*\.)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    /// Extra folders from the settings: below home, never a protected area (see `protectedReason`).
    static func validFolder(_ path: String, home: String = NSHomeDirectory(),
                            support: String = SandboxManager.supportDirectory.path) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        guard resolved.hasPrefix(home + "/") else { return String(localized: "Only folders inside your home folder.") }
        return protectedReason(resolved, home: home, support: support)
    }

    /// Why a folder must not be given to a sandbox, or nil. Covers the folder itself, anything
    /// inside a protected area and any folder that contains one.
    static func protectedReason(_ resolved: String, home: String, support: String) -> String? {
        let credentials = ["/.ssh", "/.gnupg", "/.aws", "/Library/Keychains", "/Library/Cookies"].map { home + $0 }
        // Hearth's own settings and agent homes, autostart, agent and shell configuration.
        let configuration = [support, home + "/Library", home + "/.claude", home + "/.claude.json", home + "/.codex",
                             home + "/.gemini", home + "/.copilot", home + "/.config",
                             home + "/.zshrc", home + "/.zprofile", home + "/.bashrc", home + "/.bash_profile", home + "/.profile"]
        func overlaps(_ protected: String) -> Bool {
            resolved == protected || resolved.hasPrefix(protected + "/") || protected.hasPrefix(resolved + "/")
        }
        if credentials.contains(where: overlaps) { return String(localized: "This folder contains credentials and stays blocked.") }
        if configuration.contains(where: overlaps) {
            return String(localized: "This folder contains settings of Hearth, macOS or an agent and stays blocked.")
        }
        return nil
    }
}

/// Secrets for nono live in the login keychain under service "nono"; nono reads them
/// itself when a sandbox starts. Hearth only writes and deletes them.
enum CredentialKeychain {
    static let service = "nono"

    static func store(_ secret: String, account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrLabel as String] = "Hearth IDE: \(account)"
        // Let the bundled nono read it without a keychain prompt (nono is Developer-ID signed).
        if let nono = SandboxManager.locateNono() {
            var apps: [SecTrustedApplication] = []
            var app: SecTrustedApplication?
            if SecTrustedApplicationCreateFromPath(nono.path, &app) == errSecSuccess, let app { apps.append(app) }
            var access: SecAccess?
            if !apps.isEmpty, SecAccessCreate("Hearth IDE: \(account)" as CFString, apps as CFArray, &access) == errSecSuccess, let access {
                add[kSecAttrAccess as String] = access
            }
        }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func exists(account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnAttributes as String: true]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
