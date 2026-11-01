import Foundation

/// The agent CLIs Hearth can run in a sandbox. Each brings its own login; Hearth
/// only grants the paths and hosts that agent needs.
enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, copilot, opencode, gemini, shell

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .copilot: "GitHub Copilot CLI"
        case .opencode: "OpenCode"
        case .gemini: "Gemini CLI"
        case .shell: "Sandbox-Shell"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .copilot: "person.2.wave.2"
        case .opencode: "curlybraces"
        case .gemini: "diamond"
        case .shell: "terminal"
        }
    }

    /// Executable looked up on the login shell's PATH.
    var executable: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .copilot: "copilot"
        case .opencode: "opencode"
        case .gemini: "gemini"
        case .shell: "zsh"
        }
    }

    var installHint: String {
        switch self {
        case .claude: "npm install -g @anthropic-ai/claude-code"
        case .codex: "npm install -g @openai/codex"
        case .copilot: "npm install -g @github/copilot"
        case .opencode: "brew install opencode"
        case .gemini: "npm install -g @google/gemini-cli"
        case .shell: ""
        }
    }

    /// How the agent tells Hearth that it is working, waiting or finished.
    enum StatusSource { case hooks, notify, terminal }

    var statusSource: StatusSource {
        switch self {
        case .claude: .hooks
        case .codex: .notify
        default: .terminal
        }
    }

    /// Arguments for a fresh session, or one continuing `sessionID` when the agent supports it.
    func arguments(resume sessionID: String?) -> [String] {
        switch self {
        case .claude: sessionID.map { ["--resume", $0] } ?? []
        case .codex: sessionID.map { ["resume", $0] } ?? []
        case .opencode: sessionID.map { ["--session", $0] } ?? []
        case .shell: ["-f", "-i"]   // no rc files: shell configs are denied inside the sandbox anyway
        default: []
        }
    }

    /// Arguments that start the agent's own login flow (nil: log in from inside the agent).
    var loginArguments: [String]? {
        switch self {
        case .claude: ["auth", "login"]
        case .codex: ["login"]
        case .opencode: ["auth", "login"]
        default: nil
        }
    }

    var loginHint: String {
        switch self {
        case .claude: "Startet „claude auth login“ in der Sandbox. Alternativ in einer Sitzung /login eingeben."
        case .codex: "Startet „codex login“ in der Sandbox."
        case .copilot: "In einer Sitzung /login eingeben."
        case .opencode: "Startet „opencode auth login“ und fragt nach dem Anbieter."
        case .gemini: "Beim ersten Start fragt Gemini nach der Anmeldung."
        case .shell: ""
        }
    }

    var sandbox: AgentSandboxSpec {
        switch self {
        case .claude:
            AgentSandboxSpec(groups: ["claude_code_macos"],
                             domains: ["statsig.anthropic.com", "console.anthropic.com"],
                             keychain: true,
                             openURLOrigins: ["https://claude.ai", "https://platform.claude.com", "https://console.anthropic.com"],
                             environment: ["DISABLE_AUTOUPDATER": "1"])
        case .codex:
            AgentSandboxSpec(groups: ["codex_macos"],
                             domains: ["chatgpt.com", "auth.openai.com", "ab.chatgpt.com"],
                             keychain: true,
                             openURLOrigins: ["https://auth.openai.com", "https://chatgpt.com"],
                             allowLocalhost: true, openPorts: [1455])
        case .copilot:
            AgentSandboxSpec(domains: ["api.githubcopilot.com", "api.individual.githubcopilot.com",
                                       "api.business.githubcopilot.com", "api.enterprise.githubcopilot.com",
                                       "copilot-proxy.githubusercontent.com", "telemetry.individual.githubcopilot.com",
                                       "origin-tracker.githubusercontent.com"],
                             keychain: true,
                             openURLOrigins: ["https://github.com"])
        case .opencode:
            AgentSandboxSpec(domains: ["models.dev", "opencode.ai", "api.githubcopilot.com", "api.individual.githubcopilot.com"],
                             openURLOrigins: ["https://github.com", "https://opencode.ai"],
                             environment: ["OPENCODE_DISABLE_AUTOUPDATE": "1"])
        case .gemini:
            AgentSandboxSpec(domains: ["cloudcode-pa.googleapis.com", "oauth2.googleapis.com", "www.googleapis.com",
                                       "accounts.google.com", "play.googleapis.com"],
                             openURLOrigins: ["https://accounts.google.com"], allowLocalhost: true)
        case .shell:
            AgentSandboxSpec()
        }
    }
}

/// What one agent needs on top of Hearth's base sandbox (project folder, toolchains).
/// Its configuration folder comes from AgentHome.
struct AgentSandboxSpec: Sendable {
    var groups: [String] = []
    var domains: [String] = []
    /// Login keychain access (Claude Code, Codex and Copilot keep their login there).
    var keychain = false
    var openURLOrigins: [String] = []
    var allowLocalhost = false
    var openPorts: [Int] = []
    var environment: [String: String] = [:]
}
