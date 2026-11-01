import Foundation
import Testing
@testable import Hearth

@Suite(.serialized)
struct GitHubActionsTests {
    static let repo = CIRemote.parse("git@github.com:octo/app.git")!

    private func client(writing: Bool = false, remote: CIRemote = repo) -> (GitHubAPI, URLSession) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeGitHub.self]
        let session = URLSession(configuration: config, delegate: NoRedirectTransport(), delegateQueue: nil)
        let credential = CICredential(origin: Self.repo.origin, token: "dummy-gh-token", allowsWrites: writing)
        return (GitHubAPI(remote: remote, credential: credential, session: session, logSession: session), session)
    }

    @Test func remotesAreRecognised() throws {
        #expect(Self.repo.provider == .gitHub && Self.repo.path == "octo/app")
        #expect(Self.repo.apiBase.absoluteString == "https://api.github.com")
        #expect(Self.repo.pipelinesPage.absoluteString == "https://github.com/octo/app/actions")
        let https = try need(CIRemote.parse("https://github.com/octo/app"))
        #expect(https.provider == .gitHub && https.origin == Self.repo.origin)
        let enterprise = try need(CIRemote.parse("https://github.acme.example/team/tool.git"))
        #expect(enterprise.provider == .gitHub && enterprise.apiBase.absoluteString == "https://github.acme.example/api/v3")
        let gitLab = try need(CIRemote.parse("git@gitlab.example.test:group/sub/project.git"))
        #expect(gitLab.provider == .gitLab && gitLab.apiBase.absoluteString == "https://gitlab.example.test/api/v4")
    }

    @Test func runsAndJobsMapToPipelines() async throws {
        FakeGitHub.reset()
        let (api, session) = client()
        defer { session.invalidateAndCancel() }
        let runs = try await api.pipelines(ref: "main")
        #expect(runs.map(\.status) == ["running", "failed", "success", "canceled"])
        #expect(runs[0].iid == 42 && runs[0].ref == "main" && runs[0].name == "CI" && runs[0].source == "push")
        #expect(runs[0].webURL?.absoluteString == "https://github.com/octo/app/actions/runs/7")
        let request = try need(FakeGitHub.requests.first)
        #expect(request.url?.host == "api.github.com" && request.url?.path == "/repos/octo/app/actions/runs")
        #expect(request.url?.query?.contains("branch=main") == true)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer dummy-gh-token")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")

        let jobs = try await api.jobs(pipeline: 7)
        #expect(jobs.map(\.stage) == ["build", "build", "CI"])
        #expect(jobs.map(\.name) == ["macos", "linux", "lint"])
        #expect(jobs[0].duration == 90 && jobs[0].status == "success" && jobs[2].status == "running")
    }

    @Test func logsFollowTheSignedURLWithoutToken() async throws {
        FakeGitHub.reset()
        let (api, session) = client()
        defer { session.invalidateAndCancel() }
        let log = try await api.log(job: 11)
        #expect(log == "▸ Run tests\nok\n✖ boom\n")
        let signed = try need(FakeGitHub.requests.first { $0.url?.host == "logs.example.test" })
        #expect(signed.value(forHTTPHeaderField: "Authorization") == nil, "Token sent to the log storage")
    }

    @Test func writesNeedAWriteTokenAndTheApprovedOrigin() async throws {
        FakeGitHub.reset()
        let (reader, s1) = client()
        defer { s1.invalidateAndCancel() }
        await #expect(throws: GitHubAPI.APIError.readOnly) { try await reader.retry(job: 11) }
        #expect(FakeGitHub.requests.isEmpty)

        let (writer, s2) = client(writing: true)
        defer { s2.invalidateAndCancel() }
        let workflows = try await writer.workflows()
        #expect(workflows.map(\.name) == ["Deploy"], "Disabled workflows offered")
        try await writer.run(ref: "main", workflow: workflows[0])
        let dispatch = try need(FakeGitHub.requests.last)
        #expect(dispatch.httpMethod == "POST" && dispatch.url?.path == "/repos/octo/app/actions/workflows/5/dispatches")
        #expect(FakeGitHub.lastBody == #"{"ref":"main"}"#)
        try await writer.retry(pipeline: 7)
        #expect(FakeGitHub.requests.last?.url?.path == "/repos/octo/app/actions/runs/7/rerun-failed-jobs")

        // A token approved for github.com is never sent for another host.
        let other = try need(CIRemote.parse("https://github.evil.example/octo/app"))
        let (foreign, s3) = client(remote: other)
        defer { s3.invalidateAndCancel() }
        FakeGitHub.reset()
        await #expect(throws: GitHubAPI.APIError.unauthorizedOrigin) { _ = try await foreign.pipelines(ref: nil) }
        #expect(FakeGitHub.requests.isEmpty)
    }

    @Test func renamedRepositoriesFollowGitHubsMove() async throws {
        FakeGitHub.reset()
        let old = try need(CIRemote.parse("git@github.com:octo/old-name.git"))
        let (api, session) = client(remote: old)
        defer { session.invalidateAndCancel() }
        let runs = try await api.pipelines(ref: "main")
        #expect(runs.count == 4, "Moved repository not followed")
        let moved = try need(FakeGitHub.requests.last)
        #expect(moved.url?.path == "/repositories/99/actions/runs" && moved.url?.query?.contains("branch=main") == true)
        #expect(moved.value(forHTTPHeaderField: "Authorization") == "Bearer dummy-gh-token")
        // Only GitHub's moved-repository address on the same API origin is followed.
        let base = URL(string: "https://api.github.com")!
        #expect(GitHubAPI.movedRepositoryURL("https://api.github.com/repositories/99/actions/runs", apiBase: base) != nil)
        #expect(GitHubAPI.movedRepositoryURL("https://evil.example/repositories/99/actions/runs", apiBase: base) == nil)
        #expect(GitHubAPI.movedRepositoryURL("http://api.github.com/repositories/99/actions/runs", apiBase: base) == nil)
        #expect(GitHubAPI.movedRepositoryURL("https://api.github.com/user", apiBase: base) == nil)
        #expect(GitHubAPI.movedRepositoryURL("https://x@api.github.com/repositories/99/actions/runs", apiBase: base) == nil)
    }

    @Test func statusVocabulary() {
        #expect(GitHubAPI.status("completed", "timed_out") == "failed")
        #expect(GitHubAPI.status("completed", "action_required") == "manual")
        #expect(GitHubAPI.status("queued", nil) == "pending")
        #expect(GitHubAPI.status("waiting", nil) == "pending")
        #expect(GitHubAPI.cleanLog("\u{FEFF}2026-11-01T07:05:28.3680690Z hello\n2026-11-01T07:05:29Z ##[warning]careful\n") == "hello\n⚠ careful\n")
    }
}

/// api.github.com and a log storage host, recording every request.
private final class FakeGitHub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) static var lastBody: String?
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = []; lastBody = nil } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body: Data?
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
            while case let n = stream.read(&buffer, maxLength: buffer.count), n > 0 { data.append(contentsOf: buffer.prefix(n)) }
            stream.close()
            body = data
        }
        Self.lock.withLock {
            Self.recorded.append(request)
            if let b = body ?? request.httpBody { Self.lastBody = String(decoding: b, as: UTF8.self) }
        }
        let url = request.url!
        func reply(_ code: Int, _ text: String, headers: [String: String] = [:]) {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!,
                                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        if url.host == "logs.example.test" {
            return reply(200, "2026-11-01T07:05:28.1Z ##[group]Run tests\n2026-11-01T07:05:28.2Z ok\n2026-11-01T07:05:28.3Z ##[endgroup]\n2026-11-01T07:05:28.4Z ##[error]boom\n")
        }
        guard url.host == "api.github.com", request.value(forHTTPHeaderField: "Authorization") == "Bearer dummy-gh-token" else {
            return reply(401, "{}")
        }
        switch (request.httpMethod ?? "GET", url.path) {
        case ("GET", "/repos/octo/old-name/actions/runs"):
            reply(301, #"{"message":"Moved Permanently"}"#,
                  headers: ["Location": "https://api.github.com/repositories/99/actions/runs?" + (url.query ?? "")])
        case ("GET", "/repos/octo/app/actions/runs"), ("GET", "/repositories/99/actions/runs"):
            reply(200, """
            {"workflow_runs":[
             {"id":7,"run_number":42,"head_branch":"main","head_sha":"abc","status":"in_progress","conclusion":null,"event":"push","name":"CI","created_at":"2026-11-01T07:00:00Z","html_url":"https://github.com/octo/app/actions/runs/7"},
             {"id":6,"run_number":41,"head_branch":"main","head_sha":"abd","status":"completed","conclusion":"failure","event":"push","name":"CI"},
             {"id":5,"run_number":40,"head_branch":"main","head_sha":"abe","status":"completed","conclusion":"success","event":"workflow_dispatch","name":"Deploy"},
             {"id":4,"run_number":39,"head_branch":"main","head_sha":"abf","status":"completed","conclusion":"cancelled","event":"push","name":"CI"}]}
            """)
        case ("GET", "/repos/octo/app/actions/runs/7/jobs"):
            reply(200, """
            {"jobs":[
             {"id":11,"name":"build / macos","status":"completed","conclusion":"success","started_at":"2026-11-01T07:00:00Z","completed_at":"2026-11-01T07:01:30Z"},
             {"id":12,"name":"build / linux","status":"queued","conclusion":null},
             {"id":13,"name":"lint","status":"in_progress","conclusion":null,"workflow_name":"CI"}]}
            """)
        case ("GET", "/repos/octo/app/actions/jobs/11/logs"):
            reply(302, "", headers: ["Location": "https://logs.example.test/signed?sig=1"])
        case ("GET", "/repos/octo/app/actions/workflows"):
            reply(200, #"{"workflows":[{"id":5,"name":"Deploy","path":".github/workflows/deploy.yml","state":"active"},{"id":6,"name":"Old","path":"x","state":"disabled_manually"}]}"#)
        case ("POST", _):
            reply(204, "")
        default:
            reply(404, "{}")
        }
    }
    override func stopLoading() {}
}
