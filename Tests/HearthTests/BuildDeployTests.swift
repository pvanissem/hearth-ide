import Foundation
import Testing
@testable import Hearth

@MainActor
@Suite(.serialized)
struct BuildDeployTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-build-\(UUID().uuidString)")
        func write(_ path: String, _ text: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("pom.xml", """
        <project><parent><artifactId>spring-boot-starter-parent</artifactId></parent>
        <artifactId>shop</artifactId><packaging>pom</packaging>
        <modules><module>api</module><module>lib</module><module>../escape</module></modules>
        <profiles><profile><id>local</id></profile><profile><id>it</id></profile><profile><id>bad;rm</id></profile></profiles>
        <!-- <module>commented</module> --></project>
        """)
        try write("mvnw", "#!/bin/sh\n")
        try write("api/pom.xml", "<project><artifactId>api</artifactId><build><plugins><plugin><artifactId>spring-boot-maven-plugin</artifactId></plugin></plugins></build><dependency>spring-boot-starter-actuator</dependency></project>")
        try write("api/src/main/resources/application.yml", "spring:\n  application:\n    name: api\nserver:\n  servlet:\n    context-path: /\n  port: 8081\n")
        try write("lib/pom.xml", "<project><artifactId>lib</artifactId></project>")
        try write("frontend/package.json", #"{"name":"web","scripts":{"dev":"vite","build":"vite build","lint":"eslint .","evil name":"x"}}"#)
        try write("frontend/pnpm-lock.yaml", "lockfileVersion: 9\n")
        try write("tools/go.mod", "module tools\n")
        try write("tools/cmd/server/main.go", "package main\nimport \"net/http\"\nfunc main(){ http.ListenAndServe(\":9090\", nil) }\n")
        try write("tools/cmd/server/main_test.go", "package main\n")
        try write("Makefile", ".PHONY: run\nVAR := 1\nbuild:\n\techo\nrun: build\n\techo\n%.o: %.c\n")
        try write(".hearth/tasks.json", #"{"tasks":[{"name":"Docs","command":"echo docs"},{"name":"Bad","command":"x","cwd":"../outside"},{"name":"Svc","command":"java -jar app.jar","service":true,"port":7070,"health":"/../etc"}]}"#)
        try write("node_modules/x/package.json", #"{"scripts":{"hidden":"x"}}"#)
        return root
    }

    @Test func detectsProjectsAndServices() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = BuildDetector.scan(root: root.path)
        let rootProject = projects.first { $0.path == "" }
        try require(rootProject?.name == "shop" && rootProject?.tools.contains(.maven) == true, "Maven root not detected")
        try require(rootProject?.profiles == ["it", "local"], "Profiles wrong or unsafe profile accepted")
        let all = projects.flatMap(\.tasks)
        let verify = all.first { $0.id == "Maven::verify" }
        try require(verify?.argv == ["./mvnw", "-B", "--no-transfer-progress", "verify"], "Maven wrapper not preferred")
        let boot = all.first { $0.id == "Maven:api:spring-boot-run" }
        try require(boot?.kind == .service && boot?.port == 8081 && boot?.healthPath == "/actuator/health" && boot?.argv.first == "../mvnw",
                    "Spring Boot module service/port/actuator wrong")
        try require(!all.contains { $0.id.contains("escape") || $0.id.contains("commented") }, "Unsafe/commented module used")
        try require(!all.contains { $0.id == "Maven:lib:spring-boot-run" } && !all.contains { $0.id == "Maven::spring-boot-run" },
                    "Non-boot module/pom parent offered as service")
        let dev = all.first { $0.id == "Node:frontend:dev" }
        try require(dev?.argv == ["pnpm", "run", "dev"] && dev?.kind == .service && dev?.port == 5173, "Node service/pnpm/vite port wrong")
        try require(all.first { $0.id == "Node:frontend:lint" }?.kind == .task, "Node script kind wrong")
        try require(!all.contains { $0.title == "evil name" || $0.title == "hidden" }, "Invalid script or node_modules scanned")
        let goService = all.first { $0.id == "Go:tools:run:./cmd/server" }
        try require(goService?.argv == ["go", "run", "./cmd/server"] && goService?.port == 9090, "Go cmd service wrong")
        try require(all.contains { $0.id == "Go:tools:test" }, "Go tests missing")
        let make = all.filter { $0.tool == .make }.map(\.title)
        try require(make == ["build", "run"], "Make targets parsed wrongly: \(make)")
        let custom = all.filter { $0.tool == .custom }
        try require(custom.map(\.title) == ["Docs", "Svc"] && custom.last?.port == 7070 && custom.last?.healthPath == "/",
                    "Custom tasks validation failed")
    }

    @Test func commandsAreQuotedAndScoped() throws {
        let task = BuildTask(id: "x", tool: .maven, project: "", title: "x", kind: .service,
                             argv: ["mvn", "-Dfoo=it's; rm -rf ~", "spring-boot:run"], port: 8080, acceptsProfile: true)
        let command = BuildCommand.render(task, profile: "local", port: 9000)
        try require(command.contains(#"'mvn' -gs "$HEARTH_MAVEN_SETTINGS" '-Dfoo=it'\''s; rm -rf ~' 'spring-boot:run' '-Plocal'; else 'mvn' '-Dfoo"#), "Arguments not quoted: \(command)")
        try require(command.contains("export PORT=9000 SERVER_PORT=9000") && command.contains("GOCACHE="), "Environment prelude missing")
        try require(!BuildCommand.render(task, profile: "x;touch /tmp/p").contains("touch"), "Unsafe profile accepted")
        let oneShot = BuildTask(id: "y", tool: .go, project: "", title: "y", kind: .task, argv: ["go", "test", "./..."], port: 1)
        try require(!BuildCommand.render(oneShot).contains("PORT="), "Port exported for non-service")
        try require(BuildDeployStore.workingDirectory(root: "/w/repo", project: "api") == "/w/repo/api", "Subdirectory cwd")
        for bad in ["../x", "/etc", "a/../../x"] {
            try require(BuildDeployStore.workingDirectory(root: "/w/repo", project: bad) == nil, "cwd escape \(bad)")
        }
        // Execute the generated Maven script with a fake mvn and a fake sandbox proxy.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-mvn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "#!/bin/sh\necho ARGS:\"$*\" COUNT:$#\nwhile [ $# -gt 0 ]; do [ \"$1\" = -gs ] && { ls -l \"$2\" | cut -c1-10; cat \"$2\"; echo; echo FILE:$2; }; shift; done\nexit 3\n"
            .write(to: dir.appendingPathComponent("mvn"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("mvn").path)
        let maven = BuildTask(id: "m", tool: .maven, project: "", title: "m", kind: .task, argv: ["mvn", "-B", "verify"], acceptsProfile: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", BuildCommand.render(maven, profile: "it")]
        process.environment = ["PATH": dir.path + ":/usr/bin:/bin", "TMPDIR": dir.path + "/",
                               "HTTPS_PROXY": "http://nono:tok3n@127.0.0.1:4711"]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        try require(process.terminationStatus == 3, "Maven exit code not propagated: \(process.terminationStatus) \(output)")
        try require(output.contains("ARGS:-gs ") && output.contains(" -B verify -Pit COUNT:5"), "Maven args/settings wrong: \(output)")
        try require(output.contains("-rw-------") && output.contains("<host>127.0.0.1</host><port>4711</port><username>nono</username><password>tok3n</password>"),
                    "Proxy settings missing or not private: \(output)")
        let settings = output.components(separatedBy: "FILE:").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try require(!settings.isEmpty && !FileManager.default.fileExists(atPath: settings), "Temporary proxy settings not removed")
        try require(BuildDeployStore.networkHint("Could not transfer from https://nexus.example.org/x: Operation not permitted")?.contains("nexus.example.org") == true
                    && BuildDeployStore.networkHint("BUILD FAILURE: compilation error") == nil, "Network hint")
        let vaadin = "[WARNING] Could not transfer metadata from https://central.sonatype.com/x: Operation not permitted\n"
            + "Caused by: java.io.FileNotFoundException: /Users/x/.vaadin/userKey (Operation not permitted)\n"
        let hint = BuildDeployStore.networkHint(vaadin) ?? ""
        try require(hint.contains("/Users/x/.vaadin/userKey") && !hint.contains("sonatype"), "File hint: \(hint)")
        try require(BuildTask(id: "z", tool: .node, project: "", title: "", kind: .task, argv: ["./mvnw"]).requiredTool == nil
                    && oneShot.requiredTool == "go", "Required tool detection")
    }

    @Test func runnerLifecycleAgainstSandbox() async throws {
        let api = FakeCommandRunner()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeLocalService.self]
        let store = BuildDeployStore()
        store.probe = LocalPortProbe(session: URLSession(configuration: config))
        store.pollInterval = .milliseconds(10)
        store.healthInterval = .milliseconds(10)
        FakeLocalService.listening = []

        // One-shot task: paged output, success, cleanup.
        let build = BuildTask(id: "Go::build", tool: .go, project: "", title: "Build", kind: .task, argv: ["go", "build", "./..."])
        api.reset([.output("compiling…\n"), .output("\u{1B}[32mok\u{1B}[0m\r\n"), .exit(0)])
        let run = try need(await store.start(build, root: "/w/repo", serverID: "s1", client: api))
        try await wait { run.state == .succeeded }
        try require(run.output.contains("compiling…") && run.output.contains("ok\n") && !run.output.contains("\u{1B}"), "Output not collected/cleaned: \(run.output)")
        let start = try need(api.requests.first)
        try require(start.cwd == "/w/repo" && start.command.contains("exec 'go' 'build'"), "Wrong start request")
        try require(start.metadata["source"] == "Hearth IDE" && start.metadata["kind"] == "build-deploy" && start.metadata["root"] == "/w/repo", "Metadata")
        try require(!api.removed.isEmpty, "Finished command not removed")

        // Failure keeps exit code.
        api.reset([.exit(1)])
        let failed = try need(await store.start(build, root: "/w/repo", serverID: "s1", client: api))
        try await wait { !failed.state.isActive }
        try require(failed.state == .failed("exit 1"), "Exit code not reported: \(failed.state)")

        // Service: health becomes up via the host probe, stop removes the command.
        let service = BuildTask(id: "Go::run", tool: .go, project: "", title: "Run", kind: .service, argv: ["go", "run", "."], port: 18_080, healthPath: "/health")
        api.reset([.output("listening\n"), .running])
        let svc = try need(await store.start(service, root: "/w/repo", serverID: "s1", client: api))
        try require(api.requests.first?.port == 18_080, "Service port not opened in the sandbox")
        try require(store.activeRun(service, root: "/w/repo") === svc, "Service not active")
        let again = await store.start(service, root: "/w/repo", serverID: "s1", client: api)
        try require(again === svc && api.requests.count == 1, "Service started twice")
        FakeLocalService.listening = [18_080]
        try await wait { svc.health == .up(200) }
        try require(FakeLocalService.paths.contains("/health"), "Health path not probed")
        await store.stop(svc, client: api)
        try require(svc.state == .stopped && !api.removed.isEmpty, "Service not stopped")

        // Port already used on the host: refuse before starting anything.
        api.reset([])
        let blocked = try need(await store.start(service, root: "/w/repo", serverID: "s1", client: api))
        try require(blocked.state == .failed("port in use") && api.requests.isEmpty, "Port conflict not detected")
        FakeLocalService.listening = []

        // Missing tool in sandbox: nothing starts, no host fallback.
        api.reset([.output("go\nmvn\n"), .exit(0)])
        await store.probeTools(client: api, serverID: "s2", root: "/w/repo")
        let npm = BuildTask(id: "Node::install", tool: .node, project: "", title: "i", kind: .task, argv: ["npm", "ci"])
        try require(store.unavailableReason(npm, serverID: "s2") != nil && store.unavailableReason(build, serverID: "s2") == nil, "Tool probe")
        api.reset([])
        let missing = try need(await store.start(npm, root: "/w/repo", serverID: "s2", client: api))
        try require(missing.state == .failed("not available") && api.requests.isEmpty, "Unavailable tool executed")

        // A sandbox that cannot start reports it and never falls back to the host.
        api.reset([])
        api.failStart = true
        let refused = try need(await store.start(build, root: "/w/repo", serverID: "s1", client: api))
        try require(refused.state == .failed("start failed") && refused.output.contains("Nothing was run on the host"), "Start failure")

        // Re-attach a running service; ignore commands of others.
        api.reset([.running])
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        api.list = [
            SandboxCommandInfo(id: "sh_adopt", command: "x", metadata: ["source": "Hearth IDE", "kind": "build-deploy", "root": "/w/repo",
                "task": "Maven:api:spring-boot-run", "title": "Spring Boot", "service": "true", "port": "8081",
                "display": "mvn spring-boot:run", "tool": "Maven"], started: started),
            SandboxCommandInfo(id: "sh_other", command: "y", metadata: ["source": "agent"], started: started),
            SandboxCommandInfo(id: "sh_otherrepo", command: "z", metadata: ["source": "Hearth IDE", "kind": "build-deploy", "root": "/w/other", "task": "t"], started: started),
        ]
        await store.adopt(client: api, root: "/w/repo", serverID: "s1")
        let adopted = store.runs.filter { $0.shellID == "sh_adopt" }
        try require(adopted.count == 1 && adopted[0].task.kind == .service && adopted[0].port == 8081 && adopted[0].startedAt == started, "Service not adopted")
        try require(!store.runs.contains { $0.shellID == "sh_other" || $0.shellID == "sh_otherrepo" }, "Foreign command adopted")
        await store.adopt(client: api, root: "/w/repo", serverID: "s1")
        try require(store.runs.filter { $0.shellID == "sh_adopt" }.count == 1, "Adopted twice")

        store.serverGone("s1")
        try require(adopted[0].state == .lost("sandbox ended"), "Sandbox loss not reflected")
    }

    private func wait(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestFailure(description: "Timeout waiting for runner state")
    }
}

/// Simulates host localhost listeners for LocalPortProbe.
final class FakeLocalService: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var listening: Set<Int> = []
    nonisolated(unsafe) static var paths: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let port = url.port, Self.listening.contains(port) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        Self.paths.append(url.path)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
