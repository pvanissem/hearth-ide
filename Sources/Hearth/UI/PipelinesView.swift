import SwiftUI
import AppKit

/// GitLab CI/CD pipelines of the workspace repository.
struct PipelinesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale
    let root: String

    private let remote = State(initialValue: GitLabRemote?.none)
    private let remoteChecked = State(initialValue: false)
    private let remoteRoot = State(initialValue: "")
    private let tokenInput = State(initialValue: "")
    private let onlyCurrentBranch = State(initialValue: true)
    private let pipelines = State(initialValue: [CIPipeline]())
    private let jobs = State(initialValue: [Int: [CIJob]]())
    private let expanded = State(initialValue: Set<Int>())
    private let error = State(initialValue: String?.none)
    private let loading = State(initialValue: false)
    private let log = State(initialValue: JobLog?.none)
    private let lastRefresh = State(initialValue: Date?.none)
    private let showList = State(initialValue: Set<Int>())     // pipelines shown as list instead of graph
    private let bigGraph = State(initialValue: CIPipeline?.none)
    private let confirmPlay = State(initialValue: CIJob?.none)
    private let confirmRun = State(initialValue: false)
    private let writingToken = State(initialValue: false)
    private let configureToken = State(initialValue: false)

    struct JobLog: Identifiable {
        let id = UUID()
        let job: CIJob
        var text: String?
    }

    private var api: GitLabAPI? {
        guard remoteRoot.wrappedValue == root, let r = remote.wrappedValue else { return nil }
        return model.gitLab.api(for: r)
    }

    var body: some View {
        Group {
            if !remoteChecked.wrappedValue {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if remote.wrappedValue == nil {
                ContentUnavailableView("Kein GitLab-Projekt", systemImage: "network.slash",
                                       description: Text("Das Repository hat keinen GitLab-Remote „origin“."))
            } else if api == nil || configureToken.wrappedValue {
                tokenSetup
            } else {
                content
            }
        }
        .task(id: "\(root)#\(model.workspace.revision)") {
            remoteChecked.wrappedValue = false
            remote.wrappedValue = nil
            let detected = await GitLabRemote.of(repo: root)
            guard !Task.isCancelled else { return }
            remote.wrappedValue = detected
            remoteRoot.wrappedValue = root
            if let r = remote.wrappedValue { await model.gitLab.load(for: r.origin) }
            remoteChecked.wrappedValue = true
            pipelines.wrappedValue = []
            jobs.wrappedValue = [:]
        }
        // Poll while visible: every 15 s if something runs, otherwise every 60 s.
        .task(id: "\(root)#\(remote.wrappedValue?.origin.value ?? "")#\(api != nil)#\(onlyCurrentBranch.wrappedValue)#\(model.workspace.gitSnapshot.branch)") {
            while !Task.isCancelled {
                await refresh()
                let active = pipelines.wrappedValue.contains { CIStatus.isActive($0.status) }
                try? await Task.sleep(for: .seconds(active ? 15 : 60))
            }
        }
        .sheet(item: log.projectedValue) { l in jobLogSheet(l) }
        .sheet(item: bigGraph.projectedValue) { p in bigGraphSheet(p) }
        .confirmationDialog("Manuellen Job „\(confirmPlay.wrappedValue?.name ?? "")“ starten?",
                            isPresented: Binding(get: { confirmPlay.wrappedValue != nil }, set: { if !$0 { confirmPlay.wrappedValue = nil } }),
                            presenting: confirmPlay.wrappedValue) { job in
            Button("Starten") { act("Job „\(job.name)“ gestartet") { try await $0.play(job: job.id) } }
        } message: { job in
            Text("Stage „\(job.stage)“. Manuelle Jobs sind oft Deployments oder andere Aktionen mit Wirkung außerhalb des Repos.")
        }
        .confirmationDialog("Neue Pipeline für „\(model.workspace.gitSnapshot.branch)“ starten?", isPresented: confirmRun.projectedValue) {
            Button("Pipeline starten") {
                let ref = model.workspace.gitSnapshot.branch
                act("Pipeline für \(ref) gestartet") { try await $0.runPipeline(ref: ref) }
            }
        } message: {
            Text("Gestartet wird der Stand auf GitLab (origin/\(model.workspace.gitSnapshot.branch)), nicht deine lokalen, ungepushten Änderungen.")
        }
    }

    // MARK: Token setup

    private var tokenSetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("GitLab-Zugang einrichten", systemImage: "key.fill").scaledFont(.headline)
            Text("Tokens werden nur an den unten ausdrücklich freigegebenen HTTPS-Origin gesendet und getrennt nach Server und Zugriff im Schlüsselbund gespeichert. Der alte globale Token wird nicht übernommen. Bitte zuerst die Serveradresse prüfen.")
                .scaledFont(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let r = remote.wrappedValue {
                Text(r.origin.value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Toggle("Separaten Schreibzugriff einrichten (api)", isOn: writingToken.projectedValue)
                Text(writingToken.wrappedValue ? "Nur für ausdrücklich ausgelöste Schreibaktionen; zusätzlich ist ein Lesetoken nötig." : "Für automatisches Laden reicht der Scope read_api.")
                    .scaledFont(.caption).foregroundStyle(.secondary)
                Link(destination: GitLabAPI.tokenPage(host: r.host, writing: writingToken.wrappedValue)) {
                    Label("Token in GitLab erstellen", systemImage: "arrow.up.forward.square")
                }
            }
            HStack {
                SecureField("Token einfügen", text: tokenInput.projectedValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveToken)
                Button("Server freigeben & speichern", action: saveToken)
                    .buttonStyle(.borderedProminent)
                    .disabled(tokenInput.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if api != nil {
                Button("Zurück zu Pipelines") { configureToken.wrappedValue = false }
                if let r = remote.wrappedValue {
                    Button("Serverfreigabe widerrufen", role: .destructive) {
                        model.gitLab.revoke(r.origin)
                        pipelines.wrappedValue = []
                        jobs.wrappedValue = [:]
                        tokenInput.wrappedValue = ""
                    }
                }
            }
            if let e = error.wrappedValue { Text(e).foregroundStyle(.orange) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func saveToken() {
        let t = tokenInput.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let r = remote.wrappedValue else { return }
        let alert = NSAlert()
        alert.messageText = "Diesen GitLab-Server freigeben?"
        alert.informativeText = "\(r.origin.value)\n\nNur dieser HTTPS-Origin erhält den Token. Zugriff: \(writingToken.wrappedValue ? "Schreiben (api)" : "Lesen (read_api)"). Keine Freigabe für andere Hosts oder Ports."
        alert.addButton(withTitle: "Freigeben")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if model.gitLab.save(t, for: r.origin, writing: writingToken.wrappedValue) {
            tokenInput.wrappedValue = ""
            configureToken.wrappedValue = false
            model.toast("GitLab-Token gespeichert")
        } else {
            error.wrappedValue = "Token konnte nicht im Schlüsselbund gespeichert werden."
        }
    }

    // MARK: Pipelines

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let e = error.wrappedValue {
                Label(e, systemImage: "exclamationmark.triangle").scaledFont(.caption).foregroundStyle(.orange)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if pipelines.wrappedValue.isEmpty && !loading.wrappedValue && error.wrappedValue == nil {
                ContentUnavailableView("Keine Pipelines", systemImage: "checklist",
                                       description: Text(onlyCurrentBranch.wrappedValue
                                                         ? "Für „\(model.workspace.gitSnapshot.branch)“ gibt es noch keine Pipeline."
                                                         : "Für dieses Projekt gibt es noch keine Pipeline."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(pipelines.wrappedValue) { pipelineRow($0) }
                    }
                    .padding(8)
                }
            }
        }
        .busyOverlay(loading.wrappedValue && pipelines.wrappedValue.isEmpty, label: "Lade Pipelines …")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted").foregroundStyle(.orange)
            Text(remote.wrappedValue?.path ?? "").scaledFont(.callout, bold: true).lineLimit(1).truncationMode(.head)
            Spacer()
            Button { configureToken.wrappedValue = true } label: { Image(systemName: "key") }
                .buttonStyle(.borderless).help("Zugriff für diesen GitLab-Server einrichten")
            Picker("", selection: onlyCurrentBranch.projectedValue) {
                Text(model.workspace.gitSnapshot.branch.isEmpty ? "Branch" : model.workspace.gitSnapshot.branch).tag(true)
                Text("Alle").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button { confirmRun.wrappedValue = true } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .disabled(model.workspace.gitSnapshot.branch.isEmpty)
                .help("Neue Pipeline für den aktuellen Branch starten")
            Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help(lastRefresh.wrappedValue.map { "Aktualisiert \($0.formatted(.relative(presentation: .named)))" } ?? "Aktualisieren")
            if let r = remote.wrappedValue {
                Button { NSWorkspace.shared.open(r.webURL.appendingPathComponent("-/pipelines")) } label: {
                    Image(systemName: "arrow.up.forward.square")
                }
                .buttonStyle(.borderless).help("Pipelines in GitLab öffnen")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func color(_ s: String) -> Color {
        switch s {
        case "success": .green
        case "failed": .red
        case "running": .blue
        case "canceled", "canceling", "skipped": .secondary
        case "manual": .purple
        default: .orange
        }
    }

    private func pipelineRow(_ p: CIPipeline) -> some View {
        let open = expanded.wrappedValue.contains(p.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right").font(.system(size: 9 * scale, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(.secondary)
                Image(systemName: CIStatus.symbol(p.status)).foregroundStyle(color(p.status))
                    .symbolEffect(.pulse, isActive: p.status == "running")
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("#\(p.iid)").scaledFont(.callout, bold: true, digits: true)
                        Text(p.ref).scaledFont(.callout, mono: true).lineLimit(1)
                        Text(String(p.sha.prefix(8))).scaledFont(.caption, mono: true).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 4) {
                        Text(CIStatus.label(p.status)).foregroundStyle(color(p.status))
                        if let d = p.createdAt { Text("· \(d.formatted(.relative(presentation: .named)))") }
                        if !p.source.isEmpty { Text("· \(p.source)") }
                    }
                    .scaledFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .interactiveRow {
                withAnimation(.easeOut(duration: 0.15)) {
                    if open { expanded.wrappedValue.remove(p.id) } else { expanded.wrappedValue.insert(p.id) }
                }
                if !open { Task { await loadJobs(p.id) } }
            }
            .contextMenu {
                if let url = p.webURL {
                    Button { NSWorkspace.shared.open(url) } label: { Label("In GitLab öffnen", systemImage: "arrow.up.forward.square") }
                }
                if p.status == "failed" || p.status == "canceled" {
                    Button { act("Pipeline #\(p.iid) wird wiederholt") { try await $0.retry(pipeline: p.id) } } label: {
                        Label("Fehlgeschlagene Jobs wiederholen", systemImage: "arrow.clockwise")
                    }
                }
                if CIStatus.isActive(p.status) {
                    Button(role: .destructive) { act("Pipeline #\(p.iid) wird abgebrochen") { try await $0.cancel(pipeline: p.id) } } label: {
                        Label("Abbrechen", systemImage: "stop.circle")
                    }
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.sha, forType: .string)
                    model.toast("Commit-SHA kopiert")
                } label: { Label("Commit-SHA kopieren", systemImage: "doc.on.doc") }
            }
            if open { stages(p).padding(.leading, 24) }
        }
    }

    @ViewBuilder
    private func stages(_ p: CIPipeline) -> some View {
        if let list = jobs.wrappedValue[p.id] {
            let asList = showList.wrappedValue.contains(p.id)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Picker("", selection: Binding(get: { asList }, set: { list in
                        if list { showList.wrappedValue.insert(p.id) } else { showList.wrappedValue.remove(p.id) }
                    })) {
                        Label("Diagramm", systemImage: "point.3.filled.connected.trianglepath.dotted").tag(false)
                        Label("Liste", systemImage: "list.bullet").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    if !asList {
                        Button { bigGraph.wrappedValue = p } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                            .buttonStyle(.borderless).help("Diagramm groß anzeigen")
                    }
                }
                if asList {
                    let order = list.reduce(into: [String]()) { if !$0.contains($1.stage) { $0.append($1.stage) } }
                    ForEach(order, id: \.self) { stage in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stage).scaledFont(.caption, bold: true).foregroundStyle(.secondary)
                            ForEach(list.filter { $0.stage == stage }) { jobRow($0) }
                        }
                    }
                } else {
                    PipelineGraph(jobs: list, onSelect: openLog, onRetry: retryJob, onPlay: { confirmPlay.wrappedValue = $0 })
                        .frame(height: graphHeight(list))
                        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        } else {
            HStack { ProgressView().controlSize(.small); Text("Lade Jobs …").scaledFont(.caption) }
        }
    }

    private func jobRow(_ j: CIJob) -> some View {
        HStack(spacing: 6) {
            Image(systemName: CIStatus.symbol(j.status)).foregroundStyle(color(j.status))
            Text(j.name).scaledFont(.callout).lineLimit(1)
            if j.allowFailure && j.status == "failed" {
                Text("erlaubt").scaledFont(.caption2).foregroundStyle(.orange)
            }
            Spacer()
            if let d = j.duration {
                Text(d < 60 ? "\(Int(d)) s" : "\(Int(d) / 60) min \(Int(d) % 60) s")
                    .scaledFont(.caption2, digits: true).foregroundStyle(.secondary)
            }
            if j.status == "manual" {
                CircleAction(symbol: "play.fill", tint: .purple, help: "Manuellen Job starten") { confirmPlay.wrappedValue = j }
            } else if j.status == "failed" || j.status == "canceled" {
                CircleAction(symbol: "arrow.clockwise", tint: .orange, help: "Job wiederholen") { retryJob(j) }
            }
        }
        .interactiveRow { openLog(j) }
        .help("Klicken für das Job-Log")
        .contextMenu {
            Button { openLog(j) } label: { Label("Log anzeigen", systemImage: "doc.text") }
            if let url = j.webURL {
                Button { NSWorkspace.shared.open(url) } label: { Label("In GitLab öffnen", systemImage: "arrow.up.forward.square") }
            }
            if j.status == "manual" {
                Button { confirmPlay.wrappedValue = j } label: { Label("Manuell starten …", systemImage: "play.fill") }
            }
            if PipelineGraph.retryable(j) {
                Button { retryJob(j) } label: { Label("Job wiederholen", systemImage: "arrow.clockwise") }
            }
        }
    }

    private func graphHeight(_ jobs: [CIJob]) -> CGFloat {
        let perStage = Dictionary(grouping: jobs, by: \.stage).values.map(\.count).max() ?? 1
        return min(CGFloat(perStage) * 40 * scale + 70 * scale, 420)
    }

    private func retryJob(_ j: CIJob) {
        act("Job „\(j.name)“ wird wiederholt") { try await $0.retry(job: j.id) }
    }

    private func bigGraphSheet(_ p: CIPipeline) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: CIStatus.symbol(p.status)).foregroundStyle(PipelineGraph.color(p.status))
                Text("Pipeline #\(p.iid)").font(.headline)
                Text(p.ref).font(.callout.monospaced()).foregroundStyle(.secondary)
                Text(CIStatus.label(p.status)).foregroundStyle(PipelineGraph.color(p.status))
                Spacer()
                if let url = p.webURL { Button("In GitLab öffnen") { NSWorkspace.shared.open(url) } }
                Button("Schließen") { bigGraph.wrappedValue = nil }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            PipelineGraph(jobs: jobs.wrappedValue[p.id] ?? [], large: true, onSelect: { job in
                bigGraph.wrappedValue = nil
                Task { try? await Task.sleep(for: .milliseconds(300)); openLog(job) }
            }, onRetry: retryJob, onPlay: { job in
                bigGraph.wrappedValue = nil
                Task { try? await Task.sleep(for: .milliseconds(300)); confirmPlay.wrappedValue = job }
            })
        }
        .frame(minWidth: 900, minHeight: 500)
    }

    // MARK: Job log

    private func jobLogSheet(_ l: JobLog) -> some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: CIStatus.symbol(l.job.status)).foregroundStyle(color(l.job.status))
                Text(l.job.name).font(.headline)
                Text(l.job.stage).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let url = l.job.webURL {
                    Button("In GitLab öffnen") { NSWorkspace.shared.open(url) }
                }
                Button("Schließen") { log.wrappedValue = nil }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            if let text = l.text {
                CodeEditor(text: .constant(text), language: .shell, editable: false,
                           highlightLine: text.split(separator: "\n", omittingEmptySubsequences: false).count)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 900, height: 600)
    }

    private func openLog(_ job: CIJob) {
        log.wrappedValue = JobLog(job: job, text: nil)
        guard let api else { return }
        Task {
            do {
                let raw = try await api.trace(job: job.id)
                // Strip ANSI colors and GitLab section markers; keep the tail of huge logs.
                let clean = raw.strippingANSI
                    .replacingOccurrences(of: #"section_(start|end):\d+:[^\n\r]*?(\r|\n)?"#, with: "", options: .regularExpression)
                let lines = clean.split(separator: "\n", omittingEmptySubsequences: false)
                let text = lines.count > 3000 ? "… (\(lines.count - 3000) Zeilen gekürzt)\n" + lines.suffix(3000).joined(separator: "\n") : clean
                log.wrappedValue?.text = text.isEmpty ? "(leeres Log)" : text
            } catch {
                log.wrappedValue?.text = "Log konnte nicht geladen werden: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Loading & actions

    private func refresh() async {
        guard let api else { return }
        loading.wrappedValue = true
        defer { loading.wrappedValue = false }
        do {
            let ref = onlyCurrentBranch.wrappedValue && !model.workspace.gitSnapshot.branch.isEmpty ? model.workspace.gitSnapshot.branch : nil
            let list = try await api.pipelines(ref: ref)
            guard !Task.isCancelled, self.api?.remote == api.remote else { return }
            pipelines.wrappedValue = list
            error.wrappedValue = nil
            lastRefresh.wrappedValue = Date()
            for id in expanded.wrappedValue where pipelines.wrappedValue.contains(where: { $0.id == id }) {
                await loadJobs(id)
            }
        } catch {
            self.error.wrappedValue = error.localizedDescription
        }
    }

    private func loadJobs(_ pipeline: Int) async {
        guard let api else { return }
        if let list = try? await api.jobs(pipeline: pipeline), !Task.isCancelled, self.api?.remote == api.remote {
            jobs.wrappedValue[pipeline] = list
        }
    }

    private func act(_ message: String, _ action: @escaping (GitLabAPI) async throws -> Void) {
        guard remoteRoot.wrappedValue == root, let r = remote.wrappedValue, let api = model.gitLab.api(for: r, writing: true) else {
            writingToken.wrappedValue = true
            configureToken.wrappedValue = true
            model.banner = "Bitte separaten Schreibzugriff für diesen GitLab-Server freigeben."
            return
        }
        Task {
            do {
                try await action(api)
                model.toast(message)
                try? await Task.sleep(for: .seconds(1))
                await refresh()
            } catch {
                model.banner = error.localizedDescription
            }
        }
    }
}
