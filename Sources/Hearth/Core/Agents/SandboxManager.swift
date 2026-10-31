import Foundation

/// Runs agents inside a nono sandbox (Seatbelt on macOS). Writes one nono profile
/// per run and builds the command line; the terminal view starts the process.
enum SandboxManager {
    static let nonoVersion = "v0.80.0"

    /// Toolchains every agent may use to build and test the project (read-only grants).
    static let runtimeGroups = ["node_runtime", "bun_runtime", "python_runtime", "go_runtime", "go_runtime_macos",
                                "rust_runtime", "java_runtime", "git_config", "user_caches_macos"]

    enum Failure: LocalizedError {
        case nonoMissing
        case agentMissing(AgentKind)
        case outsideHome(String)

        var errorDescription: String? {
            switch self {
            case .nonoMissing:
                "nono wurde nicht gefunden. Im App-Bundle liegt es unter Contents/Helpers; für die Entwicklung scripts/fetch-nono.sh ausführen."
            case .agentMissing(let kind):
                "\(kind.displayName) ist nicht installiert (\(kind.executable) nicht im PATH)." + (kind.installHint.isEmpty ? "" : " Installation: \(kind.installHint)")
            case .outsideHome(let dir):
                "Der Ordner muss unterhalb deines Home-Verzeichnisses liegen: \(dir)"
            }
        }
    }

    // MARK: Locating tools

    /// nono: HEARTH_NONO_BIN, the app bundle, a development checkout's Vendor folder, then PATH.
    static func locateNono() -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let override = ProcessInfo.processInfo.environment["HEARTH_NONO_BIN"] { candidates.append(override) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/nono").path)
        // `swift run`: the executable lives in <repo>/.build/<config>/; walk up to the repo.
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<5 {
            guard let d = dir else { break }
            candidates.append(d.appendingPathComponent("Vendor/nono/\(nonoVersion)/nono").path)
            dir = d.deletingLastPathComponent()
        }
        candidates += searchPath.map { ($0 as NSString).appendingPathComponent("nono") }
        return candidates.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// PATH of the user's login shell (GUI apps start with a minimal PATH), plus common tool folders.
    static let searchPath: [String] = {
        var dirs: [String] = []
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            dirs = String(decoding: data, as: UTF8.self).split(separator: ":").map(String.init)
        }
        let home = NSHomeDirectory()
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin",
                 "\(home)/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }
    }()

    static func locate(_ kind: AgentKind) -> URL? {
        if kind == .shell { return URL(fileURLWithPath: "/bin/zsh") }
        return searchPath.map { URL(fileURLWithPath: $0).appendingPathComponent(kind.executable) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: Profile

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Hearth")
    }

    static func runDirectory(_ runID: String) -> URL {
        supportDirectory.appendingPathComponent("runs/\(runID)")
    }

    private static func expand(_ path: String) -> String {
        path.hasPrefix("~/") ? NSHomeDirectory() + path.dropFirst() : path
    }

    /// The nono profile for one run: nono's conservative default, the project folder
    /// read/write, toolchains read-only, the agent's own state, and only the hosts in
    /// nono's developer network profile plus the agent's API hosts.
    static func profile(kind: AgentKind, runDirectory: URL, extraDomains: [String] = [],
                        extraOpenPorts: [Int] = []) -> [String: Any] {
        let spec = kind.sandbox
        let fm = FileManager.default
        var allow = spec.readWrite.map(expand)
        allow.append(runDirectory.path)
        var filesystem: [String: Any] = [:]
        if spec.keychain {
            // Claude Code, Codex and Copilot keep their login in the login keychain.
            let keychains = expand("~/Library/Keychains")
            allow.append(keychains)
            filesystem["bypass_protection"] = [keychains]
        }
        for dir in spec.readWrite.map(expand) where !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        filesystem["allow"] = allow
        let files = spec.readWriteFiles.map(expand)
        if !files.isEmpty { filesystem["allow_file"] = files }
        if kind == .claude {
            // The user's own Claude hooks run inside the sandbox too: let them read their scripts.
            let scripts = userHookScripts()
            if !scripts.isEmpty { filesystem["read_file"] = scripts }
        }

        var network: [String: Any] = ["network_profile": "developer"]
        let domains = spec.domains + extraDomains
        if !domains.isEmpty { network["allow_domain"] = domains }
        let ports = spec.openPorts + extraOpenPorts
        if !ports.isEmpty { network["open_port"] = ports }

        var profile: [String: Any] = [
            "extends": "default",
            "meta": ["name": "hearth-\(kind.rawValue)", "description": "Hearth IDE: \(kind.displayName) (generated, do not edit)"],
            "groups": ["include": runtimeGroups + spec.groups],
            "workdir": ["access": "readwrite"],
            "filesystem": filesystem,
            "network": network,
        ]
        if !spec.openURLOrigins.isEmpty || spec.allowLocalhost {
            profile["open_urls"] = ["allow_origins": spec.openURLOrigins, "allow_localhost": spec.allowLocalhost]
        }
        if !spec.environment.isEmpty { profile["environment"] = ["set_vars": spec.environment] }
        return profile
    }

    /// Absolute script paths referenced by hooks in ~/.claude/settings.json (outside the home's
    /// denied areas), so status scripts like iTerm2's keep working in the sandbox.
    static func userHookScripts() -> [String] {
        let url = URL(fileURLWithPath: expand("~/.claude/settings.json"))
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return [] }
        var commands: [String] = []
        for case let groups as [[String: Any]] in hooks.values {
            for group in groups {
                for case let hook as [String: Any] in group["hooks"] as? [Any] ?? [] {
                    if let c = hook["command"] as? String { commands.append(c) }
                }
            }
        }
        let home = NSHomeDirectory()
        var paths = Set<String>()
        for command in commands {
            for token in command.split(whereSeparator: { $0 == " " || $0 == "'" || $0 == "\"" }) {
                let path = expand(String(token))
                guard path.hasPrefix(home + "/"), !path.contains("/.ssh"),
                      FileManager.default.isReadableFile(atPath: path) else { continue }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue { paths.insert(path) }
            }
        }
        return paths.sorted()
    }

    /// A currently free TCP port on 127.0.0.1.
    static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard ok else { throw POSIXError(.EADDRINUSE) }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// Starts `opencode serve` on the given port, waits until it listens, runs the client and
    /// stops the server when the client exits (ported from devkcode). Args: opencode, port, log, client args.
    static let openCodeLauncher = #"""
    set -eu
    oc="$1"; port="$2"; log="$3"; shift 3
    "$oc" serve --hostname 127.0.0.1 --port "$port" >"$log" 2>&1 &
    srv=$!
    trap 'kill "$srv" 2>/dev/null || true' EXIT
    trap 'exit 130' INT TERM HUP
    i=0
    until grep -q "server listening" "$log" 2>/dev/null; do
      if ! kill -0 "$srv" 2>/dev/null; then echo "OpenCode-Server konnte nicht starten:" >&2; cat "$log" >&2; exit 1; fi
      i=$((i + 1)); if [ "$i" -gt 300 ]; then echo "OpenCode-Server startet nicht (30 s)" >&2; exit 1; fi
      sleep 0.1
    done
    exec 3<&0
    "$oc" "$@" <&3 3<&- &
    cli=$!
    stop() {
      trap '' INT TERM HUP
      kill -TERM "$cli" 2>/dev/null || true
      (sleep 1; kill -KILL "$cli" 2>/dev/null) </dev/null >/dev/null 2>&1 &
      wait "$cli" || true
      exit 130
    }
    trap stop INT TERM HUP
    wait "$cli"
    """#

    // MARK: Launch

    struct Launch {
        let executable: String
        let arguments: [String]
        let environment: [String]
        let directory: String
    }

    /// Writes the profile (and status hooks) for `run` and returns how to start it.
    static func prepare(kind: AgentKind, runID: String, directory: String, agentArguments: [String],
                        statusHooks: Bool = true, openPorts extraPorts: [Int] = []) throws -> Launch {
        guard let nono = locateNono() else { throw Failure.nonoMissing }
        guard let agent = locate(kind) else { throw Failure.agentMissing(kind) }
        let home = NSHomeDirectory()
        let resolved = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        guard resolved.hasPrefix(home + "/") else { throw Failure.outsideHome(directory) }

        let runDir = runDirectory(runID)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        var args = agentArguments
        if statusHooks { args = try AgentStatusHooks.install(kind: kind, runDirectory: runDir) + args }
        var program = agent.path
        var openPorts: [Int] = extraPorts
        var extraEnv: [String: String] = [:]
        if kind == .opencode, args.first != "auth" {
            // OpenCode's clients attach to a shared background service on a fixed port (outside any
            // sandbox), and --standalone binds a random port nono can't allow without opening every
            // local port. Run a private server on one picked port, protected by a per-run password.
            let port = try freeLocalPort()
            openPorts.append(port)
            extraEnv["OPENCODE_SERVER_PASSWORD"] = UUID().uuidString + UUID().uuidString
            args = ["-c", openCodeLauncher, "hearth-opencode", agent.path, String(port),
                    runDir.appendingPathComponent("opencode-server.log").path,
                    "--server", "http://127.0.0.1:\(port)"] + args
            program = "/bin/sh"
        }

        let profileURL = runDir.appendingPathComponent("nono-profile.json")
        let data = try JSONSerialization.data(withJSONObject: profile(kind: kind, runDirectory: runDir, extraOpenPorts: openPorts),
                                              options: [.prettyPrinted, .sortedKeys])
        try data.write(to: profileURL, options: .atomic)

        var env = ProcessInfo.processInfo.environment
        // Never pass on state of an agent session Hearth itself was started from.
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("CLAUDE_AGENT_SDK")
            || key == "CODEX_SANDBOX" || key.hasPrefix("OPENCODE_") || key.hasPrefix("NONO_") {
            env[key] = nil
        }
        env["PATH"] = searchPath.joined(separator: ":")
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "hearth"
        env["HEARTH_RUN_ID"] = runID
        env["NONO_NO_UPDATE_CHECK"] = "1"
        env["NONO_NO_SAVE_PROMPT"] = "1"
        env["NONO_NO_PACK_UPDATE_HINTS"] = "1"
        if env["LANG"] == nil { env["LANG"] = "de_DE.UTF-8" }
        env.merge(extraEnv) { $1 }

        let nonoArgs = ["run", "--silent", "--profile", profileURL.path, "--allow-cwd", "--no-diagnostics",
                        "--log-file", runDir.appendingPathComponent("nono.log").path, "--", program] + args
        return Launch(executable: nono.path, arguments: nonoArgs,
                      environment: env.map { "\($0.key)=\($0.value)" }, directory: resolved)
    }
}

/// Status reporting from inside the sandbox: the agent appends one JSON line per
/// event to `<run>/events.jsonl` (the only Hearth path it may write); the app tails it.
enum AgentStatusHooks {
    static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
                               "Notification", "Stop", "SessionEnd"]

    /// Writes the hook script/settings and returns the extra agent arguments that enable them.
    static func install(kind: AgentKind, runDirectory: URL) throws -> [String] {
        let events = runDirectory.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: events.path) {
            FileManager.default.createFile(atPath: events.path, contents: nil)
        }
        switch kind.statusSource {
        case .hooks:
            // Hook input is one JSON object on stdin; newlines only occur as whitespace.
            let script = runDirectory.appendingPathComponent("hook.sh")
            try "#!/bin/sh\n{ /usr/bin/tr -d '\\n\\r'; echo; } >> \"$(dirname \"$0\")/events.jsonl\"\nexit 0\n"
                .write(to: script, atomically: true, encoding: .utf8)
            let command = "/bin/sh '\(script.path)'"
            var hooks: [String: Any] = [:]
            for event in claudeEvents {
                hooks[event] = [["hooks": [["type": "command", "command": command, "timeout": 5]]]]
            }
            let settings = runDirectory.appendingPathComponent("claude-settings.json")
            let data = try JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: settings, options: .atomic)
            return ["--settings", settings.path]
        case .notify:
            // Codex calls `notify` with the event JSON as the last argument after each turn.
            let script = runDirectory.appendingPathComponent("notify.sh")
            try "#!/bin/sh\nprintf '%s' \"$1\" | /usr/bin/tr -d '\\n\\r' >> \"$(dirname \"$0\")/events.jsonl\"; echo >> \"$(dirname \"$0\")/events.jsonl\"\nexit 0\n"
                .write(to: script, atomically: true, encoding: .utf8)
            return ["-c", "notify=[\"/bin/sh\",\"\(script.path)\"]"]
        case .terminal:
            return []
        }
    }
}
