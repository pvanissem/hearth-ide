import Foundation

/// Read-only view on devkcode's personal configuration files below
/// ~/.local/share/devkcode. All *changes* go through the devkcode CLI.
struct DevkProfile: Identifiable, Hashable, Sendable {
    let name: String
    let description: String?
    var id: String { name }
}

struct DevkProject: Identifiable, Hashable, Sendable {
    struct Dir: Hashable, Sendable {
        let path: String
        let write: Bool
    }
    let id: String
    let name: String
    let root: String
    let extraDirs: [Dir]
}

struct DevkCredential: Identifiable, Hashable, Sendable {
    let name: String
    let description: String?
    let mode: String
    let upstream: String?
    var id: String { name }
}

struct DevkMCPServer: Identifiable, Hashable, Sendable {
    let name: String
    let type: String
    let command: String?
    let url: String?
    let enabled: Bool
    var id: String { name }
}

struct DevkConfigSnapshot: Sendable {
    var activeProfile: String?
    var projects: [DevkProject] = []
    var rememberedProjects: [String: String] = [:]
    var allowDomains: [String] = []
    var openPorts: [Int] = []
    var credentials: [DevkCredential] = []
    var mcpServers: [DevkMCPServer] = []
}

enum DevkConfig {
    static var baseDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/devkcode")
    }

    private static func json(_ file: String) -> JSON? {
        guard let data = try? Data(contentsOf: baseDir.appendingPathComponent(file)) else { return nil }
        return JSON.parse(data)
    }

    static func load() -> DevkConfigSnapshot {
        var s = DevkConfigSnapshot()
        s.activeProfile = (try? String(contentsOf: baseDir.appendingPathComponent("active-profile"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = json("projects.json") {
            s.projects = p["projects"]?.array.compactMap { j in
                guard let id = j["id"]?.string, let name = j["name"]?.string, let root = j["root"]?.string else { return nil }
                let dirs = j["extraDirs"]?.array.compactMap { d -> DevkProject.Dir? in
                    guard let path = d["path"]?.string else { return nil }
                    return DevkProject.Dir(path: path, write: d["access"]?.string == "write")
                } ?? []
                return DevkProject(id: id, name: name, root: root, extraDirs: dirs)
            }.sorted { $0.name.lowercased() < $1.name.lowercased() } ?? []
        }
        if let a = json("active-projects.json") {
            s.rememberedProjects = a["selections"]?.object.compactMapValues(\.string) ?? [:]
        }
        if let n = json("network-overrides.json") {
            s.allowDomains = n["allowDomain"]?.array.compactMap(\.string) ?? []
            s.openPorts = n["openPort"]?.array.compactMap { $0.double.map(Int.init) } ?? []
        }
        if let c = json("credentials.json") {
            s.credentials = c["credentials"]?.object.map { name, v in
                DevkCredential(name: name, description: v["description"]?.string,
                               mode: v["mode"]?.string ?? "env", upstream: v["httpProxy"]?["upstream"]?.string)
            }.sorted { $0.name < $1.name } ?? []
        }
        if let m = json("mcp-servers.json") {
            s.mcpServers = m["servers"]?.object.map { name, v in
                DevkMCPServer(name: name, type: v["type"]?.string ?? "?",
                              command: v["command"]?.array.compactMap(\.string).joined(separator: " "),
                              url: v["url"]?.string, enabled: v["enabled"] != .bool(false))
            }.sorted { $0.name < $1.name } ?? []
        }
        return s
    }

    /// Profile list including descriptions. devkcode only prints descriptions in its
    /// interactive picker, so we run it in a pseudo-terminal and stop before choosing.
    static func profiles(cli: DevkCLI) async -> [DevkProfile] {
        if let listed = await interactiveList(cli: cli), !listed.isEmpty { return listed }
        // Fallback: names from the "Available: …" error of an unknown profile (changes nothing).
        let r = try? await cli.run(["profile", "__hearth_probe__"], in: NSTemporaryDirectory())
        guard let out = r?.output.strippingANSI, let range = out.range(of: "Available: ") else { return [] }
        return out[range.upperBound...].split(separator: "\n")[0].split(separator: ",")
            .map { DevkProfile(name: $0.trimmingCharacters(in: .whitespaces), description: nil) }
    }

    private static func interactiveList(cli: DevkCLI) async -> [DevkProfile]? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            p.arguments = ["-q", "/dev/null", cli.executable.path, "profile"]
            p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
            let input = Pipe()   // kept open: EOF would make devkcode error out early
            let output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = output
            do { try p.run() } catch { return nil }
            var data = Data()
            let deadline = Date().addingTimeInterval(8)
            let handle = output.fileHandleForReading
            while Date() < deadline {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                if String(decoding: data, as: UTF8.self).contains("(Nummer oder Name)") { break }
            }
            p.terminate()
            try? input.fileHandleForWriting.close()
            let text = String(decoding: data, as: UTF8.self).strippingANSI
            let regex = try! NSRegularExpression(pattern: #"^\s*\d+\)\s+(\S+)(?:\s+-\s+(.*))?$"#, options: .anchorsMatchLines)
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
                let name = ns.substring(with: m.range(at: 1))
                let desc = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : nil
                return DevkProfile(name: name, description: desc?.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }.value
    }
}

extension String {
    var strippingANSI: String {
        replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[A-Za-z]|\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }
}
