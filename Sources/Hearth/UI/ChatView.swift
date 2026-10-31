import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    private let followsLatest = State(initialValue: true)

    var body: some View {
        let connection = model.server(for: model.selectedServerID)
        content.task(id: connection.map(ObjectIdentifier.init)) { await watchModels(connection) }
    }

    @ViewBuilder private var content: some View {
        if let run = model.agents.selectedRun {
            AgentRunView(run: run).id(run.id)
        } else if let session = model.selectedSession {
            let generation = model.chatViewGeneration
            let displayedMessages = ChatTranscript.withLiveFailure(model.messages, failure: currentFailure(session))
            VStack(spacing: 0) {
                header(session)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(displayedMessages) { MessageBubble(message: $0) }
                            if model.chatIsLoading && displayedMessages.isEmpty {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Chatverlauf wird geladen …").scaledFont(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if let failure = currentFailure(session), !ChatTranscript.hasCurrentFailure(displayedMessages, matching: failure) {
                                ChatFailureCard(failure: failure)
                            } else if session.status == .blocked, !ChatTranscript.hasCurrentFailure(displayedMessages), currentFailure(session) == nil {
                                ChatFailureCard(failure: .unspecified)
                            }
                            if let connectionError = model.server(for: session.serverID)?.error {
                                ChatFailureCard(failure: ChatFailure(message: connectionError), title: "Verbindung zum Agenten unterbrochen")
                            } else if let failure = model.chatLoadFailure {
                                ChatFailureCard(failure: failure, title: "Chatverlauf konnte nicht geladen werden")
                            }
                            ForEach(permissions(for: session)) { PermissionCard(request: $0) }
                            ForEach(forms(for: session)) { FormCard(form: $0).id($0.id) }
                            if isWorking(session) {
                                AgentWorkingIndicator(label: model.chatIsSynchronizing ? "Live-Antwort wird synchronisiert …" : "Agent arbeitet …")
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding()
                        .background(ChatScrollTracking { atBottom in
                            guard model.chatViewGeneration == generation else { return }
                            followsLatest.wrappedValue = atBottom
                        })
                    }
                    .onChange(of: model.messages) { if followsLatest.wrappedValue { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: forms(for: session).count) { if followsLatest.wrappedValue { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: permissions(for: session).count) { if followsLatest.wrappedValue { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: currentFailure(session)) { if followsLatest.wrappedValue { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: model.chatLoadFailure) { if followsLatest.wrappedValue { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: model.server(for: session.serverID)?.error) { if followsLatest.wrappedValue { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: session.status) { if followsLatest.wrappedValue { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: isWorking(session)) { if followsLatest.wrappedValue { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: generation, initial: true) {
                        followsLatest.wrappedValue = true
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if !followsLatest.wrappedValue {
                            Button {
                                followsLatest.wrappedValue = true
                                proxy.scrollTo("bottom", anchor: .bottom)
                            } label: { Label("Zur neuesten Nachricht", systemImage: "arrow.down") }
                                .buttonStyle(.borderedProminent).controlSize(.small).padding(10)
                        }
                    }
                }
                composer(session)
            }
            .id(generation)
        } else if let conn = model.server(for: model.selectedServerID) {
            ContentUnavailableView {
                Label(conn.entry.displayName, systemImage: "shippingbox")
            } description: {
                Text(conn.entry.repoRoot)
            } actions: {
                Button("Neue Session starten") {
                    let generation = model.chatViewGeneration
                    Task { await model.newSession(on: conn.id, expectedGeneration: generation) }
                }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            ContentUnavailableView("Keine Session ausgewählt",
                                   systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Wähle links eine Session oder starte eine Sandbox."))
        }
    }

    private func permissions(for session: SessionItem) -> [PermissionRequest] {
        model.server(for: session.serverID)?.permissions.values
            .filter { $0.sessionID == session.id } ?? []
    }

    private func forms(for session: SessionItem) -> [FormRequest] {
        model.server(for: session.serverID)?.forms.values
            .filter { $0.sessionID == session.id }.sorted { $0.id < $1.id } ?? []
    }

    private func currentFailure(_ session: SessionItem) -> ChatFailure? {
        model.server(for: session.serverID)?.sessionFailures[session.id]
            ?? session.lastError.flatMap { ChatFailure.parse(.string($0)) }
    }

    private func isWorking(_ session: SessionItem) -> Bool {
        ChatActivity.showsWorking(status: session.status,
            awaitingInput: !permissions(for: session).isEmpty || !forms(for: session).isEmpty,
            connectionFailed: model.server(for: session.serverID)?.error != nil)
    }

    private func header(_ s: SessionItem) -> some View {
        HStack {
            Text(s.title).scaledFont(.headline).lineLimit(1)
            Text("· \(URL(fileURLWithPath: s.directory).lastPathComponent)")
                .scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            ProfileBadge(name: model.server(for: s.serverID)?.entry.profileName)
            StatusBadge(status: s.status)
            Menu {
                ForEach(TerminalLauncher.installed) { app in
                    Button {
                        TerminalLauncher.preferred = app
                        model.openInTerminal(s, app: app)
                    } label: {
                        if app == TerminalLauncher.preferred { Label(app.rawValue, systemImage: "checkmark") } else { Text(app.rawValue) }
                    }
                }
            } label: {
                Image(systemName: "terminal")
            } primaryAction: {
                model.openInTerminal(s)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Im Terminal öffnen (\(TerminalLauncher.preferred.rawValue)) – Pfeil für andere Terminals")
        }
        .padding(10)
    }

    private func composer(_ s: SessionItem) -> some View {
        let selection = ChatSelection(serverID: s.serverID, sessionID: s.id)
        let generation = model.chatViewGeneration
        let empty = model.draft(for: selection).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            SlashComposerField(onSubmit: { submit(for: selection, generation: generation) }, context: selection, generation: generation)
            HStack(spacing: 8) {
                agentMenu(s)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                modelMenu(s)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                Spacer()
                Text("↩ senden · ⌘↩ neue Zeile · / Befehle").scaledFont(.caption2).foregroundStyle(.tertiary)
                if s.status == .running {
                    Button { Task { await model.interrupt(for: selection) } } label: {
                        Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(Color.red.opacity(0.85), in: Circle())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain).help("Agent stoppen")
                }
                Button { submit(for: selection, generation: generation) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold))
                        .frame(width: 28, height: 28)
                        .background(empty ? Color.secondary.opacity(0.3) : Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(empty)
                .help("Senden (↩)")
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
    }

    @ViewBuilder
    private func agentMenu(_ s: SessionItem) -> some View {
        let agents = model.server(for: s.serverID)?.agents ?? []
        Menu {
            ForEach(agents) { a in
                Button { Task { await model.switchAgent(a.id, for: ChatSelection(serverID: s.serverID, sessionID: s.id)) } } label: {
                    if a.id == (s.agent ?? "build") { Label(a.name, systemImage: "checkmark") } else { Text(a.name) }
                }
            }
        } label: {
            Label(s.agent ?? "build", systemImage: "person.crop.circle")
        }
        .menuStyle(.borderlessButton).fixedSize().help("Agent wechseln")
    }

    @ViewBuilder
    private func modelMenu(_ s: SessionItem) -> some View {
        let conn = model.server(for: s.serverID)
        let current = s.model ?? conn?.defaultModel
        let models = conn?.models ?? []
        let currentUnconfirmed = current != nil && !models.contains(where: { $0.ref == current }) && conn?.modelsLoading != true
        Menu {
            if conn?.modelsLoading == true { Text("Modellfreigaben werden geprüft …").disabled(true) }
            ForEach(models) { m in
                Button { Task { await model.switchModel(m.ref, for: ChatSelection(serverID: s.serverID, sessionID: s.id)) } } label: {
                    if m.ref == current { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                }
                .disabled(conn?.modelsLoading == true)
            }
            if models.isEmpty && conn?.modelsLoading != true { Text("Keine bestätigten Modelle verfügbar").disabled(true) }
            if let error = conn?.modelsError { Text(error).disabled(true) }
            if let current, !models.contains(where: { $0.ref == current }), conn?.modelsLoading != true {
                Text("Aktuelles Modell: Freigabe nicht bestätigt").disabled(true)
            }
            Divider()
            Button("Modellliste aktualisieren") { Task { await conn?.refreshModels() } }
                .disabled(conn?.modelsLoading == true)
        } label: {
            HStack(spacing: 4) {
                Label(models.first { $0.ref == current }?.name ?? current?.id ?? "Modell", systemImage: "cpu")
                if conn?.modelsError != nil || currentUnconfirmed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help(conn?.modelsError ?? (currentUnconfirmed ? "Aktuelles Modell: Freigabe nicht bestätigt. Bestehende Auswahl bleibt unverändert." : "Modell wechseln – nur bestätigte Freigaben"))
    }

    private func watchModels(_ connection: ServerConnection?) async {
        guard !Task.isCancelled, let conn = connection, model.servers[conn.id] === conn else { return }
        await conn.refreshModels()
        // The first /api/model snapshot may precede plugin settlement.
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled, model.servers[conn.id] === conn else { return }
        await conn.refreshModels()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, model.servers[conn.id] === conn else { return }
            await conn.refreshModels()
        }
    }

    private func submit(for selection: ChatSelection, generation: UUID) {
        guard model.chatViewGeneration == generation else { return }
        let text = model.draft(for: selection).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.setDraft("", for: selection)
        Task { await model.send(text, to: selection) }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    /// Streaming/API parts can split one answer into adjacent text fragments.
    /// Keep these in a single native text document so selection doesn't stop there.
    private var displayParts: [ChatMessage.Part] {
        var result: [ChatMessage.Part] = []
        for part in message.parts {
            if case .text(let next) = part, case .text(let previous)? = result.last {
                result[result.count - 1] = .text(previous + next)
            } else {
                result.append(part)
            }
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.role == .user ? "Du" : "Agent")
                .scaledFont(.caption, bold: true).foregroundStyle(.secondary)
            ForEach(Array(displayParts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let text): MarkdownBlocks(text: text).environment(\.markdownMono, true)
                case .reasoning(let text):
                    DisclosureGroup("Gedanken") {
                        Text(text).scaledFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    .scaledFont(.caption)
                case .tool(let call): ToolCallRow(call: call)
                case .failure(let failure): ChatFailureCard(failure: failure)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? Color.accentColor.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ToolCallRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale
    let call: ToolCall
    private let expanded = State(initialValue: false)

    private var icon: (String, Color) {
        switch call.status {
        case "completed": ("checkmark.circle", .green)
        case "error": ("xmark.octagon", .red)
        default: ("circle.dotted", .blue)
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: expanded.projectedValue) {
            if !call.output.isEmpty {
                ScrollView {
                    Text(call.output.prefix(4000)).font(.system(size: 11 * scale, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon.0).foregroundStyle(icon.1)
                Text(call.name).scaledFont(.caption, bold: true, mono: true)
                Text(call.input).scaledFont(.caption, mono: true).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                if call.input.hasPrefix("/"), FileManager.default.fileExists(atPath: call.input) {
                    Button { model.openPreview(URL(fileURLWithPath: call.input)) } label: {
                        Image(systemName: "eye")
                    }
                    .buttonStyle(.borderless).help("Im Editor öffnen")
                }
            }
        }
    }
}

struct PermissionCard: View {
    @Environment(AppModel.self) private var model
    let request: PermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Blocker – Freigabe benötigt: \(request.action)", systemImage: "exclamationmark.triangle.fill")
                .scaledFont(.headline)
            if let msg = request.message { Text(msg) }
            ForEach(request.resources, id: \.self) { Text($0).scaledFont(.caption, mono: true) }
            HStack {
                Button("Einmal erlauben") { Task { await model.reply(request, decision: "once") } }
                Button("Immer erlauben") { Task { await model.reply(request, decision: "always") } }
                Button("Ablehnen", role: .destructive) { Task { await model.reply(request, decision: "reject") } }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.orange))
    }
}
