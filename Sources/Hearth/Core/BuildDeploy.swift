import Foundation

/// A build step or long-running service offered for a workspace project.
/// Tasks are derived from project files and always run in Hearth's nono sandbox.
struct BuildTask: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case task, service }
    enum Tool: String, Codable, Sendable, CaseIterable {
        case maven = "Maven", gradle = "Gradle", node = "Node", go = "Go", make = "Make", custom = "Eigene"
    }

    let id: String
    let tool: Tool
    /// Directory relative to the workspace root ("" = root).
    let project: String
    let title: String
    let kind: Kind
    /// Executable + arguments, quoted individually. Empty for custom shell tasks.
    var argv: [String] = []
    /// Only for `.hearth/tasks.json`: a shell command line written by the project.
    var script: String?
    var port: Int?
    var healthPath: String?
    /// Maven only: tasks accept a `-P profile` selection.
    var acceptsProfile = false

    /// The command shown to the user (without the environment prelude).
    var display: String { script ?? argv.joined(separator: " ") }
    /// The executable that must exist in the sandbox (nil for wrappers/scripts).
    var requiredTool: String? {
        guard script == nil, let first = argv.first, !first.contains("/") else { return nil }
        return first
    }
}

struct BuildProject: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    var tools: [BuildTask.Tool]
    var tasks: [BuildTask]
    var profiles: [String] = []
}

enum BuildCommand {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Caches the sandbox cannot write in their default location are redirected
    /// into the (sandbox-writable) temp directory. No credentials are added.
    static let prelude = [
        "export TERM=dumb NO_COLOR=1",
        "export GOCACHE=\"${TMPDIR:-/tmp}/hearth/go/cache\" GOMODCACHE=\"${TMPDIR:-/tmp}/hearth/go/mod\" GOPATH=\"${TMPDIR:-/tmp}/hearth/go/path\"",
        "export GRADLE_USER_HOME=\"${TMPDIR:-/tmp}/hearth/gradle\"",
    ].joined(separator: "; ")

    /// Java ignores HTTP(S)_PROXY. The sandbox only allows network access via its
    /// authenticated proxy, so it is parsed here and handed to Maven (temporary
    /// 0600 global settings, merged with the user's own settings.xml) and Gradle.
    static let proxySetup = #"""
    hearth_proxy() { p="${HTTPS_PROXY:-${https_proxy:-}}"; [ -n "$p" ] || return 1; r="${p#*://}"; c=""; case "$r" in *@*) c="${r%%@*}"; r="${r#*@}";; esac; r="${r%%/*}"; HEARTH_PROXY_HOST="${r%:*}"; HEARTH_PROXY_PORT="${r##*:}"; HEARTH_PROXY_USER="${c%%:*}"; HEARTH_PROXY_PASS=""; case "$c" in *:*) HEARTH_PROXY_PASS="${c#*:}";; esac; }
    """#

    static let mavenProxy = #"""
    HEARTH_MAVEN_SETTINGS=""; if hearth_proxy; then d="${TMPDIR:-/tmp}/hearth"; mkdir -p "$d"; find "$d" -name 'maven-proxy.*' -mmin +1440 -delete 2>/dev/null; HEARTH_MAVEN_SETTINGS="$(umask 077; mktemp "$d/maven-proxy.XXXXXX")"; { echo '<settings><proxies>'; for proto in https http; do echo "<proxy><id>hearth-sandbox-$proto</id><active>true</active><protocol>$proto</protocol><host>$HEARTH_PROXY_HOST</host><port>$HEARTH_PROXY_PORT</port><username>$HEARTH_PROXY_USER</username><password>$HEARTH_PROXY_PASS</password><nonProxyHosts>localhost|127.0.0.1</nonProxyHosts></proxy>"; done; echo '</proxies></settings>'; } > "$HEARTH_MAVEN_SETTINGS"; fi
    """#

    static let gradleProxy = #"""
    if hearth_proxy; then export GRADLE_OPTS="${GRADLE_OPTS:-} -Dhttps.proxyHost=$HEARTH_PROXY_HOST -Dhttps.proxyPort=$HEARTH_PROXY_PORT -Dhttps.proxyUser=$HEARTH_PROXY_USER -Dhttps.proxyPassword=$HEARTH_PROXY_PASS -Dhttp.proxyHost=$HEARTH_PROXY_HOST -Dhttp.proxyPort=$HEARTH_PROXY_PORT -Dhttp.proxyUser=$HEARTH_PROXY_USER -Dhttp.proxyPassword=$HEARTH_PROXY_PASS -Dhttp.nonProxyHosts=localhost|127.0.0.1"; fi
    """#

    static func render(_ task: BuildTask, profile: String? = nil, port: Int? = nil) -> String {
        var lines = [prelude]
        if let port = port ?? task.port, task.kind == .service {
            lines.append("export PORT=\(port) SERVER_PORT=\(port)")
        }
        if let script = task.script {
            lines.append(script)
            return lines.joined(separator: "; ")
        }
        var argv = task.argv
        if task.acceptsProfile, let profile, BuildDetector.validName(profile) { argv.append("-P" + profile) }
        switch task.tool {
        case .maven where !argv.isEmpty:
            lines += [proxySetup, mavenProxy]
            let rest = argv.dropFirst().map(quote).joined(separator: " ")
            // Explicit branches: zsh (the sandbox shell) does not word-split ${x:+a "$x"}.
            let exe = quote(argv[0])
            lines.append(#"if [ -n "$HEARTH_MAVEN_SETTINGS" ]; then "# + exe + #" -gs "$HEARTH_MAVEN_SETTINGS" "# + rest
                         + "; else " + exe + " " + rest + #"; fi; hearth_rc=$?; [ -n "$HEARTH_MAVEN_SETTINGS" ] && rm -f "$HEARTH_MAVEN_SETTINGS"; exit $hearth_rc"#)
        case .gradle:
            lines += [proxySetup, gradleProxy, "exec " + argv.map(quote).joined(separator: " ")]
        default:
            lines.append("exec " + argv.map(quote).joined(separator: " "))
        }
        return lines.joined(separator: "; ")
    }
}

/// Reads project files only (no execution) to find build tools and services.
enum BuildDetector {
    static let skipped: Set<String> = ["node_modules", "target", "build", "dist", "vendor", "out", "coverage", "bin", "obj"]
    static let maxDirectories = 40
    static let maxFileBytes = 512_000

    static func validName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 120 && s.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.:@/+-]*$"#, options: .regularExpression) != nil && !s.contains("..")
    }

    static func scan(root: String) -> [BuildProject] {
        let base = URL(fileURLWithPath: root)
        var projects: [BuildProject] = []
        var mavenModules: Set<String> = []
        if let maven = maven(base, relative: "") {
            projects.append(maven.project)
            mavenModules = maven.modules
        }
        var directories = [""]
        let children = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true, !name.hasPrefix("."), !skipped.contains(name) else { continue }
            directories.append(name)
            if directories.count >= maxDirectories { break }
        }
        for dir in directories {
            let url = dir.isEmpty ? base : base.appendingPathComponent(dir)
            var tasks: [BuildTask] = []
            var tools: [BuildTask.Tool] = []
            if !dir.isEmpty, !mavenModules.contains(dir), projects.first(where: { $0.path == "" && $0.tools.contains(.maven) }) == nil,
               let maven = maven(url, relative: dir) {
                projects.append(maven.project)
            }
            for (tool, found) in [(BuildTask.Tool.gradle, gradle(url, relative: dir)), (.node, node(url, relative: dir)),
                                  (.go, go(url, relative: dir)), (.make, make(url, relative: dir))] where !found.isEmpty {
                tools.append(tool); tasks += found
            }
            if dir.isEmpty {
                let custom = customTasks(base)
                if !custom.isEmpty { tools.append(.custom); tasks += custom }
            }
            guard !tasks.isEmpty else { continue }
            if let index = projects.firstIndex(where: { $0.path == dir }) {
                projects[index].tools += tools
                projects[index].tasks += tasks
            } else {
                projects.append(BuildProject(path: dir, name: dir.isEmpty ? base.lastPathComponent : dir, tools: tools, tasks: tasks))
            }
        }
        return projects.sorted { ($0.path.isEmpty ? 0 : 1, $0.path) < ($1.path.isEmpty ? 0 : 1, $1.path) }
    }

    static func read(_ url: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileBytes,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private static func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.range(at: group).location == NSNotFound ? nil : ns.substring(with: $0.range(at: group))
        }
    }

    private static func id(_ tool: BuildTask.Tool, _ dir: String, _ name: String) -> String { "\(tool.rawValue):\(dir):\(name)" }

    // MARK: Maven

    static func maven(_ dir: URL, relative: String) -> (project: BuildProject, modules: Set<String>)? {
        guard let pom = read(dir.appendingPathComponent("pom.xml")) else { return nil }
        let stripped = pom.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: [.regularExpression])
        let exe = exists(dir.appendingPathComponent("mvnw")) ? "./mvnw" : "mvn"
        let base = [exe, "-B", "--no-transfer-progress"]
        func task(_ name: String, _ title: String, _ goals: [String]) -> BuildTask {
            BuildTask(id: id(.maven, relative, name), tool: .maven, project: relative, title: title, kind: .task,
                      argv: base + goals, acceptsProfile: true)
        }
        var tasks = [
            task("clean-install", "Clean install", ["clean", "install"]),
            task("verify", "Verify", ["verify"]),
            task("test", "Test", ["test"]),
            task("package", "Package", ["package"]),
            task("package-skip", "Package ohne Tests", ["package", "-DskipTests"]),
            task("compile", "Compile", ["compile"]),
            task("clean", "Clean", ["clean"]),
            task("deps", "Dependency-Tree", ["dependency:tree"]),
        ]
        let profiles = Array(Set(matches(#"<profile>\s*<id>\s*([^<\s]+)\s*</id>"#, in: stripped).filter(validName))).sorted()
        let modules = Set(matches(#"<module>\s*([^<]+?)\s*</module>"#, in: stripped)
            .filter { validName($0) && !$0.contains("/") })
        var serviceDirs: [(String, URL)] = []
        if isSpringBoot(pom) && !stripped.contains("<packaging>pom</packaging>") { serviceDirs.append(("", dir)) }
        for module in modules.sorted() {
            let url = dir.appendingPathComponent(module)
            if let child = read(url.appendingPathComponent("pom.xml")), isSpringBoot(child) { serviceDirs.append((module, url)) }
        }
        for (module, url) in serviceDirs {
            let path = [relative, module].filter { !$0.isEmpty }.joined(separator: "/")
            let wrapper = exe == "./mvnw" ? (module.isEmpty ? "./mvnw" : "../mvnw") : "mvn"
            let childPom = read(url.appendingPathComponent("pom.xml")) ?? ""
            tasks.append(BuildTask(id: id(.maven, path, "spring-boot-run"), tool: .maven, project: path,
                                   title: module.isEmpty ? "Spring Boot starten" : "Spring Boot starten (\(module))", kind: .service,
                                   argv: [wrapper, "-B", "--no-transfer-progress", "spring-boot:run"],
                                   port: springPort(url) ?? 8080,
                                   healthPath: childPom.contains("spring-boot-starter-actuator") ? "/actuator/health" : "/",
                                   acceptsProfile: true))
        }
        let name = matches(#"<artifactId>\s*([^<\s]+)\s*</artifactId>"#,
                           in: stripped.replacingOccurrences(of: #"(?s)<parent>.*?</parent>"#, with: "", options: .regularExpression)).first
        return (BuildProject(path: relative, name: name ?? (relative.isEmpty ? dir.lastPathComponent : relative),
                             tools: [.maven], tasks: tasks, profiles: profiles), modules)
    }

    static func isSpringBoot(_ build: String) -> Bool {
        build.contains("spring-boot-maven-plugin") || build.contains("spring-boot-starter") || build.contains("org.springframework.boot")
    }

    static func springPort(_ dir: URL) -> Int? {
        let resources = dir.appendingPathComponent("src/main/resources")
        if let props = read(resources.appendingPathComponent("application.properties")),
           let value = matches(#"(?m)^\s*server\.port\s*[=:]\s*(\d{2,5})\s*$"#, in: props).first { return port(value) }
        for file in ["application.yml", "application.yaml"] {
            if let yml = read(resources.appendingPathComponent(file)),
               let value = matches(#"(?m)^server:\s*\n(?:[ \t]+.*\n)*?[ \t]+port:\s*(\d{2,5})\s*$"#, in: yml).first { return port(value) }
        }
        return nil
    }

    static func port(_ value: String) -> Int? { Int(value).flatMap { (1...65535).contains($0) ? $0 : nil } }

    // MARK: Gradle

    static func gradle(_ dir: URL, relative: String) -> [BuildTask] {
        let file = read(dir.appendingPathComponent("build.gradle.kts")) ?? read(dir.appendingPathComponent("build.gradle"))
        guard let file else { return [] }
        let exe = exists(dir.appendingPathComponent("gradlew")) ? "./gradlew" : "gradle"
        func task(_ name: String, _ title: String, _ kind: BuildTask.Kind = .task) -> BuildTask {
            BuildTask(id: id(.gradle, relative, name), tool: .gradle, project: relative, title: title, kind: kind,
                      argv: [exe, "--console=plain", name])
        }
        var tasks = [task("build", "Build"), task("test", "Test"), task("clean", "Clean")]
        if isSpringBoot(file) {
            var run = task("bootRun", "Spring Boot starten", .service)
            run.port = springPort(dir) ?? 8080
            run.healthPath = file.contains("actuator") ? "/actuator/health" : "/"
            tasks.append(run)
        }
        return tasks
    }

    // MARK: Node

    static let serviceScripts: Set<String> = ["start", "dev", "serve", "preview", "start:dev", "dev:server", "watch"]

    static func node(_ dir: URL, relative: String) -> [BuildTask] {
        guard let text = read(dir.appendingPathComponent("package.json")),
              let json = JSON.parse(Data(text.utf8)) else { return [] }
        let manager = exists(dir.appendingPathComponent("pnpm-lock.yaml")) ? "pnpm"
            : exists(dir.appendingPathComponent("yarn.lock")) ? "yarn" : "npm"
        var tasks = [BuildTask(id: id(.node, relative, "install"), tool: .node, project: relative, title: "Abhängigkeiten installieren",
                               kind: .task, argv: manager == "npm" && exists(dir.appendingPathComponent("package-lock.json"))
                                   ? ["npm", "ci"] : [manager, "install"])]
        for (name, value) in (json["scripts"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard validName(name), let command = value.string else { continue }
            let service = serviceScripts.contains(name)
            var task = BuildTask(id: id(.node, relative, name), tool: .node, project: relative, title: name,
                                 kind: service ? .service : .task, argv: [manager, "run", name])
            if service { task.port = nodePort(command); task.healthPath = "/" }
            tasks.append(task)
        }
        return tasks
    }

    static func nodePort(_ script: String) -> Int? {
        if let explicit = matches(#"(?:--port[= ]|-p\s+|PORT=)(\d{2,5})\b"#, in: script).first { return port(explicit) }
        if script.contains("vite") { return 5173 }
        if script.contains("ng serve") { return 4200 }
        if script.contains("next") || script.contains("react-scripts") || script.contains("nuxt") { return 3000 }
        return nil
    }

    // MARK: Go

    static func go(_ dir: URL, relative: String) -> [BuildTask] {
        guard exists(dir.appendingPathComponent("go.mod")) else { return [] }
        func task(_ name: String, _ title: String, _ argv: [String]) -> BuildTask {
            BuildTask(id: id(.go, relative, name), tool: .go, project: relative, title: title, kind: .task, argv: argv)
        }
        var tasks = [task("build", "Build", ["go", "build", "./..."]), task("test", "Test", ["go", "test", "./..."]),
                     task("vet", "Vet", ["go", "vet", "./..."])]
        var mains: [(String, URL)] = []
        if isGoMain(dir) { mains.append((".", dir)) }
        let cmd = dir.appendingPathComponent("cmd")
        for child in ((try? FileManager.default.contentsOfDirectory(at: cmd, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
        where validName(child.lastPathComponent) && isGoMain(child) {
            mains.append(("./cmd/" + child.lastPathComponent, child))
        }
        for (path, url) in mains.prefix(10) {
            var run = BuildTask(id: id(.go, relative, "run:" + path), tool: .go, project: relative,
                                title: path == "." ? "Starten (go run .)" : "Starten \(path.dropFirst(6))",
                                kind: .service, argv: ["go", "run", path])
            run.port = goPort(url)
            run.healthPath = "/"
            tasks.append(run)
        }
        return tasks
    }

    private static func goFiles(_ dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "go" && !$0.lastPathComponent.hasSuffix("_test.go") }.prefix(30).map { $0 }
    }

    static func isGoMain(_ dir: URL) -> Bool {
        goFiles(dir).contains { read($0).map { $0.range(of: #"(?m)^package main\b"#, options: .regularExpression) != nil } ?? false }
    }

    static func goPort(_ dir: URL) -> Int? {
        for file in goFiles(dir) {
            if let text = read(file), let value = matches(#""[A-Za-z0-9.\-]*:(\d{4,5})""#, in: text).first { return port(value) }
        }
        return nil
    }

    // MARK: Make

    static func make(_ dir: URL, relative: String) -> [BuildTask] {
        guard let text = read(dir.appendingPathComponent("Makefile")) ?? read(dir.appendingPathComponent("makefile")) else { return [] }
        var seen: [String] = []
        for target in matches(#"(?m)^([A-Za-z0-9][A-Za-z0-9_.-]*)[ \t]*:(?!=)"#, in: text) where !seen.contains(target) && validName(target) {
            seen.append(target)
        }
        return seen.prefix(30).map { target in
            let service = ["run", "serve", "start", "dev", "up"].contains(target)
            var task = BuildTask(id: id(.make, relative, target), tool: .make, project: relative, title: target,
                                 kind: service ? .service : .task, argv: ["make", target])
            if service { task.healthPath = "/" }
            return task
        }
    }

    // MARK: Custom (.hearth/tasks.json)

    static func customTasks(_ root: URL) -> [BuildTask] {
        guard let text = read(root.appendingPathComponent(".hearth/tasks.json")), let json = JSON.parse(Data(text.utf8)) else { return [] }
        return json["tasks"]?.array.prefix(50).compactMap { item -> BuildTask? in
            guard let name = item["name"]?.string, !name.isEmpty, name.count <= 80,
                  let command = item["command"]?.string, !command.isEmpty, command.count <= 4000,
                  !command.contains("\0") else { return nil }
            let cwd = item["cwd"]?.string ?? ""
            guard cwd.isEmpty || (validName(cwd) && !cwd.hasPrefix("/")) else { return nil }
            let service = item["service"] == .bool(true)
            var task = BuildTask(id: id(.custom, cwd, name), tool: .custom, project: cwd, title: name,
                                 kind: service ? .service : .task, script: command)
            if service {
                task.port = item["port"]?.double.flatMap { port(String(Int($0))) }
                task.healthPath = item["health"]?.string.flatMap { $0.hasPrefix("/") && !$0.contains("..") && $0.count < 200 ? $0 : nil } ?? "/"
            }
            return task
        } ?? []
    }
}
