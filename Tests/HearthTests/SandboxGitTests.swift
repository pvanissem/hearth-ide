import Foundation
import Testing
@testable import Hearth

@MainActor
struct SandboxGitTests {
    @Test func operationsRunOnlyInTheSandbox() async throws {
        let root = URL(fileURLWithPath: "/workspace/repository")
        let api = FakeCommandRunner()
        var runner = SandboxGitRunner(runner: api, root: root, repoOverrides: ["-c", "filter.lfs.smudge="])
        runner.pollInterval = .milliseconds(1)
        for operation in [SandboxGitOperation.fetch, .fetchUpstream, .fastForward, .clone("https://git.example.test/group/repo.git")] {
            api.reset([.output("Receiving objects: 50%\r"), .output("Done\n"), .exit(0)])
            let result = await runner.run(operation)
            try require(result.ok && result.output.contains("Done"), "Sandbox Git \(operation.name) did not finish/drain output: \(result.output)")
            let request = try need(api.requests.first)
            try require(api.requests.count == 1, "More than one command for \(operation.name)")
            try require(request.command == (try operation.command(repoOverrides: runner.repoOverrides)), "Unexpected command")
            try require(request.cwd == root.path, "Wrong command directory")
            try require(request.command.contains("core.hooksPath=/dev/null") && request.command.contains("core.fsmonitor=false"), "Unsafe hook policy")
            try require(api.removed.count == 1, "Finished command not removed")
        }

        // Failing start: reported, never retried elsewhere.
        api.reset([])
        api.failStart = true
        let refused = await runner.run(.fetch)
        try require(!refused.ok && refused.output.contains("Nothing was run on the host"), "Start failure fell back somewhere")
        try require(api.requests.count == 1, "Failed start retried")

        // Timeout stops the command in the sandbox.
        api.reset([.running])
        runner.timeout = 0
        let timeout = await runner.run(.fetch)
        try require(!timeout.ok && api.removed.count == 1, "Timeout did not remove the command")

        for url in ["http://git.example.test/g/r", "https://token@git.example.test/g/r", "ext::sh -c bad", "-u bad",
                    "ssh://git:password@git.example.test/g/r", "https://git.example.test/g/r\nmalicious"] {
            try require(!SandboxGitOperation.validCloneURL(url), "Unsafe clone URL accepted: \(url)")
        }
        let quoted = SandboxGitOperation.quote("a'b;$(touch /not-executed)")
        try require(quoted == "'a'\\''b;$(touch /not-executed)'", "Shell quoting regression")
        try require(SandboxGitOperation.validCloneURL("git@git.example.test:group/repo.git"), "SSH clone rejected")
    }

    @Test func pullIsSplitByRights() throws {
        // Network steps may use SSH keys; the fast-forward that checks files out may not.
        try require(SandboxGitOperation.fetchUpstream.needsNetwork && SandboxGitOperation.fetch.needsNetwork, "Fetch needs network")
        try require(!SandboxGitOperation.fastForward.needsNetwork, "Fast-forward must run without network rights")
        let merge = try SandboxGitOperation.fastForward.command()
        try require(merge.contains("'merge' '--ff-only'") && !merge.contains("sshCommand") && !merge.contains("credential"), "Fast-forward command")
        try require(!(try SandboxGitOperation.fetchUpstream.command()).contains("pull"), "Network step must not check out files")
    }

    @Test func repositoryHelpersAreNeutralisedForNetworkSteps() throws {
        let keys = ["filter.lfs.smudge", "filter.lfs.required", "Filter.X.Process", "credential.https://evil.example.helper",
                    "credential.helper", "credential.username", "core.askPass", "core.sshCommand", "url.x.insteadOf", "user.name"]
        let overrides = Git.networkSandboxOverrides(forKeys: keys)
        let pairs = stride(from: 1, to: overrides.count, by: 2).map { overrides[$0] }
        for expected in ["filter.lfs.smudge=", "filter.lfs.required=false", "Filter.X.Process=", "credential.https://evil.example.helper=",
                         "credential.helper=", "core.askPass=", "core.sshCommand="] {
            try require(pairs.contains(expected), "Not neutralised: \(expected) in \(pairs)")
        }
        try require(!pairs.contains { $0.hasPrefix("user.") || $0.hasPrefix("url.") || $0.hasPrefix("credential.username") }, "Harmless keys touched")
    }

    /// S1: with a real repository whose config defines a smudge filter, the network step
    /// (as Hearth builds it) does not run the filter, and the overrides cover URL-scoped helpers.
    @Test func networkStepNeverRunsRepositoryFilters() throws {
        let dir = try temporaryFolder("hearth-git")
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("FILTER_RAN").path
        func git(_ args: [String], in folder: URL) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-c", "user.email=t@example.test", "-c", "user.name=t", "-c", "protocol.file.allow=always"] + args
            p.currentDirectoryURL = folder
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            try require(p.terminationStatus == 0, "git \(args.joined(separator: " ")) failed")
        }
        let upstream = dir.appendingPathComponent("up"), work = dir.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "main"], in: upstream)
        try git(["commit", "-q", "--allow-empty", "-m", "init"], in: upstream)
        try git(["clone", "-q", upstream.path, work.path], in: dir)
        try "new\n".write(to: upstream.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git(["add", "a.txt"], in: upstream)
        try git(["commit", "-q", "-m", "add"], in: upstream)
        // What an agent could write into its project:
        try "* filter=evil\n".write(to: work.appendingPathComponent(".git/info/attributes"), atomically: true, encoding: .utf8)
        try git(["config", "filter.evil.smudge", "sh -c 'touch \(marker); cat'"], in: work)
        try git(["config", "credential.https://evil.example.helper", "!touch \(marker)"], in: work)

        let overrides = try need(Git.networkSandboxOverrides(in: work.path), "Config not readable")
        try require(overrides.contains("filter.evil.smudge=") && overrides.contains("credential.https://evil.example.helper="), "Overrides missing: \(overrides)")
        // Run the network step's git command directly (outside nono, local upstream allowed for the test).
        let command = try SandboxGitOperation.fetchUpstream.command(repoOverrides: overrides)
            .replacingOccurrences(of: "'protocol.file.allow=never'", with: "'protocol.file.allow=always'")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = work
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        try require(p.terminationStatus == 0, "fetch failed")
        try require(!FileManager.default.fileExists(atPath: marker), "Repository filter/helper ran during the network step")
    }
}
