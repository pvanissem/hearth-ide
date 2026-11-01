import SwiftUI

/// The chat area: the selected agent session as a terminal (AgentRunView), or a start hint.
struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let run = model.agents.selectedRun {
            AgentRunView(run: run).id(run.id)
        } else {
            ContentUnavailableView {
                Label("Keine Sitzung ausgewählt", systemImage: "flame")
            } description: {
                Text("Wähle links eine Agenten-Sitzung oder starte einen Agenten in einem Projektordner.")
            } actions: {
                Button("Agent starten …") { model.agents.startSheet = .init() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
