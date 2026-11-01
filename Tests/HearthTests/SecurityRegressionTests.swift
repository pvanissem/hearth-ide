import Foundation
import AppKit
import SwiftUI
import WebKit
import SwiftTerm
import Testing
@testable import Hearth

/// No keychain access, real tokens, or reads/writes of the user's clipboard.
@MainActor
struct SecurityRegressionTests {
    struct Failure: Error { let message: String }
    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    private func call(_ web: WKWebView, _ script: String, arguments: [String: Any] = [:]) async throws {
        // Explicit completion bridge: with this SDK an unused result can select
        // the synchronous overload even when written as `try await`.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    @Test func gitLabOriginBinding() async throws {
        let trusted = CIRemote.parse("https://git.example.test/group/repo.git")!
        let attacker = CIRemote.parse("https://attacker.invalid/group/repo.git")!
        let credential = CICredential(origin: trusted.origin, token: "dummy-test-token", allowsWrites: false)
        try require(CIRemote.parse("http://git.example.test/group/repo.git") == nil, "HTTP remote accepted")
        try require(CIRemote.parse("https://user:pass@git.example.test/g/r") == nil, "Credential URL accepted")
        try require(CIOrigin.parse("https://GIT.EXAMPLE.TEST:443/") == trusted.origin, "Origin normalization")
        try require(CIOrigin.parse("https://git.example.test:8443") != trusted.origin, "Ports conflated")
        try require(CIOrigin.parse("https://git.example.test@attacker.invalid") == nil, "Userinfo origin accepted")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DummyGitLabProtocol.self]
        let transport = NoRedirectTransport()
        let session = URLSession(configuration: config, delegate: transport, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let client = GitLabAPI(remote: trusted, credential: credential, session: session)
        _ = try await client.pipelines(ref: nil)
        // DummyGitLabProtocol rejects every host/header except the explicitly bound pair.
        do {
            _ = try await GitLabAPI(remote: attacker, credential: credential, session: session).pipelines(ref: nil)
            throw Failure(message: "Token accepted for unknown origin")
        } catch is GitLabAPI.APIError {}
        do {
            try await client.retry(job: 1)
            throw Failure(message: "Read token accepted for write")
        } catch is GitLabAPI.APIError {}
        let original = try client.authorizedRequest("GET", "/projects/1")
        let task = session.dataTask(with: original)
        var redirected = true
        transport.urlSession(session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: attacker.webURL)) { redirected = $0 != nil }
        try require(!redirected, "Cross-origin redirect accepted")
    }

    @Test func terminalClipboardPolicy() throws {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let gate = TerminalSecurity(view)
        view.terminalDelegate = gate
        try require(view.terminalDelegate === gate, "Security delegate not installed")
        try require(gate.clipboardRead(source: view) == nil, "OSC 52 reads clipboard")
        gate.clipboardCopy(source: view, content: Data("dummy-do-not-copy".utf8))
        try require(gate.kittyClipboardCapabilities(source: view).isEmpty, "Kitty clipboard advertised")
        try require(gate.kittyClipboardRead(source: view, location: .standard, mimeType: "text/plain") == .denied,
                    "Kitty read allows fallback to system pasteboard")
        // Exercise the real parser/callback path. The policy never calls NSPasteboard.
        view.feed(text: "\u{1b}]52;c;?\u{7}\u{1b}]52;c;ZHVtbXk=\u{7}")
    }

    @Test func directoryMoveValidation() throws {
        try require(InspectorTab.preview.title == "Editor", "Editor display name")
        try require(try JSONDecoder().decode(InspectorTab.self, from: Data("\"Preview\"".utf8)) == .preview, "Legacy layout compatibility")
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HEARTH_SECURITY_FIXTURES"] ?? NSTemporaryDirectory())
            .appendingPathComponent("directory-\(UUID().uuidString)")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        let root = parent.appendingPathComponent("workspace")
        let folder = root.appendingPathComponent("folder")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("test.txt")
        try Data("keep".utf8).write(to: source)
        let destination = try WorkspaceFiles.moveDestination(source: source, directory: folder, root: root)
        try fm.moveItem(at: source, to: destination)
        try require(fm.fileExists(atPath: destination.path), "Internal move failed")
        let escape = root.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: escape, withDestinationURL: parent)
        for (item, target) in [(destination, folder), (destination, parent), (destination, escape), (folder, folder), (root, parent)] {
            do {
                _ = try WorkspaceFiles.moveDestination(source: item, directory: target, root: root)
                throw Failure(message: "Unsafe move accepted: \(item.lastPathComponent)")
            } catch is WorkspaceFiles.Failure {}
        }
        let child = folder.appendingPathComponent("child")
        try fm.createDirectory(at: child, withIntermediateDirectories: false)
        do {
            _ = try WorkspaceFiles.moveDestination(source: folder, directory: child, root: root)
            throw Failure(message: "Folder moved into descendant")
        } catch is WorkspaceFiles.Failure {}
    }

    @Test func gitHelpersCannotExecute() async throws {
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HEARTH_SECURITY_FIXTURES"] ?? NSTemporaryDirectory())
        let repo = parent.appendingPathComponent("git-security-\(UUID().uuidString)")
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: repo) }
        func setup(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            p.environment = Git.hostEnvironment
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            try require(p.terminationStatus == 0, "Fixture setup failed: \(args.first ?? "")")
        }
        try setup(["init"])
        try "old\n".write(to: repo.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        try setup(["add", "sample.txt"])
        try setup(["-c", "user.name=Security Test", "-c", "user.email=test@example.invalid", "commit", "-m", "fixture"])
        let marker = repo.appendingPathComponent("helper-executed")
        let script = repo.appendingPathComponent("helper.sh")
        try "#!/bin/sh\nprintf executed > '\(marker.path)'\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try setup(["config", "core.fsmonitor", script.path])
        try setup(["config", "diff.evil.textconv", script.path])
        try setup(["config", "diff.evil.command", script.path])
        try setup(["config", "filter.evil.clean", script.path])
        try setup(["config", "filter.evil.smudge", script.path])
        try setup(["config", "filter.evil.process", script.path])
        try setup(["config", "filter.evil.required", "true"])
        try "*.txt diff=evil filter=evil\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "new\n".write(to: repo.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
        let status = await Git.snapshot(of: repo.path)
        try require(status.isRepo, "Hardened status failed")
        _ = await Git.diff(path: "sample.txt", in: repo.path, untracked: false)
        _ = await Git.show(commit: "HEAD", in: repo.path)
        _ = await InlineDiff.load(file: repo.appendingPathComponent("sample.txt"), root: repo.path)
        try require(!fm.fileExists(atPath: marker.path), "Read operation executed a helper")
        let filteredWrite = await Git.mutate(["add", "--", "sample.txt"], in: repo.path)
        try require(!filteredWrite.ok, "Write with configured filter allowed")
        let network = await Git.mutate(["pull", "--ff-only"], in: repo.path)
        try require(!network.ok, "Host network operation allowed")
        try setup(["config", "--remove-section", "filter.evil"])
        let hooks = repo.appendingPathComponent("hooks")
        try fm.createDirectory(at: hooks, withIntermediateDirectories: false)
        let hook = hooks.appendingPathComponent("post-checkout")
        try fm.copyItem(at: script, to: hook)
        try setup(["config", "core.hooksPath", hooks.path])
        let switched = await Git.mutate(["switch", "-c", "safe-test"], in: repo.path)
        try require(switched.ok, "Hardened local switch failed")
        try require(!fm.fileExists(atPath: marker.path), "Checkout executed a hook")
    }

    @Test func mermaidCannotInjectOrConnect() async throws {
        let controller = MermaidController()
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: MermaidWebView(source: "graph TD; A[Hello] --> B[World]", dark: false, controller: controller))
        window.contentView = hosting
        window.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(30)
        while !controller.rendered && controller.error == nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(controller.rendered, "Benign diagram failed: \(controller.error ?? "timeout")")
        guard let web = controller.webView else { throw Failure(message: "No diagram WebView") }
        let payload = "graph TD\n A[\"</script><script>window.__diagramInjected=true</script>\"]"
        try await call(web, "await window.renderDiagram(source, false)", arguments: ["source": payload])
        let injected = try await web.evaluateJavaScript("window.__diagramInjected === true") as? Bool
        try require(injected == false, "Diagram escaped into JavaScript")
        _ = try await web.evaluateJavaScript("window.__csp=[]; addEventListener('securitypolicyviolation', e => __csp.push(e.violatedDirective));")
        try await call(web, "try { await fetch('http://127.0.0.1:9/blocked'); } catch(e) {}")
        try await Task.sleep(for: .milliseconds(100))
        let violations = try await web.evaluateJavaScript("window.__csp") as? [String] ?? []
        try require(violations.contains("connect-src"), "CSP did not block network request")
        try require(!web.configuration.websiteDataStore.isPersistent, "Persistent diagram data store")
        try require(!MermaidPage.html().contains(payload), "Source interpolated into page")
    }
}

private final class DummyGitLabProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "git.example.test", request.url?.scheme == "https",
              request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "dummy-test-token" else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
