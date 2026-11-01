import Foundation
import Observation

/// State and loading of the CI/CD pane for one workspace folder: the detected remote, its
/// pipelines (or workflow runs), their jobs and the polling while the pane is visible.
/// The view only draws it; everything here runs with fakes in the tests.
@MainActor
@Observable
final class PipelinesStore {
    struct Dependencies {
        /// The repository's CI remote (`origin`), nil without a GitLab/GitHub remote.
        var detectRemote: (String) async -> CIRemote?
        /// Loads the stored tokens for a server (once per origin).
        var loadCredentials: (CIOrigin) async -> Void
        /// A read-only client, nil until a read token is approved.
        var client: (CIRemote) -> (any CIClient)?
    }

    private(set) var root = ""
    private(set) var remote: CIRemote?
    /// The remote of `root` has been looked up (the pane shows a spinner until then).
    private(set) var remoteChecked = false
    private(set) var pipelines: [CIPipeline] = []
    private(set) var jobs: [Int: [CIJob]] = [:]
    private(set) var workflows: [CIWorkflow] = []
    var expanded: Set<Int> = []
    var onlyCurrentBranch = true
    var error: String?
    private(set) var loading = false
    private(set) var lastRefresh: Date?

    @ObservationIgnored private let deps: Dependencies

    init(_ deps: Dependencies) { self.deps = deps }

    /// The read client for the current folder's remote.
    var api: (any CIClient)? { remote.flatMap(deps.client) }

    /// While something runs, poll every 15 s, otherwise every 60 s.
    static func pollInterval(_ pipelines: [CIPipeline]) -> Duration {
        pipelines.contains { CIStatus.isActive($0.status) } ? .seconds(15) : .seconds(60)
    }

    /// A new folder: forget everything and look up its remote.
    func open(root: String) async {
        self.root = root
        remoteChecked = false
        remote = nil
        clearResults()
        let detected = await deps.detectRemote(root)
        guard !Task.isCancelled, self.root == root else { return }
        if let detected { await deps.loadCredentials(detected.origin) }
        guard !Task.isCancelled, self.root == root else { return }
        remote = detected
        remoteChecked = true
    }

    /// Files changed (an agent at work): look at the remote again, quietly. Pipelines are
    /// only cleared if the remote really changed; polling takes care of new runs.
    func recheckRemote() async {
        let root = root
        guard remoteChecked, !root.isEmpty else { return }
        let detected = await deps.detectRemote(root)
        guard !Task.isCancelled, self.root == root,
              detected?.origin != remote?.origin || detected?.path != remote?.path else { return }
        if let detected { await deps.loadCredentials(detected.origin) }
        guard !Task.isCancelled, self.root == root else { return }
        remote = detected
        clearResults()
    }

    /// Loads the runs (of `branch` when only the current branch is shown) and the jobs of
    /// expanded runs. Keeps the old list while loading, so the pane doesn't flicker.
    func refresh(branch: String) async {
        guard let api else { return }
        let root = root
        loading = true
        defer { loading = false }
        do {
            let ref = onlyCurrentBranch && !branch.isEmpty ? branch : nil
            let list = try await api.pipelines(ref: ref)
            guard !Task.isCancelled, self.root == root, self.api?.remote == api.remote else { return }
            pipelines = list
            error = nil
            lastRefresh = Date()
            for id in expanded where list.contains(where: { $0.id == id }) {
                await loadJobs(id)
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    /// Refreshes until the task is cancelled (the pane disappears or its inputs change).
    func poll(branch: String, sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        while !Task.isCancelled {
            await refresh(branch: branch)
            do { try await sleep(Self.pollInterval(pipelines)) } catch { return }
        }
    }

    func loadJobs(_ pipeline: Int) async {
        guard let api else { return }
        if let list = try? await api.jobs(pipeline: pipeline), !Task.isCancelled, self.api?.remote == api.remote {
            jobs[pipeline] = list
        }
    }

    func loadWorkflows() async {
        guard let api else { workflows = []; return }
        workflows = (try? await api.workflows()) ?? []
    }

    /// The server approval was revoked.
    func clearResults() {
        pipelines = []
        jobs = [:]
        workflows = []
        error = nil
        lastRefresh = nil
    }
}
