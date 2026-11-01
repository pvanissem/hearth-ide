import SwiftUI
import AppKit

/// Left column: every agent session, the ones that need attention first.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    private let onlyAttention = State(initialValue: false)

    var body: some View {
        let runs = model.agents.sorted
        let attention = runs.filter { $0.status.priority <= AgentStatus.done.priority }
        let shown = onlyAttention.wrappedValue ? attention : runs

        List(selection: Binding(
            get: { model.agents.selectedRunID.map { "run:" + $0 } },
            set: { id in
                if let id, id.hasPrefix("run:") { model.selectRun(String(id.dropFirst(4))) }
            })) {
            Section {
                if attention.isEmpty {
                    Text("Alles ruhig – kein Agent wartet.").foregroundStyle(.secondary).scaledFont(.callout)
                } else {
                    Text("\(attention.count) Sitzungen mit Ergebnissen, Rückfragen oder Fehlern.")
                        .scaledFont(.caption).foregroundStyle(.secondary)
                }
                if !attention.isEmpty || onlyAttention.wrappedValue {
                    Button(onlyAttention.wrappedValue ? "Alle Sitzungen anzeigen" : "Nur diese Sitzungen anzeigen") {
                        onlyAttention.wrappedValue.toggle()
                    }
                    .buttonStyle(.link).scaledFont(.caption)
                }
            } header: {
                Text("Braucht Aufmerksamkeit (\(attention.count))\(onlyAttention.wrappedValue ? " · Filter aktiv" : "")")
                    .scaledFont(.caption, bold: true)
            }

            Section {
                if runs.isEmpty {
                    Button { model.agents.startSheet = .init() } label: {
                        Label("Agent starten …", systemImage: "plus.circle")
                    }
                    .buttonStyle(.link).scaledFont(.callout)
                }
                ForEach(shown) { run in
                    AgentRunRow(run: run).tag("run:" + run.id)
                }
            } header: {
                HStack {
                    Text("Agenten (\(model.agents.runningCount) aktiv)").scaledFont(.caption, bold: true)
                    Spacer()
                    Button { model.agents.startSheet = .init() } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless).help("Agent starten")
                }
                .textCase(nil)
            }
        }
        .listStyle(.sidebar)
        // Opaque like every other pane; the sidebar style alone draws a translucent vibrancy material.
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct StatusBadge: View {
    @Environment(\.textScale) private var scale
    let status: AgentStatus

    var color: Color {
        switch status {
        case .running: .blue
        case .needsInput: .orange
        case .blocked: .red
        case .done: .green
        case .idle, .inactive: .secondary
        }
    }

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 9 * scale, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}
