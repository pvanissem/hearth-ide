import SwiftUI
import AppKit

/// Areas with their own text size.
enum TextArea: Hashable {
    case chat, inspector, sidebar
    /// A single pane; falls back to its area's size until zoomed on its own.
    case pane(UUID, InspectorTab)

    static let allCases: [TextArea] = [.chat, .inspector, .sidebar]

    var rawValue: String {
        switch self {
        case .chat: "chat"
        case .inspector: "inspector"
        case .sidebar: "sidebar"
        case .pane(let id, _): "pane:\(id.uuidString)"
        }
    }

    /// Area whose size a pane inherits.
    var base: TextArea {
        guard case .pane(_, let tab) = self else { return self }
        switch tab {
        case .sessions: return .sidebar
        case .chat: return .chat
        default: return .inspector
        }
    }
}

private struct TextScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1
}

extension EnvironmentValues {
    /// Multiplier for font sizes in the current area (⌘-scroll / pinch zoom).
    var textScale: Double {
        get { self[TextScaleKey.self] }
        set { self[TextScaleKey.self] = newValue }
    }
}

extension View {
    /// Makes a region zoomable: base font scales, hover tells the event monitor which area to zoom.
    func zoomableText(_ area: TextArea, model: AppModel, baseSize: CGFloat = 13) -> some View {
        let scale = model.textZoom.scale(area)
        return self
            .environment(\.textScale, scale)
            .font(.system(size: baseSize * scale))
            .onContinuousHover { phase in
                switch phase {
                case .active: model.textZoom.hoveredArea = area
                case .ended: if model.textZoom.hoveredArea == area { model.textZoom.hoveredArea = nil }
                }
            }
    }
}

/// Global ⌘-scroll and pinch handling, routed to the area under the mouse.
@MainActor
final class TextZoomMonitor {
    private var monitor: Any?
    private weak var model: AppModel?
    private var scrollAccumulator: CGFloat = 0

    init(model: AppModel) {
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            guard let self, let model = self.model else { return event }
            // Diagrams handle their own pinch/⌘-scroll zoom.
            guard !model.textZoom.hoveringDiagram, let area = model.textZoom.hoveredArea else { return event }
            switch event.type {
            case .magnify:
                model.textZoom.zoom(area, by: 1 + event.magnification)
                return nil
            case .scrollWheel where event.modifierFlags.contains(.command):
                // Trackpads send many small precise deltas, mouse wheels a few big ones.
                let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
                self.scrollAccumulator += delta
                if abs(self.scrollAccumulator) >= 8 {
                    model.textZoom.zoom(area, by: self.scrollAccumulator > 0 ? 1.06 : 1 / 1.06)
                    self.scrollAccumulator = 0
                }
                return nil
            default:
                return event
            }
        }
    }
}

/// Text-style font that follows the area's zoom factor (macOS text styles are fixed-size).
struct ScaledFont: ViewModifier {
    @Environment(\.textScale) private var scale
    let style: Font.TextStyle
    var bold = false
    var mono = false
    var digits = false

    static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        case .footnote, .caption: 10
        case .caption2: 10
        @unknown default: 13
        }
    }

    func body(content: Content) -> some View {
        var font = Font.system(size: Self.baseSize(style) * scale,
                               weight: bold || style == .headline ? .bold : .regular,
                               design: mono ? .monospaced : .default)
        if digits { font = font.monospacedDigit() }
        return content.font(font)
    }
}

extension View {
    func scaledFont(_ style: Font.TextStyle, bold: Bool = false, mono: Bool = false, digits: Bool = false) -> some View {
        modifier(ScaledFont(style: style, bold: bold, mono: mono, digits: digits))
    }
}
