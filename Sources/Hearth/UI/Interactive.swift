import SwiftUI
import AppKit

/// Shared mouse feedback for clickable rows in the inspector:
/// hover highlight, pressed state, selection accent and a pointing-hand cursor.
/// Built on Button so clicks are delivered reliably (an extra drag gesture for
/// the pressed state swallowed taps on macOS).
struct InteractiveRow: ViewModifier {
    var selected = false
    let action: () -> Void
    private let hovering = State(initialValue: false)

    init(selected: Bool = false, action: @escaping () -> Void) {
        self.selected = selected
        self.action = action
    }

    func body(content: Content) -> some View {
        Button(action: action) {
            content
                .padding(.horizontal, 6).padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(selected: selected, hovering: hovering.wrappedValue))
        .onHover { inside in
            hovering.wrappedValue = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

private struct RowButtonStyle: ButtonStyle {
    let selected: Bool
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 5))
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 2.5).padding(.vertical, 2)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }

    private func background(pressed: Bool) -> Color {
        if pressed { return Color.accentColor.opacity(0.25) }
        if selected { return Color.accentColor.opacity(0.15) }
        if hovering { return Color.primary.opacity(0.07) }
        return .clear
    }
}

extension View {
    func interactiveRow(selected: Bool = false, action: @escaping () -> Void) -> some View {
        modifier(InteractiveRow(selected: selected, action: action))
    }

    /// Dims content and shows a spinner while an operation runs.
    func busyOverlay(_ busy: Bool, label: String? = nil) -> some View {
        overlay {
            if busy {
                ZStack {
                    Rectangle().fill(.background.opacity(0.6))
                    VStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        if let label { Text(label).font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: busy)
    }
}

/// Context menu items shared by every file reference in the inspector.
struct FileContextMenu: View {
    @Environment(AppModel.self) private var model
    let url: URL
    var changed = false

    var body: some View {
        Button { model.openPreview(url, mode: .file) } label: { Label("Im Editor öffnen", systemImage: "doc.text") }
        if changed {
            Button { model.openPreview(url, mode: .diff) } label: { Label("Diff anzeigen", systemImage: "plusminus") }
        }
        Button { NSWorkspace.shared.open(url) } label: { Label("Im Standardprogramm öffnen", systemImage: "arrow.up.forward.app") }
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: { Label("Im Finder zeigen", systemImage: "folder") }
        Divider()
        Button { copy(url.path) } label: { Label("Pfad kopieren", systemImage: "doc.on.doc") }
        if let root = model.workspaceRoot, url.path.hasPrefix(root) {
            Button { copy(String(url.path.dropFirst(root.count + 1))) } label: {
                Label("Relativen Pfad kopieren", systemImage: "doc.on.doc")
            }
        }
        Button { model.mention(url) } label: { Label("Im Chat erwähnen", systemImage: "text.bubble") }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        model.toast("In Zwischenablage kopiert")
    }
}
