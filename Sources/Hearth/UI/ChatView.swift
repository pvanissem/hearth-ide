import SwiftUI

/// The chat area: the selected agent session as a terminal (AgentRunView), or a start hint.
struct ChatView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let run = model.agents.selectedRun {
            AgentRunView(run: run).id(run.id)
        } else {
            ContentUnavailableView {
                Label("No session selected", systemImage: "flame")
            } description: {
                Text("Select an agent session on the left or start an agent in a project folder.")
            } actions: {
                Button("Start agent…") { model.agents.startSheet = .init() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
