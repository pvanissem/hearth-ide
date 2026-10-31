import Foundation
import AppKit
import SwiftUI
import Testing
@testable import Hearth

@MainActor
struct ChatFeedbackTests {
    static let providerMessage = "This content was flagged for possible cybersecurity risk. If this seems wrong, try rephrasing your request. If you’re doing authorized security work that requires more cyber permissive safeguards, apply for Daybreak access via https://platform.openai.com/settings/organization/status-and-access before retrying."

    static var chain: String {
        let body = ["error": ["message": providerMessage, "code": "cyber_policy"]]
        let json = String(data: try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!
        return "Error: reading rate-limited responses stream: reading program fingerprint response stream: reading usage tracking responses stream: reading encrypted response stream: reading from source stream: reading responses stream: reading SSE event: " + json
    }

    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw SandboxGitRunner.Failure(message) }
    }
    private func json(_ data: [String: Any]) throws -> JSON {
        JSON.parse(try JSONSerialization.data(withJSONObject: data))!
    }

    @Test func providerFailuresSurviveHistoryParsing() throws {
        guard let failure = ChatFailure.parse(.string(Self.chain)) else { throw SandboxGitRunner.Failure("Provider error not parsed") }
        try require(failure.code == "cyber_policy" && failure.message == Self.providerMessage, "Wrapped SSE error not decoded")
        try require(failure.detail == Self.chain, "Original error chain lost")
        try require(failure.title.contains("Sicherheitsrichtlinie"), "Policy block misreported as rate limit")
        let structured: [String: Any] = ["type": "ProviderRequestError", "message": Self.chain]
        let user = try json(["id": "u1", "type": "user", "text": "Test"])
        let assistant = try json(["id": "a1", "type": "assistant", "content": [], "error": structured])
        let idle = try json(["id": "i1", "type": "idle", "outcome": "failed", "error": structured])
        let history = ChatTranscript.history([user, assistant, idle])
        try require(history.count == 2 && ChatTranscript.hasCurrentFailure(history, matching: failure), "Error without answer text disappeared or duplicated")
        let historicalIdle = ChatTranscript.history([user, idle])
        try require(historicalIdle.count == 2 && ChatTranscript.hasCurrentFailure(historicalIdle), "Persisted idle error ignored on reload")

        let partial = try json(["id": "partial", "type": "assistant", "content": [["type": "text", "text": "Partial answer"]], "error": structured])
        try require(ChatMessage(json: partial)?.text == "Partial answer", "Error discarded partial answer")
        let generic = try json(["id": "generic", "type": "assistant", "content": [], "finish": "error"])
        let upgraded = ChatTranscript.history([user, generic, idle])
        try require(upgraded.count == 2 && ChatTranscript.hasCurrentFailure(upgraded, matching: failure), "Generic failure not upgraded to provider details")
        let live = ChatTranscript.withLiveFailure(ChatTranscript.history([user, generic]), failure: failure)
        try require(ChatTranscript.hasCurrentFailure(live, matching: failure), "Live details lost on generic history reload")
        let nextUser = try json(["id": "u2", "type": "user", "text": "Another request"])
        let nextIdle = try json(["id": "i2", "type": "idle", "outcome": "failed", "error": structured])
        let repeated = ChatTranscript.history([user, idle, nextUser, nextIdle])
        try require(repeated.count == 4, "Independent failed attempts deduplicated across turns")

        let body = String(data: try JSONSerialization.data(withJSONObject: ["error": ["message": Self.providerMessage, "code": "cyber_policy"]]), encoding: .utf8)!
        let http = ChatFailure.http(status: 403, body: body)
        try require(http.message == Self.providerMessage && http.detail == body && http.status == 403, "HTTP response was truncated")
        try require(http.signature == failure.signature, "HTTP/SSE error duplicated due to optional status")
        try require(ChatFailure.parse(.null) == nil && ChatFailure.parse(.string("  ")) == nil, "Empty error fabricated")
        let malformed = "reading SSE event: {\"error\":{\"message\":\"truncated"
        try require(ChatFailure.parse(.string(malformed))?.detail == malformed, "Malformed payload not preserved as text")
    }

    @Test func activityOnlyWhileAgentWorks() throws {
        try require(ChatActivity.showsWorking(status: .running, awaitingInput: false, connectionFailed: false), "Running state has no feedback")
        for status in [AgentStatus.idle, .done, .blocked, .needsInput, .inactive] {
            try require(!ChatActivity.showsWorking(status: status, awaitingInput: false, connectionFailed: false), "Inactive/failed state animates")
        }
        try require(!ChatActivity.showsWorking(status: .running, awaitingInput: true, connectionFailed: false), "Permission/form wait animates as work")
        try require(!ChatActivity.showsWorking(status: .running, awaitingInput: false, connectionFailed: true), "Disconnected agent animates as work")
    }

    @Test func liveErrorsSurviveSessionRefresh() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatStateHTTP.self]
        let transport = URLSession(configuration: config)
        defer { transport.invalidateAndCancel() }
        let entry = try JSONDecoder().decode(WebSessionEntry.self, from: Data(#"{"id":"server","repoRoot":"/workspace","port":"12345","status":"running"}"#.utf8))
        let client = OpenCodeClient(baseURL: URL(string: "http://127.0.0.1:12345")!, password: "dummy", transportSession: transport)
        var notifications = 0
        let connection = ServerConnection(entry: entry, client: client, notify: { _, _ in notifications += 1 })
        // Avoid plugin discovery or real configuration reads in tests.
        connection.agents = [AgentInfo(id: "build", name: "build", description: nil)]
        try await connection.reload()
        connection.beginRun("s1", submitting: true)
        try require(connection.sessions["s1"]?.status == .running, "No activity before first server token")
        var observerSawFailure = false
        connection.onEvent = { [weak connection] type, _ in
            if type == "session.error" {
                observerSawFailure = connection?.sessions["s1"]?.status == .blocked && connection?.sessionFailures["s1"]?.code == "cyber_policy"
            }
        }
        connection.handle(try json(["type": "session.error", "data": ["sessionID": "s1", "error": ["type": "ProviderRequestError", "message": Self.chain]]]))
        connection.handle(try json(["type": "session.execution.failed", "data": ["sessionID": "s1"]]))
        try require(observerSawFailure, "Chat consumer saw stale status instead of failure")
        try require(connection.sessionFailures["s1"]?.detail == Self.chain, "Generic event overwrote provider detail")
        try require(connection.sessionFailures["s2"] == nil, "Failure leaked into another session")
        try require(notifications == 1, "Duplicate failure notifications")
        try await connection.reload()
        try require(connection.sessions["s1"]?.status == .blocked && connection.sessionFailures["s1"]?.code == "cyber_policy", "Reload discarded live error")
        connection.beginRun("s1", submitting: true)
        try await connection.reload()
        try require(connection.sessions["s1"]?.status == .running && connection.sessionFailures["s1"] == nil, "Old failed snapshot hid a new submission")
        connection.finishSubmission("s1")
        connection.handle(try json(["type": "session.execution.succeeded", "data": ["sessionID": "s1"]]))
        try require(connection.sessions["s1"]?.status == .done && connection.sessions["s1"]?.lastError == nil, "Success did not stop/clear activity")
        connection.handle(try json(["type": "session.execution.started", "data": ["sessionID": "s1"]]))
        connection.handle(try json(["type": "session.execution.interrupted", "data": ["sessionID": "s1"]]))
        try require(connection.sessions["s1"]?.status == .idle, "Stop left agent running")
    }

    @Test func feedbackViewsRender() async throws {
        _ = NSApplication.shared
        for dark in [false, true] {
            let size = CGSize(width: 600, height: 360)
            let content = VStack(alignment: .leading, spacing: 12) {
                AgentWorkingIndicator(animates: false)
                ChatFailureCard(failure: ChatFailure.parse(.string(Self.chain))!)
                Spacer()
            }.padding(16)
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            try require(host.frame.width == size.width, "Feedback view layout failed")
            if let dir = ProcessInfo.processInfo.environment["HEARTH_SECURITY_FIXTURES"], let layer = host.layer,
               let ctx = CGContext(data: nil, width: 1200, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                window.appearance?.performAsCurrentDrawingAppearance { ctx.setFillColor(NSColor.windowBackgroundColor.cgColor) }
                ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 720))
                ctx.translateBy(x: 0, y: 720); ctx.scaleBy(x: 2, y: -2)
                layer.render(in: ctx)
                if let image = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                    try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("chat-feedback-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}

private final class ChatStateHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data: Any
        switch request.url!.path {
        case "/api/session":
            data = [
                ["id": "s1", "title": "Test", "outcome": "failed", "time": ["created": 1, "updated": 2]],
                ["id": "s2", "title": "Other", "outcome": "succeeded", "time": ["created": 1, "updated": 2]]
            ]
        case "/api/session/active": data = [String: String]()
        default: data = [String]()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["data": data]))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
