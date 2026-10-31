import SwiftUI

/// Chat input with "/" command autocomplete (↑/↓ select, Tab/↩ accept, Esc close).
struct SlashComposerField: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var scale
    let onSubmit: () -> Void
    let context: ChatSelection
    let generation: UUID

    private let selection = State(initialValue: 0)
    private let dismissedFor = State(initialValue: String?.none)
    private let inputHeight = State(initialValue: CGFloat(62))

    private var suggestions: [SlashItem] {
        guard model.chatViewGeneration == generation else { return [] }
        guard dismissedFor.wrappedValue != model.draft else { return [] }
        return model.slashSuggestions(for: model.draft)
    }

    var body: some View {
        let items = suggestions
        VStack(alignment: .leading, spacing: 6) {
            if !items.isEmpty {
                popup(items)
            }
            ComposerTextView(
                text: Binding(get: { model.draft(for: context) }, set: {
                    guard model.chatViewGeneration == generation else { return }
                    model.setDraft($0, for: context); selection.wrappedValue = 0
                }),
                height: inputHeight.projectedValue,
                placeholder: "Was soll der Agent als Nächstes tun?  (↩ senden · ⇧↩ neue Zeile)",
                fontSize: 14 * scale,
                onKey: { key in handle(key, items) })
                .frame(height: inputHeight.wrappedValue)
        }
    }

    private func popup(_ items: [SlashItem]) -> some View {
        let sel = min(selection.wrappedValue, items.count - 1)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        HStack(spacing: 8) {
                            Image(systemName: icon(item))
                                .foregroundStyle(item.kind == .server ? Color.purple : (item.kind == .plugin ? Color.orange : (item.kind == .skill ? Color.teal : Color.accentColor)))
                                .frame(width: 16)
                            Text(item.title).font(.callout.monospaced().bold())
                            if let d = item.detail {
                                Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if item.kind == .server {
                                Text("OpenCode").font(.caption2).foregroundStyle(.purple)
                            } else if item.kind == .plugin {
                                Text("Plugin").font(.caption2).foregroundStyle(.orange)
                            } else if item.kind == .skill {
                                Text("Skill").font(.caption2).foregroundStyle(.teal)
                            }
                        }
                        .id(i)
                        .interactiveRow(selected: i == sel) {
                            selection.wrappedValue = i
                            _ = accept(items, run: true)
                        }
                    }
                }
                .padding(4)
            }
            .frame(maxHeight: min(CGFloat(items.count) * 30 + 8, 240))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
            .onChange(of: sel) { proxy.scrollTo(sel) }
        }
    }

    private func icon(_ item: SlashItem) -> String {
        switch item.kind {
        case .app: "command"
        case .server: "sparkles"
        case .plugin: "puzzlepiece.extension"
        case .skill: "graduationcap"
        case .argument: item.id.hasPrefix("m:") ? "cpu" : "person.crop.circle"
        }
    }

    /// Keys from the native input. Returns false to let the text view handle them.
    private func handle(_ key: ComposerTextView.Key, _ items: [SlashItem]) -> Bool {
        guard model.chatViewGeneration == generation else { return key == .submit }
        switch key {
        case .submit:
            // ↩ accepts a "/" suggestion if the popup is open, otherwise sends.
            if !items.isEmpty { _ = accept(items, run: true) } else { onSubmit() }
            return true
        case .up: return move(-1, items) == .handled
        case .down: return move(1, items) == .handled
        case .tab: return accept(items, run: false) == .handled
        case .escape:
            guard !items.isEmpty else { return false }
            dismissedFor.wrappedValue = model.draft
            return true
        }
    }

    private func move(_ delta: Int, _ items: [SlashItem]) -> KeyPress.Result {
        guard !items.isEmpty else { return .ignored }
        selection.wrappedValue = (min(selection.wrappedValue, items.count - 1) + delta + items.count) % items.count
        return .handled
    }

    /// Completes the draft; commands without arguments (and picked models/agents) run right away on ↩/click.
    private func accept(_ items: [SlashItem], run: Bool) -> KeyPress.Result {
        guard !items.isEmpty, model.chatViewGeneration == generation else { return .ignored }
        let item = items[min(selection.wrappedValue, items.count - 1)]
        model.setDraft(item.insertion, for: context)
        selection.wrappedValue = 0
        if run && item.runsImmediately {
            onSubmit()
        }
        return .handled
    }
}
