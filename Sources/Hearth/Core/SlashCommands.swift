import Foundation

/// One entry in the "/" autocomplete popup.
struct SlashItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case app, server, plugin, skill, argument }
    let id: String
    let title: String          // shown, e.g. "/model" or "Claude Sonnet 5.5"
    let detail: String?
    let insertion: String      // text that replaces the draft when accepted
    let kind: Kind
    /// Accepting runs the command immediately (no arguments needed).
    let runsImmediately: Bool
}

/// Built-in client commands mirroring OpenCode's TUI, plus server commands
/// (/init, /review, custom ones from the team config).
enum SlashCommands {
    struct AppCommand {
        let name: String
        let detail: String
        let takesArgument: Bool
    }

    static let app: [AppCommand] = [
        .init(name: "new", detail: "Neue Session in dieser Sandbox", takesArgument: false),
        .init(name: "model", detail: "Modell wechseln", takesArgument: true),
        .init(name: "agent", detail: "Agent wechseln", takesArgument: true),
        .init(name: "compact", detail: "Verlauf zusammenfassen (Kontext sparen)", takesArgument: false),
        .init(name: "stop", detail: "Laufende Arbeit abbrechen", takesArgument: false),
        .init(name: "rename", detail: "Session umbenennen", takesArgument: true),
        .init(name: "terminal", detail: "Session im Terminal öffnen", takesArgument: false),
        .init(name: "help", detail: "Verfügbare Befehle anzeigen", takesArgument: false),
    ]

    /// Suggestions for the current draft, or empty when no popup should show.
    static func suggestions(draft: String, server: [(name: String, description: String?)],
                            plugins: [PluginCommand] = [],
                            skills: [SkillInfo] = [],
                            models: [ModelInfo], agents: [AgentInfo]) -> [SlashItem] {
        guard draft.hasPrefix("/"), !draft.contains("\n") else { return [] }
        let body = draft.dropFirst()
        if let space = body.firstIndex(of: " ") {
            // Argument completion for /model and /agent.
            let name = String(body[..<space]).lowercased()
            let arg = body[body.index(after: space)...].lowercased()
            switch name {
            case "model":
                return models.filter { arg.isEmpty || $0.name.lowercased().contains(arg) || $0.ref.key.lowercased().contains(arg) }
                    .prefix(30).map {
                        SlashItem(id: "m:" + $0.id, title: $0.name, detail: $0.ref.key,
                                  insertion: "/model \($0.ref.key)", kind: .argument, runsImmediately: true)
                    }
            case "agent":
                return agents.filter { arg.isEmpty || $0.id.lowercased().contains(arg) || $0.name.lowercased().contains(arg) }
                    .map {
                        SlashItem(id: "a:" + $0.id, title: $0.name, detail: $0.description,
                                  insertion: "/agent \($0.id)", kind: .argument, runsImmediately: true)
                    }
            default:
                return []
            }
        }
        let query = body.lowercased()
        var items: [SlashItem] = []
        let appNames = Set(app.map(\.name))
        for c in app where query.isEmpty || c.name.hasPrefix(query) || c.name.contains(query) {
            items.append(SlashItem(id: "app:" + c.name, title: "/" + c.name, detail: c.detail,
                                   insertion: "/" + c.name + (c.takesArgument ? " " : ""), kind: .app,
                                   runsImmediately: !c.takesArgument))
        }
        for c in server where !appNames.contains(c.name) && (query.isEmpty || c.name.lowercased().contains(query)) {
            items.append(SlashItem(id: "srv:" + c.name, title: "/" + c.name, detail: c.description,
                                   insertion: "/" + c.name + " ", kind: .server, runsImmediately: false))
        }
        let taken = appNames.union(server.map(\.name))
        for p in plugins where !taken.contains(p.name) && (query.isEmpty || p.name.lowercased().contains(query)) {
            let native = PluginCommands.native.contains(p.name)
            items.append(SlashItem(id: "plg:" + p.name, title: "/" + p.name,
                                   detail: (p.title ?? "Plugin-Befehl") + (native ? "" : " · öffnet im Terminal"),
                                   insertion: "/" + p.name, kind: .plugin, runsImmediately: true))
        }
        let used = taken.union(plugins.map(\.name))
        for s in skills where !used.contains(s.slug)
            && (query.isEmpty || s.slug.contains(query) || s.name.lowercased().contains(query)) {
            items.append(SlashItem(id: "skl:" + s.id, title: "/" + s.slug,
                                   detail: s.description.map { String($0.prefix(90)) } ?? "Skill \(s.name)",
                                   insertion: "/" + s.slug + " ", kind: .skill, runsImmediately: false))
        }
        // Exact and prefix matches first.
        return items.sorted { a, b in
            func rank(_ i: SlashItem) -> Int {
                let n = String(i.title.dropFirst()).lowercased()
                return n == query ? 0 : (n.hasPrefix(query) ? 1 : 2)
            }
            func group(_ i: SlashItem) -> Int {
                switch i.kind { case .app: 0; case .server: 1; case .plugin: 2; case .skill: 3; case .argument: 4 }
            }
            return (rank(a), group(a), a.title) < (rank(b), group(b), b.title)
        }
    }

    /// Splits "/name rest of line" into (name, arguments).
    static func parse(_ text: String) -> (name: String, arguments: String)? {
        guard text.hasPrefix("/") else { return nil }
        let body = text.dropFirst()
        let name = body.prefix { !$0.isWhitespace }
        guard !name.isEmpty else { return nil }
        return (String(name), body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
