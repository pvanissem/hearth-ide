import Foundation

/// Thin wrapper around the installed `devkcode` binary. The app never
/// re-implements sandbox logic; it only invokes the CLI.
struct DevkCLI: Sendable {
    let executable: URL

    static func locate() -> DevkCLI? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let override = env["HEARTH_DEVKCODE_BIN"] { candidates.append(override) }
        // GUI apps get a minimal PATH, so also check common install locations.
        candidates += (env["PATH"] ?? "").split(separator: ":").map { "\($0)/devkcode" }
        candidates += ["/usr/local/bin/devkcode", "/opt/homebrew/bin/devkcode",
                       NSHomeDirectory() + "/.local/bin/devkcode"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return DevkCLI(executable: URL(fileURLWithPath: path))
        }
        return nil
    }

    struct Result: Sendable {
        let status: Int32
        let output: String
    }

    func run(_ args: [String], in directory: String, environment: [String: String] = [:]) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = await Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(decoding: data, as: UTF8.self))
    }

    /// `profile` is applied for this start only via DEVKCODE_CONFIG (devkcode's own override).
    func startWeb(repoRoot: String, project: String?, profile: String? = nil) async throws -> Result {
        var args = ["web", "--no-open"]
        if let project { args += ["--project", project] }
        return try await run(args, in: repoRoot, environment: profile.map { ["DEVKCODE_CONFIG": $0] } ?? [:])
    }

    func stopWeb(repoRoot: String) async throws -> Result {
        try await run(["web", "--stop"], in: repoRoot)
    }
}
