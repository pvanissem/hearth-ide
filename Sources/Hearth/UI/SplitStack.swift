import SwiftUI
import AppKit

/// Split container with draggable dividers whose relative sizes are stored in
/// the app model (unlike VSplitView/HSplitView, whose positions can't be read back).
struct SplitStack<Content: View>: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let axis: SplitAxis
    let count: Int
    @ViewBuilder let content: (Int) -> Content

    static var minFraction: Double { 0.08 }
    private let dividerThickness: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let total = Double(axis == .vertical ? geo.size.height : geo.size.width)
                - Double(dividerThickness) * Double(count - 1)
            let w = model.layout.weights(for: id, count: count)
            let layout = axis == .vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                ForEach(0..<count, id: \.self) { i in
                    content(i)
                        .frame(width: axis == .horizontal ? max(0, total * w[i]) : nil,
                               height: axis == .vertical ? max(0, total * w[i]) : nil)
                        .clipped()
                    if i < count - 1 {
                        SplitDivider(axis: axis) { delta in
                            resize(at: i, delta: delta, total: total)
                        } onReset: {
                            model.layout.splitWeights[id] = nil
                        }
                        .frame(width: axis == .horizontal ? dividerThickness : nil,
                               height: axis == .vertical ? dividerThickness : nil)
                    }
                }
            }
        }
    }

    private func resize(at i: Int, delta: CGFloat, total: Double) {
        guard total > 0 else { return }
        var w = model.layout.weights(for: id, count: count)
        let d = Double(delta) / total
        let pair = w[i] + w[i + 1]
        let left = min(max(w[i] + d, Self.minFraction), pair - Self.minFraction)
        w[i] = left
        w[i + 1] = pair - left
        model.layout.splitWeights[id] = w
    }
}

private struct SplitDivider: View {
    let axis: SplitAxis
    let onDrag: (CGFloat) -> Void
    let onReset: () -> Void
    private let hovering = State(initialValue: false)
    private let last = State(initialValue: CGFloat.zero)

    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear)
            Rectangle()
                .fill(hovering.wrappedValue ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
                .frame(width: axis == .horizontal ? (hovering.wrappedValue ? 2 : 1) : nil,
                       height: axis == .vertical ? (hovering.wrappedValue ? 2 : 1) : nil)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering.wrappedValue = inside
            if inside {
                (axis == .vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let pos = axis == .vertical ? g.translation.height : g.translation.width
                    onDrag(pos - last.wrappedValue)
                    last.wrappedValue = pos
                }
                .onEnded { _ in last.wrappedValue = 0 }
        )
        .onTapGesture(count: 2, perform: onReset)
        .help("Drag to resize · double-click: distribute evenly")
    }
}
