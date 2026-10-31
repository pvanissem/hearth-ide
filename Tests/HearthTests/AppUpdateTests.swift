import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Hearth

@MainActor
@Suite(.serialized)
struct AppUpdateTests {
    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw SandboxGitRunner.Failure(message) }
    }

    @Test func releaseComparisonDistinguishesDevelopmentBuilds() throws {
        try require(ReleaseVersion("v0.1.10")! > ReleaseVersion("0.1.9")!, "Versions compared lexicographically")
        try require(ReleaseVersion("1.0.0")! > ReleaseVersion("0.99.99")!, "Major comparison")
        for invalid in ["", "1.2", "01.2.3", "v1.2.3;echo bad", "<html>login</html>", "1.2.3-rc.1", String(repeating: "9", count: 40) + ".1.1"] {
            try require(ReleaseVersion(invalid) == nil, "Invalid release accepted")
        }
        let latest = ReleaseVersion("0.1.10")!
        try require(UpdateResult(installed: InstalledAppVersion(label: "0.1.9"), latest: latest).relation == .updateAvailable, "Update not detected")
        try require(UpdateResult(installed: InstalledAppVersion(label: "0.1.10"), latest: latest).relation == .current, "Equal release")
        try require(UpdateResult(installed: InstalledAppVersion(label: "0.2.0"), latest: latest).relation == .ahead, "Downgrade offered")
        for local in [InstalledAppVersion(label: "0.1.3-100-gabcdef0"), InstalledAppVersion(label: "0.1.3", channel: "development"), InstalledAppVersion(label: "abcdef0")] {
            try require(UpdateResult(installed: local, latest: latest).relation == .development, "Development build compared as old release")
        }
    }

    @Test func feedAndCheckerAreSafe() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateFeedHTTP.self]
        let delegate = UpdateTransport()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let service = UpdateService(session: session)
        UpdateFeedHTTP.reset("v0.1.10\n")
        try require(try await service.latest() == ReleaseVersion("0.1.10"), "Feed version not decoded")
        let request = UpdateFeedHTTP.requests.first!
        try require(request.url?.host == "github.com" && request.url?.scheme == "https", "Wrong update origin")
        try require(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == nil, "Credential leaked to update check")
        try require(request.value(forHTTPHeaderField: "Cache-Control") == "no-cache", "Update response can be stale-cached")
        try require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.name == "t", "Cache busting missing")
        let download = UpdateService.downloadURL(for: ReleaseVersion("0.1.10"))
        try require(download.host == UpdateService.feed.host && download.path.hasSuffix("hearth-macos-arm64.zip") && download.query == "version=0.1.10", "Download is not fixed/cache-busted")
        let task = session.dataTask(with: request)
        var redirectAccepted = true
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: URL(string: "https://attacker.invalid/feed")!)) { redirectAccepted = $0 != nil }
        try require(!redirectAccepted, "Update redirect accepted")
        for target in ["http://github.com/x", "https://github.com:8443/x", "https://user@github.com/x", "https://github.com.attacker.invalid/x"] {
            var accepted = true
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!,
                newRequest: URLRequest(url: URL(string: target)!)) { accepted = $0 != nil }
            try require(!accepted, "Unsafe redirect accepted: \(target)")
        }
        var githubAccepted = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!,
            newRequest: URLRequest(url: URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/1/x")!)) { githubAccepted = $0 != nil }
        try require(githubAccepted, "GitHub release asset redirect refused")
        for body in ["<html>do-not-display-login</html>", String(repeating: "v", count: 256), "v1.2.3\necho bad", "v9999999999999999999999999999.1.1"] {
            UpdateFeedHTTP.reset(body)
            do {
                _ = try await service.latest()
                throw SandboxGitRunner.Failure("Invalid/oversized update feed accepted")
            } catch is UpdateService.Failure {}
        }
        let suite = "hearth-update-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(installed: InstalledAppVersion(label: "0.1.9"), service: service, defaults: defaults)
        checker.automaticChecks = false
        UpdateFeedHTTP.reset("v0.1.10")
        await checker.checkOnLaunch()
        try require(UpdateFeedHTTP.requests.isEmpty, "Disabled startup check ran")
        async let one: Void = checker.check()
        async let two: Void = checker.check()
        _ = await (one, two)
        try require(UpdateFeedHTTP.requests.count == 1 && checker.notice == ReleaseVersion("0.1.10"), "Concurrent checks duplicated request or missed update")
        try require(checker.lastCheckedAt != nil && checker.error == nil && !checker.checking, "Check state not settled")
        checker.dismissNotice()
        await checker.check()
        try require(checker.notice == nil && checker.result?.relation == .updateAvailable, "Dismissed notice reappeared or settings result lost")
        UpdateFeedHTTP.reset("v0.2.0")
        await checker.check()
        try require(checker.notice == ReleaseVersion("0.2.0"), "Newer release stays dismissed")
        let restored = UpdateChecker(installed: InstalledAppVersion(label: "0.1.9"), service: service, defaults: defaults)
        try require(!restored.automaticChecks && restored.lastCheckedAt != nil, "Update preferences not persisted")
        UpdateFeedHTTP.reset("do-not-display-error-body", status: 503)
        await checker.check()
        try require(checker.result == nil && checker.notice == nil && checker.error != nil, "Failed check reported up-to-date/available")
        try require(checker.error?.contains("do-not-display") != true, "Feed error body exposed")
        let dev = UpdateChecker(installed: InstalledAppVersion(label: "0.1.3-100-gabcdef0", channel: "development"), service: service, defaults: defaults)
        UpdateFeedHTTP.reset("v0.2.0")
        await dev.check()
        try require(dev.result?.relation == .development && dev.notice == nil, "Development build got automatic downgrade prompt")
    }

    @Test func startupChecksOnceAndSettingsRender() async throws {
        _ = NSApplication.shared
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateFeedHTTP.self]
        let session = URLSession(configuration: config, delegate: UpdateTransport(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let suite = "hearth-update-ui-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let checker = UpdateChecker(installed: InstalledAppVersion(label: "0.1.9"), service: UpdateService(session: session), defaults: defaults)
        UpdateFeedHTTP.reset("v0.1.10")
        await checker.checkOnLaunch()
        await checker.checkOnLaunch()
        try require(UpdateFeedHTTP.requests.count == 1, "Startup check ran more than once")
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 680, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: UpdateSettings(checker: checker))
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        try require(host.frame.width == 680 && checker.notice != nil, "Update settings did not render")
    }

    @Test func updateHelperRunsInstallerOnlyAfterQuit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hearth-updater-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func tool(_ name: String, _ body: String) throws {
            let url = dir.appendingPathComponent(name)
            try ("#!/bin/bash\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        // Fake curl writes the "downloaded" installer to -o; it records the URL.
        try tool("curl", #"while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift;; https://*) echo "$1" >> "$HEARTH_TEST/urls";; esac; shift; done; printf 'echo installer-ran >> "$HEARTH_TEST/ran"; exit ${HEARTH_INSTALL_RC:-0}\n' > "$out""#)
        try tool("open", #"echo "$@" >> "$HEARTH_TEST/opened""#)
        func run(appSeconds: Int, installRC: Int, wait: Int = 30) throws -> (status: String, ran: Bool, opened: String, waitedForApp: Bool) {
            for f in ["ran", "opened", "urls", "status", "log"] { try? FileManager.default.removeItem(at: dir.appendingPathComponent(f)) }
            let app = Process()
            app.executableURL = URL(fileURLWithPath: "/bin/sleep")
            app.arguments = [String(appSeconds)]
            try app.run()
            let started = Date()
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/bin/bash")
            helper.arguments = ["-c", AppUpdateInstaller.helperScript, "hearth-update", String(app.processIdentifier),
                                dir.appendingPathComponent("log").path, dir.appendingPathComponent("status").path,
                                dir.path, "https://example.invalid/install.sh"]
            helper.environment = ["PATH": dir.path + ":/usr/bin:/bin", "HEARTH_TEST": dir.path,
                                  "HEARTH_INSTALL_RC": String(installRC), "HEARTH_UPDATE_WAIT": String(wait)]
            try helper.run()
            helper.waitUntilExit()
            app.terminate()
            let read = { (name: String) in (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "" }
            return (read("status").trimmingCharacters(in: .whitespacesAndNewlines), !read("ran").isEmpty, read("opened"),
                    Date().timeIntervalSince(started) >= Double(min(appSeconds, wait)) - 0.2)
        }
        let ok = try run(appSeconds: 1, installRC: 0)
        try require(ok.status == "succeeded" && ok.ran && ok.opened.isEmpty && ok.waitedForApp, "Successful update: \(ok)")
        try require(((try? String(contentsOf: dir.appendingPathComponent("urls"), encoding: .utf8)) ?? "").hasPrefix("https://example.invalid/install.sh?t="), "Installer URL")
        let failed = try run(appSeconds: 0, installRC: 1)
        try require(failed.status == "failed" && failed.ran && failed.opened.trimmingCharacters(in: .whitespacesAndNewlines) == dir.path,
                    "Failed update must reopen the old app: \(failed)")
        let aborted = try run(appSeconds: 5, installRC: 0, wait: 1)
        try require(aborted.status == "aborted" && !aborted.ran, "Installer ran while the app was still running: \(aborted)")
        try "failed\n".write(to: dir.appendingPathComponent("status"), atomically: true, encoding: .utf8)
        try require(AppUpdateInstaller.consumeOutcome(statusURL: dir.appendingPathComponent("status")) == .failed
                    && AppUpdateInstaller.consumeOutcome(statusURL: dir.appendingPathComponent("status")) == nil, "Outcome not consumed once")
        let checker = UpdateChecker(installed: InstalledAppVersion(label: "0.1.9"))
        try require(!checker.canInstall, "Install offered without a confirmed newer release")
        checker.reportPreviousInstall(.failed)
        try require(checker.installMessage?.contains("update.log") == true, "Failure not reported")
    }

    @Test func releaseNotesForUpdateDialog() async throws {
        let markdown = """
        # Hearth IDE – Änderungen

        ## 0.1.6 · 2026-11-02

        - Editor-Tabs per **Drag & Drop** sortieren
        - Changelog im Update-Dialog

        ## 0.1.5 · 2026-10-31

        - Build & Deployment
        * Update per Klick

        ## kaputt · ohne Version
        - darf nicht erscheinen

        ## 0.1.4 · 2026-10-30
        - ältere Änderung
        """
        let sections = ReleaseNotes.parse(markdown)
        try require(sections.map(\.version.description) == ["0.1.6", "0.1.5", "0.1.4"], "Sections: \(sections.map(\.title))")
        try require(sections[1].items == ["Build & Deployment", "Update per Klick"] && !sections.flatMap(\.items).contains("darf nicht erscheinen"),
                    "Items parsed wrongly")
        let pending = ReleaseNotes.between(sections, installed: ReleaseVersion("0.1.4"), latest: ReleaseVersion("0.1.6")!)
        try require(pending.map(\.version.description) == ["0.1.6", "0.1.5"], "Pending notes should cover every skipped release")
        try require(ReleaseNotes.between(sections, installed: ReleaseVersion("0.1.5"), latest: ReleaseVersion("0.1.5")!).isEmpty, "Nothing pending")
        try require(ReleaseNotes.between(sections, installed: nil, latest: ReleaseVersion("0.1.6")!).map(\.version.description) == ["0.1.6"],
                    "Development build sees latest notes only")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateFeedHTTP.self]
        let session = URLSession(configuration: config, delegate: UpdateTransport(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let service = UpdateService(session: session)
        UpdateFeedHTTP.reset(markdown)
        try require(await service.changelog() == markdown, "Changelog not loaded")
        let request = UpdateFeedHTTP.requests.first
        try require(request?.url?.host == "github.com" && request?.url?.path.hasSuffix("/download/CHANGELOG.md") == true
                    && request?.value(forHTTPHeaderField: "Authorization") == nil, "Changelog origin/credentials")
        UpdateFeedHTTP.reset("not found", status: 404)
        try require(await service.changelog() == nil, "Missing changelog must be nil (old releases)")
        UpdateFeedHTTP.reset(String(repeating: "x", count: 5000))
        try require(await service.changelog(maxBytes: 1000) == nil, "Oversized changelog accepted")

        _ = NSApplication.shared
        let view = UpdateInstallFlow.notesView(pending, emptyText: "leer")
        let text = ((view as? NSScrollView)?.documentView as? NSTextView)?.string ?? ""
        try require(text.contains("Version 0.1.6") && text.contains("Drag & Drop") && !text.contains("**"), "Notes not rendered: \(text)")
        try require(view.frame.height >= 60 && view.frame.height <= 260 && view.frame.width == 420, "Notes view size")
        let empty = ((UpdateInstallFlow.notesView([], emptyText: "Keine Notizen") as? NSScrollView)?.documentView as? NSTextView)?.string
        try require(empty == "Keine Notizen", "Empty notes text")
    }

    @Test func installerRespectsCancelledQuit() throws {
        let fallback = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("install.sh").path
        let source = try String(contentsOfFile: ProcessInfo.processInfo.environment["HEARTH_UPDATE_INSTALLER"] ?? fallback, encoding: .utf8)
        guard let start = source.range(of: "# Quit a running instance"),
              let end = source.range(of: "\nrm -rf \"$DEST\"", range: start.upperBound..<source.endIndex) else {
            throw SandboxGitRunner.Failure("Installer quit guard not found")
        }
        // Execute ONLY the quit guard with mocked commands. No download, filesystem
        // replacement, actual app quit or actual process lookup can run here.
        let script = """
        set -eu
        unset HEARTH_INSTALL_DIR
        pgrep() { return 0; }
        osascript() { return 1; }
        sleep() { :; }
        info() { :; }
        fail() { echo EXPECTED_CANCEL_GUARD; exit 73; }
        \(source[start.lowerBound..<end.lowerBound])
        echo UNSAFE_REACHED_INSTALL
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try require(process.terminationStatus == 73 && output.contains("EXPECTED_CANCEL_GUARD") && !output.contains("UNSAFE_REACHED_INSTALL"),
                    "Cancelled quit allows app replacement")
    }
}

private final class UpdateFeedHTTP: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var payload = Data()
    private static var status = 200
    private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    static func reset(_ body: String, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        payload = Data(body.utf8); self.status = status; recorded = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.recorded.append(request); let data = Self.payload; let status = Self.status; Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
